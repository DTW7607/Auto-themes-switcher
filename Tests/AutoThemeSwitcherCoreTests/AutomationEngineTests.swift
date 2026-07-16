import XCTest
@testable import AutoThemeSwitcherCore

final class AutomationEngineTests: XCTestCase {
    func testDefaultConfigurationMatchesProductDefaults() {
        let configuration = AutomationConfiguration.defaults

        XCTAssertEqual(configuration.indoorThreshold, 1_000)
        XCTAssertEqual(configuration.outdoorThreshold, 5_000)
        XCTAssertEqual(configuration.stableDuration, 5)
        XCTAssertEqual(configuration.minimumDwellDuration, 15)
        XCTAssertNoThrow(try configuration.validate())
        XCTAssertEqual(AutomationEngine.recommendedSamplingInterval, 1)
        XCTAssertEqual(AutomationEngine.sampleWindowSize, 5)
        XCTAssertEqual(AmbientLightReadingLimits.maximumLux, 200_000)
    }

    func testConfigurationRejectsInvalidThresholdsAndStableDuration() {
        XCTAssertThrowsError(
            try AutomationConfiguration(
                indoorThreshold: -1,
                outdoorThreshold: 5_000
            ).validate()
        ) { error in
            XCTAssertEqual(error as? AutomationConfigurationError, .invalidIndoorThreshold)
        }

        XCTAssertThrowsError(
            try AutomationConfiguration(
                indoorThreshold: 1_000,
                outdoorThreshold: 1_000
            ).validate()
        ) { error in
            XCTAssertEqual(error as? AutomationConfigurationError, .invalidOutdoorThreshold)
        }

        XCTAssertThrowsError(
            try AutomationConfiguration(
                indoorThreshold: 1_000,
                outdoorThreshold: 5_000,
                stableDuration: 61
            ).validate()
        ) { error in
            XCTAssertEqual(error as? AutomationConfigurationError, .invalidStableDuration)
        }
    }

    func testRequestsLightOnlyAfterFiveContinuousSecondsAndWaitsForConfirmation() {
        var engine = AutomationEngine(initialMode: .dark)

        for second in 0 ..< 5 {
            let update = engine.process(lux: 8_000, at: TimeInterval(second))
            XCTAssertNil(update.requestedMode)
            XCTAssertEqual(update.snapshot.currentMode, .dark)
        }

        let request = engine.process(lux: 8_000, at: 5)
        XCTAssertEqual(request.requestedMode, .light)
        XCTAssertEqual(request.snapshot.currentMode, .dark)
        XCTAssertEqual(request.snapshot.pendingMode, .light)

        let repeatedSample = engine.process(lux: 8_000, at: 6)
        XCTAssertNil(repeatedSample.requestedMode)
        XCTAssertEqual(repeatedSample.snapshot.pendingMode, .light)

        XCTAssertTrue(engine.confirmThemeChange(to: .light, at: 6))
        XCTAssertEqual(engine.snapshot(at: 6).currentMode, .light)
        XCTAssertNil(engine.snapshot(at: 6).pendingMode)
    }

    func testMedianOfRecentFiveRejectsSingleBrightOutlier() throws {
        let configuration = AutomationConfiguration(
            indoorThreshold: 1_000,
            outdoorThreshold: 5_000,
            stableDuration: 1,
            minimumDwellDuration: 0
        )
        var engine = try AutomationEngine(validating: configuration, initialMode: .dark)

        for second in 0 ... 4 {
            _ = engine.process(lux: 200, at: TimeInterval(second))
        }

        let spike = engine.process(lux: 100_000, at: 5)
        XCTAssertEqual(spike.snapshot.rawLux, 100_000)
        XCTAssertEqual(spike.snapshot.filteredLux, 200)
        XCTAssertNil(spike.snapshot.candidateMode)
        XCTAssertNil(spike.requestedMode)
    }

    func testHysteresisBandDoesNotReverseLightMode() {
        var engine = AutomationEngine(initialMode: .light)

        for second in 0 ... 20 {
            let update = engine.process(lux: 3_000, at: TimeInterval(second))
            XCTAssertNil(update.requestedMode)
            XCTAssertNil(update.snapshot.candidateMode)
            XCTAssertEqual(update.snapshot.currentMode, .light)
        }
    }

    func testMinimumDwellDelaysReverseTransition() throws {
        let configuration = AutomationConfiguration(
            indoorThreshold: 1_000,
            outdoorThreshold: 5_000,
            stableDuration: 1,
            minimumDwellDuration: 15
        )
        var engine = try AutomationEngine(validating: configuration, initialMode: .dark)

        XCTAssertNil(engine.process(lux: 8_000, at: 0).requestedMode)
        XCTAssertEqual(engine.process(lux: 8_000, at: 1).requestedMode, .light)
        XCTAssertTrue(engine.confirmThemeChange(to: .light, at: 1))

        for second in 2 ..< 16 {
            let update = engine.process(lux: 100, at: TimeInterval(second))
            XCTAssertNil(update.requestedMode, "不应在驻留期第 \(second) 秒反向切换")
        }

        let reverseRequest = engine.process(lux: 100, at: 16)
        XCTAssertEqual(reverseRequest.requestedMode, .dark)
    }

    func testWakeRequiresThreeValidSamplesBeforeThresholdEvaluation() throws {
        let configuration = AutomationConfiguration(
            indoorThreshold: 1_000,
            outdoorThreshold: 5_000,
            stableDuration: 1,
            minimumDwellDuration: 0
        )
        var engine = try AutomationEngine(validating: configuration, initialMode: .dark)
        engine.handleWake()

        let first = engine.process(lux: 9_000, at: 100)
        XCTAssertEqual(first.disposition, .warmingUp)
        XCTAssertEqual(first.snapshot.warmupSamplesRemaining, 2)
        XCTAssertNil(first.snapshot.candidateMode)

        let second = engine.process(lux: 9_000, at: 101)
        XCTAssertEqual(second.disposition, .warmingUp)
        XCTAssertEqual(second.snapshot.warmupSamplesRemaining, 1)
        XCTAssertNil(second.snapshot.candidateMode)

        let third = engine.process(lux: 9_000, at: 102)
        XCTAssertEqual(third.disposition, .accepted)
        XCTAssertEqual(third.snapshot.warmupSamplesRemaining, 0)
        XCTAssertEqual(third.snapshot.candidateMode, .light)
        XCTAssertNil(third.requestedMode)

        XCTAssertEqual(engine.process(lux: 9_000, at: 103).requestedMode, .light)
    }

    func testSleepIgnoresSamplesAndWakeDropsStaleWindow() {
        var engine = AutomationEngine(initialMode: .dark)
        _ = engine.process(lux: 8_000, at: 0)
        engine.handleSleep()

        let sleeping = engine.process(lux: 0, at: 30)
        XCTAssertEqual(sleeping.disposition, .ignoredWhileSleeping)
        XCTAssertTrue(sleeping.snapshot.isSleeping)
        XCTAssertNil(sleeping.snapshot.rawLux)
        XCTAssertEqual(sleeping.snapshot.currentMode, .dark)

        engine.handleWake()
        let awake = engine.snapshot(at: 31)
        XCTAssertFalse(awake.isSleeping)
        XCTAssertEqual(awake.warmupSamplesRemaining, 3)
        XCTAssertNil(awake.filteredLux)
    }

    func testSensorFailureBreaksContinuousCandidate() {
        var engine = AutomationEngine(initialMode: .dark)
        for second in 0 ... 4 {
            XCTAssertNil(engine.process(lux: 8_000, at: TimeInterval(second)).requestedMode)
        }

        engine.handleSensorFailure()

        let recovered = engine.process(lux: 8_000, at: 10)
        XCTAssertNil(recovered.requestedMode)
        XCTAssertEqual(recovered.snapshot.candidateElapsed, 0)
        XCTAssertEqual(recovered.snapshot.candidateRemaining, 5)
        XCTAssertEqual(recovered.snapshot.currentMode, .dark)
    }

    func testLargeSamplingGapBreaksContinuousCandidate() {
        var engine = AutomationEngine(initialMode: .dark)
        _ = engine.process(lux: 8_000, at: 0)
        _ = engine.process(lux: 8_000, at: 1)
        _ = engine.process(lux: 8_000, at: 2)

        let afterGap = engine.process(lux: 8_000, at: 10)
        XCTAssertNil(afterGap.requestedMode)
        XCTAssertEqual(afterGap.snapshot.candidateElapsed, 0)
        XCTAssertEqual(afterGap.snapshot.candidateRemaining, 5)
    }

    func testInvalidLuxNeverActsAsDarkReading() {
        var engine = AutomationEngine(initialMode: .light)
        let update = engine.process(lux: .nan, at: 0)

        XCTAssertEqual(update.disposition, .invalidSample)
        XCTAssertNil(update.requestedMode)
        XCTAssertEqual(update.snapshot.currentMode, .light)
        XCTAssertNil(update.snapshot.rawLux)
        XCTAssertNil(update.snapshot.filteredLux)

        let driverSentinel = engine.process(lux: Double(UInt64.max), at: 1)
        XCTAssertEqual(driverSentinel.disposition, .invalidSample)
        XCTAssertNil(driverSentinel.requestedMode)
        XCTAssertEqual(driverSentinel.snapshot.currentMode, .light)
        XCTAssertNil(driverSentinel.snapshot.rawLux)
    }

    func testFailedThemeTransactionMustRestabilize() throws {
        let configuration = AutomationConfiguration(
            indoorThreshold: 1_000,
            outdoorThreshold: 5_000,
            stableDuration: 1,
            minimumDwellDuration: 0
        )
        var engine = try AutomationEngine(validating: configuration, initialMode: .dark)

        _ = engine.process(lux: 8_000, at: 0)
        XCTAssertEqual(engine.process(lux: 8_000, at: 1).requestedMode, .light)
        engine.cancelPendingThemeChange()

        XCTAssertNil(engine.process(lux: 8_000, at: 2).requestedMode)
        XCTAssertEqual(engine.process(lux: 8_000, at: 3).requestedMode, .light)
    }

    func testAmbientLightProviderCanBeReplacedWithAStub() throws {
        let provider: any AmbientLightProvider = StubAmbientLightProvider(values: [120, 240])

        let info = try provider.discover()
        XCTAssertEqual(info.registryName, "测试传感器")
        XCTAssertEqual(try provider.readLux(), 120)
        XCTAssertEqual(try provider.readLux(), 240)
        provider.invalidate()
        XCTAssertNil(provider.sensorInfo)
    }
}

private final class StubAmbientLightProvider: AmbientLightProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    private var info: AmbientLightSensorInfo?

    init(values: [Double]) {
        self.values = values
    }

    var sensorInfo: AmbientLightSensorInfo? {
        lock.lock()
        defer { lock.unlock() }
        return info
    }

    func discover() throws -> AmbientLightSensorInfo {
        let discovered = AmbientLightSensorInfo(
            registryName: "测试传感器",
            registryPath: nil,
            registryEntryID: 1,
            isBuiltIn: true
        )
        lock.lock()
        info = discovered
        lock.unlock()
        return discovered
    }

    func readLux() throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard info != nil else { throw AmbientLightError.sensorNotDiscovered }
        guard !values.isEmpty else { throw AmbientLightError.luxUnavailable }
        return values.removeFirst()
    }

    func invalidate() {
        lock.lock()
        info = nil
        lock.unlock()
    }
}
