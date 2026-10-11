import Foundation

struct UpdateConfiguration {
    let isReady: Bool
    let statusMessage: String

    static func isIsolatedFixture(info: [String: Any], bundleIdentifier: String?) -> Bool {
        #if DEBUG
        return bundleIdentifier == "dev.hyjoong.usagebar.updatetest" && info["UsageBarUpdateTestMode"] as? Bool == true
        #else
        return false
        #endif
    }

    static func displayVersion(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? String(localized: "개발 버전")
        guard let build = info["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }

    init(info: [String: Any], bundleIdentifier: String?, isDemo: Bool, allowsLocalFixture: Bool = false) {
        let fixture = allowsLocalFixture && Self.isIsolatedFixture(info: info, bundleIdentifier: bundleIdentifier)
        guard !isDemo || fixture else {
            isReady = false
            statusMessage = String(localized: "예시 앱에서는 업데이트를 확인하지 않아요.")
            return
        }
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else {
            isReady = false
            statusMessage = String(localized: "이 개발용 앱은 업데이트 배포 경로를 준비 중이에요.")
            return
        }
        let components = URLComponents(string: feed)
        let host = components?.host ?? ""
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        let secure = components?.scheme?.lowercased() == "https"
        let localTest = fixture && loopback && components?.scheme?.lowercased() == "http"
        guard !host.isEmpty, components?.url != nil,
              components?.user == nil, components?.password == nil, components?.fragment == nil,
              feed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              (fixture ? (loopback && (secure || localTest)) : secure), Data(base64Encoded: key)?.count == 32 else {
            isReady = false
            statusMessage = String(localized: "업데이트 설정을 확인할 수 없어요. 배포자에게 문의해 주세요.")
            return
        }
        isReady = true
        statusMessage = String(localized: "새 버전을 확인한 뒤 설치할 수 있어요. 설정과 저장된 기록은 유지돼요.")
    }
}
