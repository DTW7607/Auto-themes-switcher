import CryptoKit
import Darwin
import Foundation

// MARK: - Public adapter contract

public enum ThemeAdapterStatus: String, Codable, Equatable, Sendable {
    case ready
    case needsInstallation
    case unavailable
    case conflict
}

public struct ThemeFileSnapshot: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let data: Data?
    public let hash: String?

    public init(fileURL: URL, data: Data?) {
        self.fileURL = fileURL
        self.data = data
        hash = data.map(ThemeFileHash.sha256)
    }
}

public struct ThemeInspection: Equatable, Sendable {
    public let adapterIdentifier: String
    public let detectedMode: ThemeMode?
    public let status: ThemeAdapterStatus
    public let files: [ThemeFileSnapshot]
    public let message: String?
    public let details: [String: String]

    public init(
        adapterIdentifier: String,
        detectedMode: ThemeMode?,
        status: ThemeAdapterStatus,
        files: [ThemeFileSnapshot],
        message: String? = nil,
        details: [String: String] = [:]
    ) {
        self.adapterIdentifier = adapterIdentifier
        self.detectedMode = detectedMode
        self.status = status
        self.files = files
        self.message = message
        self.details = details
    }

    public func snapshot(for fileURL: URL) -> ThemeFileSnapshot? {
        files.first { $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL }
    }
}

/// 一项经过 prepare 的比较并交换（CAS）文件变更。
///
/// `expectedHash == nil` 表示 prepare 时文件不存在；`candidateData == nil` 表示提交时
/// 删除文件。`originalData` 会用于安全回滚，且必须与 `expectedHash` 一致。
public struct PreparedThemeMutation: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let expectedHash: String?
    public let originalData: Data?
    public let candidateData: Data?
    public let label: String

    public init(
        fileURL: URL,
        expectedHash: String?,
        originalData: Data?,
        candidateData: Data?,
        label: String
    ) {
        self.fileURL = fileURL
        self.expectedHash = expectedHash
        self.originalData = originalData
        self.candidateData = candidateData
        self.label = label
    }

    public init(snapshot: ThemeFileSnapshot, candidateData: Data?, label: String) {
        self.init(
            fileURL: snapshot.fileURL,
            expectedHash: snapshot.hash,
            originalData: snapshot.data,
            candidateData: candidateData,
            label: label
        )
    }

    public var candidateHash: String? {
        candidateData.map(ThemeFileHash.sha256)
    }
}

public struct PreparedThemeChange: Codable, Equatable, Sendable {
    public let adapterIdentifier: String
    public let targetMode: ThemeMode
    public let mutations: [PreparedThemeMutation]
    public let metadata: [String: String]

    public init(
        adapterIdentifier: String,
        targetMode: ThemeMode,
        mutations: [PreparedThemeMutation],
        metadata: [String: String] = [:]
    ) {
        self.adapterIdentifier = adapterIdentifier
        self.targetMode = targetMode
        self.mutations = mutations
        self.metadata = metadata
    }
}

public struct CommittedThemeMutation: Codable, Equatable, Sendable {
    public let mutation: PreparedThemeMutation
    public let committedHash: String?

    public init(mutation: PreparedThemeMutation, committedHash: String?) {
        self.mutation = mutation
        self.committedHash = committedHash
    }
}

public struct ThemeCommitReceipt: Codable, Equatable, Sendable {
    public let change: PreparedThemeChange
    public let committedMutations: [CommittedThemeMutation]
    public let metadata: [String: String]

    public init(
        change: PreparedThemeChange,
        committedMutations: [CommittedThemeMutation],
        metadata: [String: String] = [:]
    ) {
        self.change = change
        self.committedMutations = committedMutations
        self.metadata = metadata
    }

    /// 用于崩溃恢复：回滚器会跳过仍处于原始状态的文件，只恢复仍等于候选哈希的文件。
    public static func recoveryReceipt(for change: PreparedThemeChange) -> Self {
        Self(
            change: change,
            committedMutations: change.mutations.map {
                CommittedThemeMutation(mutation: $0, committedHash: $0.candidateHash)
            }
        )
    }

    public func mergingMetadata(_ additionalMetadata: [String: String]) -> Self {
        Self(
            change: change,
            committedMutations: committedMutations,
            metadata: metadata.merging(additionalMetadata) { _, new in new }
        )
    }
}

public protocol ThemeAdapter: Sendable {
    var identifier: String { get }
    var transactionOrder: Int { get }

    func inspect() throws -> ThemeInspection
    func prepare(targetMode: ThemeMode, from inspection: ThemeInspection) throws -> PreparedThemeChange
    func commit(_ change: PreparedThemeChange) throws -> ThemeCommitReceipt
    func verify(_ receipt: ThemeCommitReceipt) throws
    func rollback(_ receipt: ThemeCommitReceipt) throws
}

public extension ThemeAdapter {
    var transactionOrder: Int { 0 }
}

/// 支持“恢复并停用”的适配器。恢复仍使用与普通切换相同的 commit/verify/rollback
/// 协议，因此两个应用可以处于同一个原子事务中。
public protocol RestorableThemeAdapter: ThemeAdapter {
    func prepareRestoration(from inspection: ThemeInspection) throws -> PreparedThemeChange
}

// MARK: - Injected file system and CAS executor

public protocol ThemeFileSystem: Sendable {
    func fileExists(at fileURL: URL) -> Bool
    func readData(at fileURL: URL) throws -> Data
    func createDirectory(at directoryURL: URL) throws
    func atomicWrite(_ data: Data, to fileURL: URL, preservingMetadata: Bool) throws
    func removeItem(at fileURL: URL) throws
}

public extension ThemeFileSystem {
    func snapshot(at fileURL: URL) throws -> ThemeFileSnapshot {
        guard fileExists(at: fileURL) else {
            return ThemeFileSnapshot(fileURL: fileURL, data: nil)
        }
        return ThemeFileSnapshot(fileURL: fileURL, data: try readData(at: fileURL))
    }

    func currentHash(at fileURL: URL) throws -> String? {
        guard fileExists(at: fileURL) else { return nil }
        return ThemeFileHash.sha256(try readData(at: fileURL))
    }
}

public struct LocalThemeFileSystem: ThemeFileSystem {
    public init() {}

    public func fileExists(at fileURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func readData(at fileURL: URL) throws -> Data {
        try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    public func createDirectory(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    public func atomicWrite(_ data: Data, to fileURL: URL, preservingMetadata: Bool) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try createDirectory(at: directoryURL)

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).auto-theme-switcher-\(UUID().uuidString)"
        )
        var temporaryWasCreated = false
        defer {
            if temporaryWasCreated {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        if preservingMetadata, fileExists(at: fileURL) {
            let result = copyfile(
                fileURL.path,
                temporaryURL.path,
                nil,
                copyfile_flags_t(COPYFILE_METADATA)
            )
            guard result == 0 else {
                throw ThemeFileMutationError.ioFailure(
                    fileURL,
                    "无法复制文件元数据：\(String(cString: strerror(errno)))"
                )
            }
            temporaryWasCreated = true
        }

        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_TRUNC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ThemeFileMutationError.ioFailure(
                temporaryURL,
                "无法创建临时文件：\(String(cString: strerror(errno)))"
            )
        }
        temporaryWasCreated = true

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard var pointer = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw ThemeFileMutationError.ioFailure(
                            temporaryURL,
                            "写入临时文件失败：\(String(cString: strerror(errno)))"
                        )
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ThemeFileMutationError.ioFailure(
                    temporaryURL,
                    "同步临时文件失败：\(String(cString: strerror(errno)))"
                )
            }
        } catch {
            _ = close(descriptor)
            throw error
        }

        guard close(descriptor) == 0 else {
            throw ThemeFileMutationError.ioFailure(
                temporaryURL,
                "关闭临时文件失败：\(String(cString: strerror(errno)))"
            )
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw ThemeFileMutationError.ioFailure(
                fileURL,
                "原子替换失败：\(String(cString: strerror(errno)))"
            )
        }
        temporaryWasCreated = false
        try syncDirectory(directoryURL)
    }

    public func removeItem(at fileURL: URL) throws {
        guard fileExists(at: fileURL) else { return }
        guard unlink(fileURL.path) == 0 else {
            throw ThemeFileMutationError.ioFailure(
                fileURL,
                "删除文件失败：\(String(cString: strerror(errno)))"
            )
        }
        try syncDirectory(fileURL.deletingLastPathComponent())
    }

    private func syncDirectory(_ directoryURL: URL) throws {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ThemeFileMutationError.ioFailure(
                directoryURL,
                "无法打开配置目录：\(String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ThemeFileMutationError.ioFailure(
                directoryURL,
                "同步配置目录失败：\(String(cString: strerror(errno)))"
            )
        }
    }
}

public enum ThemeFileHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ThemeFileMutationError: Error, Equatable, Sendable {
    case invalidPreparedMutation(URL)
    case conflict(URL, expectedHash: String?, actualHash: String?)
    case ioFailure(URL, String)
    case partialCommit(String, rollbackFailure: String?)
    case rollbackFailures([String])
}

extension ThemeFileMutationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidPreparedMutation(url):
            "候选变更的原始内容与哈希不一致：\(url.path)"
        case let .conflict(url, expected, actual):
            "文件已被其他程序修改，已停止覆盖：\(url.path)（期望 \(expected ?? "不存在")，实际 \(actual ?? "不存在")）"
        case let .ioFailure(url, message):
            "文件操作失败：\(url.path)：\(message)"
        case let .partialCommit(message, rollbackFailure):
            if let rollbackFailure {
                "提交失败：\(message)；自动回滚也失败：\(rollbackFailure)"
            } else {
                "提交失败并已自动回滚：\(message)"
            }
        case let .rollbackFailures(messages):
            "有多项文件无法安全回滚：\(messages.joined(separator: "；"))"
        }
    }
}

/// 通用文件提交器。先检查全部基线哈希，再逐项原子写入；中途失败会安全回滚已写文件。
public struct ThemeMutationExecutor: Sendable {
    public let fileSystem: any ThemeFileSystem

    public init(fileSystem: any ThemeFileSystem = LocalThemeFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func commit(_ change: PreparedThemeChange) throws -> ThemeCommitReceipt {
        try validatePreparedChange(change)
        for mutation in change.mutations {
            try requireHash(mutation.expectedHash, at: mutation.fileURL)
        }

        var committed: [CommittedThemeMutation] = []
        do {
            for mutation in change.mutations {
                // 缩小 prepare/commit 之间以及多文件提交过程中的 TOCTOU 窗口；
                // 目标文件在前一项写入期间发生变化时，绝不继续覆盖。
                try requireHash(mutation.expectedHash, at: mutation.fileURL)
                if let candidateData = mutation.candidateData {
                    try fileSystem.atomicWrite(
                        candidateData,
                        to: mutation.fileURL,
                        preservingMetadata: mutation.expectedHash != nil
                    )
                } else {
                    try fileSystem.removeItem(at: mutation.fileURL)
                }
                let committedMutation = CommittedThemeMutation(
                    mutation: mutation,
                    committedHash: mutation.candidateHash
                )
                try requireHash(committedMutation.committedHash, at: mutation.fileURL)
                committed.append(committedMutation)
            }
            return ThemeCommitReceipt(change: change, committedMutations: committed)
        } catch {
            // atomicWrite 可能在 rename 已完成、目录 fsync 失败时抛错，因此不能只把
            // 已生成 receipt 的项视为“可能写入”。恢复全部候选会幂等跳过未写项。
            let partialReceipt = ThemeCommitReceipt.recoveryReceipt(for: change)
            var rollbackFailure: String?
            do {
                try rollback(partialReceipt)
            } catch {
                rollbackFailure = error.localizedDescription
            }
            throw ThemeFileMutationError.partialCommit(
                error.localizedDescription,
                rollbackFailure: rollbackFailure
            )
        }
    }

    public func verify(_ receipt: ThemeCommitReceipt) throws {
        for committed in receipt.committedMutations {
            try requireHash(committed.committedHash, at: committed.mutation.fileURL)
        }
    }

    /// 仅在当前文件仍等于本次候选内容时恢复；已经是原始内容时视为幂等成功。
    public func rollback(_ receipt: ThemeCommitReceipt) throws {
        var failures: [ThemeFileMutationError] = []
        for committed in receipt.committedMutations.reversed() {
            do {
                try rollback(committed)
            } catch let error as ThemeFileMutationError {
                failures.append(error)
            } catch {
                failures.append(
                    .ioFailure(committed.mutation.fileURL, error.localizedDescription)
                )
            }
        }
        if failures.count == 1, let failure = failures.first {
            throw failure
        }
        if !failures.isEmpty {
            throw ThemeFileMutationError.rollbackFailures(
                failures.map(\.localizedDescription)
            )
        }
    }

    private func rollback(_ committed: CommittedThemeMutation) throws {
        let mutation = committed.mutation
        let currentHash = try fileSystem.currentHash(at: mutation.fileURL)
        if currentHash == mutation.expectedHash { return }
        guard currentHash == committed.committedHash else {
            throw ThemeFileMutationError.conflict(
                mutation.fileURL,
                expectedHash: committed.committedHash,
                actualHash: currentHash
            )
        }
        if let originalData = mutation.originalData {
            try fileSystem.atomicWrite(
                originalData,
                to: mutation.fileURL,
                preservingMetadata: currentHash != nil
            )
        } else {
            try fileSystem.removeItem(at: mutation.fileURL)
        }
        try requireHash(mutation.expectedHash, at: mutation.fileURL)
    }

    private func validatePreparedChange(_ change: PreparedThemeChange) throws {
        var paths = Set<URL>()
        for mutation in change.mutations {
            guard mutation.originalData.map(ThemeFileHash.sha256) == mutation.expectedHash,
                  paths.insert(mutation.fileURL.standardizedFileURL).inserted
            else {
                throw ThemeFileMutationError.invalidPreparedMutation(mutation.fileURL)
            }
        }
    }

    private func requireHash(_ expectedHash: String?, at fileURL: URL) throws {
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

// MARK: - Cross-adapter transaction and crash journal

public struct ThemeTransactionJournalEntry: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let targetMode: ThemeMode
    public let preparedChanges: [PreparedThemeChange]
    public var committedReceipts: [ThemeCommitReceipt]

    public init(
        transactionID: UUID = UUID(),
        targetMode: ThemeMode,
        preparedChanges: [PreparedThemeChange],
        committedReceipts: [ThemeCommitReceipt] = []
    ) {
        self.transactionID = transactionID
        self.targetMode = targetMode
        self.preparedChanges = preparedChanges
        self.committedReceipts = committedReceipts
    }
}

public protocol ThemeTransactionJournaling: Sendable {
    func load() throws -> ThemeTransactionJournalEntry?
    func save(_ entry: ThemeTransactionJournalEntry) throws
    func clear() throws
}

public struct NullThemeTransactionJournal: ThemeTransactionJournaling {
    public init() {}
    public func load() throws -> ThemeTransactionJournalEntry? { nil }
    public func save(_: ThemeTransactionJournalEntry) throws {}
    public func clear() throws {}
}

public struct FileThemeTransactionJournal: ThemeTransactionJournaling {
    public let fileURL: URL
    public let fileSystem: any ThemeFileSystem

    public init(
        fileURL: URL,
        fileSystem: any ThemeFileSystem = LocalThemeFileSystem()
    ) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
    }

    public func load() throws -> ThemeTransactionJournalEntry? {
        guard fileSystem.fileExists(at: fileURL) else { return nil }
        return try JSONDecoder().decode(
            ThemeTransactionJournalEntry.self,
            from: fileSystem.readData(at: fileURL)
        )
    }

    public func save(_ entry: ThemeTransactionJournalEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fileSystem.atomicWrite(
            encoder.encode(entry),
            to: fileURL,
            preservingMetadata: fileSystem.fileExists(at: fileURL)
        )
    }

    public func clear() throws {
        try fileSystem.removeItem(at: fileURL)
    }
}

public struct ThemeTransactionResult: Sendable {
    public let targetMode: ThemeMode
    public let inspections: [ThemeInspection]
    public let receipts: [ThemeCommitReceipt]

    public init(
        targetMode: ThemeMode,
        inspections: [ThemeInspection],
        receipts: [ThemeCommitReceipt]
    ) {
        self.targetMode = targetMode
        self.inspections = inspections
        self.receipts = receipts
    }
}

public enum ThemeTransactionError: Error, Sendable {
    case duplicateAdapter(String)
    case adapterNotRestorable(String)
    case installationRequired([String])
    case adapterFailed(adapter: String, message: String, rollbackFailures: [String])
    case recoveryFailed([String])
}

extension ThemeTransactionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .duplicateAdapter(identifier):
            "主题事务包含重复适配器：\(identifier)"
        case let .adapterNotRestorable(identifier):
            "主题适配器不支持恢复集成：\(identifier)"
        case let .installationRequired(identifiers):
            "主题集成缺失或受损，需要用户明确执行安装/修复：\(identifiers.joined(separator: "、"))"
        case let .adapterFailed(adapter, message, rollbackFailures):
            if rollbackFailures.isEmpty {
                "\(adapter) 主题切换失败，已回滚：\(message)"
            } else {
                "\(adapter) 主题切换失败：\(message)；回滚异常：\(rollbackFailures.joined(separator: "；"))"
            }
        case let .recoveryFailed(messages):
            "上次未完成的主题事务无法安全恢复：\(messages.joined(separator: "；"))"
        }
    }
}

public actor ThemeTransactionCoordinator {
    private let adapters: [any ThemeAdapter]
    private let journal: any ThemeTransactionJournaling

    public init(
        adapters: [any ThemeAdapter],
        journal: any ThemeTransactionJournaling = NullThemeTransactionJournal()
    ) throws {
        let identifiers = adapters.map(\.identifier)
        if let duplicate = Dictionary(grouping: identifiers, by: { $0 })
            .first(where: { $0.value.count > 1 })?.key
        {
            throw ThemeTransactionError.duplicateAdapter(duplicate)
        }
        self.adapters = adapters.sorted {
            if $0.transactionOrder == $1.transactionOrder {
                return $0.identifier < $1.identifier
            }
            return $0.transactionOrder < $1.transactionOrder
        }
        self.journal = journal
    }

    public func switchTheme(
        to targetMode: ThemeMode,
        allowInstallation: Bool = false
    ) throws -> ThemeTransactionResult {
        let inspections = try adapters.map { try $0.inspect() }
        let installationRequired = inspections
            .filter { $0.status == .needsInstallation }
            .map(\.adapterIdentifier)
        if !allowInstallation, !installationRequired.isEmpty {
            throw ThemeTransactionError.installationRequired(installationRequired)
        }
        let preparedChanges = try zip(adapters, inspections).map { adapter, inspection in
            try adapter.prepare(targetMode: targetMode, from: inspection)
        }

        return try execute(
            targetMode: targetMode,
            inspections: inspections,
            preparedChanges: preparedChanges
        )
    }

    /// 字段级恢复所有集成，并在任一适配器失败时逆序回滚已恢复的适配器。
    public func restoreIntegrations() throws -> ThemeTransactionResult {
        let inspections = try adapters.map { try $0.inspect() }
        let preparedChanges = try zip(adapters, inspections).map { adapter, inspection in
            guard let restorable = adapter as? any RestorableThemeAdapter else {
                throw ThemeTransactionError.adapterNotRestorable(adapter.identifier)
            }
            return try restorable.prepareRestoration(from: inspection)
        }

        return try execute(
            targetMode: .dark,
            inspections: inspections,
            preparedChanges: preparedChanges
        )
    }

    private func execute(
        targetMode: ThemeMode,
        inspections: [ThemeInspection],
        preparedChanges: [PreparedThemeChange]
    ) throws -> ThemeTransactionResult {

        var entry = ThemeTransactionJournalEntry(
            targetMode: targetMode,
            preparedChanges: preparedChanges
        )
        try journal.save(entry)

        var completed: [(adapter: any ThemeAdapter, receipt: ThemeCommitReceipt)] = []
        var activeAdapter: (any ThemeAdapter)?
        var activeChange: PreparedThemeChange?
        do {
            for (adapter, change) in zip(adapters, preparedChanges) {
                activeAdapter = adapter
                activeChange = change
                let receipt = try adapter.commit(change)
                completed.append((adapter, receipt))
                entry.committedReceipts.append(receipt)
                try journal.save(entry)
                try adapter.verify(receipt)
            }
            try journal.clear()
            return ThemeTransactionResult(
                targetMode: targetMode,
                inspections: inspections,
                receipts: completed.map(\.receipt)
            )
        } catch {
            let originalError = error
            let failedAdapter = activeAdapter?.identifier ?? "unknown"
            var rollbackFailures: [String] = []

            // commit 自身若在多文件写入中断，可能没有 receipt 返回。使用候选哈希恢复：
            // 原始状态会幂等跳过、候选状态会恢复、任何第三方内容都会触发冲突并保留日志。
            if let activeAdapter,
               let activeChange,
               !completed.contains(where: { $0.adapter.identifier == activeAdapter.identifier })
            {
                do {
                    try activeAdapter.rollback(.recoveryReceipt(for: activeChange))
                } catch {
                    rollbackFailures.append(
                        "\(activeAdapter.identifier): \(error.localizedDescription)"
                    )
                }
            }
            for completedChange in completed.reversed() {
                do {
                    try completedChange.adapter.rollback(completedChange.receipt)
                } catch {
                    rollbackFailures.append(
                        "\(completedChange.adapter.identifier): \(error.localizedDescription)"
                    )
                }
            }
            if rollbackFailures.isEmpty {
                try? journal.clear()
            }
            throw ThemeTransactionError.adapterFailed(
                adapter: failedAdapter,
                message: originalError.localizedDescription,
                rollbackFailures: rollbackFailures
            )
        }
    }

    /// 恢复上次进程在任意适配器提交期间中断的事务。未知内容绝不覆盖并保留日志。
    @discardableResult
    public func recoverInterruptedTransaction() throws -> Bool {
        guard let entry = try journal.load() else { return false }
        let adaptersByIdentifier = Dictionary(
            uniqueKeysWithValues: adapters.map { ($0.identifier, $0) }
        )
        var failures: [String] = []

        for change in entry.preparedChanges.reversed() {
            guard let adapter = adaptersByIdentifier[change.adapterIdentifier] else {
                failures.append("缺少适配器 \(change.adapterIdentifier)")
                continue
            }
            let receipt = entry.committedReceipts.first {
                $0.change.adapterIdentifier == change.adapterIdentifier
            } ?? .recoveryReceipt(for: change)
            do {
                try adapter.rollback(receipt)
            } catch {
                failures.append("\(adapter.identifier): \(error.localizedDescription)")
            }
        }

        guard failures.isEmpty else {
            throw ThemeTransactionError.recoveryFailed(failures)
        }
        try journal.clear()
        return true
    }
}
