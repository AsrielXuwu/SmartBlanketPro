import SwiftUI

/// 温控中心主视图 (`DeviceControlView`)
/// 严格遵循 Apple iOS 26 / iOS 27 Liquid Glass 设计规范：
/// 1. 修复上滑收起悬浮按钮时的白底闪烁与滚动卡顿：使用 `.overlay(alignment: .bottom)` + 单一持久化 `Button` 视图标识（绝不在滚动中销毁重建 `_UIGlassEffect` 视图或动态改动 `List` 的 `safeAreaInsets`）
/// 2. 挡位色彩严格遵循：1~2 挡蓝色 (`.blue`)、3~5 挡绿色 (`.green`)、6~8 挡橙色 (`.orange`)、9 挡与除螨模式红色 (`.red`)，关闭状态 (`!device.isOn`) 无背景着色；待机图标采用区分鲜明的 Apple HIG 语义冷色系
/// 3. 点击顶部预约开机状态胶囊按钮时，从该按钮原位通过 `.popover` + `.presentationCompactAdaptation(.popover)` 无缝展开拨轮小菜单设置预约开机时间
/// 4. 移除底部「定时关机与预约开机」下方的横向预设时间按钮排
public struct DeviceControlView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    let deviceID: UUID

    @Namespace private var glassMorphNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentTime = Date()
    @State private var showingScannerSheet = false
    @State private var isFloatingDockCollapsed = false
    @State private var showingScheduleOnPopover = false

    /// 15 秒低频时钟刷新（仅用于更新分钟级已开启时长文案，彻底消除每秒触发 List 重排导致的滚动掉帧）
    private let clockTimer = Timer.publish(every: 15.0, on: .main, in: .common).autoconnect()

    public init(bleManager: BlanketBLEManager, deviceID: UUID) {
        self.bleManager = bleManager
        self.deviceID = deviceID
    }

    private var device: BlanketDevice {
        bleManager.devices.first(where: { $0.id == deviceID }) ?? BlanketDevice()
    }

    private var connectionPhase: DeviceConnectionPhase {
        bleManager.connectionPhase(for: deviceID)
    }

    private var dominantGearColor: Color {
        LiquidGlassTheme.gearColor(
            for: max(device.gearLeft, device.gearRight),
            mode: device.mode
        )
    }

    private var morphAnimation: Animation? {
        reduceMotion ? nil : LiquidGlassTheme.morphSpring
    }

    public var body: some View {
        List {
            // MARK: 1. 顶部双温区拨轮卡片 + 顶部快捷关机定时大卡片 + 独立状态胶囊（全宽 Section 不裁切阴影 + 20pt 内边距与下方严格对齐）
            Section {
                liquidGlassMorphingHeroHeader
            }
            .listSectionMargins(.horizontal, 0)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // MARK: 2. 原生分区挡位调节 Section
            if device.syncDualZones {
                Section {
                    nativeZoneGearRow(
                        title: "左右双温区同步挡位",
                        symbol: "bed.double.fill",
                        iconRole: .dualZone,
                        gear: device.gearLeft,
                        temperature: device.temperatureLeft,
                        onAdjust: { newGear, debounced in
                            bleManager.setGearLeft(newGear, for: deviceID, debounced: debounced)
                        }
                    )
                } header: {
                    Text("双温区同步温控 (1~9 挡 · 18°C~45°C)")
                } footer: {
                    Text("双温区同步已开启，拨动顶部卡片滚轮或拖动此处滑块将同时控制左右两侧。")
                }
            } else {
                Section {
                    nativeZoneGearRow(
                        title: "左温区 (Left)",
                        symbol: "lefthand.raised.fill",
                        iconRole: .leftZone,
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
                        iconRole: .rightZone,
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
                        guard newMode != device.mode else { return }
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

                Toggle(
                    isOn: Binding(
                        get: { device.syncDualZones },
                        set: { newValue in
                            withAnimation(morphAnimation) {
                                bleManager.binding(for: deviceID, keyPath: \.syncDualZones, default: false).wrappedValue = newValue
                            }
                        }
                    )
                ) {
                    Label {
                        Text("双温区同步调节")
                    } icon: {
                        Image(systemName: device.syncDualZones ? "link.circle.fill" : "rectangle.split.2x1.fill")
                            .foregroundStyle(
                                LiquidGlassTheme.iconColor(
                                    for: .dualZone,
                                    isOn: device.isOn,
                                    mode: device.mode,
                                    gear: device.gearLeft
                                )
                            )
                    }
                }
                .sensoryFeedback(.selection, trigger: device.syncDualZones)
            } header: {
                Text("模式与温区联动")
            } footer: {
                Text(device.mode == .miteRemoval
                     ? "除螨模式将自动以 9 挡 (45°C) 高温持续运行 2 小时。"
                     : "切换「双温区同步调节」时，上方液态玻璃温区舱将自动融合或分离。")
            }

            // MARK: 4. 定时关机与预约定时开机原生拨轮 Section（已移除底部横向时间选择按钮排）
            Section {
                HStack(spacing: 12) {
                    // 左拨轮：自动关机定时 (1~12 小时)
                    VStack(spacing: 4) {
                        Label {
                            Text("自动关机定时")
                        } icon: {
                            Image(systemName: "timer")
                                .foregroundStyle(
                                    LiquidGlassTheme.iconColor(
                                        for: .autoOffTimer,
                                        isOn: device.isOn,
                                        mode: device.mode,
                                        gear: max(device.gearLeft, device.gearRight)
                                    )
                                )
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Picker(
                            "自动关机定时",
                            selection: Binding(
                                get: { device.timeCloseHours },
                                set: { newHours in
                                    guard newHours != device.timeCloseHours else { return }
                                    Task { @MainActor in
                                        await bleManager.setAutoOffHours(newHours, for: deviceID)
                                    }
                                }
                            )
                        ) {
                            ForEach(1...12, id: \.self) { h in
                                Text("\(h) 小时").tag(h)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 112)
                        .clipped()
                        .sensoryFeedback(.selection, trigger: device.timeCloseHours)
                    }
                    .frame(maxWidth: .infinity)

                    Divider()
                        .frame(height: 96)

                    // 右拨轮：预约定时开机 (关闭 / 1~12 小时)
                    VStack(spacing: 4) {
                        Label {
                            Text("预约定时开机")
                        } icon: {
                            Image(systemName: "alarm.waves.left.and.right.fill")
                                .foregroundStyle(
                                    LiquidGlassTheme.iconColor(
                                        for: .scheduleOnTimer,
                                        isOn: device.isOn,
                                        mode: device.mode,
                                        gear: max(device.gearLeft, device.gearRight),
                                        hasActiveSchedule: device.timeOpenHours > 0
                                    )
                                )
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Picker(
                            "预约定时开机",
                            selection: Binding(
                                get: { device.timeOpenHours },
                                set: { newOpenHours in
                                    guard newOpenHours != device.timeOpenHours else { return }
                                    Task { @MainActor in
                                        await bleManager.setScheduledOnHours(newOpenHours, for: deviceID)
                                    }
                                }
                            )
                        ) {
                            Text("关闭预约").tag(0)
                            ForEach(1...12, id: \.self) { h in
                                Text("\(h) 小时").tag(h)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 112)
                        .clipped()
                        .sensoryFeedback(.selection, trigger: device.timeOpenHours)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 4)
            } header: {
                Text("定时关机与预约开机")
            } footer: {
                Text(device.isOn ? device.formattedRemainingCloseTime : device.formattedRemainingOpenTime)
            }

            // MARK: 5. 实时开启小时数与连接快照 Section (Requirement 5)
            Section("当前运行状态摘要") {
                LabeledContent("当前状态") {
                    Text(device.isOn ? "正在加热 · \(device.mode.title)" : "已关机待机")
                        .foregroundStyle(device.isOn ? dominantGearColor : Color.secondary)
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

            // 底部留白缓冲：确保最后一组卡片可滚出底部悬浮控制坞上方，且无需动态修改 List 的 safeAreaInsets
            Section {
                Color.clear
                    .frame(height: 68)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
        .onScrollGeometryChange(for: Int.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            if offset > 46 {
                return 1
            } else if offset < 16 {
                return -1
            }
            return 0
        } action: { _, scrollState in
            if scrollState == 1 && !isFloatingDockCollapsed {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    isFloatingDockCollapsed = true
                }
            } else if scrollState == -1 && isFloatingDockCollapsed {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    isFloatingDockCollapsed = false
                }
            }
        }
        .overlay(alignment: .bottom) {
            floatingLiquidGlassBottomDock
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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

    // MARK: - 顶部双温区拨轮卡片 + 顶部快捷关机定时大卡片 + 独立无粘连状态胶囊（支持点击预约状态原位展开拨轮小菜单）
    private var liquidGlassMorphingHeroHeader: some View {
        let leftTint = LiquidGlassTheme.activeGlassBackgroundTint(isOn: device.isOn, mode: device.mode, gear: device.gearLeft)
        let rightTint = LiquidGlassTheme.activeGlassBackgroundTint(isOn: device.isOn, mode: device.mode, gear: device.gearRight)

        return VStack(spacing: 0) {
            // 1. 左右温区拨轮大卡片（关闭时无背景色，开启时按 1-2蓝/3-5绿/6-8橙/9或除螨红 动态着色）
            GlassEffectContainer(spacing: 6) {
                Group {
                    if device.syncDualZones {
                        unifiedZoneGlassOrb
                            .glassEffect(
                                leftTint != nil
                                    ? .regular.tint(leftTint!).interactive()
                                    : .regular.interactive(),
                                in: .rect(cornerRadius: 26)
                            )
                            .glassEffectID("leftZone", in: glassMorphNamespace)
                    } else {
                        HStack(spacing: 14) {
                            singleZoneGlassOrb(
                                title: "左温区",
                                iconRole: .leftZone,
                                gear: device.gearLeft,
                                temperature: device.temperatureLeft,
                                onSelectGear: { newGear in
                                    bleManager.setGearLeft(newGear, for: deviceID, debounced: true)
                                }
                            )
                            .glassEffect(
                                leftTint != nil
                                    ? .regular.tint(leftTint!).interactive()
                                    : .regular.interactive(),
                                in: .rect(cornerRadius: 24)
                            )
                            .glassEffectID("leftZone", in: glassMorphNamespace)

                            singleZoneGlassOrb(
                                title: "右温区",
                                iconRole: .rightZone,
                                gear: device.gearRight,
                                temperature: device.temperatureRight,
                                onSelectGear: { newGear in
                                    bleManager.setGearRight(newGear, for: deviceID, debounced: true)
                                }
                            )
                            .glassEffect(
                                rightTint != nil
                                    ? .regular.tint(rightTint!).interactive()
                                    : .regular.interactive(),
                                in: .rect(cornerRadius: 24)
                            )
                            .glassEffectID("rightZone", in: glassMorphNamespace)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 14)
            }

            // 2. 顶部快捷关机定时大卡片
            quickAutoOffTimerHeroCard
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

            // 3. 待机/已开启状态胶囊 + 可点击展开预约开机拨轮小菜单的预约状态胶囊 (Requirement 4)
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: device.isOn ? "flame.fill" : "moon.zzz.fill")
                        .foregroundStyle(
                            LiquidGlassTheme.iconColor(
                                for: .standbyClock,
                                isOn: device.isOn,
                                mode: device.mode,
                                gear: max(device.gearLeft, device.gearRight)
                            )
                        )
                    Text(device.compactElapsedString(at: currentTime))
                        .contentTransition(.numericText())
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .glassEffect(
                    device.isOn ? .regular.tint(dominantGearColor).interactive() : .regular.interactive(),
                    in: .capsule
                )

                // 点击此预约开机状态按钮，从该按钮原位无缝展开拨轮小菜单 (Requirement 4)
                Button {
                    showingScheduleOnPopover = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: device.isOn ? "timer" : "alarm.fill")
                            .foregroundStyle(
                                LiquidGlassTheme.iconColor(
                                    for: .scheduleOnTimer,
                                    isOn: device.isOn,
                                    mode: device.mode,
                                    gear: max(device.gearLeft, device.gearRight),
                                    hasActiveSchedule: device.timeOpenHours > 0
                                )
                            )
                        Text(device.isOn ? device.formattedRemainingCloseTime : device.formattedRemainingOpenTime)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption.weight(.medium).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    (!device.isOn && device.timeOpenHours > 0)
                        ? .regular.tint(.teal).interactive()
                        : .regular.interactive(),
                    in: .capsule
                )
                .popover(
                    isPresented: $showingScheduleOnPopover,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    scheduleOnWheelPopoverMenu
                        .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
    }

    // MARK: - 从顶部预约开机胶囊原位无缝展开的拨轮小菜单 (Requirement 4)
    private var scheduleOnWheelPopoverMenu: some View {
        VStack(spacing: 8) {
            HStack {
                Label {
                    Text("预约定时开机")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "alarm.waves.left.and.right.fill")
                        .foregroundStyle(.teal)
                }
                Spacer()
                Text(device.timeOpenHours == 0 ? "已关闭" : "\(device.timeOpenHours) 小时后")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(device.timeOpenHours > 0 ? Color.teal : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Picker(
                "预约定时开机",
                selection: Binding(
                    get: { device.timeOpenHours },
                    set: { newHours in
                        guard newHours != device.timeOpenHours else { return }
                        Task { @MainActor in
                            await bleManager.setScheduledOnHours(newHours, for: deviceID)
                        }
                    }
                )
            ) {
                Text("关闭预约").tag(0)
                ForEach(1...12, id: \.self) { h in
                    Text("\(h) 小时后自动开机").tag(h)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 230, height: 132)
            .clipped()
            .sensoryFeedback(.selection, trigger: device.timeOpenHours)

            HStack {
                Text("上下滑动拨轮即可实时下发预约")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    showingScheduleOnPopover = false
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 256)
    }

    // MARK: - 单温区液态玻璃卡片（右上角显示温度 °C，中央为原生拨轮滚动调节挡位）
    private func singleZoneGlassOrb(
        title: String,
        iconRole: LiquidGlassTheme.SemanticIconRole,
        gear: Int,
        temperature: Int,
        onSelectGear: @escaping (Int) -> Void
    ) -> some View {
        let gearTint = LiquidGlassTheme.gearColor(for: gear, mode: device.mode)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        LiquidGlassTheme.iconColor(
                            for: iconRole,
                            isOn: device.isOn,
                            mode: device.mode,
                            gear: gear
                        )
                    )
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(temperature)°C")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(device.isOn ? .primary : gearTint)
                    .contentTransition(.numericText())
            }

            Picker(
                title,
                selection: Binding(
                    get: { gear },
                    set: { newGear in
                        if newGear != gear {
                            onSelectGear(newGear)
                        }
                    }
                )
            ) {
                ForEach(1...9, id: \.self) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(step)")
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(device.isOn ? Color.primary : LiquidGlassTheme.gearColor(for: step, mode: device.mode))
                        Text("挡")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .tag(step)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 96)
            .clipped()
            .sensoryFeedback(.selection, trigger: gear)

            HStack {
                Text(LiquidGlassTheme.gearComfortLabel(gear))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(device.isOn ? .secondary : gearTint)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 双区同步液态玻璃卡片
    private var unifiedZoneGlassOrb: some View {
        let gearTint = LiquidGlassTheme.gearColor(for: device.gearLeft, mode: device.mode)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .foregroundStyle(
                            LiquidGlassTheme.iconColor(
                                for: .dualZone,
                                isOn: device.isOn,
                                mode: device.mode,
                                gear: device.gearLeft
                            )
                        )
                    Text("左右双温区同步恒温")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(device.temperatureLeft)°C")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(device.isOn ? .primary : gearTint)
                    .contentTransition(.numericText())
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.isOn ? "\(device.mode.title) · \(LiquidGlassTheme.gearComfortLabel(device.gearLeft))" : "上下滚动右侧拨轮即刻调挡")
                        .font(.footnote.weight(.medium))
                    Text("定时 \(device.timeCloseHours) 小时自动关机")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker(
                    "双区同步挡位",
                    selection: Binding(
                        get: { device.gearLeft },
                        set: { newGear in
                            if newGear != device.gearLeft {
                                bleManager.setGearLeft(newGear, for: deviceID, debounced: true)
                            }
                        }
                    )
                ) {
                    ForEach(1...9, id: \.self) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(step)")
                                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(device.isOn ? Color.primary : LiquidGlassTheme.gearColor(for: step, mode: device.mode))
                            Text("挡")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .tag(step)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 120, height: 96)
                .clipped()
                .sensoryFeedback(.selection, trigger: device.gearLeft)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 顶部快捷关机定时大卡片
    private var quickAutoOffTimerHeroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text("快捷关机定时")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "timer.circle.fill")
                        .foregroundStyle(
                            LiquidGlassTheme.iconColor(
                                for: .autoOffTimer,
                                isOn: device.isOn,
                                mode: device.mode,
                                gear: max(device.gearLeft, device.gearRight)
                            )
                        )
                }
                Spacer()
                Text(device.isOn ? device.formattedRemainingCloseTime : "当前设定 \(device.timeCloseHours) 小时")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(device.isOn ? dominantGearColor : Color.secondary)
                    .contentTransition(.numericText())
            }

            HStack(spacing: 8) {
                ForEach([1, 2, 4, 6, 8, 12], id: \.self) { hours in
                    if device.timeCloseHours == hours {
                        if device.isOn {
                            Button("\(hours)h") {
                                Task { @MainActor in
                                    await bleManager.setAutoOffHours(hours, for: deviceID)
                                }
                            }
                            .buttonStyle(.glassProminent)
                            .tint(dominantGearColor)
                            .controlSize(.small)
                        } else {
                            // 关闭状态下不填充彩色背景色，仅高亮文字与图标
                            Button {
                                Task { @MainActor in
                                    await bleManager.setAutoOffHours(hours, for: deviceID)
                                }
                            } label: {
                                Text("\(hours)h")
                                    .fontWeight(.bold)
                                    .foregroundStyle(.indigo)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    } else {
                        Button("\(hours)h") {
                            Task { @MainActor in
                                await bleManager.setAutoOffHours(hours, for: deviceID)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 原生温区滑块与快捷步进控件 (1-2蓝 / 3-5绿 / 6-8橙 / 9或除螨红；关闭时按钮无背景色)
    private func nativeZoneGearRow(
        title: String,
        symbol: String,
        iconRole: LiquidGlassTheme.SemanticIconRole,
        gear: Int,
        temperature: Int,
        onAdjust: @escaping (Int, Bool) -> Void
    ) -> some View {
        let zoneColor = LiquidGlassTheme.gearColor(for: gear, mode: device.mode)
        let iconTint = LiquidGlassTheme.iconColor(for: iconRole, isOn: device.isOn, mode: device.mode, gear: gear)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text(title)
                        .font(.headline)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(iconTint)
                }
                Spacer()
                Text("\(gear) 挡 · \(temperature)°C (\(LiquidGlassTheme.gearComfortLabel(gear)))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(zoneColor)
                    .contentTransition(.numericText())
            }

            HStack(spacing: 12) {
                Button {
                    guard gear > 1 else { return }
                    onAdjust(gear - 1, false)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(gear <= 1)

                Slider(
                    value: Binding(
                        get: { Double(gear) },
                        set: { newVal in
                            let target = Int(round(newVal))
                            if target != gear {
                                onAdjust(target, true)
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
                    onAdjust(gear + 1, false)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(gear >= 9)
            }

            // 1 / 3 / 5 / 7 / 9 常用挡位原生 Glass 快捷点选行（每个挡位展示对应蓝/绿/橙/红色彩，关闭时无背景色）
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([1, 3, 5, 7, 9], id: \.self) { step in
                        let stepColor = LiquidGlassTheme.gearColor(for: step, mode: device.mode)
                        if gear == step {
                            if device.isOn {
                                Button("\(step)挡 · \(BlanketProtocol.gearToTemp(step))°") {
                                    onAdjust(step, false)
                                }
                                .buttonStyle(.glassProminent)
                                .tint(stepColor)
                                .controlSize(.small)
                            } else {
                                Button {
                                    onAdjust(step, false)
                                } label: {
                                    Text("\(step)挡 · \(BlanketProtocol.gearToTemp(step))°")
                                        .fontWeight(.bold)
                                        .foregroundStyle(stepColor)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        } else {
                            Button {
                                onAdjust(step, false)
                            } label: {
                                Text("\(step)挡")
                                    .foregroundStyle(stepColor)
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

    // MARK: - 底部悬浮 Liquid Glass 快捷控制坞
    /// 【修复白底闪烁与掉帧】：保持每个按钮为单一持久化 View 实例（绝不用 if/else 分支销毁重建 _UIGlassEffect 视图），
    /// 仅在同一按钮内部平滑收起文字，因此底层液态玻璃材质层始终常驻，0 白闪、120Hz 满帧丝滑过渡！
    private var floatingLiquidGlassBottomDock: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                if isFloatingDockCollapsed {
                    Spacer(minLength: 0)
                }

                // 1. 开关电热毯悬浮按钮（单一持久化视图，关闭时无彩色背景，开启时按当前挡位/模式显色）
                Button {
                    Task { @MainActor in
                        await bleManager.setPower(isOn: !device.isOn, for: deviceID)
                    }
                } label: {
                    HStack(spacing: isFloatingDockCollapsed ? 0 : 6) {
                        Image(systemName: "power")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(device.isOn ? Color.white : Color.primary)
                        if !isFloatingDockCollapsed {
                            Text(device.isOn ? "关闭电热毯" : "开启电热毯")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(device.isOn ? Color.white : Color.primary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: isFloatingDockCollapsed ? nil : .infinity)
                    .padding(.vertical, isFloatingDockCollapsed ? 6 : 4)
                    .padding(.horizontal, isFloatingDockCollapsed ? 6 : 8)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(device.isOn ? dominantGearColor : Color.secondary.opacity(0.22))
                .sensoryFeedback(.impact(weight: .heavy), trigger: device.isOn)
                .accessibilityLabel(device.isOn ? "关闭电热毯" : "开启电热毯")

                // 2. 切换除螨模式悬浮按钮（单一持久化视图，除螨开启时为红色，关闭时无背景色）
                Button {
                    let nextMode: BlanketHeatingMode = (device.mode == .miteRemoval) ? .normal : .miteRemoval
                    Task { @MainActor in
                        await bleManager.setMode(nextMode, for: deviceID)
                    }
                } label: {
                    HStack(spacing: isFloatingDockCollapsed ? 0 : 6) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(
                                (device.isOn && device.mode == .miteRemoval)
                                    ? Color.red
                                    : Color.primary
                            )
                        if !isFloatingDockCollapsed {
                            Text(device.mode == .miteRemoval ? "除螨中" : "除螨")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(
                                    (device.isOn && device.mode == .miteRemoval)
                                        ? Color.red
                                        : Color.primary
                                )
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, isFloatingDockCollapsed ? 6 : 4)
                    .padding(.horizontal, isFloatingDockCollapsed ? 6 : 8)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint((device.isOn && device.mode == .miteRemoval) ? Color.red : Color.primary)
                .accessibilityLabel("切换除螨模式")

                // 3. 一键切换双区同步液态玻璃圆钮
                Button {
                    withAnimation(morphAnimation) {
                        let current = device.syncDualZones
                        bleManager.binding(for: deviceID, keyPath: \.syncDualZones, default: false).wrappedValue = !current
                    }
                } label: {
                    Image(systemName: device.syncDualZones ? "link.circle.fill" : "rectangle.split.2x1")
                        .font(.title3)
                        .foregroundStyle(
                            LiquidGlassTheme.iconColor(
                                for: .dualZone,
                                isOn: device.isOn,
                                mode: device.mode,
                                gear: device.gearLeft
                            )
                        )
                        .padding(isFloatingDockCollapsed ? 6 : 4)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("切换双温区同步")
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
    }
}
