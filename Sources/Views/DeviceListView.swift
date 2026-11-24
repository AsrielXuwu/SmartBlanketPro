import SwiftUI

/// 首页：设备中心 (`DeviceListView`)
/// 严格按照 `UI_Design_Specification_iOS26_LiquidGlass.md` 第三章第 1 节执行：
/// - 采用 Apple「家庭 (Home)」App 风格的原生态 `NavigationStack` 与 `Color(.systemGroupedBackground)`
/// - 支持一键极速开关设备、实时预览双温区温度/挡位、已开启小时数与定时倒计时
/// - 支持蓝牙扫描发现新设备、手动添加设备、重命名/修改硬件 MAC 及上下文菜单管理
public struct DeviceListView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @State private var showingScannerSheet = false
    @State private var editingDevice: BlanketDevice?
    @State private var editName: String = ""
    @State private var editRoom: String = ""
    @State private var editMAC: String = ""

    public init(bleManager: BlanketBLEManager) {
        self.bleManager = bleManager
    }

    private var activeHeatingDevices: [BlanketDevice] {
        bleManager.devices.filter { $0.isOn }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    // 1. 顶部实时环境状态胶囊横幅（仿 Apple Home 顶部环境摘要）
                    topEnvironmentSummarySection

                    // 2. 设备液态玻璃卡片列表
                    ForEach(bleManager.devices) { device in
                        NavigationLink(value: device.id) {
                            DeviceGlassCardView(
                                device: device,
                                connectionPhase: bleManager.connectionPhase(for: device.id),
                                onTogglePower: {
                                    Task { @MainActor in
                                        await bleManager.setPower(isOn: !device.isOn, for: device.id)
                                    }
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                Task { @MainActor in
                                    await bleManager.setPower(isOn: !device.isOn, for: device.id)
                                }
                            } label: {
                                Label(device.isOn ? "关闭电热毯" : "开启电热毯", systemImage: "power")
                            }

                            Button {
                                beginEditing(device)
                            } label: {
                                Label("编辑名称与硬件 MAC", systemImage: "slider.horizontal.3")
                            }

                            Button {
                                Task { @MainActor in
                                    await bleManager.queryStatus(for: device.id)
                                }
                            } label: {
                                Label("立即同步硬件状态", systemImage: "arrow.clockwise")
                            }

                            Divider()

                            Button(role: .destructive) {
                                withAnimation(LiquidGlassDesign.fluidSpring) {
                                    bleManager.removeDevice(deviceID: device.id)
                                }
                            } label: {
                                Label("移除设备", systemImage: "trash")
                            }
                        }
                    }

                    // 3. 快捷指令与极速直连提示尾注
                    shortcutsFooterTip
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .animation(LiquidGlassDesign.fluidSpring, value: bleManager.devices)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("智能电热毯")
            .navigationDestination(for: UUID.self) { deviceID in
                DeviceControlView(bleManager: bleManager, deviceID: deviceID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        for dev in bleManager.devices {
                            Task { @MainActor in
                                await bleManager.queryStatus(for: dev.id)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("刷新全部设备状态")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingScannerSheet = true
                    } label: {
                        Label("添加设备", systemImage: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            .sheet(isPresented: $showingScannerSheet) {
                ScannerSheetView(bleManager: bleManager)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .sheet(item: $editingDevice) { device in
                editDeviceSheet(for: device)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
        }
    }

    // MARK: - Top Summary Capsules
    private var topEnvironmentSummarySection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // 胶囊 1：加热活动汇总
                HStack(spacing: 8) {
                    Image(systemName: activeHeatingDevices.isEmpty ? "bed.double.fill" : "flame.fill")
                        .foregroundStyle(activeHeatingDevices.isEmpty ? Color.secondary : Color.orange)
                        .symbolEffect(.pulse.byLayer, options: .repeating, isActive: !activeHeatingDevices.isEmpty)

                    if let firstActive = activeHeatingDevices.first {
                        Text("\(activeHeatingDevices.count) 台正在加热 · \(firstActive.compactElapsedString())")
                            .font(.subheadline.weight(.medium))
                            .contentTransition(.numericText())
                    } else {
                        Text("全部电热毯处于待机状态")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlassCapsule(tint: .orange, isProminent: !activeHeatingDevices.isEmpty)

                // 胶囊 2：蓝牙扫描快捷入口
                Button {
                    showingScannerSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.blue)
                        Text("扫描附近设备")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .liquidGlassCapsule(tint: .blue, isProminent: false)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
    }

    private var shortcutsFooterTip: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("已原生接入 iOS「快捷指令」与 Siri")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("可在系统快捷指令 App 中选择电热毯执行开关、分区调挡、除螨、定时或查询已开启小时数。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 18, tint: .blue, isActive: false)
        .padding(.top, 4)
    }

    // MARK: - Edit Device Metadata Sheet
    private func beginEditing(_ device: BlanketDevice) {
        editName = device.name
        editRoom = device.roomName
        editMAC = device.macAddress
        editingDevice = device
    }

    private func editDeviceSheet(for device: BlanketDevice) -> some View {
        NavigationStack {
            Form {
                Section("设备基本信息") {
                    LabeledContent("设备名称") {
                        TextField("例如：主卧智能电热毯", text: $editName)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("所属房间") {
                        TextField("例如：主卧", text: $editRoom)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    LabeledContent("硬件 MAC") {
                        TextField("8E:B2:D6:64:F8:60", text: $editMAC)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("蓝牙加密密钥参数")
                } footer: {
                    Text("晶合物联电热毯使用硬件 6 字节 MAC 地址派生 8 字节 DES-ECB 密钥（MAC + 5700）。扫描添加时会自动从 0x5700 广播包提取，您也可以在此手动核对。")
                }
            }
            .navigationTitle("设备设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingDevice = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        bleManager.updateDeviceMetadata(
                            deviceID: device.id,
                            name: editName,
                            roomName: editRoom,
                            macAddress: editMAC
                        )
                        editingDevice = nil
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - 单个电热毯液态玻璃卡片组件
private struct DeviceGlassCardView: View {
    let device: BlanketDevice
    let connectionPhase: DeviceConnectionPhase
    let onTogglePower: () -> Void

    private var themeColor: Color {
        LiquidGlassDesign.thermalTint(
            isOn: device.isOn,
            mode: device.mode,
            gear: max(device.gearLeft, device.gearRight)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶栏：动态图标 + 房间与名称 + 原生电源快控圆钮
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(device.isOn ? themeColor.opacity(0.18) : Color.secondary.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Image(systemName: device.isOn ? device.mode.symbolName : "bed.double.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(device.isOn ? themeColor : Color.secondary)
                        .symbolEffect(.pulse.byLayer, options: .repeating, isActive: device.isOn)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(device.roomName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())

                        connectionBadge
                    }

                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // 一键电源开关按钮（带原生触觉反馈）
                Button(action: onTogglePower) {
                    Image(systemName: "power")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(device.isOn ? Color.white : Color.primary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(device.isOn ? themeColor.gradient : Color(.tertiarySystemFill).gradient)
                        )
                        .shadow(color: device.isOn ? themeColor.opacity(0.35) : .clear, radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .medium), trigger: device.isOn)
                .accessibilityLabel(device.isOn ? "关闭电热毯" : "开启电热毯")
            }

            // 中部：左右双温区实时温度与挡位大字预览
            HStack(spacing: 12) {
                zoneMiniTile(
                    title: "左温区",
                    gear: device.gearLeft,
                    temp: device.temperatureLeft,
                    isOn: device.isOn
                )

                zoneMiniTile(
                    title: "右温区",
                    gear: device.gearRight,
                    temp: device.temperatureRight,
                    isOn: device.isOn
                )
            }

            // 底栏：已开启时长、定时倒计时与历史累计运行微指标
            HStack(spacing: 8) {
                Label(device.compactElapsedString(), systemImage: "clock.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(device.isOn ? themeColor : Color.secondary)
                    .contentTransition(.numericText())

                Text("·")
                    .foregroundStyle(.tertiary)

                if device.isOn {
                    Text(device.formattedRemainingCloseTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                } else if device.timeOpenHours > 0 {
                    Text(device.formattedRemainingOpenTime)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)
                        .contentTransition(.numericText())
                } else {
                    Text("累计运行 \(String(format: "%.1f", device.totalHistoricalHours())) 小时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .liquidGlassCard(cornerRadius: 22, tint: themeColor, isActive: device.isOn)
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionPhase == .connected ? Color.green : (connectionPhase == .connecting ? Color.orange : Color.secondary))
                .frame(width: 6, height: 6)

            Text(connectionPhase.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let ms = device.lastCommandLatencyMs, connectionPhase == .connected {
                Text("(\(ms)ms)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func zoneMiniTile(title: String, gear: Int, temp: Int, isOn: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(temp)°C")
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isOn ? Color.primary : Color.secondary)
                        .contentTransition(.numericText())
                    Text("\(gear)挡")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isOn ? themeColor : Color.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.65))
        )
    }
}
