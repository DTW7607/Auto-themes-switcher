import Foundation
import IOKit

/// 产品支持的照度范围。Apple ALS 在暂时没有有效读数时可能返回
/// `UInt64.max` 一类数值哨兵，不能把它解释成室外强光。
public enum AmbientLightReadingLimits {
    public static let maximumLux = 200_000.0

    public static func contains(_ lux: Double) -> Bool {
        lux.isFinite && (0 ... maximumLux).contains(lux)
    }
}

/// 可被自动化引擎替换为测试桩的环境光读取接口。
public protocol AmbientLightProvider: AnyObject, Sendable {
    /// 当前已选中的传感器；尚未发现或已失效时为 `nil`。
    var sensorInfo: AmbientLightSensorInfo? { get }

    /// 重新枚举并选择一个可用的内建环境光传感器。
    @discardableResult
    func discover() throws -> AmbientLightSensorInfo

    /// 读取当前照度。调用前必须成功执行过 `discover()`。
    func readLux() throws -> Double

    /// 释放当前 IOKit service。休眠和退出前可安全重复调用。
    func invalidate()
}

public struct AmbientLightSensorInfo: Codable, Equatable, Sendable {
    public let registryName: String
    public let registryPath: String?
    public let registryEntryID: UInt64
    public let isBuiltIn: Bool

    public init(
        registryName: String,
        registryPath: String?,
        registryEntryID: UInt64,
        isBuiltIn: Bool
    ) {
        self.registryName = registryName
        self.registryPath = registryPath
        self.registryEntryID = registryEntryID
        self.isBuiltIn = isBuiltIn
    }
}

public enum AmbientLightError: Error, Equatable, Sendable {
    case matchingDictionaryUnavailable
    case enumerationFailed(code: kern_return_t)
    case sensorUnavailable
    case sensorNotDiscovered
    case luxUnavailable
    case invalidLux
}

extension AmbientLightError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .matchingDictionaryUnavailable:
            "无法创建环境光传感器查询。"
        case let .enumerationFailed(code):
            "枚举环境光传感器失败（IOKit: \(code)）。"
        case .sensorUnavailable:
            "未找到可读取 CurrentLux 的内建环境光传感器。"
        case .sensorNotDiscovered:
            "尚未发现环境光传感器。"
        case .luxUnavailable:
            "环境光传感器暂时没有返回 CurrentLux。"
        case .invalidLux:
            "环境光传感器返回了无效照度。"
        }
    }
}

/// 通过 IOKit registry 中 Apple ALS 驱动的 `CurrentLux` 属性读取照度。
///
/// `CurrentLux` 不是公开稳定的 macOS API，因此系统升级后可能不可用。类内部
/// 使用锁保护持有的 `io_service_t`，以便采样线程与睡眠通知安全地并发访问。
public final class IOKitAmbientLightProvider: AmbientLightProvider, @unchecked Sendable {
    private static let serviceClass = "IOHIDEventService"
    private static let expectedBundleIdentifier = "com.apple.driver.AppleALSColorSensor"
    private static let bundleIdentifierKey = "CFBundleIdentifier"
    private static let currentLuxKey = "CurrentLux"
    private static let builtInKey = "Built-In"
    // IOKit 的 io_name_t / io_string_t 在公开头文件中分别固定为 128 / 512 字节。
    private static let registryNameBufferSize = 128
    private static let registryPathBufferSize = 512

    private let lock = NSLock()
    private var service: io_service_t = IO_OBJECT_NULL
    private var selectedSensorInfo: AmbientLightSensorInfo?

    public init() {}

    deinit {
        invalidate()
    }

    public var sensorInfo: AmbientLightSensorInfo? {
        lock.lock()
        defer { lock.unlock() }
        return selectedSensorInfo
    }

    @discardableResult
    public func discover() throws -> AmbientLightSensorInfo {
        guard let matching = IOServiceMatching(Self.serviceClass) else {
            throw AmbientLightError.matchingDictionaryUnavailable
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            throw AmbientLightError.enumerationFailed(code: result)
        }
        defer { IOObjectRelease(iterator) }

        var selectedService: io_service_t = IO_OBJECT_NULL
        var selectedInfo: AmbientLightSensorInfo?

        while true {
            let candidate = IOIteratorNext(iterator)
            guard candidate != IO_OBJECT_NULL else { break }

            guard Self.isAmbientLightSensor(candidate),
                  Self.numericProperty(Self.currentLuxKey, of: candidate) != nil
            else {
                IOObjectRelease(candidate)
                continue
            }

            let info = Self.makeSensorInfo(for: candidate)
            if selectedService == IO_OBJECT_NULL {
                selectedService = candidate
                selectedInfo = info
            } else if info.isBuiltIn, selectedInfo?.isBuiltIn != true {
                IOObjectRelease(selectedService)
                selectedService = candidate
                selectedInfo = info
            } else {
                // 保留枚举顺序中的首个同等级候选，确保选择稳定。
                IOObjectRelease(candidate)
            }
        }

        guard selectedService != IO_OBJECT_NULL, let selectedInfo else {
            throw AmbientLightError.sensorUnavailable
        }

        lock.lock()
        let previousService = service
        service = selectedService
        selectedSensorInfo = selectedInfo
        lock.unlock()

        if previousService != IO_OBJECT_NULL {
            IOObjectRelease(previousService)
        }

        return selectedInfo
    }

    public func readLux() throws -> Double {
        lock.lock()
        defer { lock.unlock() }

        guard service != IO_OBJECT_NULL else {
            throw AmbientLightError.sensorNotDiscovered
        }
        guard let lux = Self.numericProperty(Self.currentLuxKey, of: service) else {
            throw AmbientLightError.luxUnavailable
        }
        guard AmbientLightReadingLimits.contains(lux) else {
            throw AmbientLightError.invalidLux
        }
        return lux
    }

    public func invalidate() {
        lock.lock()
        let previousService = service
        service = IO_OBJECT_NULL
        selectedSensorInfo = nil
        lock.unlock()

        if previousService != IO_OBJECT_NULL {
            IOObjectRelease(previousService)
        }
    }

    private static func isAmbientLightSensor(_ service: io_service_t) -> Bool {
        stringProperty(bundleIdentifierKey, of: service) == expectedBundleIdentifier
    }

    private static func makeSensorInfo(for service: io_service_t) -> AmbientLightSensorInfo {
        var registryEntryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &registryEntryID) != KERN_SUCCESS {
            registryEntryID = 0
        }

        return AmbientLightSensorInfo(
            registryName: registryName(of: service) ?? "未知 ALS 传感器",
            registryPath: registryPath(of: service),
            registryEntryID: registryEntryID,
            isBuiltIn: booleanProperty(builtInKey, of: service) ?? false
        )
    }

    private static func copiedProperty(_ key: String, of service: io_service_t) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func stringProperty(_ key: String, of service: io_service_t) -> String? {
        copiedProperty(key, of: service) as? String
    }

    private static func numericProperty(_ key: String, of service: io_service_t) -> Double? {
        (copiedProperty(key, of: service) as? NSNumber)?.doubleValue
    }

    private static func booleanProperty(_ key: String, of service: io_service_t) -> Bool? {
        (copiedProperty(key, of: service) as? NSNumber)?.boolValue
    }

    private static func registryName(of service: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: registryNameBufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            IORegistryEntryGetName(service, pointer.baseAddress!)
        }
        guard result == KERN_SUCCESS else { return nil }
        return decodeNullTerminatedUTF8(buffer)
    }

    private static func registryPath(of service: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: registryPathBufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            IORegistryEntryGetPath(service, kIOServicePlane, pointer.baseAddress!)
        }
        guard result == KERN_SUCCESS else { return nil }
        return decodeNullTerminatedUTF8(buffer)
    }

    private static func decodeNullTerminatedUTF8(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
