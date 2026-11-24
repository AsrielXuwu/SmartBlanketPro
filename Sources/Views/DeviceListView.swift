import SwiftUI

/// 设备管理中心 (`DeviceListView`)
/// 严格采用 iOS 26 / iOS 27 原生 `List` (`.insetGrouped`)、`.buttonStyle(.glassProminent)` / `.buttonStyle(.glass)` 与 `ToolbarSpacer(.fixed)`
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
                        deviceNativeRow(for: device)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    bleManager.removeDevice(deviceID: device.id)
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
                                        await bleManager.setPower(isOn: !device.isOn, for: device.id)
                                    }
                                } label: {
                                    Label(device.isOn ? "关闭电热毯" : "开启电热毯", systemImage: "power")
                                }

                                Button {
                                    beginEditing(device)
                                } label: {
                                    Label("编辑名称与硬件 MAC", systemImage: "pencil")
                                }

                                Button {
                                    Task { @MainActor in
                                        await bleManager.queryStatus(for: device.id)
                                    }
                                } label: {
                                    Label("同步硬件状态", systemImage: "arrow.clockwise")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    bleManager.removeDevice(deviceID: device.id)
                                } label: {
                                    Label("移除设备", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("已配对的智能电热毯 (\(bleManager.devices.count))")
                } footer: {
                    Text("点按设备可切换为当前主控电热毯；左滑设备可修改房间名称、校准硬件 MAC 地址或移除设备。")
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
                        for dev in bleManager.devices {
                            Task { @MainActor in
                                await bleManager.queryStatus(for: dev.id)
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

    // MARK: - 原生设备列表行
    private func deviceNativeRow(for device: BlanketDevice) -> some View {
        let phase = bleManager.connectionPhase(for: device.id)
        let rowTint = LiquidGlassTheme.thermalTint(
            isOn: device.isOn,
            mode: device.mode,
            gear: max(device.gearLeft, device.gearRight)
        )
        let isCurrentActive = (bleManager.activeDeviceID == device.id)

        return HStack(spacing: 14) {
            Button {
                bleManager.activeDeviceID = device.id
                onSelectDeviceForControl?(device.id)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: device.isOn ? device.mode.symbolName : "bed.double.fill")
                        .font(.title2)
                        .foregroundStyle(device.isOn ? rowTint : Color.secondary)
                        .symbolEffect(.pulse.byLayer, options: .repeating, isActive: device.isOn)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            if isCurrentActive {
                                Text("当前主控")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
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
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // iOS 26/27 原生 Liquid Glass 电源快控按钮
            if device.isOn {
                Button {
                    Task { @MainActor in
                        await bleManager.setPower(isOn: false, for: device.id)
                    }
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(rowTint)
                .sensoryFeedback(.impact(weight: .medium), trigger: device.isOn)
            } else {
                Button {
                    Task { @MainActor in
                        await bleManager.setPower(isOn: true, for: device.id)
                    }
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .sensoryFeedback(.impact(weight: .medium), trigger: device.isOn)
            }
        }
        .padding(.vertical, 4)
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
