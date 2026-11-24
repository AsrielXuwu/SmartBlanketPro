import SwiftUI

/// 设备管理中心 (`DeviceListView`)
/// 修复并增强：
/// 1. 修复长按已配对设备时卡片内容消失且开关按钮变菱形的问题 (Requirement 6)：
///    - 避免在带有 `UIContextMenuInteraction` 的 `List` 单元格内嵌 `_UIGlassEffect` 子按钮导致系统长按快照遮罩错位；
///    - 显式配置 `.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))` 与完整长按预览卡片 `preview:`；
/// 2. 修复删除设备时偶发闪退问题 (Requirement 6)：
///    - 等待长按菜单/滑动动作收起动画释放单元格引用后再安全移除设备，配合全局安全 ID 绑定彻底杜绝越界闪退；
/// 3. 严格应用新版挡位色彩与待机语义图标配色 (Requirement 3)。
public struct DeviceListView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    var onSelectDeviceForControl: ((UUID) -> Void)?

    @State private var showingScannerSheet = false
    @State private var editingDevice: BlanketDevice?
    @State private var editName: String = ""
    @State private var editRoom: String = ""
    @State private var editMAC: String = ""

    public init(
        bleManager: BlanketBLEManager,
        onSelectDeviceForControl: ((UUID) -> Void)? = nil
    ) {
        self.bleManager = bleManager
        self.onSelectDeviceForControl = onSelectDeviceForControl
    }

    public var body: some View {
        NavigationStack {
            List {
                // 1. 已绑定电热毯设备列表 Section
                Section {
                    ForEach(bleManager.devices) { device in
                        let targetID = device.id
                        deviceNativeRow(for: device)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    scheduleSafeRemoveDevice(deviceID: targetID)
                                } label: {
                                    Label("移除", systemImage: "trash")
                                }

                                Button {
                                    beginEditing(device)
                                } label: {
                                    Label("设置", systemImage: "slider.horizontal.3")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    Task { @MainActor in
                                        await bleManager.setPower(isOn: !device.isOn, for: targetID)
                                    }
                                } label: {
                                    Label(device.isOn ? "关闭电热毯" : "开启电热毯", systemImage: "power")
                                }

                                Button {
                                    bleManager.activeDeviceID = targetID
                                    onSelectDeviceForControl?(targetID)
                                } label: {
                                    Label("设为当前主控并进入温控", systemImage: "thermometer.medium")
                                }

                                Button {
                                    beginEditing(device)
                                } label: {
                                    Label("编辑名称与硬件 MAC", systemImage: "pencil")
                                }

                                Button {
                                    Task { @MainActor in
                                        await bleManager.queryStatus(for: targetID)
                                    }
                                } label: {
                                    Label("同步硬件状态", systemImage: "arrow.clockwise")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    scheduleSafeRemoveDevice(deviceID: targetID)
                                } label: {
                                    Label("移除设备", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("已配对的智能电热毯 (\(bleManager.devices.count))")
                } footer: {
                    Text("点按设备可切换为当前主控电热毯；长按或左滑设备可修改房间名称、校准硬件 MAC 地址或移除设备。")
                }

                // 2. 快速扫描与添加入口 Section
                Section("发现与添加") {
                    Button {
                        showingScannerSheet = true
                    } label: {
                        Label("通过蓝牙扫描发现周边电热毯", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设备管理")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingScannerSheet = true
                    } label: {
                        Label("添加设备", systemImage: "plus")
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        let snapshotIDs = bleManager.devices.map(\.id)
                        for id in snapshotIDs {
                            Task { @MainActor in
                                await bleManager.queryStatus(for: id)
                            }
                        }
                    } label: {
                        Label("全部刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showingScannerSheet) {
                ScannerSheetView(bleManager: bleManager)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $editingDevice) { device in
                editDeviceSheet(for: device)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// 延迟 150ms 待 ContextMenu / SwipeActions 收起动画释放视图引用后再执行删除，彻底杜绝闪退
    private func scheduleSafeRemoveDevice(deviceID: UUID) {
        if editingDevice?.id == deviceID {
            editingDevice = nil
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            withAnimation(.easeInOut(duration: 0.22)) {
                bleManager.removeDevice(deviceID: deviceID)
            }
        }
    }

    // MARK: - 原生设备列表行（消除长按时 _UIGlassEffect 遮罩裁切与菱形畸变）
    private func deviceNativeRow(for device: BlanketDevice) -> some View {
        let phase = bleManager.connectionPhase(for: device.id)
        let dominantGear = max(device.gearLeft, device.gearRight)
        let activeGearColor = LiquidGlassTheme.gearColor(for: dominantGear, mode: device.mode)
        let standbyIconColor = LiquidGlassTheme.iconColor(
            for: .deviceListStandby,
            isOn: device.isOn,
            mode: device.mode,
            gear: dominantGear
        )
        let isCurrentActive = (bleManager.activeDeviceID == device.id)

        return HStack(spacing: 14) {
            Button {
                bleManager.activeDeviceID = device.id
                onSelectDeviceForControl?(device.id)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(device.isOn ? activeGearColor.opacity(0.16) : standbyIconColor.opacity(0.12))
                            .frame(width: 40, height: 40)

                        Image(systemName: device.isOn ? device.mode.symbolName : "bed.double.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(device.isOn ? activeGearColor : standbyIconColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            if isCurrentActive {
                                Text("当前主控")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                            }
                        }

                        Text("\(device.roomName) · 左 \(device.gearLeft)挡 (\(device.temperatureLeft)°C) / 右 \(device.gearRight)挡 (\(device.temperatureRight)°C)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        HStack(spacing: 6) {
                            Circle()
                                .fill(phase == .connected ? Color.green : (phase == .connecting ? Color.orange : Color.secondary))
                                .frame(width: 6, height: 6)
                            Text("\(phase.rawValue) · \(device.compactElapsedString()) · 累计 \(String(format: "%.1f", device.totalHistoricalHours()))h")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // 原生圆形电源开关按钮（使用标准 Circle 渲染，避免在 List cell 的 UIContextMenuInteraction 中产生菱形遮罩畸变）
            Button {
                Task { @MainActor in
                    await bleManager.setPower(isOn: !device.isOn, for: device.id)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(device.isOn ? activeGearColor : Color.secondary.opacity(0.14))
                        .frame(width: 36, height: 36)

                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(device.isOn ? Color.white : Color.primary)
                }
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: device.isOn)
            .accessibilityLabel(device.isOn ? "关闭电热毯" : "开启电热毯")
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 编辑设备信息 Sheet
    private func beginEditing(_ device: BlanketDevice) {
        editName = device.name
        editRoom = device.roomName
        editMAC = device.macAddress
        editingDevice = device
    }

    private func editDeviceSheet(for device: BlanketDevice) -> some View {
        NavigationStack {
            Form {
                Section("设备名称与房间") {
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
                    Text("DES 加密密钥 MAC 地址")
                } footer: {
                    Text("晶合物联电热毯使用硬件 6 字节 MAC 地址派生 8 字节 DES-ECB 密钥（MAC + 5700）。")
                }
            }
            .navigationTitle("编辑设备")
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
                }
            }
        }
    }
}
