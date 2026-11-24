import SwiftUI
import UIKit

/// 状态与开启时长统计中心 (`RuntimeStatusView`)
/// 满足 Requirement 3 & Requirement 5：
/// - 实时查看本次已经开启了多少小时/分钟、历史累计运行总小时数、累计开机次数、定时关机/预约开机剩余倒计时、蓝牙直连耗时与信号强度
/// - 新增「切入后台自动断开蓝牙」开关与「Apple 官方 APNs 状态推送」配置面板（适配带推送权限的自签证书）
public struct RuntimeStatusView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @ObservedObject private var pushManager = PushNotificationManager.shared
    @Namespace private var statusGlassNamespace
    @State private var currentTime = Date()
    @State private var copiedTokenToast = false

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
                GlassEffectContainer(spacing: 6) {
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
                    .padding(12)
                }
                .padding(.horizontal, -12)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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

            // MARK: 3. 点对点连接缓存、后台自动断连与开机记忆 Section (Requirement 3)
            if let idx = deviceIndex {
                Section {
                    Toggle(
                        "切入后台自动断开电热毯蓝牙",
                        systemImage: "hand.raised.slash.fill",
                        isOn: $bleManager.disconnectWhenEnteringBackground
                    )

                    Toggle(
                        "开机自动恢复上次挡位与定时",
                        systemImage: "memorychip.fill",
                        isOn: $bleManager.devices[idx].restoreMemoryOnPowerOn
                    )

                    Picker(
                        "前台蓝牙直连策略",
                        systemImage: "bolt.horizontal.circle.fill",
                        selection: $bleManager.devices[idx].connectionPolicy
                    ) {
                        ForEach(BLEConnectionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                } header: {
                    Text("点对点连接缓存与后台断连策略")
                } footer: {
                    Text("已启用三级连接缓存（外设实例 + 特征值句柄 + 8字节 DES 密钥缓存），点击控制时无需扫描即可点对点直连；App 切入后台时自动断开蓝牙并预埋硬件定时通知，重回前台或收到推送唤醒时 0.15 秒极速同步最新状态。")
                }
            }

            // MARK: 4. Apple 官方 APNs 状态推送配置 Section (Requirement 3)
            Section {
                Toggle(
                    "启用设备状态与定时到点推送",
                    systemImage: "bell.badge.fill",
                    isOn: $pushManager.enableStatusPushNotifications
                )

                LabeledContent("APNs 注册状态") {
                    Text(pushManager.apnsStatusMessage)
                        .font(.caption)
                        .foregroundStyle(pushManager.apnsDeviceToken.isEmpty ? Color.secondary : Color.green)
                }

                if !pushManager.apnsDeviceToken.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Apple 官方 APNs Device Token")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(copiedTokenToast ? "已复制" : "复制 Token") {
                                UIPasteboard.general.string = pushManager.apnsDeviceToken
                                copiedTokenToast = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedTokenToast = false
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        Text(pushManager.apnsDeviceToken)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                } else {
                    Button {
                        pushManager.requestPushAuthorizationAndRegister()
                    } label: {
                        Label("重新获取 Apple APNs 设备令牌", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                }

                DisclosureGroup("高级：配置 Apple APNs (.p8) HTTP/2 直推凭证") {
                    LabeledContent("Team ID") {
                        TextField("10位 Apple Team ID", text: $pushManager.apnsTeamID)
                            .font(.system(.subheadline, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Key ID") {
                        TextField("10位 APNs Key ID", text: $pushManager.apnsKeyID)
                            .font(.system(.subheadline, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("P8 私钥") {
                        TextField("-----BEGIN PRIVATE KEY-----...", text: $pushManager.apnsP8PrivateKey)
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("使用 Sandbox 沙盒网关 (开发证书)", isOn: $pushManager.useSandboxAPNs)

                    Button {
                        pushManager.notifyDeviceStateChanged(
                            title: "✅ 智能电热毯 APNs 推送测试",
                            body: "\(device.name) 当前状态：\(device.isOn ? "正在加热" : "待机中") · 左 \(device.gearLeft)挡 / 右 \(device.gearRight)挡"
                        )
                    } label: {
                        Label("发送一条 APNs 状态测试推送", systemImage: "paperplane.fill")
                    }
                }
            } header: {
                Text("Apple 官方 APNs 推送接入")
            } footer: {
                Text("您的自签证书具备推送权限时，App 启动会自动向 Apple 注册并获取官方 APNs Device Token；无论是预约关机到点、物理线控调挡还是远程网关静默唤醒，均可第一时间收到系统级推送提醒。")
            }

            // MARK: 5. 蓝牙底层通信与加密诊断 Section
            Section("蓝牙协议与通信诊断") {
                LabeledContent("BLE 连接状态") {
                    Text(connectionPhase.rawValue)
                }

                LabeledContent("GATT 指令响应耗时") {
                    if let ms = device.lastCommandLatencyMs {
                        Text("\(ms) ms (缓存点对点直连)")
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
