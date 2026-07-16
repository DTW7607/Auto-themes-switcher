import Darwin
import Foundation
import XCTest
@testable import AutoThemeSwitcherCore

final class ThemeTransactionTests: XCTestCase {
    func testExecutorRejectsCASConflictWithoutWriting() throws {
        let url = URL(fileURLWithPath: "/virtual/settings")
        let original = Data("original".utf8)
        let fileSystem = TransactionMemoryFileSystem([url: original])
        let snapshot = try fileSystem.snapshot(at: url)
        let change = PreparedThemeChange(
            adapterIdentifier: "test",
            targetMode: .light,
            mutations: [
                PreparedThemeMutation(snapshot: snapshot, candidateData: Data("candidate".utf8), label: "settings")
            ]
        )
        fileSystem.put(Data("external".utf8), at: url)

        XCTAssertThrowsError(try ThemeMutationExecutor(fileSystem: fileSystem).commit(change)) { error in
            guard case ThemeFileMutationError.conflict = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fileSystem.data(at: url), Data("external".utf8))
    }

    func testExecutorRechecksEachHashAndRollsBackEarlierWrite() throws {
        let first = URL(fileURLWithPath: "/virtual/first")
        let second = URL(fileURLWithPath: "/virtual/second")
        let firstOriginal = Data("first-original".utf8)
        let secondOriginal = Data("second-original".utf8)
        let external = Data("second-external".utf8)
        let fileSystem = TransactionMemoryFileSystem([
            first: firstOriginal,
            second: secondOriginal
        ])
        fileSystem.afterWrite = { writtenURL in
            if writtenURL == first {
                fileSystem.put(external, at: second)
            }
        }
        let change = PreparedThemeChange(
            adapterIdentifier: "test",
            targetMode: .light,
            mutations: [
                PreparedThemeMutation(
                    snapshot: try fileSystem.snapshot(at: first),
                    candidateData: Data("first-candidate".utf8),
                    label: "first"
                ),
                PreparedThemeMutation(
                    snapshot: ThemeFileSnapshot(fileURL: second, data: secondOriginal),
                    candidateData: Data("second-candidate".utf8),
                    label: "second"
                )
            ]
        )

        XCTAssertThrowsError(try ThemeMutationExecutor(fileSystem: fileSystem).commit(change))
        XCTAssertEqual(fileSystem.data(at: first), firstOriginal)
        XCTAssertEqual(fileSystem.data(at: second), external)
    }

    func testPartialWriteFailureRollsBackCommittedFiles() throws {
        let first = URL(fileURLWithPath: "/virtual/first")
        let second = URL(fileURLWithPath: "/virtual/second")
        let firstOriginal = Data("first-original".utf8)
        let secondOriginal = Data("second-original".utf8)
        let fileSystem = TransactionMemoryFileSystem([
            first: firstOriginal,
            second: secondOriginal
        ])
        fileSystem.failWritesTo = second
        let change = PreparedThemeChange(
            adapterIdentifier: "test",
            targetMode: .light,
            mutations: [
                PreparedThemeMutation(
                    snapshot: try fileSystem.snapshot(at: first),
                    candidateData: Data("first-candidate".utf8),
                    label: "first"
                ),
                PreparedThemeMutation(
                    snapshot: try fileSystem.snapshot(at: second),
                    candidateData: Data("second-candidate".utf8),
                    label: "second"
                )
            ]
        )

        XCTAssertThrowsError(try ThemeMutationExecutor(fileSystem: fileSystem).commit(change)) { error in
            guard case ThemeFileMutationError.partialCommit = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fileSystem.data(at: first), firstOriginal)
        XCTAssertEqual(fileSystem.data(at: second), secondOriginal)
    }

    func testRollbackRefusesToOverwritePostCommitExternalEdit() throws {
        let url = URL(fileURLWithPath: "/virtual/settings")
        let fileSystem = TransactionMemoryFileSystem([url: Data("original".utf8)])
        let change = PreparedThemeChange(
            adapterIdentifier: "test",
            targetMode: .light,
            mutations: [
                PreparedThemeMutation(
                    snapshot: try fileSystem.snapshot(at: url),
                    candidateData: Data("candidate".utf8),
                    label: "settings"
                )
            ]
        )
        let executor = ThemeMutationExecutor(fileSystem: fileSystem)
        let receipt = try executor.commit(change)
        fileSystem.put(Data("external-after-commit".utf8), at: url)

        XCTAssertThrowsError(try executor.rollback(receipt)) { error in
            guard case ThemeFileMutationError.conflict = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fileSystem.data(at: url), Data("external-after-commit".utf8))
    }

    func testCoordinatorRollsBackFirstAdapterWhenSecondFails() async throws {
        let log = TransactionEventLog()
        let firstURL = URL(fileURLWithPath: "/virtual/first")
        let secondURL = URL(fileURLWithPath: "/virtual/second")
        let fileSystem = TransactionMemoryFileSystem([
            firstURL: Data("dark".utf8),
            secondURL: Data("dark".utf8)
        ])
        let first = TransactionTestAdapter(
            identifier: "first",
            order: 0,
            fileURL: firstURL,
            fileSystem: fileSystem,
            log: log
        )
        let second = TransactionTestAdapter(
            identifier: "second",
            order: 10,
            fileURL: secondURL,
            fileSystem: fileSystem,
            log: log,
            behavior: .throwBeforeWrite
        )
        let journal = MemoryTransactionJournal()
        let coordinator = try ThemeTransactionCoordinator(
            adapters: [second, first],
            journal: journal
        )

        do {
            _ = try await coordinator.switchTheme(to: .light)
            XCTFail("expected transaction failure")
        } catch let error as ThemeTransactionError {
            guard case let .adapterFailed(adapter, _, rollbackFailures) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(adapter, "second")
            XCTAssertTrue(rollbackFailures.isEmpty)
        }

        XCTAssertEqual(fileSystem.data(at: firstURL), Data("dark".utf8))
        XCTAssertEqual(fileSystem.data(at: secondURL), Data("dark".utf8))
        XCTAssertEqual(
            log.events,
            ["first.commit", "first.verify", "second.commit", "second.rollback", "first.rollback"]
        )
        XCTAssertNil(try journal.load())
    }

    func testCoordinatorReportsAdapterWhoseVerificationFailed() async throws {
        let fileSystem = TransactionMemoryFileSystem([
            URL(fileURLWithPath: "/virtual/first"): Data("dark".utf8),
            URL(fileURLWithPath: "/virtual/second"): Data("dark".utf8)
        ])
        let first = TransactionTestAdapter(
            identifier: "first",
            order: 0,
            fileURL: URL(fileURLWithPath: "/virtual/first"),
            fileSystem: fileSystem,
            log: TransactionEventLog(),
            behavior: .verificationFailure
        )
        let second = TransactionTestAdapter(
            identifier: "second",
            order: 1,
            fileURL: URL(fileURLWithPath: "/virtual/second"),
            fileSystem: fileSystem,
            log: TransactionEventLog()
        )
        let coordinator = try ThemeTransactionCoordinator(adapters: [first, second])

        do {
            _ = try await coordinator.switchTheme(to: .light)
            XCTFail("expected verification failure")
        } catch let error as ThemeTransactionError {
            guard case let .adapterFailed(adapter, _, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(adapter, "first")
        }
        XCTAssertEqual(fileSystem.data(at: first.fileURL), Data("dark".utf8))
        XCTAssertEqual(fileSystem.data(at: second.fileURL), Data("dark".utf8))
    }

    func testAttemptedAdapterRecoveryFailureKeepsJournal() async throws {
        let url = URL(fileURLWithPath: "/virtual/partial")
        let fileSystem = TransactionMemoryFileSystem([url: Data("dark".utf8)])
        let adapter = TransactionTestAdapter(
            identifier: "partial",
            order: 0,
            fileURL: url,
            fileSystem: fileSystem,
            log: TransactionEventLog(),
            behavior: .writeThenThrow,
            rollbackFails: true
        )
        let journal = MemoryTransactionJournal()
        let coordinator = try ThemeTransactionCoordinator(adapters: [adapter], journal: journal)

        do {
            _ = try await coordinator.switchTheme(to: .light)
            XCTFail("expected partial failure")
        } catch let error as ThemeTransactionError {
            guard case let .adapterFailed(adapterID, _, rollbackFailures) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(adapterID, "partial")
            XCTAssertEqual(rollbackFailures.count, 1)
        }

        XCTAssertNotNil(try journal.load(), "回滚未完成时必须保留崩溃恢复日志")
        XCTAssertEqual(fileSystem.data(at: url), Data("light".utf8))
    }

    func testRecoverInterruptedTransactionRestoresCandidateAndClearsJournal() async throws {
        let url = URL(fileURLWithPath: "/virtual/interrupted")
        let original = Data("dark".utf8)
        let candidate = Data("light".utf8)
        let fileSystem = TransactionMemoryFileSystem([url: candidate])
        let adapter = TransactionTestAdapter(
            identifier: "test",
            order: 0,
            fileURL: url,
            fileSystem: fileSystem,
            log: TransactionEventLog()
        )
        let change = PreparedThemeChange(
            adapterIdentifier: adapter.identifier,
            targetMode: .light,
            mutations: [
                PreparedThemeMutation(
                    fileURL: url,
                    expectedHash: ThemeFileHash.sha256(original),
                    originalData: original,
                    candidateData: candidate,
                    label: "interrupted"
                )
            ]
        )
        let journal = MemoryTransactionJournal(
            ThemeTransactionJournalEntry(targetMode: .light, preparedChanges: [change])
        )
        let coordinator = try ThemeTransactionCoordinator(adapters: [adapter], journal: journal)

        let didRecover = try await coordinator.recoverInterruptedTransaction()
        XCTAssertTrue(didRecover)
        XCTAssertEqual(fileSystem.data(at: url), original)
        XCTAssertNil(try journal.load())
    }

    func testCoordinatorRestoresAllAdaptersAsOneTransaction() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first")
        let secondURL = URL(fileURLWithPath: "/virtual/second")
        let fileSystem = TransactionMemoryFileSystem([
            firstURL: Data("light".utf8),
            secondURL: Data("light".utf8)
        ])
        let first = TransactionTestAdapter(
            identifier: "first",
            order: 0,
            fileURL: firstURL,
            fileSystem: fileSystem,
            log: TransactionEventLog()
        )
        let second = TransactionTestAdapter(
            identifier: "second",
            order: 1,
            fileURL: secondURL,
            fileSystem: fileSystem,
            log: TransactionEventLog()
        )
        let coordinator = try ThemeTransactionCoordinator(adapters: [second, first])

        _ = try await coordinator.restoreIntegrations()

        XCTAssertEqual(fileSystem.data(at: firstURL), Data("restored".utf8))
        XCTAssertEqual(fileSystem.data(at: secondURL), Data("restored".utf8))
    }

    func testCoordinatorRequiresExplicitPermissionToInstallOrRepair() async throws {
        let url = URL(fileURLWithPath: "/virtual/needs-installation")
        let fileSystem = TransactionMemoryFileSystem([url: Data("dark".utf8)])
        let adapter = TransactionTestAdapter(
            identifier: "needs-installation",
            order: 0,
            fileURL: url,
            fileSystem: fileSystem,
            log: TransactionEventLog(),
            inspectionStatus: .needsInstallation
        )
        let coordinator = try ThemeTransactionCoordinator(adapters: [adapter])

        do {
            _ = try await coordinator.switchTheme(to: .light)
            XCTFail("expected explicit installation gate")
        } catch let error as ThemeTransactionError {
            guard case let .installationRequired(identifiers) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(identifiers, [adapter.identifier])
        }
        XCTAssertEqual(fileSystem.data(at: url), Data("dark".utf8))

        _ = try await coordinator.switchTheme(to: .light, allowInstallation: true)
        XCTAssertEqual(fileSystem.data(at: url), Data("light".utf8))
    }

    func testLocalAtomicWritePreservesPOSIXPermissions() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("settings")
        try Data("before".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: fileURL.path
        )

        try LocalThemeFileSystem().atomicWrite(
            Data("after".utf8),
            to: fileURL,
            preservingMetadata: true
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("after".utf8))
    }

    func testFileJournalPersistsRealJSONAndClearsRoundTrip() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeTransactionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let journalURL = rootURL
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("transaction.json")
        let journal = FileThemeTransactionJournal(fileURL: journalURL)

        XCTAssertNil(try journal.load())

        let original = Data([0x00, 0x01, 0xFF])
        let candidate = Data("light\n".utf8)
        let mutation = PreparedThemeMutation(
            fileURL: URL(fileURLWithPath: "/virtual/带空格/settings.json"),
            expectedHash: ThemeFileHash.sha256(original),
            originalData: original,
            candidateData: candidate,
            label: "VS Code 设置"
        )
        let change = PreparedThemeChange(
            adapterIdentifier: "vscode",
            targetMode: .light,
            mutations: [mutation],
            metadata: ["阶段": "准备"]
        )
        let receipt = ThemeCommitReceipt(
            change: change,
            committedMutations: [
                CommittedThemeMutation(
                    mutation: mutation,
                    committedHash: ThemeFileHash.sha256(candidate)
                )
            ],
            metadata: ["pendingReload": "false"]
        )
        var entry = ThemeTransactionJournalEntry(
            transactionID: UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!,
            targetMode: .light,
            preparedChanges: [change]
        )

        try journal.save(entry)
        XCTAssertEqual(try journal.load(), entry)

        entry.committedReceipts = [receipt]
        try journal.save(entry)
        XCTAssertEqual(try journal.load(), entry)

        let persistedData = try Data(contentsOf: journalURL)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: persistedData))
        XCTAssertTrue(
            String(decoding: persistedData, as: UTF8.self).contains("\n  \"committedReceipts\"")
        )
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: journalURL.deletingLastPathComponent().path
        )
        XCTAssertEqual(siblingNames, [journalURL.lastPathComponent])
        XCTAssertFalse(siblingNames.contains { $0.contains(".auto-theme-switcher-") })

        try journal.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertNil(try journal.load())
        try journal.clear()
    }

    func testLocalAtomicWritePreservesExtendedAttributesWhenSupported() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("settings")
        try Data("before".utf8).write(to: fileURL)

        let attributeName = "dev.dtw.AutoThemeSwitcher.tests.metadata"
        let attributeValue = Data("保留扩展属性".utf8)
        let setResult = attributeValue.withUnsafeBytes { buffer in
            setxattr(
                fileURL.path,
                attributeName,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        if setResult != 0 {
            let errorNumber = errno
            if errorNumber == ENOTSUP {
                throw XCTSkip("当前测试文件系统不支持扩展属性")
            }
            return XCTFail(
                "无法建立扩展属性测试前置条件：\(String(cString: strerror(errorNumber)))"
            )
        }
        XCTAssertEqual(
            try extendedAttribute(named: attributeName, at: fileURL),
            attributeValue
        )

        try LocalThemeFileSystem().atomicWrite(
            Data("after".utf8),
            to: fileURL,
            preservingMetadata: true
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), Data("after".utf8))
        XCTAssertEqual(
            try extendedAttribute(named: attributeName, at: fileURL),
            attributeValue
        )
    }

    private func extendedAttribute(named name: String, at fileURL: URL) throws -> Data {
        let size = getxattr(fileURL.path, name, nil, 0, 0, 0)
        guard size >= 0 else {
            throw ThemeTransactionTestPOSIXError(
                operation: "getxattr(size)",
                errorNumber: errno
            )
        }

        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { buffer in
            getxattr(fileURL.path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard readSize >= 0 else {
            throw ThemeTransactionTestPOSIXError(
                operation: "getxattr(data)",
                errorNumber: errno
            )
        }
        guard readSize == size else {
            throw ThemeTransactionTestPOSIXError(
                operation: "getxattr(size changed)",
                errorNumber: EIO
            )
        }
        return data
    }
}

private struct ThemeTransactionTestPOSIXError: Error, CustomStringConvertible {
    let operation: String
    let errorNumber: Int32

    var description: String {
        "\(operation) 失败：\(String(cString: strerror(errorNumber)))"
    }
}

private enum TransactionTestError: Error {
    case injectedWriteFailure
    case injectedAdapterFailure
    case injectedVerificationFailure
    case injectedRollbackFailure
}

private final class TransactionMemoryFileSystem: ThemeFileSystem, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var storage: [URL: Data]
    var failWritesTo: URL?
    var afterWrite: ((URL) -> Void)?

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
        if fileURL.standardizedFileURL == failWritesTo?.standardizedFileURL {
            throw TransactionTestError.injectedWriteFailure
        }
        put(data, at: fileURL)
        afterWrite?(fileURL.standardizedFileURL)
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

private final class TransactionEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class MemoryTransactionJournal: ThemeTransactionJournaling, @unchecked Sendable {
    private let lock = NSLock()
    private var entry: ThemeTransactionJournalEntry?

    init(_ entry: ThemeTransactionJournalEntry? = nil) {
        self.entry = entry
    }

    func load() throws -> ThemeTransactionJournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entry
    }

    func save(_ entry: ThemeTransactionJournalEntry) throws {
        lock.lock()
        self.entry = entry
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        entry = nil
        lock.unlock()
    }
}

private final class TransactionTestAdapter: RestorableThemeAdapter, @unchecked Sendable {
    enum Behavior {
        case normal
        case throwBeforeWrite
        case writeThenThrow
        case verificationFailure
    }

    let identifier: String
    let transactionOrder: Int
    let fileURL: URL
    private let fileSystem: TransactionMemoryFileSystem
    private let log: TransactionEventLog
    private let behavior: Behavior
    private let rollbackFails: Bool
    private let inspectionStatus: ThemeAdapterStatus

    init(
        identifier: String,
        order: Int,
        fileURL: URL,
        fileSystem: TransactionMemoryFileSystem,
        log: TransactionEventLog,
        behavior: Behavior = .normal,
        rollbackFails: Bool = false,
        inspectionStatus: ThemeAdapterStatus = .ready
    ) {
        self.identifier = identifier
        transactionOrder = order
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        self.log = log
        self.behavior = behavior
        self.rollbackFails = rollbackFails
        self.inspectionStatus = inspectionStatus
    }

    func inspect() throws -> ThemeInspection {
        let snapshot = try fileSystem.snapshot(at: fileURL)
        let mode = snapshot.data.flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(ThemeMode.init(rawValue:))
        return ThemeInspection(
            adapterIdentifier: identifier,
            detectedMode: mode,
            status: inspectionStatus,
            files: [snapshot]
        )
    }

    func prepare(targetMode: ThemeMode, from inspection: ThemeInspection) throws -> PreparedThemeChange {
        let snapshot = try XCTUnwrap(inspection.snapshot(for: fileURL))
        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: targetMode,
            mutations: [
                PreparedThemeMutation(
                    snapshot: snapshot,
                    candidateData: Data(targetMode.rawValue.utf8),
                    label: identifier
                )
            ]
        )
    }

    func prepareRestoration(from inspection: ThemeInspection) throws -> PreparedThemeChange {
        let snapshot = try XCTUnwrap(inspection.snapshot(for: fileURL))
        return PreparedThemeChange(
            adapterIdentifier: identifier,
            targetMode: .dark,
            mutations: [
                PreparedThemeMutation(
                    snapshot: snapshot,
                    candidateData: Data("restored".utf8),
                    label: identifier
                )
            ],
            metadata: ["operation": "restore"]
        )
    }

    func commit(_ change: PreparedThemeChange) throws -> ThemeCommitReceipt {
        log.append("\(identifier).commit")
        switch behavior {
        case .throwBeforeWrite:
            throw TransactionTestError.injectedAdapterFailure
        case .writeThenThrow:
            if let mutation = change.mutations.first,
               let data = mutation.candidateData
            {
                try fileSystem.atomicWrite(data, to: mutation.fileURL, preservingMetadata: true)
            }
            throw TransactionTestError.injectedAdapterFailure
        case .normal, .verificationFailure:
            return try ThemeMutationExecutor(fileSystem: fileSystem).commit(change)
        }
    }

    func verify(_ receipt: ThemeCommitReceipt) throws {
        log.append("\(identifier).verify")
        if behavior == .verificationFailure {
            throw TransactionTestError.injectedVerificationFailure
        }
        try ThemeMutationExecutor(fileSystem: fileSystem).verify(receipt)
    }

    func rollback(_ receipt: ThemeCommitReceipt) throws {
        log.append("\(identifier).rollback")
        if rollbackFails { throw TransactionTestError.injectedRollbackFailure }
        try ThemeMutationExecutor(fileSystem: fileSystem).rollback(receipt)
    }
}
