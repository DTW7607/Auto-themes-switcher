import Foundation

public enum ThemeMode: String, Codable, CaseIterable, Equatable, Sendable {
    case dark
    case light
}

public struct AutomationConfiguration: Codable, Equatable, Sendable {
    public static let defaults = AutomationConfiguration(
        indoorThreshold: 1_000,
        outdoorThreshold: 5_000,
        stableDuration: 5,
        minimumDwellDuration: 15
    )

    public var indoorThreshold: Double
    public var outdoorThreshold: Double
    public var stableDuration: TimeInterval
    public var minimumDwellDuration: TimeInterval

    public init(
        indoorThreshold: Double,
        outdoorThreshold: Double,
        stableDuration: TimeInterval = 5,
        minimumDwellDuration: TimeInterval = 15
    ) {
        self.indoorThreshold = indoorThreshold
        self.outdoorThreshold = outdoorThreshold
        self.stableDuration = stableDuration
        self.minimumDwellDuration = minimumDwellDuration
    }

    public func validate() throws {
        guard indoorThreshold.isFinite,
              (0 ... AmbientLightReadingLimits.maximumLux).contains(indoorThreshold)
        else {
            throw AutomationConfigurationError.invalidIndoorThreshold
        }
        guard outdoorThreshold.isFinite,
              (0 ... AmbientLightReadingLimits.maximumLux).contains(outdoorThreshold),
              indoorThreshold < outdoorThreshold
        else {
            throw AutomationConfigurationError.invalidOutdoorThreshold
        }
        guard stableDuration.isFinite,
              (1 ... 60).contains(stableDuration)
        else {
            throw AutomationConfigurationError.invalidStableDuration
        }
        guard minimumDwellDuration.isFinite,
              minimumDwellDuration >= 0
        else {
            throw AutomationConfigurationError.invalidMinimumDwellDuration
        }
    }
}

public enum AutomationConfigurationError: Error, Equatable, Sendable {
    case invalidIndoorThreshold
    case invalidOutdoorThreshold
    case invalidStableDuration
    case invalidMinimumDwellDuration
}

extension AutomationConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidIndoorThreshold:
            "室内阈值必须是 0 至 200000 之间的有限数值。"
        case .invalidOutdoorThreshold:
            "室外阈值必须大于室内阈值，且不超过 200000。"
        case .invalidStableDuration:
            "稳定时间必须在 1 至 60 秒之间。"
        case .invalidMinimumDwellDuration:
            "最短驻留时间不能为负数。"
        }
    }
}

public enum AutomationSampleDisposition: Equatable, Sendable {
    case accepted
    case warmingUp
    case ignoredWhileSleeping
    case invalidSample
}

public struct AutomationSnapshot: Equatable, Sendable {
    public let currentMode: ThemeMode
    public let pendingMode: ThemeMode?
    public let rawLux: Double?
    public let filteredLux: Double?
    public let candidateMode: ThemeMode?
    public let candidateElapsed: TimeInterval
    public let candidateRemaining: TimeInterval
    public let warmupSamplesRemaining: Int
    public let isSleeping: Bool

    public var isWarmingUp: Bool {
        warmupSamplesRemaining > 0
    }
}

public struct AutomationUpdate: Equatable, Sendable {
    public let disposition: AutomationSampleDisposition

    /// 非空时，调用方应执行两款应用的主题事务；成功后再调用
    /// `confirmThemeChange(to:at:)`，失败则调用 `cancelPendingThemeChange()`。
    public let requestedMode: ThemeMode?
    public let snapshot: AutomationSnapshot
}

/// 纯同步、可用显式单调时间测试的双阈值自动化状态机。
///
/// 调用方应以 `recommendedSamplingInterval` 周期读取一次传感器，并把
/// `ProcessInfo.processInfo.systemUptime` 作为 `uptime` 传入。状态机不会把切换请求
/// 直接视为成功，只有主题事务确认后才改变 `currentMode` 和开始驻留计时。
public struct AutomationEngine: Sendable {
    public static let recommendedSamplingInterval: TimeInterval = 1
    public static let sampleWindowSize = 5
    public static let wakeWarmupSampleCount = 3

    /// 超过此间隔说明采样链不连续；旧中位数窗口和候选计时会被丢弃。
    public static let maximumContinuousSampleGap: TimeInterval = 2.5

    public private(set) var configuration: AutomationConfiguration
    public private(set) var currentMode: ThemeMode

    private var samples: [Double] = []
    private var latestRawLux: Double?
    private var latestFilteredLux: Double?
    private var candidate: Candidate?
    private var pendingMode: ThemeMode?
    private var lastAcceptedSampleAt: TimeInterval?
    private var lastSuccessfulSwitchAt: TimeInterval?
    private var warmupSamplesRemaining = 0
    private var isSleeping = false

    public init(initialMode: ThemeMode = .dark) {
        configuration = .defaults
        currentMode = initialMode
    }

    public init(
        validating configuration: AutomationConfiguration,
        initialMode: ThemeMode = .dark
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        currentMode = initialMode
    }

    public mutating func updateConfiguration(_ newConfiguration: AutomationConfiguration) throws {
        try newConfiguration.validate()
        configuration = newConfiguration
        candidate = nil
    }

    /// 接收一个有效采样。采样周期由调用方控制为 1 Hz。
    @discardableResult
    public mutating func process(lux: Double, at uptime: TimeInterval) -> AutomationUpdate {
        guard !isSleeping else {
            return makeUpdate(disposition: .ignoredWhileSleeping, requestedMode: nil, at: uptime)
        }
        guard AmbientLightReadingLimits.contains(lux), uptime.isFinite else {
            resetSampleContinuity()
            return makeUpdate(disposition: .invalidSample, requestedMode: nil, at: uptime)
        }

        if let lastAcceptedSampleAt {
            let gap = uptime - lastAcceptedSampleAt
            if gap < 0 || gap > Self.maximumContinuousSampleGap {
                resetSampleContinuity()
            }
        }

        lastAcceptedSampleAt = uptime
        latestRawLux = lux
        appendSample(lux)
        latestFilteredLux = Self.median(of: samples)

        if warmupSamplesRemaining > 0 {
            warmupSamplesRemaining -= 1
            if warmupSamplesRemaining > 0 {
                return makeUpdate(disposition: .warmingUp, requestedMode: nil, at: uptime)
            }
        }

        guard pendingMode == nil else {
            return makeUpdate(disposition: .accepted, requestedMode: nil, at: uptime)
        }
        guard let filteredLux = latestFilteredLux,
              let targetMode = targetMode(for: filteredLux)
        else {
            candidate = nil
            return makeUpdate(disposition: .accepted, requestedMode: nil, at: uptime)
        }

        if candidate?.mode != targetMode {
            candidate = Candidate(mode: targetMode, startedAt: uptime)
        }

        guard isCandidateReady(at: uptime) else {
            return makeUpdate(disposition: .accepted, requestedMode: nil, at: uptime)
        }

        pendingMode = targetMode
        candidate = nil
        return makeUpdate(disposition: .accepted, requestedMode: targetMode, at: uptime)
    }

    /// 主题事务成功后确认切换。若没有对应的待处理请求，不改变状态并返回 `false`。
    @discardableResult
    public mutating func confirmThemeChange(to mode: ThemeMode, at uptime: TimeInterval) -> Bool {
        guard pendingMode == mode, uptime.isFinite else { return false }
        currentMode = mode
        pendingMode = nil
        candidate = nil
        lastSuccessfulSwitchAt = uptime
        return true
    }

    /// 主题事务失败或被取消。下一次必须重新满足完整稳定时间才会再次请求切换。
    public mutating func cancelPendingThemeChange() {
        pendingMode = nil
        candidate = nil
    }

    /// 同步外部已知模式，供启动检查和手动切换使用。
    public mutating func setCurrentMode(
        _ mode: ThemeMode,
        at uptime: TimeInterval,
        countsAsSwitch: Bool = true
    ) {
        let didChange = mode != currentMode
        currentMode = mode
        pendingMode = nil
        candidate = nil
        if countsAsSwitch, didChange, uptime.isFinite {
            lastSuccessfulSwitchAt = uptime
        }
    }

    /// 进入休眠后停止判断并丢弃可能过期的采样与候选状态。
    public mutating func handleSleep() {
        isSleeping = true
        pendingMode = nil
        resetSampleContinuity()
        warmupSamplesRemaining = 0
    }

    /// 唤醒后要求取得三个有效采样，再恢复阈值判断。
    public mutating func handleWake() {
        isSleeping = false
        pendingMode = nil
        resetSampleContinuity()
        warmupSamplesRemaining = Self.wakeWarmupSampleCount
    }

    /// 读取失败不会被解释为 0 lux；清空旧窗口以防恢复后立即误切换。
    public mutating func handleSensorFailure() {
        resetSampleContinuity()
    }

    public func snapshot(at uptime: TimeInterval) -> AutomationSnapshot {
        let timing = candidateTiming(at: uptime)
        return AutomationSnapshot(
            currentMode: currentMode,
            pendingMode: pendingMode,
            rawLux: latestRawLux,
            filteredLux: latestFilteredLux,
            candidateMode: candidate?.mode,
            candidateElapsed: timing.elapsed,
            candidateRemaining: timing.remaining,
            warmupSamplesRemaining: warmupSamplesRemaining,
            isSleeping: isSleeping
        )
    }

    private mutating func appendSample(_ lux: Double) {
        samples.append(lux)
        if samples.count > Self.sampleWindowSize {
            samples.removeFirst(samples.count - Self.sampleWindowSize)
        }
    }

    private func targetMode(for filteredLux: Double) -> ThemeMode? {
        switch currentMode {
        case .dark where filteredLux >= configuration.outdoorThreshold:
            .light
        case .light where filteredLux <= configuration.indoorThreshold:
            .dark
        default:
            nil
        }
    }

    private func isCandidateReady(at uptime: TimeInterval) -> Bool {
        guard candidate != nil else { return false }
        let timing = candidateTiming(at: uptime)
        return timing.remaining <= 0
    }

    private func candidateTiming(at uptime: TimeInterval) -> (elapsed: TimeInterval, remaining: TimeInterval) {
        guard let candidate, uptime.isFinite else { return (0, 0) }

        let elapsed = max(0, uptime - candidate.startedAt)
        let stableRemaining = max(0, configuration.stableDuration - elapsed)
        let dwellRemaining: TimeInterval
        if let lastSuccessfulSwitchAt {
            dwellRemaining = max(
                0,
                configuration.minimumDwellDuration - max(0, uptime - lastSuccessfulSwitchAt)
            )
        } else {
            dwellRemaining = 0
        }
        return (elapsed, max(stableRemaining, dwellRemaining))
    }

    private mutating func resetSampleContinuity() {
        samples.removeAll(keepingCapacity: true)
        latestRawLux = nil
        latestFilteredLux = nil
        candidate = nil
        lastAcceptedSampleAt = nil
    }

    private func makeUpdate(
        disposition: AutomationSampleDisposition,
        requestedMode: ThemeMode?,
        at uptime: TimeInterval
    ) -> AutomationUpdate {
        AutomationUpdate(
            disposition: disposition,
            requestedMode: requestedMode,
            snapshot: snapshot(at: uptime)
        )
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
        }
        return sorted[middle]
    }

    private struct Candidate: Sendable {
        let mode: ThemeMode
        let startedAt: TimeInterval
    }
}
