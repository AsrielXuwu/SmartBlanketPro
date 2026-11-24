import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// iOS 26 / iOS 27 原生灵动岛与液态玻璃实时活动组件 (`BlanketLiveActivityWidget`)
/// 严格遵循 Apple《Live Activities》Human Interface Guidelines：
/// - 锁屏与通知中心实时活动卡片采用 iOS 26/27 原生液态玻璃质感 (`.glassEffect`) 与动态挡位色系（1-2蓝 / 3-5绿 / 6-8橙 / 9或除螨红）
/// - 内置滚轮式三格垂直挡位调节视窗与快捷电源开关 (`LiveActivityIntent`)，无需打开 App 即可在灵动岛或锁屏实时控制
/// - 计时器全部采用系统级 `Text(timerInterval:)` 与 `Text(date, style: .relative)` 渲染，App 后台零唤醒、极度省电
public struct BlanketLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: BlanketActivityAttributes.self) { context in
            // MARK: - 锁屏 / 通知中心 iOS 26/27 液态玻璃实时活动卡片
            lockScreenLiquidGlassBanner(context: context)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(context.state.isOn ? context.state.themeColor : .primary)
        } dynamicIsland: { context in
            // MARK: - 灵动岛 (Dynamic Island) 展开态、紧凑态与最小化态
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(context.state.isOn ? context.state.themeColor.opacity(0.22) : Color.secondary.opacity(0.18))
                                .frame(width: 32, height: 32)
                            Image(systemName: context.state.isOn ? (context.state.isMiteRemoval ? "sparkles" : "flame.fill") : "moon.zzz.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.attributes.deviceName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(context.state.isOn ? (context.state.isMiteRemoval ? "除螨模式 · 45°C" : "普通加热中") : "已关机 · 即将自动关闭")
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
                                .foregroundStyle(context.state.isOn ? .white : .primary)
                                .frame(width: 34, height: 34)
                                .background(
                                    context.state.isOn ? context.state.themeColor : Color.secondary.opacity(0.28),
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
                    } else {
                        HStack(spacing: 10) {
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
                HStack(spacing: 4) {
                    Image(systemName: context.state.isOn ? (context.state.isMiteRemoval ? "sparkles" : "flame.fill") : "moon.zzz.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
                    Text(context.state.isOn ? "\(context.state.gearLeft)·\(context.state.gearRight)挡" : "待机")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(context.state.isOn ? .primary : .secondary)
                }
            } compactTrailing: {
                if context.state.isOn {
                    Text("\(max(context.state.tempLeft, context.state.tempRight))°C")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(context.state.themeColor)
                } else {
                    Text("已关")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                ZStack {
                    Image(systemName: context.state.isOn ? (context.state.isMiteRemoval ? "sparkles" : "flame.fill") : "power")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(context.state.isOn ? context.state.themeColor : .secondary)
                }
            }
            .keylineTint(context.state.isOn ? context.state.themeColor : .secondary)
        }
    }

    // MARK: - 锁屏实时活动 iOS 26/27 液态玻璃卡片
    @ViewBuilder
    private func lockScreenLiquidGlassBanner(context: ActivityViewContext<BlanketActivityAttributes>) -> some View {
        let state = context.state
        let deviceID = context.attributes.deviceID

        VStack(spacing: 12) {
            // 1. 顶部状态栏：设备名 + 模式 + 零功耗计时 + 快捷开关按钮
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(state.isOn ? state.themeColor.opacity(0.22) : Color.secondary.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: state.isOn ? (state.isMiteRemoval ? "sparkles" : "flame.fill") : "moon.zzz.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(state.isOn ? state.themeColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(context.attributes.deviceName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Text(state.isOn ? (state.isMiteRemoval ? "除螨模式" : "加热中") : "已关机")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(state.isOn ? state.themeColor : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (state.isOn ? state.themeColor : Color.secondary).opacity(0.14),
                                in: Capsule()
                            )
                    }

                    HStack(spacing: 8) {
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

                // 快捷电源开关按钮
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

            // 2. 仿滚轮式双温区快捷调挡视窗
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
        .glassEffect(
            state.isOn
                ? .regular.tint(state.themeColor.opacity(0.25))
                : .regular,
            in: .rect(cornerRadius: 24)
        )
    }

    // MARK: - 锁屏液态玻璃卡片：三格垂直滚轮视窗 + 上下/增减调挡控件
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

            // 仿滚轮 3 格垂直刻度预览（上格 gear-1 / 中格 current / 下格 gear+1）
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

            // 垂直滚轮上下步进按钮（下调 / 上调）
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

    // MARK: - 灵动岛展开态：紧凑滚轮调挡条
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
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(gear <= 1)

            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(gear)挡 · \(temp)°")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(isOn ? gearColor : .primary)
            }
            .frame(maxWidth: .infinity)

            Button(intent: BlanketLiveStepGearIntent(deviceID: deviceID, zone: zone, delta: 1)) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(gear >= 9)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}
