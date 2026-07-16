import Foundation

public enum VSCodeThemeAdapterError: Error, Equatable, Sendable {
    case settingsUnavailable(URL)
    case integrationNotInstalled
    case invalidInspection
    case invalidManifest(String)
    case ownershipConflict(String)
    case unexpectedPreparedChange
}

extension VSCodeThemeAdapterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .settingsUnavailable(url):
            return "找不到 VS Code User settings.json：\(url.path)"
        case .integrationNotInstalled:
            return "VS Code 集成尚未安装；自动切换不会擅自迁移配置。"
        case .invalidInspection:
            return "VS Code 检查结果与当前适配器不匹配。"
        case let .invalidManifest(message):
            return "VS Code ownership manifest 无效：\(message)"
        case let .ownershipConflict(message):
            return "VS Code 托管配置发生冲突：\(message)"
        case .unexpectedPreparedChange:
            return "收到不属于 VS Code 适配器的候选变更。"
        }
    }
}

public struct VSCodeThemeInspection: Equatable, Sendable {
    public let themeInspection: ThemeInspection
    public let colorTheme: String?
    public let autoDetectColorScheme: Bool?
    public let ignoresThemeSync: Bool
    public let ownershipManifestPresent: Bool

    public var status: ThemeAdapterStatus { themeInspection.status }
    public var detectedMode: ThemeMode? { themeInspection.detectedMode }
    public var message: String? { themeInspection.message }
}

private struct VSCodeOwnershipManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let settingsPath: String
    let backupFileName: String
    let backupHash: String
    let managedColorCustomizationsHash: String
    let installedAt: Date
}

/// VS Code Stable/User settings adapter.
///
/// The adapter is intentionally value-typed and dependency-injected. `inspect`
/// and `prepare` never touch disk; only `commit` (or the explicit convenience
/// install/restore methods) performs CAS-protected writes.
public struct VSCodeThemeAdapter: RestorableThemeAdapter, Sendable {
    public static let defaultSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Code/User/settings.json")

    public static let defaultBackupDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dev.dtw.AutoThemeSwitcher/Backups/VSCode")

    public static let lightColors: [(String, String)] = [
        ("editor.background", "#FFFFFF"),
        ("editor.foreground", "#3B3B3B"),
        ("editor.selectionBackground", "#ADD6FF"),
        ("editor.selectionForeground", "#000000"),
        ("editorCursor.foreground", "#005FB8"),
        ("editorCursor.background", "#FFFFFF"),
        ("terminal.background", "#FFFFFF"),
        ("terminal.foreground", "#3B3B3B"),
        ("terminal.border", "#E5E5E5"),
        ("terminal.selectionBackground", "#ADD6FF"),
        ("terminal.selectionForeground", "#000000"),
        ("terminalCursor.foreground", "#005FB8"),
        ("terminalCursor.background", "#FFFFFF"),
        ("terminal.ansiBlack", "#24292F"),
        ("terminal.ansiRed", "#CF222E"),
        ("terminal.ansiGreen", "#116329"),
        ("terminal.ansiYellow", "#4D2D00"),
        ("terminal.ansiBlue", "#0969DA"),
        ("terminal.ansiMagenta", "#8250DF"),
        ("terminal.ansiCyan", "#1B7C83"),
        ("terminal.ansiWhite", "#6E7781"),
        ("terminal.ansiBrightBlack", "#57606A"),
        ("terminal.ansiBrightRed", "#A40E26"),
        ("terminal.ansiBrightGreen", "#1A7F37"),
        ("terminal.ansiBrightYellow", "#633C01"),
        ("terminal.ansiBrightBlue", "#218BFF"),
        ("terminal.ansiBrightMagenta", "#A475F9"),
        ("terminal.ansiBrightCyan", "#3192AA"),
        ("terminal.ansiBrightWhite", "#8C959F"),
    ]

    public let identifier = "vscode"
    public let transactionOrder = 20
    public let settingsURL: URL
    public let backupDirectoryURL: URL
    public let fileSystem: any ThemeFileSystem

    private let executor: ThemeMutationExecutor
    private let manifestURL: URL
    private let backupURL: URL

    public init(
        settingsURL: URL = VSCodeThemeAdapter.defaultSettingsURL,
        backupDirectoryURL: URL = VSCodeThemeAdapter.defaultBackupDirectoryURL,
        fileSystem: any ThemeFileSystem = LocalThemeFileSystem()
    ) {
        self.settingsURL = settingsURL.standardizedFileURL
        self.backupDirectoryURL = backupDirectoryURL.standardizedFileURL
        self.fileSystem = fileSystem
        executor = ThemeMutationExecutor(fileSystem: fileSystem)
        manifestURL = backupDirectoryURL.appendingPathComponent("ownership.json").standardizedFileURL
        backupURL = backupDirectoryURL.appendingPathComponent("settings.json.before-auto-theme-switcher.backup").standardizedFileURL
    }

    public func inspect() throws -> ThemeInspection {
        let settingsSnapshot = try fileSystem.snapshot(at: settingsURL)
        let manifestSnapshot = try fileSystem.snapshot(at: manifestURL)
        let backupSnapshot = try fileSystem.snapshot(at: backupURL)
        let snapshots = [settingsSnapshot, manifestSnapshot, backupSnapshot]

        guard let settingsData = settingsSnapshot.data else {
            return ThemeInspection(
                adapterIdentifier: identifier,
                detectedMode: nil,
                status: .unavailable,
                files: snapshots,
                message: VSCodeThemeAdapterError.settingsUnavailable(settingsURL).localizedDescription
            )
        }

        do {
            let editor = try JSONCEditor(data: settingsData)
            let colorTheme = try editor.rootString(forKey: "workbench.colorTheme")
            let detectedMode = Self.mode(forThemeName: colorTheme)
            let autoDetect = try editor.rootBoolean(forKey: "window.autoDetectColorScheme")
            let ignored = try editor.rootStringArray(forKey: "settingsSync.ignoredSettings") ?? []
            let ignoresTheme = ignored.contains("workbench.colorTheme")

            guard let manifestData = manifestSnapshot.data else {
                if try editor.hasAnyVSCodeThemeColorBlock() {
                    return ThemeInspection(
                        adapterIdentifier: identifier,
                        detectedMode: detectedMode,
                        status: .conflict,
                        files: snapshots,
                        message: "检测到用户已有主题限定颜色块，但不存在 ownership manifest；不会接管。",
                        details: details(colorTheme, autoDetect, ignoresTheme, false)
                    )
                }
                return ThemeInspection(
                    adapterIdentifier: identifier,
                    detectedMode: detectedMode,
                    status: .needsInstallation,
                    files: snapshots,
                    message: "需要先安装 VS Code 无损主题集成。",
                    details: details(colorTheme, autoDetect, ignoresTheme, false)
                )
            }

            let manifest = try decodeAndValidateManifest(manifestData)
            guard detectedMode != nil else {
                throw VSCodeThemeAdapterError.ownershipConflict(
                    "workbench.colorTheme 已切换为非托管主题 \(colorTheme ?? "未设置")；不会自动覆盖用户选择。"
                )
            }
            guard let backupData = backupSnapshot.data,
                  ThemeFileHash.sha256(backupData) == manifest.backupHash else {
                throw VSCodeThemeAdapterError.ownershipConflict("原始逐字节备份缺失或哈希不匹配。")
            }
            guard let colors = try editor.rawRootValue(forKey: "workbench.colorCustomizations"),
                  ThemeFileHash.sha256(colors) == manifest.managedColorCustomizationsHash else {
                throw VSCodeThemeAdapterError.ownershipConflict("主题颜色块已被外部修改；为避免覆盖已暂停切换。")
            }
            guard try editor.hasInstalledVSCodeThemeColorBlocks(), autoDetect == false, ignoresTheme else {
                throw VSCodeThemeAdapterError.ownershipConflict("托管字段不完整或已被外部修改。")
            }

            return ThemeInspection(
                adapterIdentifier: identifier,
                detectedMode: detectedMode,
                status: .ready,
                files: snapshots,
                details: details(colorTheme, autoDetect, ignoresTheme, true)
            )
        } catch {
            return ThemeInspection(
                adapterIdentifier: identifier,
                detectedMode: nil,
                status: .conflict,
                files: snapshots,
                message: error.localizedDescription
            )
        }
    }

    public func inspectVSCode() throws -> VSCodeThemeInspection {
        let inspection = try inspect()
        guard let data = inspection.snapshot(for: settingsURL)?.data else {
            return VSCodeThemeInspection(
                themeInspection: inspection,
                colorTheme: nil,
                autoDetectColorScheme: nil,
                ignoresThemeSync: false,
                ownershipManifestPresent: inspection.snapshot(for: manifestURL)?.data != nil
            )
        }
        let editor = try? JSONCEditor(data: data)
        return VSCodeThemeInspection(
            themeInspection: inspection,
            colorTheme: try? editor?.rootString(forKey: "workbench.colorTheme"),
            autoDetectColorScheme: try? editor?.rootBoolean(forKey: "window.autoDetectColorScheme"),
            ignoresThemeSync: ((try? editor?.rootStringArray(forKey: "settingsSync.ignoredSettings")) ?? [])?.contains("workbench.colorTheme") == true,
            ownershipManifestPresent: inspection.snapshot(for: manifestURL)?.data != nil
        )
    }

    /// The coordinator's prepare path is side-effect free. A needsInstallation
    /// inspection produces the full first-install candidate; a ready inspection
    /// produces a daily candidate that changes only colorTheme.
    public func prepare(targetMode: ThemeMode, from inspection: ThemeInspection) throws -> PreparedThemeChange {
        if inspection.adapterIdentifier == identifier, inspection.status == .needsInstallation {
            return try prepareInstallation(initialMode: targetMode, from: inspection)
        }
        guard inspection.adapterIdentifier == identifier,
              inspection.status == .ready,
              let snapshot = inspection.snapshot(for: settingsURL),
              let settingsData = snapshot.data else {
            if inspection.adapterIdentifier != identifier { throw VSCodeThemeAdapterError.invalidInspection }
            throw VSCodeThemeAdapterError.integrationNotInstalled
        }
        var editor = try JSONCEditor(data: settingsData)
        try editor.setRootString(Self.themeName(for: targetMode), forKey: "workbench.colorTheme")
        var metadata = ["operation": "switch"]
        if let manifestHash = inspection.snapshot(for: manifestURL)?.hash {
            metadata["manifestHash"] = manifestHash
        }
        if let backupHash = inspection.snapshot(for: backupURL)?.hash {
            metadata["backupHash"] = backupHash
        }
        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: targetMode,
            mutations: [PreparedThemeMutation(snapshot: snapshot, candidateData: editor.data, label: "切换 VS Code 主题")],
            metadata: metadata
        )
    }

    /// Concrete overload useful outside the cross-adapter coordinator.
    public func prepare(theme: ThemeMode) throws -> PreparedThemeChange {
        try prepare(targetMode: theme, from: inspect())
    }

    public func prepareInstallation(initialMode: ThemeMode = .dark) throws -> PreparedThemeChange {
        try prepareInstallation(initialMode: initialMode, from: inspect())
    }

    private func prepareInstallation(
        initialMode: ThemeMode,
        from inspection: ThemeInspection
    ) throws -> PreparedThemeChange {
        guard let settingsSnapshot = inspection.snapshot(for: settingsURL),
              let originalData = settingsSnapshot.data else {
            throw VSCodeThemeAdapterError.settingsUnavailable(settingsURL)
        }
        if inspection.status == .ready {
            return try prepare(targetMode: initialMode, from: inspection)
        }
        guard inspection.status == .needsInstallation else {
            throw VSCodeThemeAdapterError.ownershipConflict(inspection.message ?? "当前配置不可安全迁移。")
        }
        guard inspection.snapshot(for: manifestURL)?.data == nil else {
            throw VSCodeThemeAdapterError.ownershipConflict("已有 manifest 但集成状态不完整。")
        }
        guard inspection.snapshot(for: backupURL)?.data == nil else {
            throw VSCodeThemeAdapterError.ownershipConflict("存在无 ownership manifest 对应的旧备份，请先人工确认。")
        }

        var editor = try JSONCEditor(data: originalData)
        guard try editor.rootString(forKey: "workbench.colorTheme") == "Dark Modern" else {
            throw VSCodeThemeAdapterError.ownershipConflict("首次迁移要求当前 workbench.colorTheme 为 Dark Modern，避免把未知主题的覆盖项错误归入 Dark Modern。")
        }
        _ = try editor.installVSCodeThemeColorBlocks(lightColors: Self.lightColors)
        try editor.setRootBoolean(false, forKey: "window.autoDetectColorScheme")
        try editor.appendUniqueString("workbench.colorTheme", toRootArray: "settingsSync.ignoredSettings")
        try editor.setRootString(Self.themeName(for: initialMode), forKey: "workbench.colorTheme")
        guard let managedColors = try editor.rawRootValue(forKey: "workbench.colorCustomizations") else {
            throw VSCodeThemeAdapterError.ownershipConflict("迁移后缺少颜色配置。")
        }

        let manifest = VSCodeOwnershipManifest(
            version: VSCodeOwnershipManifest.currentVersion,
            settingsPath: settingsURL.path,
            backupFileName: backupURL.lastPathComponent,
            backupHash: ThemeFileHash.sha256(originalData),
            managedColorCustomizationsHash: ThemeFileHash.sha256(managedColors),
            installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)

        let backupSnapshot = ThemeFileSnapshot(fileURL: backupURL, data: nil)
        let manifestSnapshot = ThemeFileSnapshot(fileURL: manifestURL, data: nil)
        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: initialMode,
            mutations: [
                PreparedThemeMutation(snapshot: backupSnapshot, candidateData: originalData, label: "备份原始 VS Code settings.json"),
                PreparedThemeMutation(snapshot: manifestSnapshot, candidateData: manifestData, label: "记录 VS Code 配置归属"),
                PreparedThemeMutation(snapshot: settingsSnapshot, candidateData: editor.data, label: "安装 VS Code 主题集成"),
            ],
            metadata: ["operation": "install"]
        )
    }

    @discardableResult
    public func installIntegration(initialMode: ThemeMode = .dark) throws -> ThemeCommitReceipt {
        let change = try prepareInstallation(initialMode: initialMode)
        let receipt = try commit(change)
        try verify(receipt)
        return receipt
    }

    public func prepareRestoration() throws -> PreparedThemeChange {
        try prepareRestoration(from: inspect())
    }

    public func prepareRestoration(from inspection: ThemeInspection) throws -> PreparedThemeChange {
        guard inspection.status == .ready,
              let settingsSnapshot = inspection.snapshot(for: settingsURL),
              let settingsData = settingsSnapshot.data,
              let manifestSnapshot = inspection.snapshot(for: manifestURL),
              let manifestData = manifestSnapshot.data,
              let backupSnapshot = inspection.snapshot(for: backupURL),
              let backupData = backupSnapshot.data else {
            throw VSCodeThemeAdapterError.integrationNotInstalled
        }
        let manifest = try decodeAndValidateManifest(manifestData)
        guard ThemeFileHash.sha256(backupData) == manifest.backupHash else {
            throw VSCodeThemeAdapterError.ownershipConflict("恢复备份哈希不匹配。")
        }

        var current = try JSONCEditor(data: settingsData)
        let original = try JSONCEditor(data: backupData)
        guard let managedColors = try current.rawRootValue(forKey: "workbench.colorCustomizations"),
              ThemeFileHash.sha256(managedColors) == manifest.managedColorCustomizationsHash else {
            throw VSCodeThemeAdapterError.ownershipConflict("颜色主题块已被修改，不能自动恢复。")
        }

        try current.setRootString(
            try original.rootString(forKey: "workbench.colorTheme") ?? "Dark Modern",
            forKey: "workbench.colorTheme"
        )
        if let originalColors = try original.rawRootValue(forKey: "workbench.colorCustomizations") {
            try current.setRootRawData(originalColors, forKey: "workbench.colorCustomizations")
        } else {
            try current.removeRootValue(forKey: "workbench.colorCustomizations")
        }
        if let originalAutoDetect = try original.rawRootValue(forKey: "window.autoDetectColorScheme") {
            try current.setRootRawData(originalAutoDetect, forKey: "window.autoDetectColorScheme")
        } else {
            try current.removeRootValue(forKey: "window.autoDetectColorScheme")
        }
        let originalIgnoredRaw = try original.rawRootValue(forKey: "settingsSync.ignoredSettings")
        let originalIgnored = try original.rootStringArray(forKey: "settingsSync.ignoredSettings") ?? []
        if !originalIgnored.contains("workbench.colorTheme") {
            var expectedAfterInstallation = original
            try expectedAfterInstallation.appendUniqueString(
                "workbench.colorTheme",
                toRootArray: "settingsSync.ignoredSettings"
            )
            let expectedInstalledRaw = try expectedAfterInstallation.rawRootValue(
                forKey: "settingsSync.ignoredSettings"
            )
            let currentIgnoredRaw = try current.rawRootValue(forKey: "settingsSync.ignoredSettings")

            if currentIgnoredRaw == expectedInstalledRaw, let originalIgnoredRaw {
                // No one has touched this array since installation. Restore the
                // backup's value byte-for-byte, including comments and a trailing comma.
                try current.setRootRawData(originalIgnoredRaw, forKey: "settingsSync.ignoredSettings")
            } else if currentIgnoredRaw == expectedInstalledRaw {
                try current.removeRootValue(forKey: "settingsSync.ignoredSettings")
            } else {
                // Preserve later user additions/formatting and remove only the
                // one value owned by this integration.
                try current.removeString("workbench.colorTheme", fromRootArray: "settingsSync.ignoredSettings")
                if originalIgnoredRaw == nil,
                   try current.rootStringArray(forKey: "settingsSync.ignoredSettings")?.isEmpty == true {
                    try current.removeRootValue(forKey: "settingsSync.ignoredSettings")
                }
            }
        }

        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: .dark,
            mutations: [
                PreparedThemeMutation(snapshot: settingsSnapshot, candidateData: current.data, label: "字段级恢复 VS Code 配置"),
                PreparedThemeMutation(snapshot: manifestSnapshot, candidateData: nil, label: "移除 VS Code ownership manifest"),
                PreparedThemeMutation(snapshot: backupSnapshot, candidateData: nil, label: "移除已消费的 VS Code ownership 备份"),
            ],
            metadata: ["operation": "restore"]
        )
    }

    @discardableResult
    public func restoreIntegration() throws -> ThemeCommitReceipt {
        let change = try prepareRestoration()
        let receipt = try commit(change)
        try verify(receipt)
        return receipt
    }

    public func commit(_ change: PreparedThemeChange) throws -> ThemeCommitReceipt {
        guard change.adapterIdentifier == identifier else { throw VSCodeThemeAdapterError.unexpectedPreparedChange }
        if change.metadata["operation"] == "switch" {
            try requireDependencyHash(change.metadata["manifestHash"], at: manifestURL)
            try requireDependencyHash(change.metadata["backupHash"], at: backupURL)
        }
        return try executor.commit(change)
    }

    public func verify(_ receipt: ThemeCommitReceipt) throws { try executor.verify(receipt) }

    public func rollback(_ receipt: ThemeCommitReceipt) throws {
        guard receipt.change.adapterIdentifier == identifier else { throw VSCodeThemeAdapterError.unexpectedPreparedChange }
        try executor.rollback(receipt)
    }

    private func decodeAndValidateManifest(_ data: Data) throws -> VSCodeOwnershipManifest {
        let manifest: VSCodeOwnershipManifest
        do {
            manifest = try JSONDecoder().decode(VSCodeOwnershipManifest.self, from: data)
        } catch {
            throw VSCodeThemeAdapterError.invalidManifest(error.localizedDescription)
        }
        guard manifest.version == VSCodeOwnershipManifest.currentVersion else {
            throw VSCodeThemeAdapterError.invalidManifest("不支持的版本 \(manifest.version)。")
        }
        guard manifest.settingsPath == settingsURL.path,
              manifest.backupFileName == backupURL.lastPathComponent else {
            throw VSCodeThemeAdapterError.invalidManifest("路径与当前适配器不匹配。")
        }
        return manifest
    }

    private func requireDependencyHash(_ expectedHash: String?, at url: URL) throws {
        let actualHash = try fileSystem.currentHash(at: url)
        guard expectedHash != nil, actualHash == expectedHash else {
            throw ThemeFileMutationError.conflict(url, expectedHash: expectedHash, actualHash: actualHash)
        }
    }

    private func details(_ theme: String?, _ autoDetect: Bool?, _ ignoresTheme: Bool, _ manifest: Bool) -> [String: String] {
        [
            "colorTheme": theme ?? "未设置",
            "autoDetectColorScheme": autoDetect.map(String.init) ?? "未设置",
            "ignoresThemeSync": String(ignoresTheme),
            "ownershipManifest": String(manifest),
        ]
    }

    private static func mode(forThemeName name: String?) -> ThemeMode? {
        switch name {
        case "Dark Modern": return .dark
        case "Light Modern": return .light
        default: return nil
        }
    }

    private static func themeName(for mode: ThemeMode) -> String {
        switch mode {
        case .dark: return "Dark Modern"
        case .light: return "Light Modern"
        }
    }
}
