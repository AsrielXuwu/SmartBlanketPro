import Foundation
import ActivityKit
import Combine

/// iOS 灵动岛与实时活动省电调度管理器 (`LiveActivityManager`)
public final class LiveActivityManager: ObservableObject, @unchecked Sendable {
    public static let shared = LiveActivityManager()

    @Published public var autoStartLiveActivityInBackground: Bool {
        didSet { UserDefaults.standard.set(autoStartLiveActivityInBackground, forKey: Self.autoStartKey) }
    }

    /// 设备关机后保留展示多少分钟再自动关闭实时活动卡片（默认 5 分钟）
    @Published public var liveActivityAutoDismissMinutes: Int {
        didSet { UserDefaults.standard.set(liveActivityAutoDismissMinutes, forKey: Self.autoDismissMinutesKey) }
    }

    private static let autoStartKey = "com.smartblanketpro.live_activity.auto_start_bg"
    private static let autoDismissMinutesKey = "com.smartblanketpro.live_activity.dismiss_minutes"

    private init() {
        self.autoStartLiveActivityInBackground = (UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool) ?? true
        let savedMinutes = UserDefaults.standard.integer(forKey: Self.autoDismissMinutesKey)
        self.liveActivityAutoDismissMinutes = savedMinutes > 0 ? savedMinutes : 5
    }

    private func makeContentState(from device: BlanketDevice) -> BlanketActivityAttributes.ContentState {
        let now = Date()
        let autoOffDate: Date? = {
            guard device.isOn else { return nil }
            let sec = device.remainingTimeCloseSec > 0 ? device.remainingTimeCloseSec : (device.timeCloseHours * 3600)
            return now.addingTimeInterval(TimeInterval(max(60, sec)))
        }()

        return BlanketActivityAttributes.ContentState(
            isOn: device.isOn,
            modeRawValue: device.mode.rawValue,
            gearLeft: device.gearLeft,
            gearRight: device.gearRight,
            tempLeft: device.temperatureLeft,
            tempRight: device.temperatureRight,
            syncDualZones: device.syncDualZones,
            sessionStartDate: device.isOn ? (device.currentSessionStartDate ?? now) : nil,
            autoOffEndDate: autoOffDate,
            lastUpdated: now
        )
    }

    @MainActor
    public func handleAppEnteredBackground(activeDevice: BlanketDevice?) async {
        guard autoStartLiveActivityInBackground else { return }
        guard let device = activeDevice, device.isOn else { return }
        await startOrUpdateActivity(for: device)
    }

    @MainActor
    public func startOrUpdateActivity(for device: BlanketDevice) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let targetID = device.id.uuidString
        let contentState = makeContentState(from: device)
        let staleDate = contentState.autoOffEndDate ?? Date().addingTimeInterval(3600 * 12)
        let content = ActivityContent(state: contentState, staleDate: staleDate)

        if let existing = Activity<BlanketActivityAttributes>.activities.first(where: { $0.attributes.deviceID == targetID }) {
            if device.isOn {
                await existing.update(content)
            } else {
                let dismissDelay = TimeInterval(max(1, liveActivityAutoDismissMinutes) * 60)
                await existing.end(content, dismissalPolicy: .after(Date().addingTimeInterval(dismissDelay)))
            }
            return
        }

        guard device.isOn else { return }

        for other in Activity<BlanketActivityAttributes>.activities where other.attributes.deviceID != targetID {
            await other.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = BlanketActivityAttributes(
            deviceID: targetID,
            deviceName: device.name,
            roomName: device.roomName
        )

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // 权限关闭或系统限制时静默忽略
        }
    }

    @MainActor
    public func syncActivityState(for device: BlanketDevice) async {
        let targetID = device.id.uuidString
        let hasActive = Activity<BlanketActivityAttributes>.activities.contains(where: { $0.attributes.deviceID == targetID })

        if hasActive {
            await startOrUpdateActivity(for: device)
        } else if device.isOn && autoStartLiveActivityInBackground {
            await startOrUpdateActivity(for: device)
        }
    }

    @MainActor
    public func endAllActivitiesImmediately() async {
        for activity in Activity<BlanketActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
