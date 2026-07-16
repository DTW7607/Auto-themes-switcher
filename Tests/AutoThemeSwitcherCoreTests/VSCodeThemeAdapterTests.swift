import Foundation
import XCTest
@testable import AutoThemeSwitcherCore

final class VSCodeThemeAdapterTests: XCTestCase {
    private let settingsURL = URL(fileURLWithPath: "/virtual/Code/User/settings.json")
    private let backupDirectoryURL = URL(fileURLWithPath: "/virtual/AutoThemeSwitcher/VSCode")

    func testFirstInstallCreatesExactBackupManifestAndManagedSettings() throws {
        let original = fixtureData()
        let fileSystem = MemoryThemeFileSystem([settingsURL: original])
        let adapter = makeAdapter(fileSystem)

        XCTAssertEqual(try adapter.inspect().status, .needsInstallation)
        let prepared = try adapter.prepareInstallation(initialMode: .dark)
        XCTAssertEqual(prepared.mutations.count, 3)
        XCTAssertEqual(prepared.mutations[0].candidateData, original)
        XCTAssertEqual(prepared.mutations[0].expectedHash, nil)

        let receipt = try adapter.commit(prepared)
        try adapter.verify(receipt)
        let inspection = try adapter.inspect()
        XCTAssertEqual(inspection.status, .ready)
        XCTAssertEqual(inspection.detectedMode, .dark)

        let installedData = try XCTUnwrap(fileSystem.data(at: settingsURL))
        let installed = try JSONCEditor(data: installedData)
        XCTAssertEqual(try installed.rootBoolean(forKey: "window.autoDetectColorScheme"), false)
        XCTAssertTrue(try installed.rootStringArray(forKey: "settingsSync.ignoredSettings")?.contains("workbench.colorTheme") == true)
        XCTAssertTrue(try installed.hasInstalledVSCodeThemeColorBlocks())
        XCTAssertEqual(try installed.rootString(forKey: "workbench.colorTheme"), "Dark Modern")
        XCTAssertTrue(installed.source.contains("\"editor.background\": \"#FFFFFF\""))
        XCTAssertTrue(installed.source.contains("\"terminal.ansiBlack\": \"#24292F\""))
    }

    func testReadyPrepareChangesOnlyTopLevelThemeValue() throws {
        let fileSystem = MemoryThemeFileSystem([settingsURL: fixtureData()])
        let adapter = makeAdapter(fileSystem)
        _ = try adapter.installIntegration()
        let before = try XCTUnwrap(fileSystem.data(at: settingsURL))
        var expected = try JSONCEditor(data: before)
        try expected.setRootString("Light Modern", forKey: "workbench.colorTheme")

        let inspection = try adapter.inspect()
        let change = try adapter.prepare(targetMode: .light, from: inspection)
        XCTAssertEqual(change.mutations.count, 1)
        XCTAssertEqual(change.mutations[0].candidateData, expected.data)

        _ = try adapter.commit(change)
        XCTAssertEqual(try adapter.inspect().detectedMode, .light)
    }

    func testCASStopsExternalConcurrentEdit() throws {
        let fileSystem = MemoryThemeFileSystem([settingsURL: fixtureData()])
        let adapter = makeAdapter(fileSystem)
        _ = try adapter.installIntegration()
        let change = try adapter.prepare(theme: .light)

        var externallyEdited = try JSONCEditor(data: try XCTUnwrap(fileSystem.data(at: settingsURL)))
        try externallyEdited.setRootString("changed elsewhere", forKey: "user.note")
        fileSystem.put(externallyEdited.data, at: settingsURL)

        XCTAssertThrowsError(try adapter.commit(change)) { error in
            guard case ThemeFileMutationError.conflict = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPreexistingThemeBlocksAreNotClaimed() throws {
        let data = Data("""
        {
          "workbench.colorTheme": "Dark Modern",
          "workbench.colorCustomizations": {
            "[Dark Modern]": {},
            "[Light Modern]": {},
          },
        }
        """.utf8)
        let adapter = makeAdapter(MemoryThemeFileSystem([settingsURL: data]))
        let inspection = try adapter.inspect()
        XCTAssertEqual(inspection.status, .conflict)
        XCTAssertThrowsError(try adapter.prepareInstallation())
    }

    func testRestoreIsFieldLevelAndKeepsUnrelatedLaterEdits() throws {
        let original = fixtureData()
        let fileSystem = MemoryThemeFileSystem([settingsURL: original])
        let adapter = makeAdapter(fileSystem)
        _ = try adapter.installIntegration(initialMode: .light)

        var edited = try JSONCEditor(data: try XCTUnwrap(fileSystem.data(at: settingsURL)))
        try edited.setRootString("later user edit", forKey: "user.note")
        fileSystem.put(edited.data, at: settingsURL)
        XCTAssertEqual(try adapter.inspect().status, .ready)

        let receipt = try adapter.restoreIntegration()
        try adapter.verify(receipt)
        let restoredData = try XCTUnwrap(fileSystem.data(at: settingsURL))
        let restored = try JSONCEditor(data: restoredData)
        let originalEditor = try JSONCEditor(data: original)

        XCTAssertEqual(try restored.rootString(forKey: "workbench.colorTheme"), "Dark Modern")
        XCTAssertEqual(try restored.rootString(forKey: "user.note"), "later user edit")
        XCTAssertEqual(
            try restored.rawRootValue(forKey: "workbench.colorCustomizations"),
            try originalEditor.rawRootValue(forKey: "workbench.colorCustomizations")
        )
        XCTAssertNil(try restored.rootBoolean(forKey: "window.autoDetectColorScheme"))
        XCTAssertFalse(try restored.rootStringArray(forKey: "settingsSync.ignoredSettings")?.contains("workbench.colorTheme") == true)
        XCTAssertNil(fileSystem.data(at: backupDirectoryURL.appendingPathComponent("ownership.json")))
        XCTAssertNil(fileSystem.data(at: backupDirectoryURL.appendingPathComponent("settings.json.before-auto-theme-switcher.backup")))

        // Restore leaves no orphan ownership files, so a later reinstall is valid.
        XCTAssertEqual(try adapter.inspect().status, .needsInstallation)
        _ = try adapter.installIntegration()
        XCTAssertEqual(try adapter.inspect().status, .ready)
    }

    func testRestoreReinstatesUntouchedIgnoredSettingsRawValueExactly() throws {
        let original = Data("""
        {
          "workbench.colorTheme": "Dark Modern",
          "workbench.colorCustomizations": {
            "editor.foreground": "#CCCCCC",
          },
          "settingsSync.ignoredSettings": [
            // keep this comment and trailing comma exactly
            "editor.fontSize",
          ],
        }
        """.utf8)
        let originalEditor = try JSONCEditor(data: original)
        let originalIgnoredRaw = try XCTUnwrap(
            originalEditor.rawRootValue(forKey: "settingsSync.ignoredSettings")
        )
        let fileSystem = MemoryThemeFileSystem([settingsURL: original])
        let adapter = makeAdapter(fileSystem)

        _ = try adapter.installIntegration()
        _ = try adapter.restoreIntegration()

        let restored = try JSONCEditor(data: try XCTUnwrap(fileSystem.data(at: settingsURL)))
        XCTAssertEqual(
            try restored.rawRootValue(forKey: "settingsSync.ignoredSettings"),
            originalIgnoredRaw
        )
    }

    func testRestoreKeepsIgnoredSettingsAddedAfterInstallation() throws {
        let original = Data("""
        {
          "workbench.colorTheme": "Dark Modern",
          "workbench.colorCustomizations": {
            "editor.foreground": "#CCCCCC",
          },
          "settingsSync.ignoredSettings": [
            // existing user entry
            "editor.fontSize",
          ],
        }
        """.utf8)
        let fileSystem = MemoryThemeFileSystem([settingsURL: original])
        let adapter = makeAdapter(fileSystem)
        _ = try adapter.installIntegration()

        var edited = try JSONCEditor(data: try XCTUnwrap(fileSystem.data(at: settingsURL)))
        try edited.appendUniqueString("user.added.after.install", toRootArray: "settingsSync.ignoredSettings")
        fileSystem.put(edited.data, at: settingsURL)

        _ = try adapter.restoreIntegration()

        let restored = try JSONCEditor(data: try XCTUnwrap(fileSystem.data(at: settingsURL)))
        XCTAssertEqual(
            try restored.rootStringArray(forKey: "settingsSync.ignoredSettings"),
            ["editor.fontSize", "user.added.after.install"]
        )
        let restoredRaw = String(decoding: try XCTUnwrap(
            restored.rawRootValue(forKey: "settingsSync.ignoredSettings")
        ), as: UTF8.self)
        XCTAssertTrue(restoredRaw.contains("// existing user entry"))
        XCTAssertTrue(restoredRaw.contains("\"editor.fontSize\","))
    }

    func testManagedColorModificationBlocksSwitchAndRestore() throws {
        let fileSystem = MemoryThemeFileSystem([settingsURL: fixtureData()])
        let adapter = makeAdapter(fileSystem)
        _ = try adapter.installIntegration()
        let current = String(decoding: try XCTUnwrap(fileSystem.data(at: settingsURL)), as: UTF8.self)
        fileSystem.put(Data(current.replacingOccurrences(of: "#FFFFFF", with: "#FEFEFE").utf8), at: settingsURL)

        XCTAssertEqual(try adapter.inspect().status, .conflict)
        XCTAssertThrowsError(try adapter.prepareRestoration())
    }

    func testUnknownThemeAfterInstallationPausesAutomation() throws {
        let fileSystem = MemoryThemeFileSystem([settingsURL: fixtureData()])
        let adapter = makeAdapter(fileSystem)
        _ = try adapter.installIntegration()

        var externallyEdited = try JSONCEditor(data: try XCTUnwrap(fileSystem.data(at: settingsURL)))
        try externallyEdited.setRootString("A User Selected Theme", forKey: "workbench.colorTheme")
        fileSystem.put(externallyEdited.data, at: settingsURL)

        let inspection = try adapter.inspect()
        XCTAssertEqual(inspection.status, .conflict)
        XCTAssertNil(inspection.detectedMode)
        XCTAssertTrue(inspection.message?.contains("不会自动覆盖用户选择") == true)
        XCTAssertThrowsError(try adapter.prepare(targetMode: .light, from: inspection))
    }

    private func makeAdapter(_ fileSystem: MemoryThemeFileSystem) -> VSCodeThemeAdapter {
        VSCodeThemeAdapter(
            settingsURL: settingsURL,
            backupDirectoryURL: backupDirectoryURL,
            fileSystem: fileSystem
        )
    }

    private func fixtureData() -> Data {
        Data("""
        {
            // keep root comment
            "user.note": "original",
            "workbench.colorTheme": "Dark Modern",
            "workbench.colorCustomizations": {
                "editor.foreground": "#CCCCCC",
                "terminal.ansiRed": "#F74949",
            },
            "settingsSync.ignoredSettings": ["editor.fontSize"],
        }
        """.utf8)
    }
}

private final class MemoryThemeFileSystem: ThemeFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data]

    init(_ storage: [URL: Data] = [:]) {
        self.storage = Dictionary(uniqueKeysWithValues: storage.map { ($0.key.standardizedFileURL, $0.value) })
    }

    func fileExists(at fileURL: URL) -> Bool { data(at: fileURL) != nil }

    func readData(at fileURL: URL) throws -> Data {
        guard let data = data(at: fileURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    func createDirectory(at _: URL) throws {}

    func atomicWrite(_ data: Data, to fileURL: URL, preservingMetadata _: Bool) throws {
        put(data, at: fileURL)
    }

    func removeItem(at fileURL: URL) throws {
        lock.lock()
        storage.removeValue(forKey: fileURL.standardizedFileURL)
        lock.unlock()
    }

    func data(at fileURL: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[fileURL.standardizedFileURL]
    }

    func put(_ data: Data, at fileURL: URL) {
        lock.lock()
        storage[fileURL.standardizedFileURL] = data
        lock.unlock()
    }
}
