import AppKit
import Foundation

public struct GhosttyConfiguration: Equatable, Sendable {
    public static let modeFileName = ".auto-theme-switcher-mode.ghostty"
    public static let lightFileName = ".auto-theme-switcher-light.ghostty"

    public let mainConfigURL: URL
    public let modeConfigURL: URL
    public let lightConfigURL: URL

    public init(
        mainConfigURL: URL,
        modeConfigURL: URL? = nil,
        lightConfigURL: URL? = nil
    ) {
        self.mainConfigURL = mainConfigURL
        let directoryURL = mainConfigURL.deletingLastPathComponent()
        self.modeConfigURL = modeConfigURL
            ?? directoryURL.appendingPathComponent(Self.modeFileName)
        self.lightConfigURL = lightConfigURL
            ?? directoryURL.appendingPathComponent(Self.lightFileName)
    }

    public static var standard: Self {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
            .appendingPathComponent("config.ghostty")
        return Self(mainConfigURL: configURL)
    }
}

public struct GhosttyValidationCandidate: Equatable, Sendable {
    public let configuration: GhosttyConfiguration
    public let mainConfigData: Data
    public let modeConfigData: Data
    public let lightConfigData: Data

    public init(
        configuration: GhosttyConfiguration,
        mainConfigData: Data,
        modeConfigData: Data,
        lightConfigData: Data
    ) {
        self.configuration = configuration
        self.mainConfigData = mainConfigData
        self.modeConfigData = modeConfigData
        self.lightConfigData = lightConfigData
    }
}

public protocol GhosttyConfigValidating: Sendable {
    /// 验证完整 main -> mode -> light 候选链。实现不得改写三个最终配置文件。
    func validate(_ candidate: GhosttyValidationCandidate) throws
}

public enum GhosttyConfigValidationError: Error, Equatable, Sendable {
    case executableNotFound
    case nonUTF8Candidate(URL)
    case processFailure(String)
    case invalidConfiguration(String)
}

extension GhosttyConfigValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "找不到 Ghostty 可执行文件，无法运行 +validate-config。"
        case let .nonUTF8Candidate(url):
            "Ghostty 候选配置不是 UTF-8：\(url.path)"
        case let .processFailure(message):
            "无法运行 Ghostty 配置验证：\(message)"
        case let .invalidConfiguration(message):
            "Ghostty 配置验证失败：\(message)"
        }
    }
}

/// 使用 Ghostty 自带的 `+validate-config`。临时链与主配置位于同一目录，确保用户
/// 已有的相对 `config-file` 仍按真实基准目录解析；仅托管 include 会指向唯一临时文件。
public struct GhosttyCLIConfigValidator: GhosttyConfigValidating {
    public let executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    public func validate(_ candidate: GhosttyValidationCandidate) throws {
        guard let executableURL = executableURL ?? Self.discoverExecutable() else {
            throw GhosttyConfigValidationError.executableNotFound
        }

        let directoryURL = candidate.configuration.mainConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let nonce = UUID().uuidString
        let stagedMainURL = directoryURL.appendingPathComponent(
            ".auto-theme-switcher-validation-\(nonce)-main.ghostty"
        )
        let stagedModeURL = directoryURL.appendingPathComponent(
            ".auto-theme-switcher-validation-\(nonce)-mode.ghostty"
        )
        let stagedLightURL = directoryURL.appendingPathComponent(
            ".auto-theme-switcher-validation-\(nonce)-light.ghostty"
        )
        let stagedURLs = [stagedMainURL, stagedModeURL, stagedLightURL]
        defer {
            for url in stagedURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let stagedMain = try replacingManagedInclude(
            in: candidate.mainConfigData,
            originalFileName: GhosttyConfiguration.modeFileName,
            stagedURL: stagedModeURL,
            sourceURL: candidate.configuration.mainConfigURL
        )
        let stagedMode = try replacingManagedInclude(
            in: candidate.modeConfigData,
            originalFileName: GhosttyConfiguration.lightFileName,
            stagedURL: stagedLightURL,
            sourceURL: candidate.configuration.modeConfigURL
        )

        do {
            try stagedLightURL.write(candidate.lightConfigData)
            try stagedModeURL.write(stagedMode)
            try stagedMainURL.write(stagedMain)
        } catch {
            throw GhosttyConfigValidationError.processFailure(error.localizedDescription)
        }

        try runValidation(executableURL: executableURL, configURL: stagedMainURL)
        // 暗色候选的 mode 文件为空，light 不在生效链中；仍单独验证可编辑的亮色文件。
        try runValidation(executableURL: executableURL, configURL: stagedLightURL)
    }

    private func replacingManagedInclude(
        in data: Data,
        originalFileName: String,
        stagedURL: URL,
        sourceURL: URL
    ) throws -> Data {
        guard let source = String(data: data, encoding: .utf8) else {
            throw GhosttyConfigValidationError.nonUTF8Candidate(sourceURL)
        }
        let originalLine = "config-file = ?\(originalFileName)"
        let stagedLine = "config-file = ?\(stagedURL.path)"
        return Data(source.replacingOccurrences(of: originalLine, with: stagedLine).utf8)
    }

    private func runValidation(executableURL: URL, configURL: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        // Ghostty 1.3.x 的 validate-config 要求带值 flag 使用 `=` 形式；分成两个
        // argv 会无诊断地返回 1。
        process.arguments = ["+validate-config", "--config-file=\(configURL.path)"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw GhosttyConfigValidationError.processFailure(error.localizedDescription)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput + output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhosttyConfigValidationError.invalidConfiguration(
                "\(configURL.lastPathComponent): "
                    + (message.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "退出状态 \(process.terminationStatus)")
            )
        }
    }

    private static func discoverExecutable() -> URL? {
        let candidates = [
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            "/opt/homebrew/bin/ghostty",
            "/usr/local/bin/ghostty"
        ]
        return candidates.lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private extension URL {
    func write(_ data: Data) throws {
        try data.write(to: self, options: [.atomic])
    }
}

public enum GhosttyReloadResult: Equatable, Sendable {
    case reloaded
    /// SIGUSR2 was accepted by a running Ghostty process. This requests an
    /// asynchronous reload; it does not confirm that Ghostty has finished it.
    case reloadRequested
    case notRunning
    case noTerminal
    case pending(String)

    fileprivate var receiptMetadata: [String: String] {
        switch self {
        case .reloaded:
            ["reload": "reloaded", "pendingReload": "false"]
        case .reloadRequested:
            ["reload": "reloadRequested", "pendingReload": "false"]
        case .notRunning:
            ["reload": "notRunning", "pendingReload": "false"]
        case .noTerminal:
            ["reload": "noTerminal", "pendingReload": "false"]
        case let .pending(message):
            ["reload": message, "pendingReload": "true"]
        }
    }
}

public protocol GhosttyReloading: Sendable {
    /// Ghostty 未运行时必须返回 `.notRunning`，不能启动应用。
    func reloadIfRunning() -> GhosttyReloadResult
}

public enum GhosttyAppleScriptExecution: Equatable, Sendable {
    case returned(String?)
    case failed(String)
}

public protocol GhosttyAppleScriptExecuting: Sendable {
    func execute(source: String) -> GhosttyAppleScriptExecution
}

public struct NSAppleScriptExecutor: GhosttyAppleScriptExecuting {
    public init() {}

    public func execute(source: String) -> GhosttyAppleScriptExecution {
        guard let appleScript = NSAppleScript(source: source) else {
            return .failed("无法创建 Ghostty reload AppleScript")
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            return .failed(message ?? "请在 Ghostty 中按 ⌘⇧, 重新载入配置")
        }
        return .returned(result.stringValue)
    }
}

public struct GhosttyRunningApplication: Equatable, Sendable {
    public let processIdentifier: Int32
    public let isFinishedLaunching: Bool
    public let isTerminated: Bool

    public init(
        processIdentifier: Int32,
        isFinishedLaunching: Bool = true,
        isTerminated: Bool = false
    ) {
        self.processIdentifier = processIdentifier
        self.isFinishedLaunching = isFinishedLaunching
        self.isTerminated = isTerminated
    }
}

public protocol GhosttyProcessQuerying: Sendable {
    func runningGhosttyApplication() -> GhosttyRunningApplication?
}

public struct NSRunningApplicationGhosttyProcessQuery: GhosttyProcessQuerying {
    public static let bundleIdentifier = "com.mitchellh.ghostty"

    public init() {}

    public func runningGhosttyApplication() -> GhosttyRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        )
        .first {
            $0.isFinishedLaunching && !$0.isTerminated && $0.processIdentifier > 0
        }
        .map {
            GhosttyRunningApplication(
                processIdentifier: $0.processIdentifier,
                isFinishedLaunching: $0.isFinishedLaunching,
                isTerminated: $0.isTerminated
            )
        }
    }
}

public enum GhosttySignalResult: Equatable, Sendable {
    case sent
    /// The process exited after discovery and before signal delivery.
    case notRunning
    case failed(String)
}

public protocol GhosttyProcessSignaling: Sendable {
    func sendSIGUSR2(to processIdentifier: Int32) -> GhosttySignalResult
}

public struct DarwinGhosttyProcessSignaler: GhosttyProcessSignaling {
    public init() {}

    public func sendSIGUSR2(to processIdentifier: Int32) -> GhosttySignalResult {
        guard processIdentifier > 0 else {
            return .failed("Ghostty 进程号无效")
        }
        let result = kill(processIdentifier, SIGUSR2)
        guard result == 0 else {
            let signalErrno = errno
            if signalErrno == ESRCH {
                return .notRunning
            }
            return .failed(String(cString: strerror(signalErrno)))
        }
        return .sent
    }
}

public struct AppleScriptGhosttyReloader: GhosttyReloading {
    public let scriptExecutor: any GhosttyAppleScriptExecuting
    public let processQuery: any GhosttyProcessQuerying
    public let processSignaler: any GhosttyProcessSignaling

    public init(
        scriptExecutor: any GhosttyAppleScriptExecuting = NSAppleScriptExecutor(),
        processQuery: any GhosttyProcessQuerying = NSRunningApplicationGhosttyProcessQuery(),
        processSignaler: any GhosttyProcessSignaling = DarwinGhosttyProcessSignaler()
    ) {
        self.scriptExecutor = scriptExecutor
        self.processQuery = processQuery
        self.processSignaler = processSignaler
    }

    // `perform action` 是面向 terminal 的命令。即使 reload_config 最终会让整个
    // Ghostty 进程重读配置，也必须按 SDEF 传入一个 terminal 作为命令目标。
    static let reloadScriptSource = """
    if application "Ghostty" is running then
        tell application "Ghostty"
            if (count of terminals) is 0 then
                return "no-terminal"
            end if
            set targetTerminal to first terminal
            set didReload to perform action "reload_config" on targetTerminal
            if didReload then
                return "reloaded"
            else
                return "action-failed"
            end if
        end tell
    else
        return "not-running"
    end if
    """

    public func reloadIfRunning() -> GhosttyReloadResult {
        // NSAppleScript 属于 AppKit；统一在主线程执行，避免从事务 actor 的后台
        // executor 直接进入非线程安全的 Apple Event 运行时。
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                executeReloadScript()
            }
        }
        return executeReloadScript()
    }

    private func executeReloadScript() -> GhosttyReloadResult {
        switch scriptExecutor.execute(source: Self.reloadScriptSource) {
        case let .failed(message):
            // Automation refusal and other Apple Event failures are terminal
            // for this attempt. Never send SIGUSR2 after an AppleScript error.
            return .pending(message)
        case let .returned(value):
            return result(for: value)
        }
    }

    private func result(for value: String?) -> GhosttyReloadResult {
        switch value {
        case "reloaded":
            return .reloaded
        case "not-running":
            return .notRunning
        case "no-terminal":
            return requestReloadWithoutTerminal()
        default:
            return .pending("Ghostty 拒绝执行 reload_config")
        }
    }

    private func requestReloadWithoutTerminal() -> GhosttyReloadResult {
        guard let application = processQuery.runningGhosttyApplication(),
              application.isFinishedLaunching,
              !application.isTerminated,
              application.processIdentifier > 0
        else {
            return .notRunning
        }
        switch processSignaler.sendSIGUSR2(to: application.processIdentifier) {
        case .sent:
            return .reloadRequested
        case .notRunning:
            return .notRunning
        case let .failed(message):
            return .pending("无法请求 Ghostty 重载：\(message)")
        }
    }
}

public enum GhosttyThemeAdapterError: Error, Equatable, Sendable {
    case wrongInspection(String)
    case wrongPreparedChange(String)
    case missingSnapshot(URL)
    case nonUTF8Configuration(URL)
    case malformedManagedMarker
    case unmanagedModeInclude
    case orphanedManagedFiles
    case managedModeFileModified
    case semanticVerificationFailed(String)
}

extension GhosttyThemeAdapterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .wrongInspection(identifier):
            "不能使用 \(identifier) 的检查结果准备 Ghostty 变更。"
        case let .wrongPreparedChange(identifier):
            "不能由 Ghostty 提交 \(identifier) 的候选变更。"
        case let .missingSnapshot(url):
            "Ghostty 检查结果缺少文件：\(url.path)"
        case let .nonUTF8Configuration(url):
            "Ghostty 配置不是 UTF-8，已停止覆盖：\(url.path)"
        case .malformedManagedMarker:
            "Ghostty 主配置中的 Auto Theme Switcher 标记不完整或重复，已停止覆盖。"
        case .unmanagedModeInclude:
            "Ghostty 主配置已有未受标记保护的 Auto Theme Switcher mode include，已停止覆盖。"
        case .orphanedManagedFiles:
            "Ghostty 保留文件已存在但主配置没有所有权标记，已停止接管或删除。"
        case .managedModeFileModified:
            "Ghostty 的托管 mode 文件包含未知内容，已停止覆盖。"
        case let .semanticVerificationFailed(message):
            "Ghostty 主题切换后的语义验证失败：\(message)"
        }
    }
}

public struct GhosttyThemeAdapter: RestorableThemeAdapter {
    public static let adapterIdentifier = "ghostty"
    public static let beginMarker = "# BEGIN Auto Theme Switcher"
    public static let endMarker = "# END Auto Theme Switcher"
    public static let modeIncludeLine = "config-file = ?\(GhosttyConfiguration.modeFileName)"
    public static let lightIncludeLine = "config-file = ?\(GhosttyConfiguration.lightFileName)"

    public let configuration: GhosttyConfiguration
    public let fileSystem: any ThemeFileSystem
    public let validator: any GhosttyConfigValidating
    public let reloader: any GhosttyReloading

    public var identifier: String { Self.adapterIdentifier }
    /// Ghostty overlay 必须先于 VS Code settings 提交。
    public var transactionOrder: Int { 0 }

    public init(
        configuration: GhosttyConfiguration = .standard,
        fileSystem: any ThemeFileSystem = LocalThemeFileSystem(),
        validator: any GhosttyConfigValidating = GhosttyCLIConfigValidator(),
        reloader: any GhosttyReloading = AppleScriptGhosttyReloader()
    ) {
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.validator = validator
        self.reloader = reloader
    }

    public func inspect() throws -> ThemeInspection {
        let main = try fileSystem.snapshot(at: configuration.mainConfigURL)
        let mode = try fileSystem.snapshot(at: configuration.modeConfigURL)
        let light = try fileSystem.snapshot(at: configuration.lightConfigURL)
        let files = [main, mode, light]

        do {
            let markerState = try Self.markerState(in: main)
            let detectedMode = try Self.detectedMode(from: mode)
            let hasLightFile = light.data != nil
            let status: ThemeAdapterStatus
            let message: String?

            if markerState == .absent, mode.data != nil || light.data != nil {
                throw GhosttyThemeAdapterError.orphanedManagedFiles
            }

            if markerState == .installed, hasLightFile {
                status = .ready
                message = nil
            } else {
                status = .needsInstallation
                if markerState != .installed {
                    message = "Ghostty 尚未安装托管 include。"
                } else {
                    message = "Ghostty 亮色配置缺失，将在下一次事务中重新创建。"
                }
            }

            return ThemeInspection(
                adapterIdentifier: identifier,
                detectedMode: detectedMode,
                status: status,
                files: files,
                message: message,
                details: [
                    "mainConfig": configuration.mainConfigURL.path,
                    "modeConfig": configuration.modeConfigURL.path,
                    "lightConfig": configuration.lightConfigURL.path,
                    "lightCustomized": String(light.data.map { $0 != Self.defaultLightConfigurationData } ?? false)
                ]
            )
        } catch {
            return ThemeInspection(
                adapterIdentifier: identifier,
                detectedMode: nil,
                status: .conflict,
                files: files,
                message: error.localizedDescription,
                details: ["mainConfig": configuration.mainConfigURL.path]
            )
        }
    }

    public func prepare(
        targetMode: ThemeMode,
        from inspection: ThemeInspection
    ) throws -> PreparedThemeChange {
        try requireOwnInspection(inspection)
        guard inspection.status != .conflict else {
            throw GhosttyThemeAdapterError.semanticVerificationFailed(
                inspection.message ?? "配置存在冲突"
            )
        }

        let main = try requireSnapshot(configuration.mainConfigURL, in: inspection)
        let mode = try requireSnapshot(configuration.modeConfigURL, in: inspection)
        let light = try requireSnapshot(configuration.lightConfigURL, in: inspection)
        _ = try Self.detectedMode(from: mode)

        let mainCandidate = try Self.installingMarker(in: main)
        let modeCandidate = targetMode == .light
            ? Data((Self.lightIncludeLine + "\n").utf8)
            : Data()
        // 首次生成后永不自动覆盖，用户可以持续定制这个文件。
        let lightCandidate = light.data ?? Self.defaultLightConfigurationData

        try validator.validate(
            GhosttyValidationCandidate(
                configuration: configuration,
                mainConfigData: mainCandidate,
                modeConfigData: modeCandidate,
                lightConfigData: lightCandidate
            )
        )

        var mutations: [PreparedThemeMutation] = []
        Self.appendMutationIfNeeded(
            snapshot: light,
            candidateData: lightCandidate,
            label: "Ghostty 亮色配置",
            to: &mutations
        )
        Self.appendMutationIfNeeded(
            snapshot: mode,
            candidateData: modeCandidate,
            label: "Ghostty 当前模式覆盖层",
            to: &mutations
        )
        Self.appendMutationIfNeeded(
            snapshot: main,
            candidateData: mainCandidate,
            label: "Ghostty 主配置 include",
            to: &mutations
        )

        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: targetMode,
            mutations: mutations,
            metadata: Self.dependencyMetadata(
                operation: "switch",
                main: main,
                mode: mode,
                light: light
            )
        )
    }

    public func prepareRestoration(from inspection: ThemeInspection) throws -> PreparedThemeChange {
        try requireOwnInspection(inspection)
        let main = try requireSnapshot(configuration.mainConfigURL, in: inspection)
        let mode = try requireSnapshot(configuration.modeConfigURL, in: inspection)
        let light = try requireSnapshot(configuration.lightConfigURL, in: inspection)

        let markerState = try Self.markerState(in: main)
        if markerState == .absent, mode.data != nil || light.data != nil {
            throw GhosttyThemeAdapterError.orphanedManagedFiles
        }
        let mainCandidate = try Self.removingMarker(in: main)
        if let modeData = mode.data,
           modeData != Data(),
           modeData != Data((Self.lightIncludeLine + "\n").utf8)
        {
            throw GhosttyThemeAdapterError.managedModeFileModified
        }

        // 验证恢复后的主配置，同时用已知有效的空 mode/default light 完成 staging 链。
        try validator.validate(
            GhosttyValidationCandidate(
                configuration: configuration,
                mainConfigData: mainCandidate ?? Data(),
                modeConfigData: Data(),
                lightConfigData: Self.defaultLightConfigurationData
            )
        )

        var mutations: [PreparedThemeMutation] = []
        if mode.data != nil {
            mutations.append(
                PreparedThemeMutation(snapshot: mode, candidateData: nil, label: "移除 Ghostty mode 覆盖层")
            )
        }
        let lightWasCustomized = light.data.map { $0 != Self.defaultLightConfigurationData } ?? false
        if light.data != nil, !lightWasCustomized {
            mutations.append(
                PreparedThemeMutation(snapshot: light, candidateData: nil, label: "移除 Ghostty 默认亮色配置")
            )
        }
        if main.data != mainCandidate {
            mutations.append(
                PreparedThemeMutation(snapshot: main, candidateData: mainCandidate, label: "移除 Ghostty 主配置 include")
            )
        }

        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: .dark,
            mutations: mutations,
            metadata: Self.dependencyMetadata(
                operation: "restore",
                main: main,
                mode: mode,
                light: light
            ).merging([
                "preservedCustomizedLightFile": String(lightWasCustomized)
            ]) { _, new in new }
        )
    }

    public func commit(_ change: PreparedThemeChange) throws -> ThemeCommitReceipt {
        guard change.adapterIdentifier == identifier else {
            throw GhosttyThemeAdapterError.wrongPreparedChange(change.adapterIdentifier)
        }
        try verifyDependencies(of: change)
        let receipt = try ThemeMutationExecutor(fileSystem: fileSystem).commit(change)
        return receipt.mergingMetadata(reloader.reloadIfRunning().receiptMetadata)
    }

    public func verify(_ receipt: ThemeCommitReceipt) throws {
        guard receipt.change.adapterIdentifier == identifier else {
            throw GhosttyThemeAdapterError.wrongPreparedChange(receipt.change.adapterIdentifier)
        }
        try ThemeMutationExecutor(fileSystem: fileSystem).verify(receipt)

        if receipt.change.metadata["operation"] == "restore" {
            let main = try fileSystem.snapshot(at: configuration.mainConfigURL)
            let mode = try fileSystem.snapshot(at: configuration.modeConfigURL)
            guard try Self.markerState(in: main) == .absent, mode.data == nil else {
                throw GhosttyThemeAdapterError.semanticVerificationFailed("托管 include 或 mode 文件仍然存在")
            }
            return
        }

        let inspection = try inspect()
        guard inspection.status == .ready,
              inspection.detectedMode == receipt.change.targetMode
        else {
            throw GhosttyThemeAdapterError.semanticVerificationFailed(
                inspection.message ?? "目标模式未生效"
            )
        }
    }

    public func rollback(_ receipt: ThemeCommitReceipt) throws {
        guard receipt.change.adapterIdentifier == identifier else {
            throw GhosttyThemeAdapterError.wrongPreparedChange(receipt.change.adapterIdentifier)
        }
        do {
            try ThemeMutationExecutor(fileSystem: fileSystem).rollback(receipt)
        } catch {
            // 回滚器会尽力恢复其余文件后再报告冲突；即使部分失败，也要让 Ghostty
            // 重载已经安全恢复的 overlay。
            _ = reloader.reloadIfRunning()
            throw error
        }
        _ = reloader.reloadIfRunning()
    }

    public static let defaultLightConfigurationData = Data(defaultLightConfiguration.utf8)

    public static let defaultLightConfiguration = """
    # Auto Theme Switcher light profile.
    # Created once; edit this file to keep your own light-theme overrides.
    theme = GitHub Light Default
    background = #FFFFFF
    foreground = #3B3B3B
    cursor-color = #005FB8
    cursor-text = #FFFFFF
    selection-background = #ADD6FF
    selection-foreground = #000000
    split-divider-color = #E5E5E5
    palette = 0=#24292f
    palette = 1=#cf222e
    palette = 2=#116329
    palette = 3=#4d2d00
    palette = 4=#0969da
    palette = 5=#8250df
    palette = 6=#1b7c83
    palette = 7=#6e7781
    palette = 8=#57606a
    palette = 9=#a40e26
    palette = 10=#1a7f37
    palette = 11=#633c01
    palette = 12=#218bff
    palette = 13=#a475f9
    palette = 14=#3192aa
    palette = 15=#8c959f
    """ + "\n"

    private enum MarkerState: Equatable {
        case absent
        case installed
    }

    private func requireOwnInspection(_ inspection: ThemeInspection) throws {
        guard inspection.adapterIdentifier == identifier else {
            throw GhosttyThemeAdapterError.wrongInspection(inspection.adapterIdentifier)
        }
    }

    private func requireSnapshot(
        _ fileURL: URL,
        in inspection: ThemeInspection
    ) throws -> ThemeFileSnapshot {
        guard let snapshot = inspection.snapshot(for: fileURL) else {
            throw GhosttyThemeAdapterError.missingSnapshot(fileURL)
        }
        return snapshot
    }

    private static func appendMutationIfNeeded(
        snapshot: ThemeFileSnapshot,
        candidateData: Data?,
        label: String,
        to mutations: inout [PreparedThemeMutation]
    ) {
        guard snapshot.data != candidateData else { return }
        mutations.append(
            PreparedThemeMutation(snapshot: snapshot, candidateData: candidateData, label: label)
        )
    }

    private static let missingDependencyHash = "<missing>"

    private static func dependencyMetadata(
        operation: String,
        main: ThemeFileSnapshot,
        mode: ThemeFileSnapshot,
        light: ThemeFileSnapshot
    ) -> [String: String] {
        [
            "operation": operation,
            "dependency.main": main.hash ?? missingDependencyHash,
            "dependency.mode": mode.hash ?? missingDependencyHash,
            "dependency.light": light.hash ?? missingDependencyHash
        ]
    }

    private func verifyDependencies(of change: PreparedThemeChange) throws {
        let dependencies: [(String, URL)] = [
            ("dependency.main", configuration.mainConfigURL),
            ("dependency.mode", configuration.modeConfigURL),
            ("dependency.light", configuration.lightConfigURL)
        ]
        for (key, fileURL) in dependencies {
            guard let encodedHash = change.metadata[key] else {
                throw GhosttyThemeAdapterError.semanticVerificationFailed("候选缺少依赖哈希 \(key)")
            }
            let expectedHash = encodedHash == Self.missingDependencyHash ? nil : encodedHash
            let actualHash = try fileSystem.currentHash(at: fileURL)
            guard actualHash == expectedHash else {
                throw ThemeFileMutationError.conflict(
                    fileURL,
                    expectedHash: expectedHash,
                    actualHash: actualHash
                )
            }
        }
    }

    private static func detectedMode(from snapshot: ThemeFileSnapshot) throws -> ThemeMode {
        guard let data = snapshot.data else { return .dark }
        if data.isEmpty { return .dark }
        guard let source = String(data: data, encoding: .utf8) else {
            throw GhosttyThemeAdapterError.nonUTF8Configuration(snapshot.fileURL)
        }
        let normalized = normalizeNewlines(source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == lightIncludeLine else {
            throw GhosttyThemeAdapterError.managedModeFileModified
        }
        return .light
    }

    private static func markerState(in snapshot: ThemeFileSnapshot) throws -> MarkerState {
        guard let data = snapshot.data else { return .absent }
        guard let source = String(data: data, encoding: .utf8) else {
            throw GhosttyThemeAdapterError.nonUTF8Configuration(snapshot.fileURL)
        }
        let normalized = normalizeNewlines(source)
        let beginCount = normalized.components(separatedBy: beginMarker).count - 1
        let endCount = normalized.components(separatedBy: endMarker).count - 1
        let exactBlock = managedBlock(lineEnding: "\n")

        if beginCount == 0, endCount == 0 {
            if normalized.components(separatedBy: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == modeIncludeLine
            }) {
                throw GhosttyThemeAdapterError.unmanagedModeInclude
            }
            return .absent
        }
        guard beginCount == 1,
              endCount == 1,
              normalized.components(separatedBy: exactBlock).count == 2
        else {
            throw GhosttyThemeAdapterError.malformedManagedMarker
        }

        let withoutManagedBlock = normalized.replacingOccurrences(of: exactBlock, with: "")
        if withoutManagedBlock.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == modeIncludeLine
        }) {
            throw GhosttyThemeAdapterError.unmanagedModeInclude
        }
        return .installed
    }

    private static func installingMarker(in snapshot: ThemeFileSnapshot) throws -> Data {
        let state = try markerState(in: snapshot)
        if state == .installed { return snapshot.data ?? Data() }
        guard let data = snapshot.data else {
            return Data((managedBlock(lineEnding: "\n") + "\n").utf8)
        }
        if data.isEmpty {
            return Data((managedBlock(lineEnding: "\n") + "\n").utf8)
        }
        guard var source = String(data: data, encoding: .utf8) else {
            throw GhosttyThemeAdapterError.nonUTF8Configuration(snapshot.fileURL)
        }
        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        if !source.hasSuffix(lineEnding) { source += lineEnding }
        source += lineEnding + managedBlock(lineEnding: lineEnding) + lineEnding
        return Data(source.utf8)
    }

    private static func removingMarker(in snapshot: ThemeFileSnapshot) throws -> Data? {
        guard let data = snapshot.data else { return nil }
        let state = try markerState(in: snapshot)
        guard state == .installed else { return data }
        guard var source = String(data: data, encoding: .utf8) else {
            throw GhosttyThemeAdapterError.nonUTF8Configuration(snapshot.fileURL)
        }
        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        let block = managedBlock(lineEnding: lineEnding)
        guard let range = source.range(of: block) else {
            throw GhosttyThemeAdapterError.malformedManagedMarker
        }
        var removalRange = range
        if removalRange.upperBound < source.endIndex,
           source[removalRange.upperBound...].hasPrefix(lineEnding)
        {
            removalRange = removalRange.lowerBound ..< source.index(
                removalRange.upperBound,
                offsetBy: lineEnding.count
            )
        }
        if removalRange.lowerBound > source.startIndex {
            let prefix = source[..<removalRange.lowerBound]
            if prefix.hasSuffix(lineEnding + lineEnding) {
                removalRange = source.index(
                    removalRange.lowerBound,
                    offsetBy: -lineEnding.count
                ) ..< removalRange.upperBound
            }
        }
        source.removeSubrange(removalRange)
        return Data(source.utf8)
    }

    private static func managedBlock(lineEnding: String) -> String {
        [beginMarker, modeIncludeLine, endMarker].joined(separator: lineEnding)
    }

    private static func normalizeNewlines(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
