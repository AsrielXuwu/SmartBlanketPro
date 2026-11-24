import Foundation
import AppIntents
import ActivityKit

/// 灵动岛与实时活动卡片专用交互指令：快捷开关电源
public struct BlanketLiveTogglePowerIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "灵动岛快捷开关电热毯"
    public static var description = IntentDescription("在灵动岛或实时活动卡片中直接开启或关闭电热毯。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "设备 ID")
    public var deviceIDString: String

    public init() {
        self.deviceIDString = ""
    }

    public init(deviceID: String) {
        self.deviceIDString = deviceID
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        guard let targetUUID = UUID(uuidString: deviceIDString),
              let device = BlanketBLEManager.shared.devices.first(where: { $0.id == targetUUID }) else {
            return .result()
        }
        let targetOn = !device.isOn
        await BlanketBLEManager.shared.setPower(isOn: targetOn, for: targetUUID)
        if let updated = BlanketBLEManager.shared.devices.first(where: { $0.id == targetUUID }) {
            await LiveActivityManager.shared.syncActivityState(for: updated)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        if BlanketBLEManager.shared.disconnectWhenEnteringBackground {
            BlanketBLEManager.shared.disconnect(deviceID: targetUUID)
        }
        #endif
        return .result()
    }
}

/// 灵动岛与实时活动卡片专用交互指令：滚轮式快捷调节温区挡位 (+/- 1 挡)
public struct BlanketLiveStepGearIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "灵动岛调节电热毯挡位"
    public static var description = IntentDescription("在灵动岛或实时活动卡片中直接上调或下调左右温区挡位。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "设备 ID")
    public var deviceIDString: String

    @Parameter(title: "温区 (left/right/both)")
    public var zone: String

    @Parameter(title: "挡位步进 (-1 或 +1)")
    public var delta: Int

    public init() {
        self.deviceIDString = ""
        self.zone = "left"
        self.delta = 1
    }

    public init(deviceID: String, zone: String, delta: Int) {
        self.deviceIDString = deviceID
        self.zone = zone
        self.delta = delta
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        guard let targetUUID = UUID(uuidString: deviceIDString),
              let device = BlanketBLEManager.shared.devices.first(where: { $0.id == targetUUID }),
              device.isOn,
              device.mode != .miteRemoval else {
            return .result()
        }

        if zone == "right" && !device.syncDualZones {
            let nextRight = min(9, max(1, device.gearRight + delta))
            BlanketBLEManager.shared.setGearRight(nextRight, for: targetUUID, debounced: false)
        } else {
            let nextLeft = min(9, max(1, device.gearLeft + delta))
            BlanketBLEManager.shared.setGearLeft(nextLeft, for: targetUUID, debounced: false)
        }

        if let updated = BlanketBLEManager.shared.devices.first(where: { $0.id == targetUUID }) {
            await LiveActivityManager.shared.syncActivityState(for: updated)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        if BlanketBLEManager.shared.disconnectWhenEnteringBackground {
            BlanketBLEManager.shared.disconnect(deviceID: targetUUID)
        }
        #endif
        return .result()
    }
}
