import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let automaticEnabled = "automaticEnabled"
        static let indoorThreshold = "indoorThreshold"
        static let outdoorThreshold = "outdoorThreshold"
        static let stabilitySeconds = "stabilitySeconds"
        static let minimumDwellSeconds = "minimumDwellSeconds"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    @Published var automaticEnabled: Bool {
        didSet { defaults.set(automaticEnabled, forKey: Key.automaticEnabled) }
    }

    @Published var indoorThreshold: Double {
        didSet { persistAutomationSettingsIfValid() }
    }

    @Published var outdoorThreshold: Double {
        didSet { persistAutomationSettingsIfValid() }
    }

    @Published var stabilitySeconds: Double {
        didSet { persistAutomationSettingsIfValid() }
    }

    @Published var minimumDwellSeconds: Double {
        didSet { persistAutomationSettingsIfValid() }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.automaticEnabled: true,
            Key.indoorThreshold: 1_000.0,
            Key.outdoorThreshold: 5_000.0,
            Key.stabilitySeconds: 5.0,
            Key.minimumDwellSeconds: 15.0,
            Key.launchAtLogin: true
        ])

        automaticEnabled = defaults.bool(forKey: Key.automaticEnabled)

        let storedIndoor = defaults.double(forKey: Key.indoorThreshold)
        let storedOutdoor = defaults.double(forKey: Key.outdoorThreshold)
        let storedStability = defaults.double(forKey: Key.stabilitySeconds)
        let storedDwell = defaults.double(forKey: Key.minimumDwellSeconds)
        if Self.isValidAutomationConfiguration(
            indoorThreshold: storedIndoor,
            outdoorThreshold: storedOutdoor,
            stabilitySeconds: storedStability,
            minimumDwellSeconds: storedDwell
        ) {
            indoorThreshold = storedIndoor
            outdoorThreshold = storedOutdoor
            stabilitySeconds = storedStability
            minimumDwellSeconds = storedDwell
        } else {
            // 旧版本或外部工具可能留下非法偏好。只在内存中回退，避免把非法值送入状态机。
            indoorThreshold = 1_000
            outdoorThreshold = 5_000
            stabilitySeconds = 5
            minimumDwellSeconds = 15
        }
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }

    var validationMessage: String? {
        guard indoorThreshold.isFinite, indoorThreshold >= 0 else {
            return "室内阈值不能小于 0 lux"
        }
        guard outdoorThreshold.isFinite, outdoorThreshold <= 200_000 else {
            return "室外阈值不能大于 200000 lux"
        }
        guard indoorThreshold < outdoorThreshold else {
            return "室内阈值必须小于室外阈值"
        }
        guard stabilitySeconds.isFinite, (1 ... 60).contains(stabilitySeconds) else {
            return "稳定时间必须在 1–60 秒之间"
        }
        guard minimumDwellSeconds.isFinite, minimumDwellSeconds >= 0 else {
            return "最短驻留时间不能小于 0 秒"
        }
        return nil
    }

    private func persistAutomationSettingsIfValid() {
        guard validationMessage == nil else { return }
        defaults.set(indoorThreshold, forKey: Key.indoorThreshold)
        defaults.set(outdoorThreshold, forKey: Key.outdoorThreshold)
        defaults.set(stabilitySeconds, forKey: Key.stabilitySeconds)
        defaults.set(minimumDwellSeconds, forKey: Key.minimumDwellSeconds)
    }

    private static func isValidAutomationConfiguration(
        indoorThreshold: Double,
        outdoorThreshold: Double,
        stabilitySeconds: Double,
        minimumDwellSeconds: Double
    ) -> Bool {
        indoorThreshold.isFinite
            && outdoorThreshold.isFinite
            && stabilitySeconds.isFinite
            && minimumDwellSeconds.isFinite
            && indoorThreshold >= 0
            && indoorThreshold < outdoorThreshold
            && outdoorThreshold <= 200_000
            && (1 ... 60).contains(stabilitySeconds)
            && minimumDwellSeconds >= 0
    }
}
