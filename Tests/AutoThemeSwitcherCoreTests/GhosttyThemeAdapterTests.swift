import Foundation
import XCTest
@testable import AutoThemeSwitcherCore

final class GhosttyThemeAdapterTests: XCTestCase {
    private let mainURL = URL(fileURLWithPath: "/virtual/ghostty/config.ghostty")

    func testReloadAppleScriptTargetsATerminalAndChecksTheActionResult() {
        let script = AppleScriptGhosttyReloader.reloadScriptSource

        XCTAssertTrue(script.contains("first terminal"))
        XCTAssertTrue(script.contains("perform action \"reload_config\" on targetTerminal"))
        XCTAssertTrue(script.contains("if didReload then"))
    }

    func testFirstLightInstallAddsOwnedIncludeAndBothHelperFiles() throws {
        let original = Data("font-family = Berkeley Mono\nwindow-padding-x = 8\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: original])
        let validator = CapturingGhosttyValidator()
        let reloader = StubGhosttyReloader(result: .reloaded)
        let adapter = makeAdapter(fileSystem, validator: validator, reloader: reloader)

        XCTAssertEqual(try adapter.inspect().status, .needsInstallation)
        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        let validated = try XCTUnwrap(validator.lastCandidate)
        XCTAssertTrue(String(decoding: validated.mainConfigData, as: UTF8.self).contains(Self.markerBlock))
        XCTAssertEqual(
            validated.modeConfigData,
            Data((GhosttyThemeAdapter.lightIncludeLine + "\n").utf8)
        )
        XCTAssertEqual(validated.lightConfigData, GhosttyThemeAdapter.defaultLightConfigurationData)

        let receipt = try adapter.commit(change)
        try adapter.verify(receipt)

        let configuration = adapter.configuration
        let installedMain = try XCTUnwrap(fileSystem.data(at: configuration.mainConfigURL))
        XCTAssertTrue(installedMain.starts(with: original))
        XCTAssertTrue(String(decoding: installedMain, as: UTF8.self).contains(Self.markerBlock))
        XCTAssertEqual(
            fileSystem.data(at: configuration.modeConfigURL),
            Data((GhosttyThemeAdapter.lightIncludeLine + "\n").utf8)
        )
        XCTAssertEqual(
            fileSystem.data(at: configuration.lightConfigURL),
            GhosttyThemeAdapter.defaultLightConfigurationData
        )
        XCTAssertEqual(reloader.reloadCount, 1)
        XCTAssertEqual(receipt.metadata["pendingReload"], "false")
        XCTAssertEqual(try adapter.inspect().detectedMode, .light)
    }

    func testDarkSwitchOnlyEmptiesModeOverlayAndKeepsUserConfiguration() throws {
        let original = Data("font-size = 15\nbackground-opacity = 0.91\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: original])
        let adapter = makeAdapter(fileSystem)
        _ = try install(adapter, mode: .light)
        let mainAfterInstall = fileSystem.data(at: adapter.configuration.mainConfigURL)
        let lightAfterInstall = fileSystem.data(at: adapter.configuration.lightConfigURL)

        let change = try adapter.prepare(targetMode: .dark, from: adapter.inspect())
        XCTAssertEqual(change.mutations.map(\.fileURL), [adapter.configuration.modeConfigURL])
        let receipt = try adapter.commit(change)
        try adapter.verify(receipt)

        XCTAssertEqual(fileSystem.data(at: adapter.configuration.modeConfigURL), Data())
        XCTAssertEqual(fileSystem.data(at: adapter.configuration.mainConfigURL), mainAfterInstall)
        XCTAssertEqual(fileSystem.data(at: adapter.configuration.lightConfigURL), lightAfterInstall)
        XCTAssertTrue(
            String(decoding: try XCTUnwrap(mainAfterInstall), as: UTF8.self)
                .contains("background-opacity = 0.91")
        )
    }

    func testCustomizedLightFileIsNeverOverwrittenByLaterSwitches() throws {
        let fileSystem = GhosttyMemoryFileSystem([mainURL: Data("theme = Dark Modern\n".utf8)])
        let adapter = makeAdapter(fileSystem)
        _ = try install(adapter, mode: .light)

        let customized = GhosttyThemeAdapter.defaultLightConfigurationData
            + Data("font-thicken = true\n".utf8)
        fileSystem.put(customized, at: adapter.configuration.lightConfigURL)

        let dark = try adapter.prepare(targetMode: .dark, from: adapter.inspect())
        XCTAssertFalse(dark.mutations.contains { $0.fileURL == adapter.configuration.lightConfigURL })
        _ = try adapter.commit(dark)
        let light = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        XCTAssertFalse(light.mutations.contains { $0.fileURL == adapter.configuration.lightConfigURL })
        _ = try adapter.commit(light)

        XCTAssertEqual(fileSystem.data(at: adapter.configuration.lightConfigURL), customized)
        XCTAssertEqual(try adapter.inspect().details["lightCustomized"], "true")
    }

    func testDeletedLightFileIsReportedAndRepaired() throws {
        let fileSystem = GhosttyMemoryFileSystem([mainURL: Data("font-size = 13\n".utf8)])
        let adapter = makeAdapter(fileSystem)
        _ = try install(adapter, mode: .light)
        try fileSystem.removeItem(at: adapter.configuration.lightConfigURL)

        let damaged = try adapter.inspect()
        XCTAssertEqual(damaged.status, .needsInstallation)
        let repair = try adapter.prepare(targetMode: .light, from: damaged)
        XCTAssertTrue(repair.mutations.contains { $0.fileURL == adapter.configuration.lightConfigURL })
        let receipt = try adapter.commit(repair)
        try adapter.verify(receipt)

        XCTAssertEqual(try adapter.inspect().status, .ready)
        XCTAssertEqual(
            fileSystem.data(at: adapter.configuration.lightConfigURL),
            GhosttyThemeAdapter.defaultLightConfigurationData
        )
    }

    func testValidatorFailureLeavesEveryFinalFileUntouched() throws {
        let original = Data("font-size = 13\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: original])
        let adapter = GhosttyThemeAdapter(
            configuration: GhosttyConfiguration(mainConfigURL: mainURL),
            fileSystem: fileSystem,
            validator: ThrowingGhosttyValidator(),
            reloader: StubGhosttyReloader(result: .notRunning)
        )

        XCTAssertThrowsError(try adapter.prepare(targetMode: .light, from: adapter.inspect()))
        XCTAssertEqual(fileSystem.data(at: mainURL), original)
        XCTAssertNil(fileSystem.data(at: adapter.configuration.modeConfigURL))
        XCTAssertNil(fileSystem.data(at: adapter.configuration.lightConfigURL))
    }

    func testPendingReloadDoesNotUndoCommittedConfiguration() throws {
        let fileSystem = GhosttyMemoryFileSystem([mainURL: Data("font-size = 13\n".utf8)])
        let reloader = StubGhosttyReloader(result: .pending("Automation denied"))
        let adapter = makeAdapter(fileSystem, reloader: reloader)
        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())

        let receipt = try adapter.commit(change)
        try adapter.verify(receipt)

        XCTAssertEqual(receipt.metadata["pendingReload"], "true")
        XCTAssertEqual(receipt.metadata["reload"], "Automation denied")
        XCTAssertEqual(try adapter.inspect().detectedMode, .light)
        XCTAssertEqual(reloader.reloadCount, 1)
    }

    func testNoTerminalDoesNotMarkCommittedConfigurationAsPendingReload() throws {
        let fileSystem = GhosttyMemoryFileSystem([mainURL: Data("font-size = 13\n".utf8)])
        let reloader = StubGhosttyReloader(result: .noTerminal)
        let adapter = makeAdapter(fileSystem, reloader: reloader)
        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())

        let receipt = try adapter.commit(change)
        try adapter.verify(receipt)

        XCTAssertEqual(receipt.metadata["pendingReload"], "false")
        XCTAssertEqual(receipt.metadata["reload"], "noTerminal")
        XCTAssertEqual(try adapter.inspect().detectedMode, .light)
        XCTAssertEqual(reloader.reloadCount, 1)
    }

    func testUnchangedValidatedLightDependencyIsRecheckedBeforeModeWrite() throws {
        let fileSystem = GhosttyMemoryFileSystem([mainURL: Data("font-size = 13\n".utf8)])
        let adapter = makeAdapter(fileSystem)
        _ = try install(adapter, mode: .dark)
        let modeBefore = fileSystem.data(at: adapter.configuration.modeConfigURL)
        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        let externalLight = GhosttyThemeAdapter.defaultLightConfigurationData
            + Data("# concurrent light edit\n".utf8)
        fileSystem.put(externalLight, at: adapter.configuration.lightConfigURL)

        XCTAssertThrowsError(try adapter.commit(change)) { error in
            guard case ThemeFileMutationError.conflict = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fileSystem.data(at: adapter.configuration.modeConfigURL), modeBefore)
        XCTAssertEqual(fileSystem.data(at: adapter.configuration.lightConfigURL), externalLight)
    }

    func testOrphanReservedFileIsConflictAndIsNeverClaimedOrDeleted() throws {
        let configuration = GhosttyConfiguration(mainConfigURL: mainURL)
        let orphan = Data("# this belongs to somebody else\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([
            mainURL: Data("font-size = 13\n".utf8),
            configuration.lightConfigURL: orphan
        ])
        let adapter = makeAdapter(fileSystem)
        let inspection = try adapter.inspect()

        XCTAssertEqual(inspection.status, .conflict)
        XCTAssertThrowsError(try adapter.prepare(targetMode: .light, from: inspection))
        XCTAssertThrowsError(try adapter.prepareRestoration(from: inspection)) { error in
            XCTAssertEqual(error as? GhosttyThemeAdapterError, .orphanedManagedFiles)
        }
        XCTAssertEqual(fileSystem.data(at: configuration.lightConfigURL), orphan)
        XCTAssertFalse(String(decoding: try fileSystem.readData(at: mainURL), as: UTF8.self).contains(Self.markerBlock))
    }

    func testMalformedOrDuplicateMarkerBlocksAllWrites() throws {
        let malformed = Data("""
        font-size = 13
        # BEGIN Auto Theme Switcher
        config-file = ?.auto-theme-switcher-mode.ghostty
        """.utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: malformed])
        let adapter = makeAdapter(fileSystem)
        let inspection = try adapter.inspect()

        XCTAssertEqual(inspection.status, .conflict)
        XCTAssertThrowsError(try adapter.prepare(targetMode: .light, from: inspection))
        XCTAssertEqual(fileSystem.data(at: mainURL), malformed)
    }

    func testCASDetectsConcurrentMainConfigEditBeforeWritingAnyHelper() throws {
        let original = Data("font-size = 13\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: original])
        let adapter = makeAdapter(fileSystem)
        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        fileSystem.put(original + Data("# concurrent edit\n".utf8), at: mainURL)

        XCTAssertThrowsError(try adapter.commit(change)) { error in
            guard case ThemeFileMutationError.conflict = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNil(fileSystem.data(at: adapter.configuration.modeConfigURL))
        XCTAssertNil(fileSystem.data(at: adapter.configuration.lightConfigURL))
    }

    func testRestorationRemovesOwnedDefaultFilesButPreservesCustomizedLightFile() throws {
        let original = Data("font-family = Berkeley Mono\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: original])
        let adapter = makeAdapter(fileSystem)
        _ = try install(adapter, mode: .light)

        let customized = GhosttyThemeAdapter.defaultLightConfigurationData
            + Data("# user's retained override\n".utf8)
        fileSystem.put(customized, at: adapter.configuration.lightConfigURL)
        let restoration = try adapter.prepareRestoration(from: adapter.inspect())
        XCTAssertEqual(restoration.metadata["preservedCustomizedLightFile"], "true")
        XCTAssertFalse(restoration.mutations.contains { $0.fileURL == adapter.configuration.lightConfigURL })
        let receipt = try adapter.commit(restoration)
        try adapter.verify(receipt)

        XCTAssertEqual(fileSystem.data(at: mainURL), original)
        XCTAssertNil(fileSystem.data(at: adapter.configuration.modeConfigURL))
        XCTAssertEqual(fileSystem.data(at: adapter.configuration.lightConfigURL), customized)
    }

    func testRestorationDeletesUnmodifiedGeneratedLightFile() throws {
        let original = Data("font-family = Berkeley Mono\n".utf8)
        let fileSystem = GhosttyMemoryFileSystem([mainURL: original])
        let adapter = makeAdapter(fileSystem)
        _ = try install(adapter, mode: .dark)

        let receipt = try adapter.commit(adapter.prepareRestoration(from: adapter.inspect()))
        try adapter.verify(receipt)

        XCTAssertEqual(fileSystem.data(at: mainURL), original)
        XCTAssertNil(fileSystem.data(at: adapter.configuration.modeConfigURL))
        XCTAssertNil(fileSystem.data(at: adapter.configuration.lightConfigURL))
    }

    func testDefaultCLIValidatorKeepsExistingRelativeIncludeSemantics() throws {
        let executableURL = URL(
            fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        )
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw XCTSkip("当前环境未安装 Ghostty CLI")
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyValidatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let configuration = GhosttyConfiguration(
            mainConfigURL: directoryURL.appendingPathComponent("config.ghostty")
        )
        try Data("font-size = 12\n".utf8).write(
            to: directoryURL.appendingPathComponent("existing-relative.ghostty")
        )
        let main = Data("""
        config-file = existing-relative.ghostty
        \(Self.markerBlock)

        """.utf8)
        let candidate = GhosttyValidationCandidate(
            configuration: configuration,
            mainConfigData: main,
            modeConfigData: Data((GhosttyThemeAdapter.lightIncludeLine + "\n").utf8),
            lightConfigData: GhosttyThemeAdapter.defaultLightConfigurationData
        )

        XCTAssertNoThrow(
            try GhosttyCLIConfigValidator(executableURL: executableURL).validate(candidate)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.mainConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.modeConfigURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.lightConfigURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        XCTAssertEqual(leftovers, ["existing-relative.ghostty"])
    }

    private func makeAdapter(
        _ fileSystem: GhosttyMemoryFileSystem,
        validator: CapturingGhosttyValidator = CapturingGhosttyValidator(),
        reloader: StubGhosttyReloader = StubGhosttyReloader(result: .notRunning)
    ) -> GhosttyThemeAdapter {
        GhosttyThemeAdapter(
            configuration: GhosttyConfiguration(mainConfigURL: mainURL),
            fileSystem: fileSystem,
            validator: validator,
            reloader: reloader
        )
    }

    @discardableResult
    private func install(_ adapter: GhosttyThemeAdapter, mode: ThemeMode) throws -> ThemeCommitReceipt {
        let change = try adapter.prepare(targetMode: mode, from: adapter.inspect())
        let receipt = try adapter.commit(change)
        try adapter.verify(receipt)
        return receipt
    }

    private static let markerBlock = """
    # BEGIN Auto Theme Switcher
    config-file = ?.auto-theme-switcher-mode.ghostty
    # END Auto Theme Switcher
    """
}

private final class CapturingGhosttyValidator: GhosttyConfigValidating, @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [GhosttyValidationCandidate] = []

    var lastCandidate: GhosttyValidationCandidate? {
        lock.lock()
        defer { lock.unlock() }
        return candidates.last
    }

    func validate(_ candidate: GhosttyValidationCandidate) throws {
        lock.lock()
        candidates.append(candidate)
        lock.unlock()
    }
}

private struct ThrowingGhosttyValidator: GhosttyConfigValidating {
    func validate(_: GhosttyValidationCandidate) throws {
        throw GhosttyConfigValidationError.invalidConfiguration("injected")
    }
}

private final class StubGhosttyReloader: GhosttyReloading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: GhosttyReloadResult
    private var count = 0

    init(result: GhosttyReloadResult) {
        self.result = result
    }

    var reloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reloadIfRunning() -> GhosttyReloadResult {
        lock.lock()
        count += 1
        lock.unlock()
        return result
    }
}

private final class GhosttyMemoryFileSystem: ThemeFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data]

    init(_ storage: [URL: Data] = [:]) {
        self.storage = Dictionary(uniqueKeysWithValues: storage.map {
            ($0.key.standardizedFileURL, $0.value)
        })
    }

    func fileExists(at fileURL: URL) -> Bool { data(at: fileURL) != nil }

    func readData(at fileURL: URL) throws -> Data {
        guard let value = data(at: fileURL) else { throw CocoaError(.fileNoSuchFile) }
        return value
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
