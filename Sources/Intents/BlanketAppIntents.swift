import AppIntents
import SwiftUI

// MARK: - 1. 快捷指令设备实体 (BlanketDeviceEntity)
/// 让用户可以在 iOS「快捷指令 (Shortcuts)」与 Siri 中直接下拉选择已保存的任意电热毯设备
public struct BlanketDeviceEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "智能电热毯"
    public static var defaultQuery = BlanketDeviceEntityQuery()

    public let id: UUID
    public let name: String
    public let roomName: String
    public let macAddress: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(roomName) · \(macAddress)",
            image: .init(systemName: "bed.double.fill")
        )
    }

    public init(from device: BlanketDevice) {
        self.id = device.id
        self.name = device.name
        self.roomName = device.roomName
        self.macAddress = device.macAddress
    }
}

public struct BlanketDeviceEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [BlanketDeviceEntity] {
        let snapshot = BlanketBLEManager.loadSavedDevicesSnapshot()
        return snapshot
            .filter { identifiers.contains($0.id) }
            .map { BlanketDeviceEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [BlanketDeviceEntity] {
        let snapshot = BlanketBLEManager.loadSavedDevicesSnapshot()
        return snapshot.map { BlanketDeviceEntity(from: $0) }
    }

    public func defaultResult() async -> BlanketDeviceEntity? {
        let snapshot = BlanketBLEManager.loadSavedDevicesSnapshot()
        guard let first = snapshot.first else { return nil }
        return BlanketDeviceEntity(from: first)
    }
}

// MARK: - 2. 快捷指令枚举定义 (操作类型、温区选择、工作模式)
public enum BlanketPowerOperation: String, AppEnum, Sendable {
    case turnOn = "turn_on"
    case turnOff = "turn_off"
    case toggle = "toggle"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "电源操作"
    public static var caseDisplayRepresentations: [BlanketPowerOperation: DisplayRepresentation] = [
        .turnOn: "开启电热毯",
        .turnOff: "关闭电热毯",
        .toggle: "切换开关状态"
    ]
}

public enum BlanketZoneTarget: String, AppEnum, Sendable {
    case both = "both"
    case left = "left"
    case right = "right"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "温区选择"
    public static var caseDisplayRepresentations: [BlanketZoneTarget: DisplayRepresentation] = [
        .both: "左右双温区同步",
        .left: "仅左温区",
        .right: "仅右温区"
    ]
}

public enum BlanketModeOption: String, AppEnum, Sendable {
    case normal = "normal"
    case miteRemoval = "mite"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "工作模式"
    public static var caseDisplayRepresentations: [BlanketModeOption: DisplayRepresentation] = [
        .normal: "普通恒温加热",
        .miteRemoval: "2小时高温除螨模式"
    ]
}

public enum BlanketTimerKind: String, AppEnum, Sendable {
    case autoOff = "auto_off"
    case scheduledOn = "scheduled_on"

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "定时类型"
    public static var caseDisplayRepresentations: [BlanketTimerKind: DisplayRepresentation] = [
        .autoOff: "定时自动关机",
        .scheduledOn: "预约定时开机"
    ]
}

// MARK: - 3. 快捷指令 Intent 1：控制电热毯开关
public struct ControlBlanketPowerIntent: AppIntent {
    public static var title: LocalizedStringResource = "控制电热毯开关"
    public static var description = IntentDescription("通过蓝牙直连开启、关闭或切换指定电热毯的电源状态（开机自动恢复记忆挡位）。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "选择电热毯")
    public var device: BlanketDeviceEntity

    @Parameter(title: "执行操作", default: .turnOn)
    public var operation: BlanketPowerOperation

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$device) \(\.$operation)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = BlanketBLEManager.shared
        guard let target = manager.devices.first(where: { $0.id == device.id }) ?? manager.devices.first else {
            return .result(dialog: "未找到指定的电热毯设备。")
        }

        let targetPower: Bool
        switch operation {
        case .turnOn: targetPower = true
        case .turnOff: targetPower = false
        case .toggle: targetPower = !target.isOn
        }

        await manager.setPower(isOn: targetPower, for: target.id)
        let actionText = targetPower
            ? "已开启 \(target.name)，左温区 \(target.savedGearLeft) 挡 (\(BlanketProtocol.gearToTemp(target.savedGearLeft))°C)，右温区 \(target.savedGearRight) 挡 (\(BlanketProtocol.gearToTemp(target.savedGearRight))°C)"
            : "已关闭 \(target.name)"
        return .result(dialog: "\(actionText)")
    }
}

// MARK: - 4. 快捷指令 Intent 2：调节分区挡位 (1~9 挡)
public struct SetBlanketGearIntent: AppIntent {
    public static var title: LocalizedStringResource = "调节电热毯温区挡位"
    public static var description = IntentDescription("设置指定电热毯左温区、右温区或双温区的加热挡位 (1~9 挡，对应 18°C~45°C)。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "选择电热毯")
    public var device: BlanketDeviceEntity

    @Parameter(title: "目标温区", default: .both)
    public var zone: BlanketZoneTarget

    @Parameter(title: "加热挡位 (1-9)", default: 5, controlStyle: .stepper, inclusiveRange: (1, 9))
    public var gear: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$device) 的 \(\.$zone) 设为 \(\.$gear) 挡")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = BlanketBLEManager.shared
        let clamped = min(9, max(1, gear))
        let temp = BlanketProtocol.gearToTemp(clamped)

        switch zone {
        case .left:
            manager.setGearLeft(clamped, for: device.id, debounced: false)
            return .result(dialog: "已将 \(device.name) 左温区设为 \(clamped) 挡 (\(temp)°C)。")
        case .right:
            manager.setGearRight(clamped, for: device.id, debounced: false)
            return .result(dialog: "已将 \(device.name) 右温区设为 \(clamped) 挡 (\(temp)°C)。")
        case .both:
            manager.setGearLeft(clamped, for: device.id, debounced: false)
            manager.setGearRight(clamped, for: device.id, debounced: false)
            return .result(dialog: "已将 \(device.name) 左右双温区同步设为 \(clamped) 挡 (\(temp)°C)。")
        }
    }
}

// MARK: - 5. 快捷指令 Intent 3：切换工作模式（普通加热 / 除螨模式）
public struct SetBlanketModeIntent: AppIntent {
    public static var title: LocalizedStringResource = "切换电热毯工作模式"
    public static var description = IntentDescription("在普通恒温加热与 2 小时高温除螨模式之间切换。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "选择电热毯")
    public var device: BlanketDeviceEntity

    @Parameter(title: "工作模式", default: .miteRemoval)
    public var mode: BlanketModeOption

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$device) 切换为 \(\.$mode)")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let heatingMode: BlanketHeatingMode = (mode == .miteRemoval) ? .miteRemoval : .normal
        await BlanketBLEManager.shared.setMode(heatingMode, for: device.id)
        return .result(dialog: "已将 \(device.name) 切换为\(heatingMode.title)。")
    }
}

// MARK: - 6. 快捷指令 Intent 4：设置定时关机或预约定时开机
public struct SetBlanketTimerIntent: AppIntent {
    public static var title: LocalizedStringResource = "设置电热毯定时关机或预约开机"
    public static var description = IntentDescription("为指定电热毯设置自动关机时长 (1~12 小时) 或预约开机倒计时 (0~12 小时)。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "选择电热毯")
    public var device: BlanketDeviceEntity

    @Parameter(title: "定时类型", default: .autoOff)
    public var timerKind: BlanketTimerKind

    @Parameter(title: "小时数 (0-12)", default: 8, controlStyle: .stepper, inclusiveRange: (0, 12))
    public var hours: Int

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("为 \(\.$device) 设置 \(\.$timerKind) 为 \(\.$hours) 小时")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = BlanketBLEManager.shared
        switch timerKind {
        case .autoOff:
            let h = max(1, min(12, hours))
            await manager.setAutoOffHours(h, for: device.id)
            return .result(dialog: "已设置 \(device.name) 在 \(h) 小时后自动关机。")
        case .scheduledOn:
            let h = max(0, min(12, hours))
            await manager.setScheduledOnHours(h, for: device.id)
            if h == 0 {
                return .result(dialog: "已取消 \(device.name) 的预约定时开机。")
            } else {
                return .result(dialog: "已设置 \(device.name) 在 \(h) 小时后自动开机。")
            }
        }
    }
}

// MARK: - 7. 快捷指令 Intent 5：查询电热毯实时状态与已开启小时数
public struct GetBlanketStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "查询电热毯状态与开启时长"
    public static var description = IntentDescription("查看指定电热毯的当前开关状态、左右温区挡位与温度、本次已开启小时数及剩余定时。")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "选择电热毯")
    public var device: BlanketDeviceEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("查询 \(\.$device) 的当前运行状态")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let manager = BlanketBLEManager.shared
        await manager.queryStatus(for: device.id)
        guard let current = manager.devices.first(where: { $0.id == device.id }) ?? manager.devices.first else {
            return .result(value: "未找到设备", dialog: "未找到指定的电热毯设备。")
        }

        let summary: String
        if current.isOn {
            summary = "\(current.name)当前正在加热（\(current.mode.title)）：左温区 \(current.gearLeft) 挡 (\(current.temperatureLeft)°C)，右温区 \(current.gearRight) 挡 (\(current.temperatureRight)°C)；本次已开启 \(current.currentSessionElapsedHoursString())，\(current.formattedRemainingCloseTime)，历史累计运行 \(String(format: "%.1f", current.totalHistoricalHours())) 小时。"
        } else {
            summary = "\(current.name)当前处于待机状态；\(current.formattedRemainingOpenTime)；历史累计运行 \(String(format: "%.1f", current.totalHistoricalHours())) 小时。"
        }
        return .result(value: summary, dialog: "\(summary)")
    }
}

// MARK: - 8. 官方预置快捷指令组 (AppShortcutsProvider)
public struct BlanketShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ControlBlanketPowerIntent(),
            phrases: [
                "用 \(.applicationName) 开启电热毯",
                "用 \(.applicationName) 控制电热毯开关"
            ],
            shortTitle: "开关电热毯",
            systemImageName: "power"
        )
        AppShortcut(
            intent: SetBlanketGearIntent(),
            phrases: [
                "用 \(.applicationName) 调节电热毯挡位",
                "用 \(.applicationName) 设置电热毯温度"
            ],
            shortTitle: "调节温区挡位",
            systemImageName: "thermometer.medium"
        )
        AppShortcut(
            intent: SetBlanketModeIntent(),
            phrases: [
                "用 \(.applicationName) 开启电热毯除螨模式",
                "用 \(.applicationName) 切换电热毯模式"
            ],
            shortTitle: "切换除螨/加热模式",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: GetBlanketStatusIntent(),
            phrases: [
                "用 \(.applicationName) 查看电热毯开了多久",
                "用 \(.applicationName) 查询电热毯状态"
            ],
            shortTitle: "查看电热毯状态与时长",
            systemImageName: "clock.badge.checkmark"
        )
    }
}
