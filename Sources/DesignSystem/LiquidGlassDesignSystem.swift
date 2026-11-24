import SwiftUI

/// Apple iOS 26 / iOS 27 原生 Liquid Glass 辅助语义色彩与无障碍动效系统
/// 严格遵循 Apple Human Interface Guidelines 与《Adopting Liquid Glass》官方指南：
/// - 1~2 挡：Apple 系统蓝色 (`.blue`)
/// - 3~5 挡：Apple 系统绿色 (`.green`)
/// - 6~8 挡：Apple 系统橙色 (`.orange`)
/// - 9 挡及除螨模式：Apple 系统红色 (`.red`)
/// - 关闭状态 (`isOn == false`)：无背景着色 (`nil`)，卡片保持纯净透明液态玻璃本色
public enum LiquidGlassTheme {

    /// 标准流体形变弹簧动画
    public static let morphSpring: Animation = .spring(duration: 0.38, bounce: 0.14)

    /// 根据挡位 (1~9) 与工作模式返回 Apple 官方语义主题色
    /// - 1~2 挡：蓝色 (`.blue`)
    /// - 3~5 挡：绿色 (`.green`)
    /// - 6~8 挡：橙色 (`.orange`)
    /// - 9 挡或除螨模式：红色 (`.red`)
    public static func gearColor(for gear: Int, mode: BlanketHeatingMode = .normal) -> Color {
        if mode == .miteRemoval || gear >= 9 {
            return .red
        }
        switch gear {
        case 1...2:
            return .blue
        case 3...5:
            return .green
        case 6...8:
            return .orange
        default:
            return .red
        }
    }

    /// 根据电热毯开关状态、工作模式与挡位返回语义强调色（用于文字、滑块与开启态高亮）
    public static func thermalTint(isOn: Bool, mode: BlanketHeatingMode, gear: Int = 5) -> Color {
        guard isOn else { return .secondary }
        return gearColor(for: gear, mode: mode)
    }

    /// 返回液态玻璃卡片的背景着色：关闭时严格返回 `nil`（无背景色），开启时按挡位/模式返回对应色彩
    public static func activeGlassBackgroundTint(isOn: Bool, mode: BlanketHeatingMode, gear: Int) -> Color? {
        guard isOn else { return nil }
        return gearColor(for: gear, mode: mode)
    }

    /// 待机与运行状态下的语义化图标颜色（避免待机时所有图标均显示为单一橙色而无法区分）
    public enum SemanticIconRole {
        case leftZone
        case rightZone
        case dualZone
        case autoOffTimer
        case scheduleOnTimer
        case standbyClock
        case deviceListStandby
    }

    public static func iconColor(
        for role: SemanticIconRole,
        isOn: Bool,
        mode: BlanketHeatingMode = .normal,
        gear: Int = 5,
        hasActiveSchedule: Bool = false
    ) -> Color {
        if isOn {
            switch role {
            case .leftZone, .rightZone, .dualZone, .standbyClock, .deviceListStandby:
                return gearColor(for: gear, mode: mode)
            case .autoOffTimer:
                return .indigo
            case .scheduleOnTimer:
                return hasActiveSchedule ? .teal : .secondary
            }
        } else {
            // 待机状态下采用层次分明的 Apple HIG 语义冷色系，一目了然
            switch role {
            case .leftZone:
                return .cyan
            case .rightZone:
                return .teal
            case .dualZone:
                return .blue
            case .autoOffTimer:
                return .indigo
            case .scheduleOnTimer:
                return hasActiveSchedule ? .mint : .secondary
            case .standbyClock:
                return .secondary
            case .deviceListStandby:
                return .teal
            }
        }
    }

    /// 挡位语义化舒适度标签
    public static func gearComfortLabel(_ gear: Int) -> String {
        switch gear {
        case 1...2: return "微温舒眠"
        case 3...5: return "舒适恒温"
        case 6...8: return "暖意速热"
        case 9:     return "高温除螨"
        default:    return "舒适恒温"
        }
    }
}
