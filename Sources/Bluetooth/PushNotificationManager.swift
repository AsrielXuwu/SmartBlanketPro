import Foundation
import UIKit
import UserNotifications
import CryptoKit

/// Apple 官方 APNs (Apple Push Notification service) 与本地实时状态推送中心
/// 修复 `@UIApplicationDelegateAdaptor` 独立实例与 `PushNotificationManager.shared` 单例状态不同步导致状态一直显示“等待获取 APNs 令牌...”的问题：
/// - 所有 UIApplicationDelegate 回调统一同步更新 `PushNotificationManager.shared`
/// - 当 `apnsDeviceToken` 已获取时，`effectiveStatusText` 立即显示“已成功接入 Apple 官方 APNs”并反馈最新推送投递状态
public final class PushNotificationManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject, @unchecked Sendable {
    public static let shared = PushNotificationManager()

    // MARK: - Published APNs State
    @Published public var apnsDeviceToken: String = UserDefaults.standard.string(forKey: "com.smartblanketpro.apns_token") ?? ""
    @Published public var isPushAuthorized: Bool = false
    @Published public var apnsStatusMessage: String = ""

    /// 计算当前真实 APNs 状态描述（彻底避免已拿到 Token 却仍显示“等待获取 APNs 令牌”的问题）
    public var effectiveStatusText: String {
        if !apnsStatusMessage.isEmpty {
            return apnsStatusMessage
        }
        if !apnsDeviceToken.isEmpty {
            return "已成功接入 Apple 官方 APNs"
        }
        return "正在向 Apple APNs 请求令牌..."
    }

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
        let savedToken = UserDefaults.standard.string(forKey: "com.smartblanketpro.apns_token") ?? ""
        if !savedToken.isEmpty {
            self.apnsDeviceToken = savedToken
            self.isPushAuthorized = true
            self.apnsStatusMessage = "已成功接入 Apple 官方 APNs"
        }
    }

    // MARK: - UIApplicationDelegate Lifecycle
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = PushNotificationManager.shared
        PushNotificationManager.shared.requestPushAuthorizationAndRegister()
        return true
    }

    public func requestPushAuthorizationAndRegister() {
        let center = UNUserNotificationCenter.current()
        center.delegate = PushNotificationManager.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                let target = PushNotificationManager.shared
                target.isPushAuthorized = granted
                if granted {
                    if !target.apnsDeviceToken.isEmpty {
                        target.apnsStatusMessage = "已成功接入 Apple 官方 APNs"
                    }
                    UIApplication.shared.registerForRemoteNotifications()
                } else if let error = error {
                    target.apnsStatusMessage = "通知权限请求异常: \(error.localizedDescription)"
                } else {
                    target.apnsStatusMessage = "未开启通知权限，请在系统设置中开启"
                }
            }
        }
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(tokenHex, forKey: "com.smartblanketpro.apns_token")
        DispatchQueue.main.async {
            let target = PushNotificationManager.shared
            target.apnsDeviceToken = tokenHex
            target.isPushAuthorized = true
            target.apnsStatusMessage = "已成功接入 Apple 官方 APNs"
            self.apnsDeviceToken = tokenHex
            self.apnsStatusMessage = "已成功接入 Apple 官方 APNs"
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DispatchQueue.main.async {
            let target = PushNotificationManager.shared
            if target.apnsDeviceToken.isEmpty {
                target.apnsStatusMessage = "APNs 注册失败: \(error.localizedDescription)"
            }
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
        Task { @MainActor in
            if let active = BlanketBLEManager.shared.activeDevice {
                await BlanketBLEManager.shared.performQuickBackgroundStatusSync(for: active.id)
            }
            completionHandler(.newData)
        }
    }

    // MARK: - 测试推送与实时状态更新推送
    public func sendTestPushNotification(for device: BlanketDevice) {
        let title = "✅ 智能电热毯状态推送"
        let body = "\(device.name) 当前状态：\(device.isOn ? "正在加热" : "待机中") · 左 \(device.gearLeft)挡 (\(device.temperatureLeft)°C) / 右 \(device.gearRight)挡 (\(device.temperatureRight)°C)"

        if !apnsDeviceToken.isEmpty && !apnsTeamID.isEmpty && !apnsKeyID.isEmpty && !apnsP8PrivateKey.isEmpty {
            apnsStatusMessage = "正在通过 Apple APNs 云端网关下发..."
            Task {
                let (ok, detail) = await sendDirectAppleAPNsPushWithDetail(title: title, body: body)
                DispatchQueue.main.async {
                    self.apnsStatusMessage = detail
                    if !ok {
                        self.scheduleSystemNotification(title: title, body: body, delay: 0.1, identifier: UUID().uuidString)
                    }
                }
            }
        } else {
            scheduleSystemNotification(title: title, body: body, delay: 0.1, identifier: UUID().uuidString)
            let timeStr = Date().formatted(date: .omitted, time: .standard)
            if !apnsDeviceToken.isEmpty {
                apnsStatusMessage = "已就绪 · 测试通知已于 \(timeStr) 送达"
            } else {
                apnsStatusMessage = "本地通知已于 \(timeStr) 送达"
            }
        }
    }

    public func notifyDeviceStateChanged(title: String, body: String, categoryIdentifier: String = "BLANKET_STATUS") {
        guard enableStatusPushNotifications else { return }

        if !apnsDeviceToken.isEmpty && !apnsTeamID.isEmpty && !apnsKeyID.isEmpty && !apnsP8PrivateKey.isEmpty {
            Task {
                let (sentViaAPNs, detail) = await sendDirectAppleAPNsPushWithDetail(title: title, body: body)
                DispatchQueue.main.async {
                    self.apnsStatusMessage = detail
                    if !sentViaAPNs {
                        self.scheduleSystemNotification(title: title, body: body, delay: 0.1, identifier: UUID().uuidString)
                    }
                }
            }
        } else {
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
    public func sendDirectAppleAPNsPushWithDetail(title: String, body: String) async -> (Bool, String) {
        guard !apnsDeviceToken.isEmpty else {
            return (false, "尚未获取到 APNs Device Token")
        }
        guard let jwt = generateAPNsJWT(teamID: apnsTeamID, keyID: apnsKeyID, p8PEM: apnsP8PrivateKey) else {
            return (false, "APNs .p8 私钥格式无效，已回退系统通知")
        }

        let host = useSandboxAPNs ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com"
        guard let url = URL(string: "\(host)/3/device/\(apnsDeviceToken)") else {
            return (false, "APNs URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jinghe.smartblanket.pro"
        request.setValue(bundleID, forHTTPHeaderField: "apns-topic")
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

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            return (false, "JSON 编码失败")
        }
        request.httpBody = bodyData

        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    return (true, "Apple 官方 APNs 云端直推成功 (HTTP 200)")
                } else {
                    let reason = String(data: respData, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
                    return (false, "APNs 返回 \(httpResp.statusCode): \(reason)")
                }
            }
        } catch {
            return (false, "APNs 网络异常: \(error.localizedDescription)")
        }
        return (false, "APNs 未知响应")
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
