import SwiftUI

/// 蓝牙扫描发现与设备配对原生模态抽屉 (`ScannerSheetView`)
/// 严格采用 iOS 26 / iOS 27 原生 `List`、`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`
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
                // 1. 扫描状态与过滤开关 Section
                Section("蓝牙发现雷达") {
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
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)

                    Toggle(
                        "仅显示晶合物联电热毯 (J* / 0x5700)",
                        systemImage: "line.3.horizontal.decrease.circle",
                        isOn: $bleManager.onlyFilterJingHeDevices
                    )
                }

                // 2. 扫描到的蓝牙设备列表 Section
                Section {
                    if filteredPeripherals.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在搜寻晶合物联 0x5700 广播包...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(filteredPeripherals) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.isJingHeBlanket ? "bed.double.circle.fill" : "wave.3.right.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(item.isJingHeBlanket ? Color.orange : Color.blue)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("MAC: \(item.displayMAC) · \(item.rssi) dBm")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("选择") {
                                    selectedDiscovered = item
                                    customName = item.name.hasPrefix("J") ? "主卧智能电热毯" : item.name
                                    if let mac = item.extractedMAC {
                                        manualMAC = mac
                                    }
                                }
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text("发现的设备 (\(filteredPeripherals.count))")
                } footer: {
                    Text("点击「选择」可自动从 0x5700 广播包第 6~11 字节提取硬件 MAC 地址。")
                }

                // 3. 绑定确认与手动输入 MAC Section
                Section("绑定参数确认 / 手动添加") {
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
                                selectedDiscovered != nil ? "绑定并直连 (\(selectedDiscovered!.name))" : "按 MAC 地址保存设备",
                                systemImage: "checkmark.circle.fill"
                            )
                            .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("扫描蓝牙电热毯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
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
