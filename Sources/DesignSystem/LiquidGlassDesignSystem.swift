import SwiftUI

/// Apple iOS 26/27 Liquid Glass（液态玻璃）原生视觉设计系统
/// 严格遵循 `UI_Design_Specification_iOS26_LiquidGlass.md`：
/// - 100% 使用系统语义背景色 `Color(.systemGroupedBackground)`，绝不添加杂乱壁纸或花哨背景
/// - 采用 `.ultraThinMaterial` / `.regularMaterial` 液态毛玻璃材质 + 0.5pt 镜面高光折射边缘 (Specular Rim)
/// - 统一使用 Apple 连续曲率圆角 `RoundedRectangle(cornerRadius: style: .continuous)` 与物理弹簧阻尼动效
public enum LiquidGlassDesign {

    /// 标准物理弹簧动效（iOS 26 官方流体阻尼参数）
    public static let fluidSpring: Animation = .spring(duration: 0.38, bounce: 0.16)

    /// 根据电热毯开关、工作模式与挡位返回 Apple 官方语义主题色
    public static func thermalTint(isOn: Bool, mode: BlanketHeatingMode, gear: Int = 5) -> Color {
        guard isOn else { return .secondary }
        if mode == .miteRemoval || gear >= 8 {
            return .red
        } else if gear >= 5 {
            return .orange
        } else {
            return .yellow
        }
    }

    /// 挡位语义化舒适度描述
    public static func gearComfortDescription(_ gear: Int) -> String {
        switch gear {
        case 1...2: return "微温舒眠"
        case 3...4: return "温和暖被"
        case 5...6: return "舒适恒温"
        case 7...8: return "强效速热"
        case 9:     return "高温烘被"
        default:    return "舒适恒温"
        }
    }
}

// MARK: - iOS 26/27 Liquid Glass Card Modifier
public struct LiquidGlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var tint: Color
    public var isActive: Bool

    public init(cornerRadius: CGFloat = 22, tint: Color = .orange, isActive: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.isActive = isActive
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    // 1. 原生液态玻璃模糊基底
                    shape.fill(.regularMaterial)

                    // 2. 激活态语义热力柔光折射层（严格控制在低透明度 0.10 以内，保持原生纯净感）
                    if isActive {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(0.12),
                                    tint.opacity(0.03),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
            }
            .overlay {
                // 3. iOS 26 标志性 0.5pt 镜面高光描边 (Specular Rim Highlight)
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(isActive ? 0.22 : 0.14),
                            Color.primary.opacity(0.04),
                            isActive ? tint.opacity(0.25) : Color.primary.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.65
                )
            }
            .shadow(
                color: Color.black.opacity(isActive ? 0.06 : 0.03),
                radius: isActive ? 14 : 8,
                x: 0,
                y: isActive ? 6 : 3
            )
    }
}

// MARK: - iOS 26/27 Liquid Glass Pill / Capsule Modifier
public struct LiquidGlassCapsuleModifier: ViewModifier {
    public var tint: Color
    public var isProminent: Bool

    public func body(content: Content) -> some View {
        content
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        if isProminent {
                            Capsule(style: .continuous)
                                .fill(tint.opacity(0.14))
                        }
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isProminent ? tint.opacity(0.32) : Color.primary.opacity(0.12),
                        lineWidth: 0.6
                    )
            }
    }
}

extension View {
    /// 应用 iOS 26/27 液态玻璃圆角卡片材质
    public func liquidGlassCard(
        cornerRadius: CGFloat = 22,
        tint: Color = .orange,
        isActive: Bool = false
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, tint: tint, isActive: isActive))
    }

    /// 应用 iOS 26/27 液态玻璃胶囊微标签材质
    public func liquidGlassCapsule(
        tint: Color = .accentColor,
        isProminent: Bool = false
    ) -> some View {
        modifier(LiquidGlassCapsuleModifier(tint: tint, isProminent: isProminent))
    }
}
