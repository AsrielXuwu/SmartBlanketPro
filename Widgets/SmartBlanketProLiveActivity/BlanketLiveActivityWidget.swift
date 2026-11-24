import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// iOS 26 / iOS 27 原生灵动岛与通知中心液态玻璃实时活动组件 (`BlanketLiveActivityWidget`)
/// 严格遵循 Apple WidgetKit Remote View 归档规范：
/// - 使用系统原生兼容的 `.ultraThinMaterial` + `.activityBackgroundTint(.clear)` 呈现 iOS 26/27 通知中心通透液态玻璃背景，确保前景内容 100% 稳定渲染不空白
/// - 灵动岛紧凑态 (`compactLeading` / `compactTrailing` / `minimal`) 严格控制在安全宽度内，确保 100% 成功上岛
/// - 展开态 (`expanded`) 与通知中心卡片均提供快捷电源开关与仿滚轮挡位调节按钮
public struct BlanketLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: BlanketActivityAttributes.self) { context in
            // MARK: - 锁屏 / 通知中心实时活动卡片（液态玻璃背景）
            lockScreenLiquidGlassBanner(context: context)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(context.state.isOn ? context.state.themeColor : .primary)
        } dynamicIsland: { context in
            // MARK: - 灵动岛 (Dynamic Island)
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(context.state.isOn ? context.state.themeColor.opacity(0.24) : Color.secondary.opacity(0.2))
                                .frame(width: 30, height: 30)
                            Image(systemName: context.state.isOn ? (context.state.isMiteRemoval ? "sparkles" : "flame.fill") : "moon.zzz.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.deviceName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(context.state.isOn ? (context.state.isMiteRemoval ? "除螨 · 45°C" : "加热中") : "已关机")
                                .font(.caption2)
                                .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        if context.state.isOn, let endDate = context.state.autoOffEndDate, endDate > Date() {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("剩余关机")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(timerInterval: Date()...endDate, countsDown: true)
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(context.state.themeColor)
                                    .multilineTextAlignment(.trailing)
                            }
                        }

                        Button(intent: BlanketLiveTogglePowerIntent(deviceID: context.attributes.deviceID)) {
                            Image(systemName: "power")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    context.state.isOn ? context.state.themeColor : Color.gray.opacity(0.45),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.syncDualZones {
                        expandedWheelStepperBar(
                            deviceID: context.attributes.deviceID,
                            title: "双温区同步",
                            zone: "both",
                            gear: context.state.gearLeft,
                            temp: context.state.tempLeft,
                            isOn: context.state.isOn,
                            isMiteRemoval: context.state.isMiteRemoval
                        )
                        .padding(.top, 4)
                    } else {
                        HStack(spacing: 8) {
                            expandedWheelStepperBar(
                                deviceID: context.attributes.deviceID,
                                title: "左区",
                                zone: "left",
                                gear: context.state.gearLeft,
                                temp: context.state.tempLeft,
                                isOn: context.state.isOn,
                                isMiteRemoval: context.state.isMiteRemoval
                            )

                            expandedWheelStepperBar(
                                deviceID: context.attributes.deviceID,
                                title: "右区",
                                zone: "right",
                                gear: context.state.gearRight,
                                temp: context.state.tempRight,
                                isOn: context.state.isOn,
                                isMiteRemoval: context.state.isMiteRemoval
                            )
                        }
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: context.state.isOn ? (context.state.isMiteRemoval ? "sparkles" : "flame.fill") : "moon.zzz.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
                    Text(context.state.isOn ? "\(context.state.gearLeft)·\(context.state.gearRight)" : "待机")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
            } compactTrailing: {
                if context.state.isOn {
                    Text("\(max(context.state.tempLeft, context.state.tempRight))°C")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(context.state.themeColor)
                } else {
                    Text("已关")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: context.state.isOn ? (context.state.isMiteRemoval ? "sparkles" : "flame.fill") : "power")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
            }
            .keylineTint(context.state.isOn ? context.state.themeColor : .secondary)
        }
    }

    // MARK: - 锁屏 / 通知中心液态玻璃实时活动卡片
    @ViewBuilder
    private func lockScreenLiquidGlassBanner(context: ActivityViewContext<BlanketActivityAttributes>) -> some View {
        let state = context.state
        let deviceID = context.attributes.deviceID

        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(state.isOn ? state.themeColor.opacity(0.22) : Color.secondary.opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: state.isOn ? (state.isMiteRemoval ? "sparkles" : "flame.fill") : "moon.zzz.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(state.isOn ? state.themeColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(context.attributes.deviceName)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(state.isOn ? (state.isMiteRemoval ? "除螨模式" : "加热中") : "已关机")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(state.isOn ? state.themeColor : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (state.isOn ? state.themeColor : Color.secondary).opacity(0.15),
                                in: Capsule()
                            )
                    }

                    HStack(spacing: 6) {
                        if state.isOn, let startDate = state.sessionStartDate {
                            HStack(spacing: 3) {
                                Text("已开")
                                Text(startDate, style: .relative)
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else {
                            Text("已关机，卡片稍后自动关闭")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if state.isOn, let endDate = state.autoOffEndDate, endDate > Date() {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 3) {
                                Image(systemName: "timer")
                                Text(timerInterval: Date()...endDate, countsDown: true)
                            }
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(state.themeColor)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button(intent: BlanketLiveTogglePowerIntent(deviceID: deviceID)) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.caption.weight(.bold))
                        Text(state.isOn ? "关机" : "开机")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(state.isOn ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        state.isOn ? state.themeColor : Color.secondary.opacity(0.22),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            if state.syncDualZones {
                wheelPickerStyleZoneControl(
                    deviceID: deviceID,
                    title: "左右双温区同步",
                    zone: "both",
                    gear: state.gearLeft,
                    temp: state.tempLeft,
                    isOn: state.isOn,
                    isMiteRemoval: state.isMiteRemoval
                )
            } else {
                HStack(spacing: 10) {
                    wheelPickerStyleZoneControl(
                        deviceID: deviceID,
                        title: "左温区",
                        zone: "left",
                        gear: state.gearLeft,
                        temp: state.tempLeft,
                        isOn: state.isOn,
                        isMiteRemoval: state.isMiteRemoval
                    )

                    wheelPickerStyleZoneControl(
                        deviceID: deviceID,
                        title: "右温区",
                        zone: "right",
                        gear: state.gearRight,
                        temp: state.tempRight,
                        isOn: state.isOn,
                        isMiteRemoval: state.isMiteRemoval
                    )
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.isOn ? state.themeColor.opacity(0.10) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
                )
        }
    }

    @ViewBuilder
    private func wheelPickerStyleZoneControl(
        deviceID: String,
        title: String,
        zone: String,
        gear: Int,
        temp: Int,
        isOn: Bool,
        isMiteRemoval: Bool
    ) -> some View {
        let gearColor = BlanketActivityAttributes.ContentState.gearColor(for: gear, isMiteRemoval: isMiteRemoval)

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(temp)°C")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(isOn ? gearColor : .secondary)
            }

            Spacer(minLength: 2)

            VStack(spacing: 0) {
                Text(gear > 1 ? "\(gear - 1)" : " ")
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(height: 12)

                Text("\(gear) 挡")
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isOn ? gearColor : .primary)
                    .frame(height: 20)

                Text(gear < 9 ? "\(gear + 1)" : " ")
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(height: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 4) {
                Button(intent: BlanketLiveStepGearIntent(deviceID: deviceID, zone: zone, delta: 1)) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 20)
                        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(gear >= 9)

                Button(intent: BlanketLiveStepGearIntent(deviceID: deviceID, zone: zone, delta: -1)) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 20)
                        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(gear <= 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func expandedWheelStepperBar(
        deviceID: String,
        title: String,
        zone: String,
        gear: Int,
        temp: Int,
        isOn: Bool,
        isMiteRemoval: Bool
    ) -> some View {
        let gearColor = BlanketActivityAttributes.ContentState.gearColor(for: gear, isMiteRemoval: isMiteRemoval)

        HStack(spacing: 6) {
            Button(intent: BlanketLiveStepGearIntent(deviceID: deviceID, zone: zone, delta: -1)) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(gear <= 1)

            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(gear)挡 · \(temp)°")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(isOn ? gearColor : .white)
            }
            .frame(maxWidth: .infinity)

            Button(intent: BlanketLiveStepGearIntent(deviceID: deviceID, zone: zone, delta: 1)) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(gear >= 9)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.10), in: Capsule())
    }
}
