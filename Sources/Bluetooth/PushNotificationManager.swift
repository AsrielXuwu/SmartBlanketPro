import Foundation
import UIKit
import UserNotifications
import CryptoKit

/// Apple 官方 APNs (Apple Push Notification service) 与本地实时状态推送中心
/// 针对拥有推送权限 (aps-environment) 的自签证书与 iOS 26/27 原生通知设计：
/// 1. 启动时向 Apple APNs 服务器注册并获取真实 64 位 Hex `deviceToken`；
/// 2. 支持配置 Apple Developer `.p8` Auth Key (Key ID / Team ID / Private Key)，使用 iOS 原生 `CryptoKit` (`P256.Signing`) 签发 ES256 JWT，直接通过 HTTP/2 请求 Apple 官方 `https://api.push.apple.com/3/device/<token>` 推送电热毯实时状态；
/// 3. 同时结合 `UNUserNotificationCenter` 提供毫秒级状态变更推送与后台定时到点（预约开机触发、自动关机完成、除螨完成）精准提醒。
public final class PushNotificationManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject, @unchecked Sendable {
    public static let shared = PushNotificationManager()

    // MARK: - Published APNs State
    @Published public var apnsDeviceToken: String = UserDefaults.standard.string(forKey: "com.smartblanketpro.apns_token") ?? ""
    @Published public var isPushAuthorized: Bool = false
    @Published public var apnsStatusMessage: String = "等待获取 APNs 令牌..."

    /// 用户可选配置的 Apple 官方 APNs HTTP/2 (.p8 Token-Based) 直推参数
    @Published public var apnsTeamID: String = UserDefaults.standard.string(forKey: "com.smartblanketpro.apns_team_id") ?? "" {
        didSet { UserDefaults.standard.set(apnsTeamID, forKey: "com.smartblanketpro.apns_team_id") }
    }
    @Published public var apnsKeyID: String = UserDefaults.standard.string(forKey: "com.smartblanketpro.apns_key_id") ?? "" {
        didSet { UserDefaults.standard.set(apnsKeyID, forKey: "com.smartblanketpro.apns_key_id") }
    }
    @Published public var apnsP8PrivateKey: String = UserDefaults.standard.string(forKey: "com.smartblanketpro.apns_p8_key") ?? "" {
        didSet { UserDefaults.standard.set(apnsP8PrivateKey, forKey: "com.smartblanketpro.apns_p8_key") }
    }
    @Published public var useSandboxAPNs: Bool = UserDefaults.standard.bool(forKey: "com.smartblanketpro.apns_sandbox") {
        didSet { UserDefaults.standard.set(useSandboxAPNs, forKey: "com.smartblanketpro.apns_sandbox") }
    }
    @Published public var enableStatusPushNotifications: Bool = (UserDefaults.standard.object(forKey: "com.smartblanketpro.enable_push") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(enableStatusPushNotifications, forKey: "com.smartblanketpro.enable_push") }
    }

    public override init() {
        super.init()
    }

    // MARK: - UIApplicationDelegate Lifecycle
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestPushAuthorizationAndRegister()
        return true
    }

    public func requestPushAuthorizationAndRegister() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isPushAuthorized = granted
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                } else if let error = error {
                    self?.apnsStatusMessage = "通知权限请求失败: \(error.localizedDescription)"
                } else {
                    self?.apnsStatusMessage = "请在系统设置中允许通知权限"
                }
            }
        }
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        DispatchQueue.main.async { [weak self] in
            self?.apnsDeviceToken = tokenHex
            self?.apnsStatusMessage = "已成功接入 Apple 官方 APNs"
            UserDefaults.standard.set(tokenHex, forKey: "com.smartblanketpro.apns_token")
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.apnsStatusMessage = "APNs 注册提示: \(error.localizedDescription)"
        }
    }

    // MARK: - UNUserNotificationCenterDelegate (前台横幅展示与后台静默唤醒)
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // 收到远程静默 APNs (`content-available: 1`) 时，快速点对点查询一次电热毯最新状态后立即释放蓝牙连接
        Task { @MainActor in
            if let active = BlanketBLEManager.shared.activeDevice {
                await BlanketBLEManager.shared.performQuickBackgroundStatusSync(for: active.id)
            }
            completionHandler(.newData)
        }
    }

    // MARK: - 设备状态更新推送 (Apple 官方 APNs HTTP/2 + 系统通知中心双保险)
    public func notifyDeviceStateChanged(title: String, body: String, categoryIdentifier: String = "BLANKET_STATUS") {
        guard enableStatusPushNotifications else { return }

        // 1. 若用户已配置 .p8 密钥且获取了 APNs Device Token，优先通过 Apple 官方 APNs HTTP/2 网关下发远程推送
        if !apnsDeviceToken.isEmpty && !apnsTeamID.isEmpty && !apnsKeyID.isEmpty && !apnsP8PrivateKey.isEmpty {
            Task {
                let sentViaAPNs = await sendDirectAppleAPNsPush(title: title, body: body)
                if !sentViaAPNs {
                    scheduleSystemNotification(title: title, body: body, delay: 0.1, identifier: UUID().uuidString)
                }
            }
        } else {
            // 2. 直接通过 iOS 原生 UNUserNotificationCenter 投递系统通知横幅
            scheduleSystemNotification(title: title, body: body, delay: 0.1, identifier: UUID().uuidString)
        }
    }

    /// 在 App 退入后台断连蓝牙前，根据当前硬件剩余定时秒数预埋精准的到点状态通知（预约开机 / 自动关机）
    public func scheduleBackgroundHardwareTimerNotifications(for device: BlanketDevice) {
        let center = UNUserNotificationCenter.current()
        let closeID = "timer_close_\(device.id.uuidString)"
        let openID = "timer_open_\(device.id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [closeID, openID])

        guard enableStatusPushNotifications else { return }

        if device.isOn && device.remainingTimeCloseSec > 5 {
            scheduleSystemNotification(
                title: "❄️ \(device.name) 已到点自动关机",
                body: "设定的 \(device.timeCloseHours) 小时自动关机定时已完成，电热毯已安全停止加热。",
                delay: TimeInterval(device.remainingTimeCloseSec),
                identifier: closeID
            )
        }

        if !device.isOn && device.timeOpenHours > 0 && device.remainingTimeOpenSec > 5 {
            scheduleSystemNotification(
                title: "🔥 \(device.name) 预约定时开机已启动",
                body: "预约的 \(device.timeOpenHours) 小时开机时间已到，电热毯已开始为您暖被。",
                delay: TimeInterval(device.remainingTimeOpenSec),
                identifier: openID
            )
        }
    }

    private func scheduleSystemNotification(title: String, body: String, delay: TimeInterval, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, delay), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Apple Official APNs HTTP/2 Direct Push Engine (CryptoKit ES256 JWT)
    /// 使用 iOS 原生 CryptoKit 签发 ES256 JWT 并直接向 Apple 官方 `api.push.apple.com` 发送 HTTP/2 推送请求
    public func sendDirectAppleAPNsPush(title: String, body: String) async -> Bool {
        guard !apnsDeviceToken.isEmpty,
              let jwt = generateAPNsJWT(teamID: apnsTeamID, keyID: apnsKeyID, p8PEM: apnsP8PrivateKey) else {
            return false
        }

        let host = useSandboxAPNs ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com"
        guard let url = URL(string: "\(host)/3/device/\(apnsDeviceToken)") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("com.jinghe.smartblanket.pro", forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")

        let payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": title,
                    "body": body
                ],
                "sound": "default",
                "content-available": 1
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        request.httpBody = bodyData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    private func generateAPNsJWT(teamID: String, keyID: String, p8PEM: String) -> String? {
        let cleanTeam = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKeyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPEM = p8PEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTeam.isEmpty, !cleanKeyID.isEmpty, !cleanPEM.isEmpty else { return nil }

        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: cleanPEM) else {
            return nil
        }

        let headerJSON = #"{"alg":"ES256","kid":"\#(cleanKeyID)"}"#
        let iat = Int(Date().timeIntervalSince1970)
        let claimsJSON = #"{"iss":"\#(cleanTeam)","iat":\#(iat)}"#

        guard let headerB64 = headerJSON.data(using: .utf8)?.base64URLEncodedString(),
              let claimsB64 = claimsJSON.data(using: .utf8)?.base64URLEncodedString() else {
            return nil
        }

        let signingInput = "\(headerB64).\(claimsB64)"
        guard let signingData = signingInput.data(using: .utf8),
              let signature = try? privateKey.signature(for: signingData) else {
            return nil
        }

        let sigB64 = signature.rawRepresentation.base64URLEncodedString()
        return "\(signingInput).\(sigB64)"
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
