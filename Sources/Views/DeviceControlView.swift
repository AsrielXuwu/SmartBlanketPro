import SwiftUI

/// 温控中心主视图 (`DeviceControlView`)
/// 100% 严格采用 iOS 26 / iOS 27 原生控件与官方 Liquid Glass API：
/// - 零自定义背景色、零伪造 `.regularMaterial` 卡片，完全由系统 `List` 与 Scroll Edge 折射引擎接管
/// - 顶部采用 `GlassEffectContainer(spacing: 16)` + `@Namespace` + `.glassEffectID(_:in:)` 实现左右温区玻璃舱在「独立调温」与「双区同步」之间的物理级流体合并/分离形变（Morphing）
/// - 底部悬浮控制栏（`.safeAreaInset(edge: .bottom)`）采用 `GlassEffectContainer` + `.buttonStyle(.glassProminent)` / `.buttonStyle(.glass)`
/// - 挡位调节采用原生 `Slider(value:in: 1...9, step: 1)`（在 iOS 26/27 SDK 下拖动自动呈现官方液态水滴透镜）
public struct DeviceControlView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    let deviceID: UUID

    @Namespace private var glassMorphNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentTime = Date()
    @State private var showingScannerSheet = false

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

    private var activeTint: Color {
        LiquidGlassTheme.thermalTint(
            isOn: device.isOn,
            mode: device.mode,
            gear: max(device.gearLeft, device.gearRight)
        )
    }

    private var morphAnimation: Animation? {
        reduceMotion ? nil : LiquidGlassTheme.morphSpring
    }

    public var body: some View {
        List {
            // MARK: 1. 顶部双温区 Liquid Glass 流体形变状态舱 (GlassEffectContainer + glassEffectID)
            Section {
                liquidGlassMorphingHeroHeader
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 8, trailing: 4))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // MARK: 2. 原生分区挡位调节 Section (iOS 26/27 Liquid Glass Slider & Glass Buttons)
            if device.syncDualZones {
                Section {
                    nativeZoneGearRow(
                        title: "左右双温区同步挡位",
                        symbol: "bed.double.fill",
                        gear: device.gearLeft,
                        temperature: device.temperatureLeft,
                        onAdjust: { newGear, debounced in
                            bleManager.setGearLeft(newGear, for: deviceID, debounced: debounced)
                        }
                    )
                } header: {
                    Text("双温区同步温控 (1~9 挡 · 18°C~45°C)")
                } footer: {
                    Text("双温区同步已开启，拖动滑块或点击快捷挡位将同时控制左右两侧。")
                }
            } else {
                Section {
                    nativeZoneGearRow(
                        title: "左温区 (Left)",
                        symbol: "lefthand.raised.fill",
                        gear: device.gearLeft,
                        temperature: device.temperatureLeft,
                        onAdjust: { newGear, debounced in
                            bleManager.setGearLeft(newGear, for: deviceID, debounced: debounced)
                        }
                    )
                } header: {
                    Text("左温区独立控制")
                }

                Section {
                    nativeZoneGearRow(
                        title: "右温区 (Right)",
                        symbol: "righthand.raised.fill",
                        gear: device.gearRight,
                        temperature: device.temperatureRight,
                        onAdjust: { newGear, debounced in
                            bleManager.setGearRight(newGear, for: deviceID, debounced: debounced)
                        }
                    )
                } header: {
                    Text("右温区独立控制")
                }
            }

            // MARK: 3. 工作模式与双温区联动原生控件 Section
            Section {
                Picker("工作模式", selection: Binding(
                    get: { device.mode },
                    set: { newMode in
                        Task { @MainActor in
                            await bleManager.setMode(newMode, for: deviceID)
                        }
                    }
                )) {
                    ForEach(BlanketHeatingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: device.mode)

                if let idx = deviceIndex {
                    Toggle(
                        "双温区同步调节",
                        systemImage: device.syncDualZones ? "link.circle.fill" : "rectangle.split.2x1.fill",
                        isOn: Binding(
                            get: { bleManager.devices[idx].syncDualZones },
                            set: { newValue in
                                withAnimation(morphAnimation) {
                                    bleManager.devices[idx].syncDualZones = newValue
                                }
                            }
                        )
                    )
                    .sensoryFeedback(.selection, trigger: device.syncDualZones)
                }
            } header: {
                Text("模式与温区联动")
            } footer: {
                Text(device.mode == .miteRemoval
                     ? "除螨模式将自动以 9 挡 (45°C) 高温持续运行 2 小时。"
                     : "切换「双温区同步调节」时，上方液态玻璃温区舱将自动融合或分离。")
            }

            // MARK: 4. 定时关机与预约定时开机原生 Section
            Section {
                Picker(
                    "自动关机定时",
                    systemImage: "timer",
                    selection: Binding(
                        get: { device.timeCloseHours },
                        set: { newHours in
                            Task { @MainActor in
                                await bleManager.setAutoOffHours(newHours, for: deviceID)
                            }
                        }
                    )
                ) {
                    ForEach(1...12, id: \.self) { h in
                        Text("\(h) 小时后关机").tag(h)
                    }
                }
                .sensoryFeedback(.selection, trigger: device.timeCloseHours)

                // 原生 GlassEffectContainer 快捷定时关机按钮组
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach([2, 4, 6, 8, 10, 12], id: \.self) { preset in
                            if device.timeCloseHours == preset {
                                Button("\(preset)h") {
                                    Task { @MainActor in
                                        await bleManager.setAutoOffHours(preset, for: deviceID)
                                    }
                                }
                                .buttonStyle(.glassProminent)
                                .tint(activeTint)
                                .controlSize(.small)
                            } else {
                                Button("\(preset)h") {
                                    Task { @MainActor in
                                        await bleManager.setAutoOffHours(preset, for: deviceID)
                                    }
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }

                Picker(
                    "预约定时开机",
                    systemImage: "alarm.waves.left.and.right.fill",
                    selection: Binding(
                        get: { device.timeOpenHours },
                        set: { newOpenHours in
                            Task { @MainActor in
                                await bleManager.setScheduledOnHours(newOpenHours, for: deviceID)
                            }
                        }
                    )
                ) {
                    Text("关闭预约").tag(0)
                    ForEach(1...12, id: \.self) { h in
                        Text("\(h) 小时后自动开机").tag(h)
                    }
                }
                .sensoryFeedback(.selection, trigger: device.timeOpenHours)
            } header: {
                Text("定时关机与预约开机")
            } footer: {
                Text(device.isOn ? device.formattedRemainingCloseTime : device.formattedRemainingOpenTime)
            }

            // MARK: 5. 实时开启小时数与连接快照 Section (Requirement 5)
            Section("当前运行状态摘要") {
                LabeledContent("当前状态") {
                    Text(device.isOn ? "正在加热 · \(device.mode.title)" : "已关机待机")
                        .foregroundStyle(device.isOn ? activeTint : Color.secondary)
                        .fontWeight(.medium)
                }

                LabeledContent("本次已开启时长") {
                    Text(device.currentSessionElapsedHoursString(at: currentTime))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("历史累计开启") {
                    Text(String(format: "%.1f 小时 (%d 次)", device.totalHistoricalHours(at: currentTime), device.totalPowerOnCount))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("蓝牙直连状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionPhase == .connected ? Color.green : (connectionPhase == .connecting ? Color.orange : Color.secondary))
                            .frame(width: 8, height: 8)
                        Text(connectionPhase.rawValue)
                        if let ms = device.lastCommandLatencyMs, connectionPhase == .connected {
                            Text("(\(ms)ms)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(morphAnimation, value: device)
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // iOS 26/27 原生液态玻璃工具栏 + ToolbarSpacer(.fixed) 分组
            if bleManager.devices.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(bleManager.devices) { item in
                            Button {
                                bleManager.activeDeviceID = item.id
                            } label: {
                                Label(
                                    "\(item.name) (\(item.roomName))",
                                    systemImage: item.id == device.id ? "checkmark.circle.fill" : "bed.double"
                                )
                            }
                        }
                    } label: {
                        Label(device.roomName, systemImage: "chevron.up.chevron.down")
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { @MainActor in
                        await bleManager.queryStatus(for: deviceID)
                    }
                } label: {
                    Label("同步状态", systemImage: "arrow.clockwise")
                }
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingScannerSheet = true
                } label: {
                    Label("扫描新设备", systemImage: "plus")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            floatingLiquidGlassBottomDock
        }
        .sheet(isPresented: $showingScannerSheet) {
            ScannerSheetView(bleManager: bleManager)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: deviceID) {
            bleManager.activeDeviceID = deviceID
            await bleManager.ensureConnected(deviceID: deviceID)
        }
        .onReceive(clockTimer) { now in
            currentTime = now
        }
    }

    // MARK: - 顶部双温区 Liquid Glass 流体形变舱 (GlassEffectContainer + glassEffectID)
    private var liquidGlassMorphingHeroHeader: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 12) {
                // 1. 双温区温度与挡位液态玻璃晶体（切换 syncDualZones 时触发真实 Liquid Glass Morphing 合并/分裂）
                if device.syncDualZones {
                    unifiedZoneGlassOrb
                        .glassEffect(
                            device.isOn
                                ? .regular.tint(activeTint).interactive()
                                : .regular.interactive(),
                            in: .rect(cornerRadius: 26)
                        )
                        .glassEffectID("leftZone", in: glassMorphNamespace)
                } else {
                    HStack(spacing: 14) {
                        singleZoneGlassOrb(
                            title: "左温区",
                            gear: device.gearLeft,
                            temperature: device.temperatureLeft
                        )
                        .glassEffect(
                            device.isOn
                                ? .regular.tint(LiquidGlassTheme.thermalTint(isOn: true, mode: device.mode, gear: device.gearLeft)).interactive()
                                : .regular.interactive(),
                            in: .rect(cornerRadius: 24)
                        )
                        .glassEffectID("leftZone", in: glassMorphNamespace)

                        singleZoneGlassOrb(
                            title: "右温区",
                            gear: device.gearRight,
                            temperature: device.temperatureRight
                        )
                        .glassEffect(
                            device.isOn
                                ? .regular.tint(LiquidGlassTheme.thermalTint(isOn: true, mode: device.mode, gear: device.gearRight)).interactive()
                                : .regular.interactive(),
                            in: .rect(cornerRadius: 24)
                        )
                        .glassEffectID("rightZone", in: glassMorphNamespace)
                    }
                }

                // 2. 悬浮状态微胶囊对：本次已开启小时数 + 定时倒计时
                HStack(spacing: 10) {
                    Label(device.compactElapsedString(at: currentTime), systemImage: "clock.fill")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(
                            device.isOn ? .regular.tint(activeTint).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                        .glassEffectID("elapsedPill", in: glassMorphNamespace)

                    Label(
                        device.isOn ? device.formattedRemainingCloseTime : device.formattedRemainingOpenTime,
                        systemImage: device.isOn ? "timer" : "alarm.fill"
                    )
                    .font(.caption.weight(.medium).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("countdownPill", in: glassMorphNamespace)
                }
            }
        }
    }

    private func singleZoneGlassOrb(title: String, gear: Int, temperature: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(gear) 挡")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(temperature)")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("°C")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(device.isOn ? LiquidGlassTheme.gearComfortLabel(gear) : "待机休眠中")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unifiedZoneGlassOrb: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                    Text("左右双温区同步恒温")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(device.temperatureLeft)")
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("°C")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(device.isOn ? "\(device.mode.title) · \(LiquidGlassTheme.gearComfortLabel(device.gearLeft))" : "点击下方主电源极速唤醒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text("\(device.gearLeft) 挡")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("定时 \(device.timeCloseHours) 小时")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 原生温区滑块与快捷步进控件 (iOS 26/27 Native Slider + .buttonStyle(.glass))
    private func nativeZoneGearRow(
        title: String,
        symbol: String,
        gear: Int,
        temperature: Int,
        onAdjust: @escaping (Int, Bool) -> Void
    ) -> some View {
        let zoneColor = LiquidGlassTheme.thermalTint(isOn: true, mode: device.mode, gear: gear)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text("\(gear) 挡 · \(temperature)°C (\(LiquidGlassTheme.gearComfortLabel(gear)))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(device.isOn ? zoneColor : Color.secondary)
                    .contentTransition(.numericText())
            }

            HStack(spacing: 12) {
                Button {
                    guard gear > 1 else { return }
                    withAnimation(morphAnimation) {
                        onAdjust(gear - 1, false)
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(gear <= 1)

                // iOS 26/27 原生液态水滴滑块
                Slider(
                    value: Binding(
                        get: { Double(gear) },
                        set: { newVal in
                            let target = Int(round(newVal))
                            if target != gear {
                                withAnimation(morphAnimation) {
                                    onAdjust(target, true)
                                }
                            }
                        }
                    ),
                    in: 1...9,
                    step: 1
                )
                .tint(zoneColor)
                .sensoryFeedback(.selection, trigger: gear)

                Button {
                    guard gear < 9 else { return }
                    withAnimation(morphAnimation) {
                        onAdjust(gear + 1, false)
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(gear >= 9)
            }

            // 1 / 3 / 5 / 7 / 9 常用挡位原生 Glass 快捷点选行
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([1, 3, 5, 7, 9], id: \.self) { step in
                        if gear == step {
                            Button("\(step)挡 · \(BlanketProtocol.gearToTemp(step))°") {
                                withAnimation(morphAnimation) {
                                    onAdjust(step, false)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(zoneColor)
                            .controlSize(.small)
                        } else {
                            Button("\(step)挡") {
                                withAnimation(morphAnimation) {
                                    onAdjust(step, false)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - 底部悬浮 Liquid Glass 快捷控制坞 (Floating Liquid Glass Action Dock)
    private var floatingLiquidGlassBottomDock: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                // 1. 主电源液态玻璃醒目按钮 (.buttonStyle(.glassProminent))
                Button {
                    Task { @MainActor in
                        await bleManager.setPower(isOn: !device.isOn, for: deviceID)
                    }
                } label: {
                    Label(
                        device.isOn ? "关闭电热毯" : "开启电热毯",
                        systemImage: "power"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(device.isOn ? activeTint : .blue)
                .sensoryFeedback(.impact(weight: .heavy), trigger: device.isOn)

                // 2. 一键除螨 / 普通加热切换液态玻璃按钮 (.buttonStyle(.glass))
                Button {
                    let nextMode: BlanketHeatingMode = (device.mode == .miteRemoval) ? .normal : .miteRemoval
                    Task { @MainActor in
                        await bleManager.setMode(nextMode, for: deviceID)
                    }
                } label: {
                    Label(
                        device.mode == .miteRemoval ? "除螨中" : "除螨",
                        systemImage: "sparkles"
                    )
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .tint(device.mode == .miteRemoval ? Color.red : Color.primary)

                // 3. 一键切换双区同步液态玻璃圆钮 (.buttonStyle(.glass))
                if let idx = deviceIndex {
                    Button {
                        withAnimation(morphAnimation) {
                            bleManager.devices[idx].syncDualZones.toggle()
                        }
                    } label: {
                        Image(systemName: device.syncDualZones ? "link.circle.fill" : "rectangle.split.2x1")
                            .font(.title3)
                            .padding(4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("切换双温区同步")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
