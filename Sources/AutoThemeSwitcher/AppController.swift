import AppKit
import AutoThemeSwitcherCore
import Combine
import Foundation

@MainActor
final class AppController: ObservableObject {
    private enum PreferenceKey {
        static let currentMode = "currentThemeMode"
    }

    private enum SwitchOrigin {
        case automatic
        case manual

        var successDescription: String {
            switch self {
            case .automatic: "已根据环境光自动切换"
            case .manual: "已手动切换"
            }
        }
    }

    let preferences: AppPreferences

    @Published private(set) var currentLux: Double?
    @Published private(set) var smoothedLux: Double?
    @Published private(set) var sensorStatus = "正在检查…"
    @Published private(set) var vscodeStatus = "正在检查…"
    @Published private(set) var ghosttyStatus = "正在检查…"
    @Published private(set) var loginItemStatus = "正在检查…"
    @Published private(set) var candidateProgressLabel: String?
    @Published private(set) var statusMessage = "正在进行只读检查…"
    @Published private(set) var hasError = false
    @Published private(set) var isWorking = true
    @Published private(set) var displayedMode: ThemeMode

    var menuBarSymbol: String {
        if hasError { return "exclamationmark.triangle.fill" }
        return displayedMode == .light ? "sun.max.fill" : "moon.fill"
    }

    var modeLabel: String {
        displayedMode == .light ? "室外亮色" : "室内暗色"
    }

    private let paths: AppPaths
    private let defaults: UserDefaults
    private let ambientLightProvider: any AmbientLightProvider
    private let adapters: [any RestorableThemeAdapter]
    private let transactionCoordinator: ThemeTransactionCoordinator

    private var automationEngine: AutomationEngine
    private var inspections: [String: ThemeInspection] = [:]
    private var inspectionFailures: [String: String] = [:]
    private var sensorInfo: AmbientLightSensorInfo?
    private var sensorIsDiscovered = false
    private var isSleeping = false
    private var nextSensorDiscoveryAt: TimeInterval = 0
    private var sensorRetryDelay: TimeInterval = 1
    private var sensorErrorMessage: String?
    private var integrationErrorMessage: String?
    private var operationMessage: String?
    private var operationErrorMessage: String?
    private var workingMessage: String?
    private var transactionRecoveryBlocked = false
    private var transactionRecoveryErrorMessage: String?
    private var samplingTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var preferencesCancellable: AnyCancellable?

    convenience init() {
        let paths = AppPaths.currentUser()
        let defaults = UserDefaults.standard
        let initialMode = defaults.string(forKey: PreferenceKey.currentMode)
            .flatMap(ThemeMode.init(rawValue:)) ?? .dark
        let vscode = VSCodeThemeAdapter(
            settingsURL: paths.vscodeSettings,
            backupDirectoryURL: paths.backupDirectory
                .appendingPathComponent("VSCode", isDirectory: true)
        )
        let ghostty = GhosttyThemeAdapter(
            configuration: GhosttyConfiguration(mainConfigURL: paths.ghosttyConfiguration),
            validator: GhosttyCLIConfigValidator(executableURL: paths.ghosttyExecutable)
        )

        self.init(
            preferences: AppPreferences(defaults: defaults),
            paths: paths,
            defaults: defaults,
            ambientLightProvider: IOKitAmbientLightProvider(),
            adapters: [ghostty, vscode],
            initialMode: initialMode
        )
    }

    init(
        preferences: AppPreferences,
        paths: AppPaths,
        defaults: UserDefaults,
        ambientLightProvider: any AmbientLightProvider,
        adapters: [any RestorableThemeAdapter],
        initialMode: ThemeMode
    ) {
        self.preferences = preferences
        self.paths = paths
        self.defaults = defaults
        self.ambientLightProvider = ambientLightProvider
        self.adapters = adapters
        displayedMode = initialMode
        automationEngine = AutomationEngine(initialMode: initialMode)

        let journal = FileThemeTransactionJournal(
            fileURL: paths.applicationSupportDirectory
                .appendingPathComponent("transaction-journal.json", isDirectory: false)
        )
        do {
            transactionCoordinator = try ThemeTransactionCoordinator(
                adapters: adapters.map { $0 as any ThemeAdapter },
                journal: journal
            )
        } catch {
            // 默认依赖不会重复。保留显式失败，避免以缺少事务保护的方式继续写配置。
            fatalError("无法创建主题事务协调器：\(error.localizedDescription)")
        }

        observePreferences()
        observeSystemLifecycle()
        Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
    }

    deinit {
        samplingTask?.cancel()
        ambientLightProvider.invalidate()
    }

    func setAutomaticEnabled(_ enabled: Bool) {
        preferences.automaticEnabled = enabled
        if !enabled {
            automationEngine.cancelPendingThemeChange()
            updateDisplayedReadings(from: automationEngine.snapshot(at: systemUptime))
            operationMessage = "已暂停自动切换"
            operationErrorMessage = nil
        } else {
            operationMessage = integrationInstalled
                ? "已开启自动切换"
                : "自动模式已开启；安装集成前不会修改配置"
            operationErrorMessage = nil
        }
        refreshSummary()
    }

    func switchManually(to mode: ThemeMode) {
        guard !isWorking else { return }
        preferences.automaticEnabled = false
        automationEngine.cancelPendingThemeChange()

        guard !transactionRecoveryBlocked else {
            presentOperationError("上次事务无法安全恢复；已禁止继续写配置，请先处理事务日志。")
            return
        }
        guard integrationInstalled else {
            presentOperationError("集成尚未安装或存在冲突，请先点“安装或修复集成”。")
            return
        }
        beginThemeSwitch(to: mode, origin: .manual)
    }

    func installIntegration() {
        guard !isWorking else { return }
        guard !transactionRecoveryBlocked else {
            presentOperationError("上次事务无法安全恢复；已禁止继续写配置，请先处理事务日志。")
            return
        }
        do {
            try paths.prepareOwnedDirectories()
            // 为两个适配器预留互不重叠的自有目录；Ghostty v1 不需要整文件备份。
            try FileManager.default.createDirectory(
                at: paths.backupDirectory.appendingPathComponent("VSCode", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: paths.backupDirectory.appendingPathComponent("Ghostty", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            presentOperationError("无法准备 App 支持目录：\(error.localizedDescription)")
            return
        }

        isWorking = true
        workingMessage = "正在验证并安装两款应用的集成…"
        operationErrorMessage = nil
        refreshSummary()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await transactionCoordinator.switchTheme(
                    to: displayedMode,
                    allowInstallation: true
                )
                automationEngine.setCurrentMode(
                    displayedMode,
                    at: systemUptime,
                    countsAsSwitch: false
                )
                persistCurrentMode(displayedMode)

                var loginWarning: String?
                if preferences.launchAtLogin {
                    do {
                        try LoginItemManager.setEnabled(true)
                    } catch {
                        loginWarning = "集成已安装，但登录启动注册失败：\(error.localizedDescription)"
                    }
                }
                refreshLoginItemStatus()

                var warnings = [String]()
                if let reloadWarning = pendingReloadMessage(in: result) {
                    warnings.append(reloadWarning)
                }
                if let loginWarning {
                    warnings.append(loginWarning)
                }
                operationMessage = "VS Code 与 Ghostty 集成已安装并验证"
                operationErrorMessage = warnings.isEmpty
                    ? nil
                    : warnings.joined(separator: "；")
            } catch {
                operationMessage = nil
                operationErrorMessage = error.localizedDescription
            }
            isWorking = false
            workingMessage = nil
            inspectIntegrations(syncDetectedMode: false)
            refreshSummary()
        }
    }

    func restoreAndDisable() {
        guard !isWorking else { return }
        preferences.automaticEnabled = false
        automationEngine.cancelPendingThemeChange()

        isWorking = true
        workingMessage = "正在恢复暗色配置并移除集成…"
        operationErrorMessage = nil
        refreshSummary()

        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var restorationNotice: String?

            do {
                guard !transactionRecoveryBlocked else {
                    throw ControllerError.recoveryBlocked
                }
                guard integrationInstalled else {
                    throw ControllerError.integrationNotReady
                }
                let result = try await transactionCoordinator.restoreIntegrations()
                automationEngine.setCurrentMode(.dark, at: systemUptime)
                displayedMode = .dark
                persistCurrentMode(.dark)
                var notices = [String]()
                if result.receipts.contains(where: {
                    $0.change.metadata["preservedCustomizedLightFile"] == "true"
                }) {
                    notices.append("已保留用户定制的 Ghostty 亮色文件")
                }
                if let reloadWarning = pendingReloadMessage(in: result) {
                    notices.append(reloadWarning)
                }
                if !notices.isEmpty {
                    restorationNotice = notices.joined(separator: "；")
                }
            } catch {
                failures.append(error.localizedDescription)
            }

            do {
                try LoginItemManager.setEnabled(false)
                preferences.launchAtLogin = false
            } catch {
                failures.append("关闭登录启动失败：\(error.localizedDescription)")
            }
            refreshLoginItemStatus()

            if failures.isEmpty {
                operationMessage = [
                    "已恢复暗色配置、移除集成并停用自动切换",
                    restorationNotice
                ].compactMap { $0 }.joined(separator: "；")
                operationErrorMessage = nil
            } else {
                operationMessage = nil
                operationErrorMessage = failures.joined(separator: "；")
            }
            isWorking = false
            workingMessage = nil
            inspectIntegrations(syncDetectedMode: false)
            refreshSummary()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isWorking else { return }
        do {
            try LoginItemManager.setEnabled(enabled)
            preferences.launchAtLogin = enabled
            operationMessage = enabled ? "已启用登录时启动" : "已关闭登录时启动"
            operationErrorMessage = nil
        } catch {
            preferences.launchAtLogin = LoginItemManager.isEnabled
            operationMessage = nil
            operationErrorMessage = "修改登录启动失败：\(error.localizedDescription)"
        }
        refreshLoginItemStatus()
        refreshSummary()
    }

    func openVSCodeConfiguration() {
        openExistingItem(paths.vscodeSettings, description: "VS Code 配置")
    }

    func openGhosttyConfiguration() {
        openExistingItem(paths.ghosttyConfiguration, description: "Ghostty 配置")
    }

    func openBackupDirectory() {
        openExistingItem(paths.backupDirectory, description: "备份目录")
    }

    func copyDiagnostics() {
        let processInfo = ProcessInfo.processInfo
        let sensorDescription: String
        if let sensorInfo {
            sensorDescription = "\(sensorInfo.registryName), id=\(sensorInfo.registryEntryID), builtIn=\(sensorInfo.isBuiltIn)"
        } else {
            sensorDescription = "unavailable"
        }

        let rawLuxText = currentLux.map { String($0) } ?? "unavailable"
        let filteredLuxText = smoothedLux.map { String($0) } ?? "unavailable"
        let journalPath = paths.applicationSupportDirectory
            .appendingPathComponent("transaction-journal.json", isDirectory: false)
            .path
        var lines = [String]()
        lines.append(contentsOf: [
            "Auto Theme Switcher 诊断摘要",
            "系统：\(processInfo.operatingSystemVersionString)",
            "当前模式：\(displayedMode.rawValue)",
            "自动切换：\(preferences.automaticEnabled)",
            "实时 lux：\(rawLuxText)",
            "平滑 lux：\(filteredLuxText)",
            "阈值：indoor=\(preferences.indoorThreshold), outdoor=\(preferences.outdoorThreshold), stable=\(preferences.stabilitySeconds)s, dwell=\(preferences.minimumDwellSeconds)s",
            "传感器：\(sensorDescription)",
            "传感器状态：\(sensorStatus)",
            "VS Code：\(safeAdapterDiagnostic(identifier: "vscode"))",
            "Ghostty：\(safeAdapterDiagnostic(identifier: "ghostty"))",
            "VS Code 路径：\(paths.vscodeSettings.path)",
            "Ghostty 路径：\(paths.ghosttyConfiguration.path)",
            "事务日志路径：\(journalPath)"
        ])
        let summary = lines.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        operationMessage = "诊断摘要已复制（不包含配置文件内容）"
        operationErrorMessage = nil
        refreshSummary()
    }

    private func bootstrap() async {
        workingMessage = "正在只读检查配置并检查事务日志…"
        refreshSummary()
        inspectIntegrations(syncDetectedMode: true)
        refreshLoginItemStatus()

        // 无 journal 时此调用零写入；仅对崩溃留下的半完成事务执行 CAS 安全回滚。
        do {
            let recovered = try await transactionCoordinator.recoverInterruptedTransaction()
            if recovered {
                operationMessage = "已安全恢复上次未完成的主题事务"
                inspectIntegrations(syncDetectedMode: true)
            }
            transactionRecoveryBlocked = false
            transactionRecoveryErrorMessage = nil
        } catch {
            transactionRecoveryBlocked = true
            transactionRecoveryErrorMessage = error.localizedDescription
            operationMessage = nil
            operationErrorMessage = "上次事务恢复失败，已禁止自动写入：\(error.localizedDescription)"
        }

        _ = discoverSensor(at: systemUptime, force: true)
        startSampling()
        isWorking = false
        workingMessage = nil
        refreshSummary()
    }

    private func beginThemeSwitch(to mode: ThemeMode, origin: SwitchOrigin) {
        isWorking = true
        workingMessage = "正在切换为\(mode == .light ? "亮色" : "暗色")…"
        operationErrorMessage = nil
        refreshSummary()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await transactionCoordinator.switchTheme(to: mode)
                if origin == .automatic {
                    _ = automationEngine.confirmThemeChange(to: mode, at: systemUptime)
                } else {
                    automationEngine.setCurrentMode(mode, at: systemUptime)
                }
                displayedMode = mode
                persistCurrentMode(mode)
                operationMessage = "\(origin.successDescription)为\(mode == .light ? "亮色" : "暗色")"
                operationErrorMessage = pendingReloadMessage(in: result)
            } catch {
                automationEngine.cancelPendingThemeChange()
                operationMessage = nil
                operationErrorMessage = error.localizedDescription
            }
            isWorking = false
            workingMessage = nil
            inspectIntegrations(syncDetectedMode: false)
            updateDisplayedReadings(from: automationEngine.snapshot(at: systemUptime))
            refreshSummary()
        }
    }

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sampleOnce()
                do {
                    try await Task.sleep(for: .seconds(AutomationEngine.recommendedSamplingInterval))
                } catch {
                    return
                }
            }
        }
    }

    private func sampleOnce() {
        guard !isSleeping else { return }
        let uptime = systemUptime

        if !sensorIsDiscovered {
            guard uptime >= nextSensorDiscoveryAt else {
                updateSensorRetryStatus(at: uptime)
                return
            }
            guard discoverSensor(at: uptime, force: false) else { return }
        }

        do {
            let lux = try ambientLightProvider.readLux()
            sensorErrorMessage = nil
            sensorStatus = sensorInfo.map { "可用 · \($0.registryName)" } ?? "可用"

            let configurationIsValid = updateAutomationConfigurationIfValid()
            let update = automationEngine.process(lux: lux, at: uptime)
            let automationMayWrite = preferences.automaticEnabled
                && configurationIsValid
                && integrationInstalled
                && themesAreAligned
                && !transactionRecoveryBlocked

            if !automationMayWrite {
                // 继续维护中位数用于菜单显示，但清除候选/待提交状态，确保未安装时绝不写。
                automationEngine.setCurrentMode(
                    displayedMode,
                    at: uptime,
                    countsAsSwitch: false
                )
            }

            let snapshot = automationEngine.snapshot(at: uptime)
            updateDisplayedReadings(from: snapshot)
            if automationMayWrite, let requestedMode = update.requestedMode, !isWorking {
                beginThemeSwitch(to: requestedMode, origin: .automatic)
            }
        } catch {
            handleSensorFailure(error, at: uptime)
        }
        refreshSummary()
    }

    @discardableResult
    private func discoverSensor(at uptime: TimeInterval, force: Bool) -> Bool {
        guard force || uptime >= nextSensorDiscoveryAt else { return false }
        do {
            let info = try ambientLightProvider.discover()
            sensorInfo = info
            sensorIsDiscovered = true
            sensorRetryDelay = 1
            nextSensorDiscoveryAt = 0
            sensorErrorMessage = nil
            sensorStatus = "可用 · \(info.registryName)"
            return true
        } catch {
            scheduleSensorRediscovery(after: error, at: uptime)
            return false
        }
    }

    private func handleSensorFailure(_ error: Error, at uptime: TimeInterval) {
        ambientLightProvider.invalidate()
        sensorInfo = nil
        sensorIsDiscovered = false
        automationEngine.handleSensorFailure()
        updateDisplayedReadings(from: automationEngine.snapshot(at: uptime))
        scheduleSensorRediscovery(after: error, at: uptime)
    }

    private func scheduleSensorRediscovery(after error: Error, at uptime: TimeInterval) {
        sensorErrorMessage = "环境光传感器不可用：\(error.localizedDescription)"
        nextSensorDiscoveryAt = uptime + sensorRetryDelay
        sensorStatus = "不可用 · \(Int(sensorRetryDelay)) 秒后重试"
        sensorRetryDelay = min(sensorRetryDelay * 2, 60)
        refreshSummary()
    }

    private func updateSensorRetryStatus(at uptime: TimeInterval) {
        let remaining = max(1, Int(ceil(nextSensorDiscoveryAt - uptime)))
        sensorStatus = "不可用 · \(remaining) 秒后重试"
        refreshSummary()
    }

    private func updateAutomationConfigurationIfValid() -> Bool {
        guard preferences.validationMessage == nil else {
            automationEngine.cancelPendingThemeChange()
            return false
        }
        let configuration = AutomationConfiguration(
            indoorThreshold: preferences.indoorThreshold,
            outdoorThreshold: preferences.outdoorThreshold,
            stableDuration: preferences.stabilitySeconds,
            minimumDwellDuration: preferences.minimumDwellSeconds
        )
        guard configuration != automationEngine.configuration else { return true }
        do {
            try automationEngine.updateConfiguration(configuration)
            return true
        } catch {
            operationErrorMessage = error.localizedDescription
            return false
        }
    }

    private func inspectIntegrations(syncDetectedMode: Bool) {
        var nextInspections: [String: ThemeInspection] = [:]
        var nextFailures: [String: String] = [:]
        for adapter in adapters {
            do {
                nextInspections[adapter.identifier] = try adapter.inspect()
            } catch {
                nextFailures[adapter.identifier] = error.localizedDescription
            }
        }
        inspections = nextInspections
        inspectionFailures = nextFailures

        if syncDetectedMode {
            let detectedModes = ["vscode", "ghostty"].compactMap {
                inspections[$0]?.detectedMode
            }
            if detectedModes.count == 2,
               let first = detectedModes.first,
               detectedModes.allSatisfy({ $0 == first })
            {
                automationEngine.setCurrentMode(
                    first,
                    at: systemUptime,
                    countsAsSwitch: false
                )
                displayedMode = first
            }
        }

        vscodeStatus = adapterStatus(identifier: "vscode")
        ghosttyStatus = adapterStatus(identifier: "ghostty")
        integrationErrorMessage = computeIntegrationError()
    }

    private var integrationInstalled: Bool {
        ["vscode", "ghostty"].allSatisfy {
            inspections[$0]?.status == .ready
        }
    }

    private var themesAreAligned: Bool {
        guard let vscodeMode = inspections["vscode"]?.detectedMode,
              let ghosttyMode = inspections["ghostty"]?.detectedMode else {
            return false
        }
        return vscodeMode == ghosttyMode && vscodeMode == displayedMode
    }

    private var integrationNeedsInstallation: Bool {
        ["vscode", "ghostty"].contains {
            inspections[$0]?.status == .needsInstallation
        }
    }

    private func adapterStatus(identifier: String) -> String {
        if let failure = inspectionFailures[identifier] {
            return "检查失败 · \(shortMessage(failure))"
        }
        guard let inspection = inspections[identifier] else {
            return "未找到"
        }
        let mode = inspection.detectedMode.map {
            $0 == .light ? "亮色" : "暗色"
        }
        switch inspection.status {
        case .ready:
            return ["已就绪", mode].compactMap { $0 }.joined(separator: " · ")
        case .needsInstallation:
            return ["待安装", mode].compactMap { $0 }.joined(separator: " · ")
        case .unavailable:
            return "不可用 · \(shortMessage(inspection.message ?? "找不到配置"))"
        case .conflict:
            return "冲突 · \(shortMessage(inspection.message ?? "需要人工确认"))"
        }
    }

    private func computeIntegrationError() -> String? {
        if let failure = inspectionFailures.sorted(by: { $0.key < $1.key }).first {
            return "\(failure.key) 检查失败：\(failure.value)"
        }
        for identifier in ["vscode", "ghostty"] {
            guard let inspection = inspections[identifier] else {
                return "缺少 \(identifier) 适配器检查结果。"
            }
            if inspection.status == .unavailable || inspection.status == .conflict {
                return inspection.message ?? "\(identifier) 配置不可安全修改。"
            }
        }
        if integrationInstalled, !themesAreAligned {
            return "VS Code 与 Ghostty 当前主题不一致；请手动选择一次亮色或暗色。"
        }
        return nil
    }

    private func updateDisplayedReadings(from snapshot: AutomationSnapshot) {
        displayedMode = snapshot.currentMode
        currentLux = snapshot.rawLux
        smoothedLux = snapshot.filteredLux

        if let pending = snapshot.pendingMode {
            candidateProgressLabel = "正在切换\(pending == .light ? "亮色" : "暗色")"
        } else if snapshot.isWarmingUp {
            candidateProgressLabel = "唤醒预热 · 还需 \(snapshot.warmupSamplesRemaining) 个样本"
        } else if let candidate = snapshot.candidateMode {
            candidateProgressLabel = "\(candidate == .light ? "亮色" : "暗色") · 还需 \(Int(ceil(snapshot.candidateRemaining))) 秒"
        } else {
            candidateProgressLabel = nil
        }
    }

    private func pendingReloadMessage(in result: ThemeTransactionResult) -> String? {
        guard let receipt = result.receipts.first(where: {
            $0.metadata["pendingReload"] == "true"
        }) else {
            return nil
        }
        let detail = receipt.metadata["reload"].flatMap { $0.isEmpty ? nil : $0 }
        return [
            "主题文件已切换；Ghostty 未能自动重载",
            detail,
            "请在 Ghostty 中按 ⌘⇧,"
        ].compactMap { $0 }.joined(separator: "；")
    }

    private func refreshLoginItemStatus() {
        loginItemStatus = LoginItemManager.statusDescription
    }

    private func refreshSummary() {
        if let workingMessage, isWorking {
            statusMessage = workingMessage
            hasError = false
            return
        }
        if transactionRecoveryBlocked {
            let detail = transactionRecoveryErrorMessage.map { "：\($0)" } ?? ""
            statusMessage = "上次事务无法安全恢复，已禁止写入\(detail)"
            hasError = true
            return
        }
        if let operationErrorMessage {
            statusMessage = operationErrorMessage
            hasError = true
            return
        }
        if let integrationErrorMessage {
            statusMessage = integrationErrorMessage
            hasError = true
            return
        }
        if let sensorErrorMessage {
            statusMessage = sensorErrorMessage + "；仍可手动切换"
            hasError = true
            return
        }
        if let validation = preferences.validationMessage {
            statusMessage = validation + "；自动切换已暂停"
            hasError = true
            return
        }
        if let operationMessage {
            statusMessage = operationMessage
            hasError = false
            return
        }
        if integrationNeedsInstallation {
            statusMessage = "尚未安装集成；启动检查不会修改配置"
            hasError = false
            return
        }
        if !preferences.automaticEnabled {
            statusMessage = "自动切换已暂停"
            hasError = false
            return
        }
        statusMessage = "正在根据环境光自动判断"
        hasError = false
    }

    private func presentOperationError(_ message: String) {
        operationMessage = nil
        operationErrorMessage = message
        refreshSummary()
    }

    private func openExistingItem(_ url: URL, description: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentOperationError("\(description)不存在：\(url.path)")
            return
        }
        guard NSWorkspace.shared.open(url) else {
            presentOperationError("无法打开\(description)：\(url.path)")
            return
        }
        operationMessage = "已打开\(description)"
        operationErrorMessage = nil
        refreshSummary()
    }

    private func persistCurrentMode(_ mode: ThemeMode) {
        defaults.set(mode.rawValue, forKey: PreferenceKey.currentMode)
    }

    private func observePreferences() {
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            objectWillChange.send()
            DispatchQueue.main.async { [weak self] in
                self?.refreshSummary()
            }
        }
    }

    private func observeSystemLifecycle() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleSleep() }
            }
        )
        notificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleWake() }
            }
        )
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
        )
    }

    private func handleSleep() {
        isSleeping = true
        ambientLightProvider.invalidate()
        sensorIsDiscovered = false
        sensorInfo = nil
        automationEngine.handleSleep()
        updateDisplayedReadings(from: automationEngine.snapshot(at: systemUptime))
        sensorStatus = "睡眠中 · 已暂停采样"
        sensorErrorMessage = nil
        refreshSummary()
    }

    private func handleWake() {
        isSleeping = false
        ambientLightProvider.invalidate()
        sensorIsDiscovered = false
        sensorInfo = nil
        sensorRetryDelay = 1
        nextSensorDiscoveryAt = 0
        automationEngine.handleWake()
        updateDisplayedReadings(from: automationEngine.snapshot(at: systemUptime))
        _ = discoverSensor(at: systemUptime, force: true)
        refreshSummary()
    }

    private func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        ambientLightProvider.invalidate()
    }

    private var systemUptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func safeAdapterDiagnostic(identifier: String) -> String {
        if inspectionFailures[identifier] != nil {
            return "inspectionFailed"
        }
        guard let inspection = inspections[identifier] else {
            return "missing"
        }
        let mode = inspection.detectedMode?.rawValue ?? "unknown"
        return "status=\(inspection.status.rawValue), mode=\(mode)"
    }

    private func shortMessage(_ message: String, maximumLength: Int = 72) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > maximumLength else { return singleLine }
        return String(singleLine.prefix(maximumLength - 1)) + "…"
    }
}

private enum ControllerError: LocalizedError {
    case integrationNotReady
    case recoveryBlocked

    var errorDescription: String? {
        switch self {
        case .integrationNotReady:
            "集成未处于可安全恢复状态；未覆盖任何冲突配置。"
        case .recoveryBlocked:
            "上次事务无法安全恢复；已禁止继续写配置。"
        }
    }
}
