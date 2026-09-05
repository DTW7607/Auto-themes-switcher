import Foundation
import XCTest
@testable import AutoThemeSwitcherCore

final class GhosttyReloadBehaviorTests: XCTestCase {
    func testNoTerminalRequestsSIGUSR2ForTheDiscoveredRunningPID() {
        let script = RecordingAppleScriptExecutor(result: .returned("no-terminal"))
        let query = RecordingGhosttyProcessQuery(application: GhosttyRunningApplication(processIdentifier: 4123))
        let signaler = RecordingGhosttyProcessSignaler(result: .sent)
        let reloader = AppleScriptGhosttyReloader(
            scriptExecutor: script,
            processQuery: query,
            processSignaler: signaler
        )

        XCTAssertEqual(reloader.reloadIfRunning(), .reloadRequested)
        XCTAssertEqual(script.callCount, 1)
        XCTAssertEqual(query.callCount, 1)
        XCTAssertEqual(signaler.processIdentifiers, [4123])
    }

    func testSuccessfulWindowReloadDoesNotQueryOrSignalProcess() {
        let script = RecordingAppleScriptExecutor(result: .returned("reloaded"))
        let query = RecordingGhosttyProcessQuery(application: GhosttyRunningApplication(processIdentifier: 4123))
        let signaler = RecordingGhosttyProcessSignaler(result: .sent)
        let reloader = AppleScriptGhosttyReloader(
            scriptExecutor: script,
            processQuery: query,
            processSignaler: signaler
        )

        XCTAssertEqual(reloader.reloadIfRunning(), .reloaded)
        XCTAssertEqual(script.callCount, 1)
        XCTAssertEqual(query.callCount, 0)
        XCTAssertTrue(signaler.processIdentifiers.isEmpty)
    }

    func testNotRunningActionFailureAndAutomationDeniedNeverFallBackToSignal() {
        let cases: [GhosttyAppleScriptExecution] = [
            .returned("not-running"),
            .returned("action-failed"),
            .failed("Not authorized to send Apple events")
        ]

        for execution in cases {
            let script = RecordingAppleScriptExecutor(result: execution)
            let query = RecordingGhosttyProcessQuery(
                application: GhosttyRunningApplication(processIdentifier: 4123)
            )
            let signaler = RecordingGhosttyProcessSignaler(result: .sent)
            let reloader = AppleScriptGhosttyReloader(
                scriptExecutor: script,
                processQuery: query,
                processSignaler: signaler
            )

            let result = reloader.reloadIfRunning()
            switch execution {
            case .returned("not-running"):
                XCTAssertEqual(result, .notRunning)
            case .returned("action-failed"), .failed:
                guard case .pending = result else {
                    return XCTFail("expected pending for AppleScript failure, got \(result)")
                }
            default:
                return XCTFail("unexpected test case")
            }
            XCTAssertEqual(query.callCount, 0)
            XCTAssertTrue(signaler.processIdentifiers.isEmpty)
        }
    }

    func testMissingUnfinishedTerminatedAndInvalidProcessAreNotSignaled() {
        let applications: [GhosttyRunningApplication?] = [
            nil,
            GhosttyRunningApplication(processIdentifier: 4123, isFinishedLaunching: false),
            GhosttyRunningApplication(processIdentifier: 4123, isTerminated: true),
            GhosttyRunningApplication(processIdentifier: 0),
            GhosttyRunningApplication(processIdentifier: -1)
        ]

        for application in applications {
            let query = RecordingGhosttyProcessQuery(application: application)
            let signaler = RecordingGhosttyProcessSignaler(result: .sent)
            let reloader = AppleScriptGhosttyReloader(
                scriptExecutor: RecordingAppleScriptExecutor(result: .returned("no-terminal")),
                processQuery: query,
                processSignaler: signaler
            )

            XCTAssertEqual(reloader.reloadIfRunning(), .notRunning)
            XCTAssertEqual(query.callCount, 1)
            XCTAssertTrue(signaler.processIdentifiers.isEmpty)
        }
    }

    func testProcessExitedBetweenQueryAndSignalIsNotRunning() {
        let reloader = AppleScriptGhosttyReloader(
            scriptExecutor: RecordingAppleScriptExecutor(result: .returned("no-terminal")),
            processQuery: RecordingGhosttyProcessQuery(
                application: GhosttyRunningApplication(processIdentifier: 4123)
            ),
            processSignaler: RecordingGhosttyProcessSignaler(result: .notRunning)
        )

        XCTAssertEqual(reloader.reloadIfRunning(), .notRunning)
    }

    func testSignalFailureBecomesPending() {
        let reloader = AppleScriptGhosttyReloader(
            scriptExecutor: RecordingAppleScriptExecutor(result: .returned("no-terminal")),
            processQuery: RecordingGhosttyProcessQuery(
                application: GhosttyRunningApplication(processIdentifier: 4123)
            ),
            processSignaler: RecordingGhosttyProcessSignaler(result: .failed("operation not permitted"))
        )

        XCTAssertEqual(
            reloader.reloadIfRunning(),
            .pending("无法请求 Ghostty 重载：operation not permitted")
        )
    }

    func testReloadRequestedReceiptHasNormalMetadataAndVerifiesWrittenConfiguration() throws {
        let fileSystem = GhosttyTestMemoryFileSystem([
            testMainURL: Data("font-size = 13\n".utf8)
        ])
        let adapter = GhosttyThemeAdapter(
            configuration: GhosttyConfiguration(mainConfigURL: testMainURL),
            fileSystem: fileSystem,
            validator: NoOpGhosttyValidator(),
            reloader: StubGhosttyReloader(result: .reloadRequested)
        )

        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        let receipt = try adapter.commit(change)
        try adapter.verify(receipt)

        XCTAssertEqual(receipt.metadata["reload"], "reloadRequested")
        XCTAssertEqual(receipt.metadata["pendingReload"], "false")
        XCTAssertEqual(try adapter.inspect().detectedMode, .light)
    }

    func testSameModeCommitDoesNotMutateFilesButStillRequestsReload() throws {
        let original = Data("font-size = 13\n".utf8)
        let fileSystem = GhosttyTestMemoryFileSystem([testMainURL: original])
        let reloader = StubGhosttyReloader(result: .reloadRequested)
        let adapter = GhosttyThemeAdapter(
            configuration: GhosttyConfiguration(mainConfigURL: testMainURL),
            fileSystem: fileSystem,
            validator: NoOpGhosttyValidator(),
            reloader: reloader
        )

        let first = try adapter.commit(try adapter.prepare(targetMode: .light, from: adapter.inspect()))
        try adapter.verify(first)
        let before = fileSystem.allData
        let sameMode = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        XCTAssertTrue(sameMode.mutations.isEmpty)

        let receipt = try adapter.commit(sameMode)
        try adapter.verify(receipt)
        XCTAssertEqual(fileSystem.allData, before)
        XCTAssertEqual(reloader.reloadCount, 2)
        XCTAssertEqual(receipt.metadata["reload"], "reloadRequested")
    }

    func testRollbackRestoresFilesAndReusesTheSameReloader() throws {
        let original = Data("font-size = 13\n".utf8)
        let fileSystem = GhosttyTestMemoryFileSystem([testMainURL: original])
        let reloader = StubGhosttyReloader(result: .reloadRequested)
        let adapter = GhosttyThemeAdapter(
            configuration: GhosttyConfiguration(mainConfigURL: testMainURL),
            fileSystem: fileSystem,
            validator: NoOpGhosttyValidator(),
            reloader: reloader
        )

        let change = try adapter.prepare(targetMode: .light, from: adapter.inspect())
        let receipt = try adapter.commit(change)
        XCTAssertEqual(reloader.reloadCount, 1)
        try adapter.rollback(receipt)

        XCTAssertEqual(fileSystem.data(at: testMainURL), original)
        XCTAssertNil(fileSystem.data(at: adapter.configuration.modeConfigURL))
        XCTAssertNil(fileSystem.data(at: adapter.configuration.lightConfigURL))
        XCTAssertEqual(reloader.reloadCount, 2)
    }

    func testAdapterAndInjectedAppleScriptReloaderCommitReloadRequestedAndPending() throws {
        let customizedLight = GhosttyThemeAdapter.defaultLightConfigurationData
            + Data("font-thicken = true\n".utf8)
        let main = Data("""
        font-family = Berkeley Mono
        \(GhosttyThemeAdapter.beginMarker)
        config-file = ?.auto-theme-switcher-mode.ghostty
        \(GhosttyThemeAdapter.endMarker)
        """.utf8)
        let mode = Data()
        let fileSystem = GhosttyTestMemoryFileSystem([
            testMainURL: main,
            testMainURL.deletingLastPathComponent()
                .appendingPathComponent(GhosttyConfiguration.modeFileName): mode,
            testMainURL.deletingLastPathComponent()
                .appendingPathComponent(GhosttyConfiguration.lightFileName): customizedLight
        ])
        let configuration = GhosttyConfiguration(mainConfigURL: testMainURL)

        let successfulReloader = AppleScriptGhosttyReloader(
            scriptExecutor: RecordingAppleScriptExecutor(result: .returned("no-terminal")),
            processQuery: RecordingGhosttyProcessQuery(
                application: GhosttyRunningApplication(processIdentifier: 7123)
            ),
            processSignaler: RecordingGhosttyProcessSignaler(result: .sent)
        )
        let adapter = GhosttyThemeAdapter(
            configuration: configuration,
            fileSystem: fileSystem,
            validator: NoOpGhosttyValidator(),
            reloader: successfulReloader
        )

        let light = try adapter.commit(try adapter.prepare(targetMode: .light, from: adapter.inspect()))
        try adapter.verify(light)
        XCTAssertEqual(light.metadata["reload"], "reloadRequested")
        XCTAssertEqual(light.metadata["pendingReload"], "false")
        XCTAssertEqual(try adapter.inspect().detectedMode, .light)

        let dark = try adapter.commit(try adapter.prepare(targetMode: .dark, from: adapter.inspect()))
        try adapter.verify(dark)
        XCTAssertEqual(dark.metadata["reload"], "reloadRequested")
        XCTAssertEqual(dark.metadata["pendingReload"], "false")
        XCTAssertEqual(try adapter.inspect().detectedMode, .dark)
        XCTAssertEqual(fileSystem.data(at: configuration.lightConfigURL), customizedLight)

        let failedReloader = AppleScriptGhosttyReloader(
            scriptExecutor: RecordingAppleScriptExecutor(result: .returned("no-terminal")),
            processQuery: RecordingGhosttyProcessQuery(
                application: GhosttyRunningApplication(processIdentifier: 7123)
            ),
            processSignaler: RecordingGhosttyProcessSignaler(result: .failed("operation not permitted"))
        )
        let failedAdapter = GhosttyThemeAdapter(
            configuration: configuration,
            fileSystem: fileSystem,
            validator: NoOpGhosttyValidator(),
            reloader: failedReloader
        )
        let pending = try failedAdapter.commit(
            try failedAdapter.prepare(targetMode: .light, from: failedAdapter.inspect())
        )
        try failedAdapter.verify(pending)
        XCTAssertEqual(pending.metadata["pendingReload"], "true")
        XCTAssertEqual(try failedAdapter.inspect().detectedMode, .light)
        XCTAssertEqual(fileSystem.data(at: configuration.lightConfigURL), customizedLight)
    }

    private let testMainURL = URL(fileURLWithPath: "/virtual/ghostty-reload/config.ghostty")
}

private final class RecordingAppleScriptExecutor: GhosttyAppleScriptExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: GhosttyAppleScriptExecution
    private var count = 0

    init(result: GhosttyAppleScriptExecution) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func execute(source _: String) -> GhosttyAppleScriptExecution {
        lock.lock()
        count += 1
        lock.unlock()
        return result
    }
}

private final class RecordingGhosttyProcessQuery: GhosttyProcessQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private let application: GhosttyRunningApplication?
    private var count = 0

    init(application: GhosttyRunningApplication?) {
        self.application = application
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func runningGhosttyApplication() -> GhosttyRunningApplication? {
        lock.lock()
        count += 1
        lock.unlock()
        return application
    }
}

private final class RecordingGhosttyProcessSignaler: GhosttyProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private let result: GhosttySignalResult
    private var identifiers: [Int32] = []

    init(result: GhosttySignalResult) {
        self.result = result
    }

    var processIdentifiers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func sendSIGUSR2(to processIdentifier: Int32) -> GhosttySignalResult {
        lock.lock()
        identifiers.append(processIdentifier)
        lock.unlock()
        return result
    }
}

private struct NoOpGhosttyValidator: GhosttyConfigValidating {
    func validate(_: GhosttyValidationCandidate) throws {}
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

private final class GhosttyTestMemoryFileSystem: ThemeFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data]

    init(_ storage: [URL: Data] = [:]) {
        self.storage = Dictionary(uniqueKeysWithValues: storage.map {
            ($0.key.standardizedFileURL, $0.value)
        })
    }

    var allData: [URL: Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func fileExists(at fileURL: URL) -> Bool { data(at: fileURL) != nil }

    func readData(at fileURL: URL) throws -> Data {
        guard let value = data(at: fileURL) else { throw CocoaError(.fileNoSuchFile) }
        return value
    }

    func createDirectory(at _: URL) throws {}

    func atomicWrite(_ data: Data, to fileURL: URL, preservingMetadata _: Bool) throws {
        lock.lock()
        storage[fileURL.standardizedFileURL] = data
        lock.unlock()
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
}
