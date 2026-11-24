import SwiftUI

/// 设备详情与温控遥测主面板 (`DeviceControlView`)
/// 严格按照 `UI_Design_Specification_iOS26_LiquidGlass.md` 第三章第 2 节的 5 大原生模块构建：
/// - 模块 A：液态玻璃主控状态舱（主状态、双温区大字温度/挡位、本次已开启小时数、自动关机/预约开机倒计时）
/// - 模块 B：工作模式（普通加热 / 2h 高温除螨）原生分段控制器与双区联动开关
/// - 模块 C：左右温区 1~9 挡原生精准滑块（内置 120ms 防抖合并与微调步进按钮）
/// - 模块 D：定时自动关机 (1~12h) 与预约定时开机 (0~12h)
/// - 模块 E：设备实时运行状态信息、已开启小时数、历史累计运行时长与极速直连策略
public struct DeviceControlView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    let deviceID: UUID

    @State private var currentTime = Date()
    private let clockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init(bleManager: BlanketBLEManager, deviceID: UUID) {
        self.bleManager = bleManager
        self.deviceID = deviceID
    }

    private var deviceIndex: Int? {
        bleManager.devices.firstIndex(where: { $0.id == deviceID })
    }

    private var device: BlanketDevice {
        if let idx = deviceIndex {
            return bleManager.devices[idx]
        }
        return BlanketDevice()
    }

    private var connectionPhase: DeviceConnectionPhase {
        bleManager.connectionPhase(for: deviceID)
    }

    private var themeColor: Color {
        LiquidGlassDesign.thermalTint(
            isOn: device.isOn,
            mode: device.mode,
            gear: max(device.gearLeft, device.gearRight)
        )
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // 模块 A：液态玻璃主控状态舱 (Hero Status Capsule)
                heroStatusGlassCard

                // 模块 B：工作模式与双温区联动控制
                modeAndSyncGlassCard

                // 模块 C：左右分区挡位原生调节卡片 (1~9 挡 / 18°C~45°C)
                zoneGearControlSection

                // 模块 D：定时自动关机与预约定时开机
                timerAndScheduleGlassCard

                // 模块 E：设备状态信息与已开启小时数遥测面板 (Requirement 5)
                runtimeTelemetryAndDiagnosticsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await bleManager.queryStatus(for: deviceID) }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connectionPhase == .connected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(connectionPhase == .connected ? "已直连" : "唤醒同步")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule(tint: .green, isProminent: false)
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            bleManager.activeDeviceID = deviceID
            await bleManager.ensureConnected(deviceID: deviceID)
        }
        .onReceive(clockTimer) { now in
            currentTime = now
        }
    }

    // MARK: - 模块 A：液态玻璃主控状态舱
    private var heroStatusGlassCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. 顶部主状态与大号原生电源键
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(device.isOn ? themeColor.opacity(0.20) : Color.secondary.opacity(0.12))
                        .frame(width: 54, height: 54)

                    Image(systemName: device.isOn ? device.mode.symbolName : "power.circle.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(device.isOn ? themeColor : .secondary)
                        .symbolEffect(.pulse.byLayer, options: .repeating, isActive: device.isOn)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(device.isOn ? (device.mode == .miteRemoval ? "高温除螨进行中" : "正在恒温加热") : "已关机待机")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)

                        Text(device.roomName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }

                    Text(device.isOn ? device.mode.subtitle : "点击右侧电源键极速唤醒并恢复记忆设定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(LiquidGlassDesign.fluidSpring) {
                        Task { await bleManager.setPower(isOn: !device.isOn, for: deviceID) }
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(device.isOn ? .white : .primary)
                        .frame(width: 54, height: 54)
                        .background(
                            Circle()
                                .fill(device.isOn ? themeColor.gradient : Color(.tertiarySystemFill).gradient)
                        )
                        .shadow(color: device.isOn ? themeColor.opacity(0.4) : .clear, radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .heavy), trigger: device.isOn)
            }

            // 2. 中部双温区大字温度与挡位对比看板
            HStack(spacing: 12) {
                heroZoneMetricBox(
                    zoneTitle: "左温区 (Left)",
                    gear: device.gearLeft,
                    temperature: device.temperatureLeft,
                    isOn: device.isOn
                )

                heroZoneMetricBox(
                    zoneTitle: "右温区 (Right)",
                    gear: device.gearRight,
                    temperature: device.temperatureRight,
                    isOn: device.isOn
                )
            }

            // 3. 底部实时运行小时数与倒计时横幅
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark.fill")
                        .foregroundStyle(device.isOn ? themeColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("本次已开启时长")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(device.currentSessionElapsedHoursString(at: currentTime))
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                    }
                }

                Spacer(minLength: 4)

                Divider()
                    .frame(height: 26)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    Image(systemName: device.isOn ? "timer" : "alarm.fill")
                        .foregroundStyle(device.isOn ? .orange : (device.timeOpenHours > 0 ? .blue : .secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.isOn ? "自动关机倒计时" : "预约开机状态")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(device.isOn ? device.formattedRemainingCloseTime : device.formattedRemainingOpenTime)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.75))
            )
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 24, tint: themeColor, isActive: device.isOn)
    }

    private func heroZoneMetricBox(zoneTitle: String, gear: Int, temperature: Int, isOn: Bool) -> some View {
        let zoneTint = LiquidGlassDesign.thermalTint(isOn: isOn, mode: device.mode, gear: gear)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(zoneTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(gear) 挡")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(isOn ? zoneTint : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background((isOn ? zoneTint : Color.secondary).opacity(0.14), in: Capsule())
                    .contentTransition(.numericText())
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(temperature)")
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .contentTransition(.numericText())
                Text("°C")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // 原生进度条指示当前挡位热力 (1~9)
            ProgressView(value: Double(gear), total: 9.0)
                .tint(isOn ? zoneTint : .secondary.opacity(0.4))

            Text(LiquidGlassDesign.gearComfortDescription(gear))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.75))
        )
    }

    // MARK: - 模块 B：工作模式与双温区联动控制
    private var modeAndSyncGlassCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("工作模式", systemImage: "flame.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(device.mode == .miteRemoval ? "高温 45°C · 2 小时定时" : "18°C ~ 45°C 自由调节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 原生 Segmented Picker
            Picker("工作模式", selection: Binding(
                get: { device.mode },
                set: { newMode in
                    withAnimation(LiquidGlassDesign.fluidSpring) {
                        Task { await bleManager.setMode(newMode, for: deviceID) }
                    }
                }
            )) {
                ForEach(BlanketHeatingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: device.mode)

            Divider()

            // 双温区同步调节原生 Toggle
            if let idx = deviceIndex {
                Toggle(isOn: $bleManager.devices[idx].syncDualZones.animation(LiquidGlassDesign.fluidSpring)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("双温区同步调节")
                                .font(.subheadline.weight(.medium))
                            Text("开启后拖动单个滑块即可同时调整左右两个温区")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: device.syncDualZones ? "link.circle.fill" : "rectangle.split.2x1.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .sensoryFeedback(.selection, trigger: device.syncDualZones)
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 22, tint: themeColor, isActive: false)
    }

    // MARK: - 模块 C：左右温区分区挡位调节 (1~9 挡)
    private var zoneGearControlSection: some View {
        VStack(spacing: 14) {
            if device.syncDualZones {
                singleZoneSliderCard(
                    title: "左右双温区同步挡位",
                    icon: "bed.double.circle.fill",
                    gear: device.gearLeft,
                    temp: device.temperatureLeft,
                    onChange: { newGear, debounced in
                        bleManager.setGearLeft(newGear, for: deviceID, debounced: debounced)
                    }
                )
            } else {
                singleZoneSliderCard(
                    title: "左温区挡位调节",
                    icon: "lefthand.raised.fill",
                    gear: device.gearLeft,
                    temp: device.temperatureLeft,
                    onChange: { newGear, debounced in
                        bleManager.setGearLeft(newGear, for: deviceID, debounced: debounced)
                    }
                )

                singleZoneSliderCard(
                    title: "右温区挡位调节",
                    icon: "righthand.raised.fill",
                    gear: device.gearRight,
                    temp: device.temperatureRight,
                    onChange: { newGear, debounced in
                        bleManager.setGearRight(newGear, for: deviceID, debounced: debounced)
                    }
                )
            }
        }
    }

    private func singleZoneSliderCard(
        title: String,
        icon: String,
        gear: Int,
        temp: Int,
        onChange: @escaping (Int, Bool) -> Void
    ) -> some View {
        let sliderTint = LiquidGlassDesign.thermalTint(isOn: true, mode: device.mode, gear: gear)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 6) {
                    Text("\(gear) 挡")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(sliderTint)
                        .contentTransition(.numericText())
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(temp)°C \(LiquidGlassDesign.gearComfortDescription(gear))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .liquidGlassCapsule(tint: sliderTint, isProminent: device.isOn)
            }

            // 原生 Slider + 左右微调步进按钮
            HStack(spacing: 12) {
                Button {
                    guard gear > 1 else { return }
                    withAnimation(LiquidGlassDesign.fluidSpring) {
                        onChange(gear - 1, false)
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(gear > 1 ? .primary : .tertiary)
                }
                .buttonStyle(.plain)
                .disabled(gear <= 1)

                Slider(
                    value: Binding(
                        get: { Double(gear) },
                        set: { newVal in
                            let target = Int(round(newVal))
                            if target != gear {
                                withAnimation(LiquidGlassDesign.fluidSpring) {
                                    onChange(target, true)
                                }
                            }
                        }
                    ),
                    in: 1...9,
                    step: 1
                )
                .tint(sliderTint)
                .sensoryFeedback(.selection, trigger: gear)

                Button {
                    guard gear < 9 else { return }
                    withAnimation(LiquidGlassDesign.fluidSpring) {
                        onChange(gear + 1, false)
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(gear < 9 ? sliderTint : .tertiary)
                }
                .buttonStyle(.plain)
                .disabled(gear >= 9)
            }

            // 1~9 挡快捷刻度数字点按栏
            HStack(spacing: 0) {
                ForEach(1...9, id: \.self) { step in
                    Button {
                        withAnimation(LiquidGlassDesign.fluidSpring) {
                            onChange(step, false)
                        }
                    } label: {
                        Text("\(step)挡")
                            .font(.caption2.weight(step == gear ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(step == gear ? sliderTint : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(step == gear ? sliderTint.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 22, tint: sliderTint, isActive: device.isOn)
    }

    // MARK: - 模块 D：定时关机与预约定时开机
    private var timerAndScheduleGlassCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 1. 定时自动关机 (1~12 小时)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("自动关机定时", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("自动关机时长", selection: Binding(
                        get: { device.timeCloseHours },
                        set: { newHours in
                            withAnimation(LiquidGlassDesign.fluidSpring) {
                                Task { await bleManager.setAutoOffHours(newHours, for: deviceID) }
                            }
                        }
                    )) {
                        ForEach(1...12, id: \.self) { h in
                            Text("\(h) 小时后关机").tag(h)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(themeColor)
                }

                // 常用定时关机快捷胶囊 (2h / 4h / 6h / 8h / 10h / 12h)
                HStack(spacing: 8) {
                    ForEach([2, 4, 6, 8, 10, 12], id: \.self) { preset in
                        let isSelected = (device.timeCloseHours == preset)
                        Button {
                            withAnimation(LiquidGlassDesign.fluidSpring) {
                                Task { await bleManager.setAutoOffHours(preset, for: deviceID) }
                            }
                        } label: {
                            Text("\(preset)h")
                                .font(.caption.weight(isSelected ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(isSelected ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(isSelected ? themeColor.gradient : Color(.tertiarySystemFill).gradient)
                                )
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.selection, trigger: device.timeCloseHours)
                    }
                }
            }

            Divider()

            // 2. 预约定时开机 (0~12 小时，0 = 关闭)
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("预约定时开机")
                            .font(.subheadline.weight(.semibold))
                        Text(device.timeOpenHours > 0 ? device.formattedRemainingOpenTime : "提前暖被，到点自动开机加热")
                            .font(.caption2)
                            .foregroundStyle(device.timeOpenHours > 0 ? .blue : .secondary)
                            .contentTransition(.numericText())
                    }
                } icon: {
                    Image(systemName: "alarm.waves.left.and.right.fill")
                        .foregroundStyle(device.timeOpenHours > 0 ? .blue : .secondary)
                }

                Spacer()

                Picker("预约开机", selection: Binding(
                    get: { device.timeOpenHours },
                    set: { newOpenHours in
                        withAnimation(LiquidGlassDesign.fluidSpring) {
                            Task { await bleManager.setScheduledOnHours(newOpenHours, for: deviceID) }
                        }
                    }
                )) {
                    Text("关闭预约").tag(0)
                    ForEach(1...12, id: \.self) { h in
                        Text("\(h) 小时后开机").tag(h)
                    }
                }
                .pickerStyle(.menu)
                .tint(.blue)
                .sensoryFeedback(.selection, trigger: device.timeOpenHours)
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 22, tint: .blue, isActive: false)
    }

    // MARK: - 模块 E：设备运行状态信息、已开启小时数与连接策略 (Requirement 5)
    private var runtimeTelemetryAndDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("运行状态与开启时长统计", systemImage: "chart.bar.doc.horizontal.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let syncDate = device.lastSyncDate {
                    Text("更新于 \(syncDate.formatted(date: .omitted, time: .standard))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 11) {
                LabeledContent("当前工作状态") {
                    Text(device.isOn ? "正在加热 (\(device.mode.title))" : "待机休眠")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(device.isOn ? themeColor : .secondary)
                }

                Divider()

                LabeledContent("本次已开启时长") {
                    Text(device.currentSessionElapsedHoursString(at: currentTime))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(device.isOn ? .primary : .secondary)
                        .contentTransition(.numericText())
                }

                Divider()

                LabeledContent("历史累计开启时长") {
                    Text(String(format: "%.1f 小时 (%d 次开机)", device.totalHistoricalHours(at: currentTime), device.totalPowerOnCount))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                }

                Divider()

                LabeledContent("剩余自动关机时间") {
                    Text(device.formattedRemainingCloseTime)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Divider()

                LabeledContent("指令响应与信号") {
                    HStack(spacing: 6) {
                        if let ms = device.lastCommandLatencyMs {
                            Text("\(ms) ms")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                        Text(device.signalQualityDescription)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                LabeledContent("硬件 MAC 密钥源") {
                    Text(device.macAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let idx = deviceIndex {
                    Divider()

                    Toggle(isOn: $bleManager.devices[idx].restoreMemoryOnPowerOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动恢复记忆挡位与定时")
                                .font(.subheadline)
                            Text("开启后开机自动恢复为左\(device.savedGearLeft)挡/右\(device.savedGearRight)挡/\(device.savedTimeCloseHours)h（避开硬件默认9挡）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    HStack {
                        Text("蓝牙直连策略")
                            .font(.subheadline)
                        Spacer()
                        Picker("蓝牙直连策略", selection: $bleManager.devices[idx].connectionPolicy) {
                            ForEach(BLEConnectionPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 22, tint: .green, isActive: false)
    }
}
