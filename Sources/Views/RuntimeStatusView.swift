import SwiftUI

/// 状态与开启时长统计中心 (`RuntimeStatusView`)
/// 满足 Requirement 5 & Requirement 1：
/// - 实时查看本次已经开启了多少小时/分钟、历史累计运行总小时数、累计开机次数、定时关机/预约开机剩余倒计时、蓝牙直连耗时与信号强度
/// - 严格采用 iOS 26 / iOS 27 原生 `List` + `GlassEffectContainer` + `.glassEffect(_:in:)` + `.buttonStyle(.glass)`
public struct RuntimeStatusView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @Namespace private var statusGlassNamespace
    @State private var currentTime = Date()

    private let clockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init(bleManager: BlanketBLEManager) {
        self.bleManager = bleManager
    }

    private var deviceIndex: Int? {
        if let activeID = bleManager.activeDeviceID {
            return bleManager.devices.firstIndex(where: { $0.id == activeID })
        }
        return bleManager.devices.indices.first
    }

    private var device: BlanketDevice {
        if let idx = deviceIndex {
            return bleManager.devices[idx]
        }
        return BlanketDevice()
    }

    private var connectionPhase: DeviceConnectionPhase {
        bleManager.connectionPhase(for: device.id)
    }

    private var activeTint: Color {
        LiquidGlassTheme.thermalTint(
            isOn: device.isOn,
            mode: device.mode,
            gear: max(device.gearLeft, device.gearRight)
        )
    }

    public var body: some View {
        List {
            // MARK: 1. 顶部双联 Liquid Glass 开启时长统计舱 (GlassEffectContainer)
            Section {
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 14) {
                        // 左舱：本次已开启小时数
                        VStack(alignment: .leading, spacing: 6) {
                            Label("本次已开启", systemImage: "flame.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(String(format: "%.2f h", Double(device.currentSessionElapsedSeconds(at: currentTime)) / 3600.0))
                                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())

                            Text(device.currentSessionElapsedHoursString(at: currentTime))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(
                            device.isOn ? .regular.tint(activeTint).interactive() : .regular.interactive(),
                            in: .rect(cornerRadius: 24)
                        )
                        .glassEffectID("sessionHours", in: statusGlassNamespace)

                        // 右舱：历史累计开启总小时数
                        VStack(alignment: .leading, spacing: 6) {
                            Label("历史累计运行", systemImage: "chart.bar.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(String(format: "%.1f h", device.totalHistoricalHours(at: currentTime)))
                                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())

                            Text("累计开启 \(device.totalPowerOnCount) 次")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                        .glassEffectID("totalHours", in: statusGlassNamespace)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 8, trailing: 4))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // MARK: 2. 实时运行状态明细 Section
            Section("实时加热与定时遥测") {
                LabeledContent("当前设备") {
                    Text("\(device.name) (\(device.roomName))")
                        .fontWeight(.medium)
                }

                LabeledContent("电源与工作模式") {
                    Text(device.isOn ? "开机 · \(device.mode.title)" : "关机待命")
                        .foregroundStyle(device.isOn ? activeTint : Color.secondary)
                        .fontWeight(.semibold)
                }

                LabeledContent("左温区实时设定") {
                    Text("\(device.gearLeft) 挡 · \(device.temperatureLeft)°C")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("右温区实时设定") {
                    Text("\(device.gearRight) 挡 · \(device.temperatureRight)°C")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("本次已开启时长") {
                    Text(device.currentSessionElapsedHoursString(at: currentTime))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                        .contentTransition(.numericText())
                }

                LabeledContent("剩余自动关机倒计时") {
                    Text(device.formattedRemainingCloseTime)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("预约定时开机状态") {
                    Text(device.formattedRemainingOpenTime)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            // MARK: 3. 硬件开机记忆与极速直连策略 Section
            if let idx = deviceIndex {
                Section {
                    Toggle(
                        "开机自动恢复上次挡位与定时",
                        systemImage: "memorychip.fill",
                        isOn: $bleManager.devices[idx].restoreMemoryOnPowerOn
                    )

                    Picker(
                        "蓝牙直连策略",
                        systemImage: "bolt.horizontal.circle.fill",
                        selection: $bleManager.devices[idx].connectionPolicy
                    ) {
                        ForEach(BLEConnectionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                } header: {
                    Text("智能记忆与直连优化")
                } footer: {
                    Text("开启「开机自动恢复记忆」后，每次开机将在 0.35 秒后自动恢复为左 \(device.savedGearLeft) 挡 / 右 \(device.savedGearRight) 挡 / 定时 \(device.savedTimeCloseHours) 小时，避开电热毯硬件断电复位的默认 9 挡。")
                }
            }

            // MARK: 4. 蓝牙底层通信与加密诊断 Section
            Section("蓝牙协议与通信诊断") {
                LabeledContent("BLE 连接状态") {
                    Text(connectionPhase.rawValue)
                }

                LabeledContent("GATT 指令响应耗时") {
                    if let ms = device.lastCommandLatencyMs {
                        Text("\(ms) ms (极速直连)")
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    } else {
                        Text("等待首次指令测速")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("无线信号强度 (RSSI)") {
                    Text(device.signalQualityDescription)
                        .monospacedDigit()
                }

                LabeledContent("硬件 MAC (DES 密钥源)") {
                    Text(device.macAddress)
                        .font(.system(.subheadline, design: .monospaced))
                }

                LabeledContent("广播标识符") {
                    Text(device.advertisedName)
                        .font(.system(.subheadline, design: .monospaced))
                }

                if let syncDate = device.lastSyncDate {
                    LabeledContent("最近同步时间") {
                        Text(syncDate.formatted(date: .omitted, time: .standard))
                            .monospacedDigit()
                    }
                }
            }

            // MARK: 5. iOS 快捷指令 (AppIntents) 指南 Section
            Section {
                LabeledContent("控制电热毯开关", value: "支持开机 / 关机 / 切换")
                LabeledContent("调节电热毯温区挡位", value: "支持左区 / 右区 / 双区 1~9 挡")
                LabeledContent("切换电热毯工作模式", value: "普通加热 / 2h 高温除螨")
                LabeledContent("设置定时关机或预约开机", value: "0~12 小时自由定时")
                LabeledContent("查询电热毯状态与开启时长", value: "支持 Siri 播报已开小时数")
            } header: {
                Text("已注册的 iOS「快捷指令」动作")
            } footer: {
                Text("打开系统「快捷指令」App 搜索「智能电热毯」，即可在自动化中选择任意已绑定的电热毯设备并执行上述操作。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("状态与时长")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { @MainActor in
                        await bleManager.queryStatus(for: device.id)
                    }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
            }
        }
        .onReceive(clockTimer) { now in
            currentTime = now
        }
    }
}
