import SwiftUI

/// 蓝牙扫描发现与设备配对原生模态抽屉 (`ScannerSheetView`)
/// 严格按照 `UI_Design_Specification_iOS26_LiquidGlass.md` 第三章第 3 节执行：
/// - 自动识别以 `J` 开头或含 `0x5700` Service UUID / Service Data 的晶合物联蓝牙电热毯
/// - 自动从 14 字节 `0x5700` Service Data 的第 6~11 字节提取真实硬件 MAC 地址用于派生 DES 密钥
/// - 支持一键配对添加，同时提供手动输入硬件 MAC 地址的兜底能力
public struct ScannerSheetView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDiscovered: DiscoveredBLEBlanket?
    @State private var customName: String = "智能蓝牙电热毯"
    @State private var roomName: String = "主卧"
    @State private var manualMAC: String = "8E:B2:D6:64:F8:60"
    @State private var showingManualAddSection: Bool = false

    public init(bleManager: BlanketBLEManager) {
        self.bleManager = bleManager
    }

    private var filteredPeripherals: [DiscoveredBLEBlanket] {
        if bleManager.onlyFilterJingHeDevices {
            return bleManager.discoveredPeripherals.filter { $0.isJingHeBlanket }
        }
        return bleManager.discoveredPeripherals
    }

    public var body: some View {
        NavigationStack {
            List {
                // 1. 扫描雷达状态与过滤开关 Section
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: bleManager.isScanning)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(bleManager.isScanning ? "正在扫描周边蓝牙电热毯..." : "蓝牙扫描已暂停")
                                .font(.subheadline.weight(.semibold))
                            Text("请确保电热毯电源已接通，手机靠近线控器")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(bleManager.isScanning ? "停止" : "重新扫描") {
                            if bleManager.isScanning {
                                bleManager.stopScanning()
                            } else {
                                bleManager.startScanning()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)

                    Toggle(isOn: $bleManager.onlyFilterJingHeDevices.animation(LiquidGlassDesign.fluidSpring)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("仅显示晶合物联电热毯 (J* / 0x5700)")
                                .font(.subheadline)
                            Text("关闭后可查看周围所有广播名称的 BLE 蓝牙设备")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("蓝牙发现雷达")
                }

                // 2. 扫描发现的设备列表 Section
                Section {
                    if filteredPeripherals.isEmpty {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("正在搜寻广播包 (0x5700 / JH_*)...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(filteredPeripherals) { item in
                            Button {
                                selectedDiscovered = item
                                customName = item.name.hasPrefix("J") ? "主卧智能电热毯" : item.name
                                if let mac = item.extractedMAC {
                                    manualMAC = mac
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.isJingHeBlanket ? "bed.double.circle.fill" : "wave.3.right.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(item.isJingHeBlanket ? .orange : .blue)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            if item.isJingHeBlanket {
                                                Text("晶合协议")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.orange)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Color.orange.opacity(0.14), in: Capsule())
                                            }
                                        }
                                        Text("MAC: \(item.displayMAC)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text("\(item.rssi) dBm")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("发现的设备 (\(filteredPeripherals.count))")
                } footer: {
                    Text("点击列表中的设备即可自动提取广播 MAC 地址并绑定至本地设备中心。")
                }

                // 3. 配对信息确认或手动通过 MAC 添加设备 Section
                Section {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { selectedDiscovered != nil || showingManualAddSection },
                            set: { showingManualAddSection = $0 }
                        )
                    ) {
                        LabeledContent("设备名称") {
                            TextField("例如：主卧电热毯", text: $customName)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("所属房间") {
                            TextField("例如：主卧", text: $roomName)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("硬件 MAC") {
                            TextField("8E:B2:D6:64:F8:60", text: $manualMAC)
                                .font(.system(.body, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        }

                        Button {
                            if let discovered = selectedDiscovered {
                                bleManager.addOrUpdateDevice(
                                    from: discovered,
                                    customName: customName,
                                    roomName: roomName,
                                    manualMAC: manualMAC
                                )
                            } else {
                                bleManager.addManualDevice(
                                    name: customName,
                                    roomName: roomName,
                                    macAddress: manualMAC
                                )
                            }
                            bleManager.stopScanning()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label(
                                    selectedDiscovered != nil ? "绑定并极速直连 (\(selectedDiscovered!.name))" : "按 MAC 地址添加设备",
                                    systemImage: "checkmark.circle.fill"
                                )
                                .font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                        }
                        .tint(.blue)
                    } label: {
                        Label(
                            selectedDiscovered != nil ? "确认绑定：\(selectedDiscovered!.name)" : "已知硬件 MAC 地址？手动直接添加",
                            systemImage: "keyboard.badge.ellipsis"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                } header: {
                    Text("设备配置与手动添加")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("添加蓝牙电热毯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        bleManager.stopScanning()
                        dismiss()
                    }
                }
            }
            .onAppear {
                bleManager.startScanning()
            }
            .onDisappear {
                bleManager.stopScanning()
            }
        }
    }
}
