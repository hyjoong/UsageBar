import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginStore: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let isDemo: Bool
    private let service: SMAppService?

    init(demo: Bool = false) {
        isDemo = demo
        let service = demo ? nil : SMAppService.mainApp
        self.service = service
        status = service?.status ?? .notRegistered
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusMessage: String {
        if isDemo { return String(localized: "예시 모드에서는 이 화면에서만 변경되며, Mac의 로그인 항목에는 등록하지 않아요.") }
        switch status {
        case .notRegistered:
            return String(localized: "꺼져 있어요. 이 옵션을 켜면 다음 로그인부터 자동으로 실행해요.")
        case .enabled:
            return String(localized: "다음 로그인부터 UsageBar를 자동으로 실행해요.")
        case .requiresApproval:
            return String(localized: "자동 실행이 아직 허용되지 않았어요. 시스템 설정의 로그인 항목에서 UsageBar를 허용해 주세요.")
        case .notFound:
            return String(localized: "로그인 항목을 찾지 못했어요. 응용 프로그램 폴더의 UsageBar 앱에서 다시 시도해 주세요.")
        @unknown default:
            return String(localized: "로그인 항목 상태를 확인하지 못했어요.")
        }
    }

    func refreshStatus() {
        guard let service else { return }
        status = service.status
    }

    // Only the user's toggle action calls this method; initialization and refresh are read-only.
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        if isDemo {
            status = enabled ? .enabled : .notRegistered
            return
        }
        guard let service else { return }
        refreshStatus()
        do {
            if enabled {
                // A denied or pending registration must be approved in System Settings.
                if status != .enabled && status != .requiresApproval {
                    try service.register()
                }
            } else if status == .enabled || status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            errorMessage = String(localized: "로그인 시 실행 설정을 변경하지 못했어요. \(error.localizedDescription)")
        }
        refreshStatus()
    }

    func openSystemSettings() {
        guard !isDemo else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
