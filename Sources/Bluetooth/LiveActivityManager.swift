import Foundation
import ActivityKit
import Combine

/// iOS 灵动岛与实时活动省电调度管理器 (`LiveActivityManager`)
/// 严格遵循 Apple 官方 Live Activities 省电与生命周期最佳实践：
/// 1. **后台按需自动上岛**：仅当用户开启了「后台自动上岛」开关，且当前电热毯处于开启状态 (`isOn == true`) 时，切入后台才自动启动灵动岛与锁屏实时活动；待机状态绝不上岛；
/// 2. **零后台唤醒省电倒计时**：采用系统级 `sessionStartDate` 与 `autoOffEndDate` 时间戳交由 SpringBoard/WidgetKit 原生渲染计时器，App 在后台零唤醒、零蓝牙保活；
/// 3. **关机后延时自动下岛**：当设备关机时，立即将实时活动标记为待机并设置 `dismissalPolicy: .after(N 分钟)`，由系统在指定时间后自动移除卡片；下次重新开启后再自动上岛。
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

    /// App 切入后台时调用：仅当开关开启且当前设备正在加热时自动上岛
    @MainActor
    public func handleAppEnteredBackground(activeDevice: BlanketDevice?) async {
        guard autoStartLiveActivityInBackground else { return }
        guard let device = activeDevice, device.isOn else { return }
        await startOrUpdateActivity(for: device)
    }

    /// 启动或更新实时活动卡片
    @MainActor
    public func startOrUpdateActivity(for device: BlanketDevice) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let targetID = device.id.uuidString
        let contentState = makeContentState(from: device)
        let staleDate = contentState.autoOffEndDate ?? Date().addingTimeInterval(3600 * 12)
        let content = ActivityContent(state: contentState, staleDate: staleDate)

        // 若已存在同一设备的活跃 Live Activity，直接就地更新
        if let existing = Activity<BlanketActivityAttributes>.activities.first(where: { $0.attributes.deviceID == targetID }) {
            if device.isOn {
                await existing.update(content)
            } else {
                let dismissDelay = TimeInterval(max(1, liveActivityAutoDismissMinutes) * 60)
                await existing.end(content, dismissalPolicy: .after(Date().addingTimeInterval(dismissDelay)))
            }
            return
        }

        // 仅当设备开启时创建新的 Live Activity 上岛
        guard device.isOn else { return }

        // 清理其他旧设备的残留活动，确保灵动岛始终聚焦当前设备
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

    /// 状态同步入口：若当前已有活跃 Live Activity，随设备状态（开关/调挡/定时）实时同步；若已关机则延时自动下岛
    @MainActor
    public func syncActivityState(for device: BlanketDevice) async {
        let targetID = device.id.uuidString
        let hasActive = Activity<BlanketActivityAttributes>.activities.contains(where: { $0.attributes.deviceID == targetID })

        if hasActive {
            await startOrUpdateActivity(for: device)
        } else if device.isOn && autoStartLiveActivityInBackground {
            // 若在后台通过快捷指令/灵动岛重新开机，也自动上岛
            await startOrUpdateActivity(for: device)
        }
    }

    /// 立即结束全部实时活动
    @MainActor
    public func endAllActivitiesImmediately() async {
        for activity in Activity<BlanketActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
