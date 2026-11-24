import SwiftUI

/// Apple iOS 26 / iOS 27 原生 Liquid Glass 辅助语义色彩与无障碍动效系统
/// 严格遵循《Adopting Liquid Glass》官方指南：
/// - 绝不伪造 `.regularMaterial` 卡片或自定义背景色
/// - 所有玻璃效果全部直接调用 iOS 26/27 SDK 原生 `.glassEffect(_:in:)`、`GlassEffectContainer`、`.glassEffectID(_:in:)`、`.buttonStyle(.glass)` 与 `.buttonStyle(.glassProminent)`
public enum LiquidGlassTheme {

    /// 标准流体形变弹簧动画（用于 `GlassEffectContainer` 内的 `glassEffectID` 合并与分离）
    public static let morphSpring: Animation = .spring(duration: 0.42, bounce: 0.18)

    /// 根据电热毯开关状态、工作模式与挡位返回 Apple 官方语义色调
    public static func thermalTint(isOn: Bool, mode: BlanketHeatingMode, gear: Int = 5) -> Color {
        guard isOn else { return .blue }
        if mode == .miteRemoval || gear >= 8 {
            return .red
        } else if gear >= 5 {
            return .orange
        } else {
            return .amberTint
        }
    }

    /// 挡位语义化舒适度标签
    public static func gearComfortLabel(_ gear: Int) -> String {
        switch gear {
        case 1...2: return "微温舒眠"
        case 3...4: return "温和暖被"
        case 5...6: return "舒适恒温"
        case 7...8: return "强效速热"
        case 9:     return "高温除螨"
        default:    return "舒适恒温"
        }
    }
}

extension Color {
    /// 温和暖琥珀色调（用于中低挡位液态玻璃微着色）
    public static let amberTint = Color(red: 0.96, green: 0.58, blue: 0.12)
}
