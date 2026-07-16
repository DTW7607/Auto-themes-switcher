import Foundation
import ServiceManagement

@MainActor
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            "已启用"
        case .requiresApproval:
            "等待系统设置批准"
        case .notRegistered:
            "未注册"
        case .notFound:
            "找不到已安装的 App"
        @unknown default:
            "状态未知"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
