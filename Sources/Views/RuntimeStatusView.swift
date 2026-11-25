import SwiftUI
import Charts
import UIKit

/// 状态与开启时长统计中心 (`RuntimeStatusView`)
/// 严格实现并修复：
/// 1. 顶部与小组件矩阵全部采用 `.listSectionMargins(.horizontal, 0)` + 内部 `.padding(.horizontal, 20)` 与充足上下边距，卡片边缘与下方列表严格对齐且**绝不裁切外发光阴影**；
/// 2. 点击「本次已开启」或「历史累计运行」卡片，无缝展开对应的详细运行记录图表（Swift Charts 柱状趋势图、温区功率轨迹与会话时间轴）；
/// 3. 采用 iOS 桌面小组件风格 (`1x1`、`2x1`、`2x2` 混合 Bento 组合) 展示：**本周运行时间**、**本月运行时间**、**单次均时与除螨统计**、**最常使用挡位排行（各挡位运行时间与色彩占比条）**；
/// 4. 提供**清除运行记录数据**功能，支持按预设范围或**自定义起止日期时间范围 (`DatePicker`)** 精确清理；
/// 5. 右上角新增**设置**按钮，将「点对点连接缓存与后台断连策略」与「Apple 官方 APNs 推送接入」收纳至独立设置面板中，并使用安全 ID 绑定彻底杜绝删设备闪退。
public struct RuntimeStatusView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @ObservedObject private var pushManager = PushNotificationManager.shared
    @ObservedObject private var liveActivityManager = LiveActivityManager.shared
    @Namespace private var statusGlassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public enum ExpandedChartType: String, Identifiable {
        case currentSession = "本次已开启详情图表"
        case historicalDaily = "历史累计运行趋势图表"

        public var id: String { rawValue }
    }

    @State private var currentTime = Date()
    @State private var expandedChart: ExpandedChartType? = nil
    @State private var historyChartDays: Int = 7
    @State private var showAllNineGears: Bool = true
    @State private var showingSettingsSheet: Bool = false
    @State private var showingClearHistorySheet: Bool = false
    @State private var selectedClearScope: UsageHistoryClearScope = .customRange
    @State private var customClearStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customClearEndDate: Date = Date()
    @State private var copiedTokenToast: Bool = false

    /// 15 秒低频时钟刷新，彻底消除每秒重排导致的滚动掉帧
    private let clockTimer = Timer.publish(every: 15.0, on: .main, in: .common).autoconnect()

    public init(bleManager: BlanketBLEManager) {
        self.bleManager = bleManager
    }

    private var device: BlanketDevice {
        if let activeID = bleManager.activeDeviceID,
           let match = bleManager.devices.first(where: { $0.id == activeID }) {
            return match
        }
        return bleManager.devices.first ?? BlanketDevice()
    }

    private var connectionPhase: DeviceConnectionPhase {
        bleManager.connectionPhase(for: device.id)
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
            // MARK: 1. 顶部两个 1x1 卡片 + 动态图表 + 其余小组件置于同一 Section 的独立行中（消除跨 Section 默认大间距，保持精确 14pt 间距且展开不跳动）
            Section {
                topTwoSummaryCardsRow
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                if let activeChart = expandedChart {
                    expandedRuntimeChartCard(for: activeChart)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(.opacity)
                }

                lowerBentoWidgetsGrid
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionMargins(.horizontal, 0)

            // MARK: 2. 实时运行状态明细 Section
            Section("实时加热与定时遥测") {
                LabeledContent("当前设备") {
                    Text("\(device.name) (\(device.roomName))")
                        .fontWeight(.medium)
                }

                LabeledContent("电源与工作模式") {
                    Text(device.isOn ? "开机 · \(device.mode.title)" : "关机待命")
                        .foregroundStyle(device.isOn ? dominantGearColor : Color.secondary)
                        .fontWeight(.semibold)
                }

                LabeledContent("左温区实时设定") {
                    Text("\(device.gearLeft) 挡 · \(device.temperatureLeft)°C")
                        .foregroundStyle(LiquidGlassTheme.gearColor(for: device.gearLeft, mode: device.mode))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                LabeledContent("右温区实时设定") {
                    Text("\(device.gearRight) 挡 · \(device.temperatureRight)°C")
                        .foregroundStyle(LiquidGlassTheme.gearColor(for: device.gearRight, mode: device.mode))
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

            // MARK: 3. 蓝牙底层通信与加密诊断 Section
            Section("蓝牙协议与通信诊断") {
                LabeledContent("BLE 连接状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionPhase == .connected ? Color.green : (connectionPhase == .connecting ? Color.orange : Color.secondary))
                            .frame(width: 8, height: 8)
                        Text(connectionPhase.rawValue)
                    }
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

            // MARK: 4. 运行记录数据管理 Section (Requirement 7)
            Section {
                Button(role: .destructive) {
                    customClearStartDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                    customClearEndDate = Date()
                    showingClearHistorySheet = true
                } label: {
                    Label("清除运行记录数据（可选日期时间范围）...", systemImage: "trash.slash.fill")
                }
            } header: {
                Text("运行记录管理")
            } footer: {
                Text("可按今日、近 7 天、近 30 天、自定义起止日期时间或全部历史清理运行时长与挡位统计。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("状态与时长")
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
                        await bleManager.queryStatus(for: device.id, userInitiated: true)
                    }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
            }

            ToolbarSpacer(.fixed)

            // 右上角新增设置按钮 (Requirement 7)
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    showingSettingsSheet = true
                } label: {
                    Label("设置", systemImage: "gearshape.fill")
                }
            }
        }
        .sheet(isPresented: $showingSettingsSheet) {
            settingsSheetView
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingClearHistorySheet) {
            clearHistoryDateRangeSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onReceive(clockTimer) { now in
            currentTime = now
        }
    }

    // MARK: - 顶部两个 1x1 卡片（独立固定 Section，彻底消除展开图表时上跳）
    private var topTwoSummaryCardsRow: some View {
        let sessionTint = LiquidGlassTheme.activeGlassBackgroundTint(
            isOn: device.isOn,
            mode: device.mode,
            gear: max(device.gearLeft, device.gearRight)
        )

        return HStack(spacing: 14) {
            Button {
                withAnimation(.snappy(duration: 0.32, extraBounce: 0.0)) {
                    expandedChart = (expandedChart == .currentSession) ? nil : .currentSession
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label {
                            Text("本次已开启")
                        } icon: {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(device.isOn ? Color.primary : Color.cyan)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Spacer()

                        Image(systemName: expandedChart == .currentSession ? "chevron.up.circle.fill" : "chart.xyaxis.line")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(String(format: "%.2f h", Double(device.currentSessionElapsedSeconds(at: currentTime)) / 3600.0))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())

                    Text(device.isOn ? device.currentSessionElapsedHoursString(at: currentTime) : "点击查看实时运行轨迹")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .glassEffect(
                sessionTint != nil
                    ? .regular.tint(sessionTint!).interactive()
                    : .regular.interactive(),
                in: .rect(cornerRadius: 24)
            )

            Button {
                withAnimation(.snappy(duration: 0.32, extraBounce: 0.0)) {
                    expandedChart = (expandedChart == .historicalDaily) ? nil : .historicalDaily
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label {
                            Text("历史累计运行")
                        } icon: {
                            Image(systemName: "chart.bar.fill")
                                .foregroundStyle(.blue)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        Spacer()

                        Image(systemName: expandedChart == .historicalDaily ? "chevron.up.circle.fill" : "chart.bar.xaxis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(String(format: "%.1f h", device.totalHistoricalHours(at: currentTime)))
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())

                    Text("累计 \(device.totalPowerOnCount) 次 · 点击展开图表")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 7)
    }

    // MARK: - 其余 iOS 小组件 Bento 网格
    private var lowerBentoWidgetsGrid: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label {
                            Text("本周运行时间")
                        } icon: {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundStyle(.green)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Spacer()
                    }

                    Text(String(format: "%.1f h", device.weeklyRuntimeHours(at: currentTime)))
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())

                    Text("本周开启 \(device.weeklySessionCount(at: currentTime)) 次 · 日均 \(String(format: "%.1f", device.weeklyRuntimeHours(at: currentTime) / 7.0))h")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label {
                            Text("本月运行时间")
                        } icon: {
                            Image(systemName: "calendar")
                                .foregroundStyle(.indigo)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Spacer()
                    }

                    Text(String(format: "%.1f h", device.monthlyRuntimeHours(at: currentTime)))
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())

                    Text("本月开启 \(device.monthlySessionCount(at: currentTime)) 次 · 均时 \(String(format: "%.1f", device.averageSessionHours(at: currentTime)))h")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            }

            wideOverviewWidgetCard
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))

            gearUsageRanking2x2WidgetCard
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal, 20)
        .padding(.top, 7)
        .padding(.bottom, 18)
    }

    // MARK: - 点击顶部卡片展开的 2x2 详细运行记录图表卡片 (Requirement 7)
    private func expandedRuntimeChartCard(for chartType: ExpandedChartType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text(chartType.rawValue)
                        .font(.subheadline.weight(.bold))
                } icon: {
                    Image(systemName: chartType == .currentSession ? "waveform.path.ecg" : "chart.bar.xaxis")
                        .foregroundStyle(chartType == .currentSession ? dominantGearColor : .blue)
                }

                Spacer()

                if chartType == .historicalDaily {
                    Picker("统计跨度", selection: $historyChartDays.animation(.easeInOut(duration: 0.2))) {
                        Text("近7天").tag(7)
                        Text("近14天").tag(14)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 124)
                }

                Button {
                    withAnimation(.snappy(duration: 0.32, extraBounce: 0.0)) {
                        expandedChart = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if chartType == .currentSession {
                currentSessionDetailChartContent
            } else {
                historicalDailyBarChartContent
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 本次开启详细图表：双温区实时挡位对比与定时关机进度条
    private var currentSessionDetailChartContent: some View {
        let elapsedSec = Double(device.currentSessionElapsedSeconds(at: currentTime))
        let totalCloseSec = Double(device.effectiveTimeCloseHours * 3600)
        let progress = device.isOn ? min(1.0, max(0.02, elapsedSec / totalCloseSec)) : 0.0
        let displayLeftGear = (device.mode == .miteRemoval) ? 9 : device.gearLeft
        let displayRightGear = (device.mode == .miteRemoval) ? 9 : device.gearRight
        let displayLeftTemp = (device.mode == .miteRemoval) ? 45 : device.temperatureLeft
        let displayRightTemp = (device.mode == .miteRemoval) ? 45 : device.temperatureRight

        return VStack(alignment: .leading, spacing: 14) {
            Chart {
                BarMark(
                    x: .value("温区", "左温区 (\(displayLeftGear)挡)"),
                    y: .value("摄氏温度", displayLeftTemp)
                )
                .foregroundStyle(LiquidGlassTheme.gearColor(for: displayLeftGear, mode: device.mode).gradient)
                .cornerRadius(8)
                .annotation(position: .top) {
                    Text("\(displayLeftTemp)°C · \(displayLeftGear)挡")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(LiquidGlassTheme.gearColor(for: displayLeftGear, mode: device.mode))
                }

                BarMark(
                    x: .value("温区", "右温区 (\(displayRightGear)挡)"),
                    y: .value("摄氏温度", displayRightTemp)
                )
                .foregroundStyle(LiquidGlassTheme.gearColor(for: displayRightGear, mode: device.mode).gradient)
                .cornerRadius(8)
                .annotation(position: .top) {
                    Text("\(displayRightTemp)°C · \(displayRightGear)挡")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(LiquidGlassTheme.gearColor(for: displayRightGear, mode: device.mode))
                }
            }
            .chartYScale(domain: 0...50)
            .frame(height: 148)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(device.isOn ? "本次加热进度 (\(device.currentSessionElapsedHoursString(at: currentTime)))" : "当前处于待机状态")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(device.isOn ? device.formattedRemainingCloseTime : "开启后自动记录实时轨迹")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress)
                    .tint(device.isOn ? dominantGearColor : .secondary)
            }
        }
    }

    /// 历史累计运行趋势图表：每日开启时长柱状图 + 最近运行会话明细
    private var historicalDailyBarChartContent: some View {
        let points = device.dailyUsageChartPoints(days: historyChartDays, at: currentTime)
        let recentSessions = Array(device.usageRecords.suffix(4).reversed())

        return VStack(alignment: .leading, spacing: 14) {
            Chart(points) { pt in
                BarMark(
                    x: .value("日期", pt.label),
                    y: .value("时长 (h)", pt.hours)
                )
                .foregroundStyle(LiquidGlassTheme.gearColor(for: pt.dominantGear).gradient)
                .cornerRadius(6)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { val in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = val.as(Double.self) {
                            Text(String(format: "%.1fh", d))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .frame(height: 156)

            if !recentSessions.isEmpty {
                Divider()
                Text("最近开启会话记录")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(recentSessions) { rec in
                    let lGear = (rec.mode == .miteRemoval) ? 9 : rec.gearLeft
                    let rGear = (rec.mode == .miteRemoval) ? 9 : rec.gearRight
                    let domGear = max(lGear, rGear)
                    let gearSummaryText: String = {
                        if rec.mode == .miteRemoval {
                            return "9挡 (45°C) · \(rec.mode.title)"
                        } else if lGear == rGear {
                            return "双区 \(lGear)挡 (\(BlanketProtocol.gearToTemp(lGear))°C) · \(rec.mode.title)"
                        } else {
                            return "左\(lGear)挡/右\(rGear)挡 · \(rec.mode.title)"
                        }
                    }()

                    HStack {
                        Circle()
                            .fill(LiquidGlassTheme.gearColor(for: domGear, mode: rec.mode))
                            .frame(width: 8, height: 8)
                        Text(rec.startDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2.monospacedDigit())
                        Spacer()
                        Text(gearSummaryText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(LiquidGlassTheme.gearColor(for: domGear, mode: rec.mode))
                        Text(String(format: "%.2f h", rec.durationSeconds / 3600.0))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("暂无历史归档会话，每次开启或关闭电热毯时将自动记录每日趋势。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 2x1 宽幅小组件卡片（单次均时、首选挡位与除螨统计）
    private var wideOverviewWidgetCard: some View {
        let topGear = device.topFavoriteGear(at: currentTime)

        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("单次平均开启")
                } icon: {
                    Image(systemName: "hourglass.bottomhalf.filled")
                        .foregroundStyle(.cyan)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                Text(String(format: "%.1f h", device.averageSessionHours(at: currentTime)))
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("最常使用挡位")
                } icon: {
                    Image(systemName: "star.circle.fill")
                        .foregroundStyle(topGear != nil ? LiquidGlassTheme.gearColor(for: topGear!.gear) : .teal)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                if let top = topGear {
                    Text("\(top.gear) 挡 (\(BlanketProtocol.gearToTemp(top.gear))°C)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(LiquidGlassTheme.gearColor(for: top.gear))
                } else {
                    Text("\(device.gearLeft) 挡 (预设)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(LiquidGlassTheme.gearColor(for: device.gearLeft))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("高温除螨累计")
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.red)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                Text("\(device.totalMiteRemovalCount) 次")
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 2x2 大号小组件卡片：最常使用挡位排行（各挡位运行时间分布）
    private var gearUsageRanking2x2WidgetCard: some View {
        let rankedItems = device.gearUsageRanking(at: currentTime)
        let displayedItems = showAllNineGears ? rankedItems : Array(rankedItems.prefix(5))

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text("最常使用挡位排行（各挡位运行时间）")
                        .font(.subheadline.weight(.bold))
                } icon: {
                    Image(systemName: "chart.bar.doc.horizontal.fill")
                        .foregroundStyle(.teal)
                }

                Spacer()

                Button(showAllNineGears ? "仅看前5" : "全部9挡") {
                    withAnimation(morphAnimation) {
                        showAllNineGears.toggle()
                    }
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.mini)
            }

            VStack(spacing: 9) {
                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                    let gearColor = LiquidGlassTheme.gearColor(for: item.gear)
                    HStack(spacing: 10) {
                        // 排名与挡位标识
                        HStack(spacing: 4) {
                            Text("#\(index + 1)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .leading)

                            Text("\(item.gear)挡")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(gearColor)
                                .frame(width: 28, alignment: .leading)

                            Text("\(BlanketProtocol.gearToTemp(item.gear))°C")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                        }

                        // 视觉占比进度条（严格采用 1-2蓝 / 3-5绿 / 6-8橙 / 9红）
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.14))
                                    .frame(height: 8)

                                Capsule()
                                    .fill(gearColor.gradient)
                                    .frame(
                                        width: max(6, geo.size.width * CGFloat(min(1.0, max(0.0, item.percentage)))),
                                        height: 8
                                    )
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 16)

                        // 运行时间与百分比
                        Text(formatGearDuration(seconds: item.seconds, percentage: item.percentage))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 12) {
                legendDot(color: .blue, text: "1-2挡 微温蓝")
                legendDot(color: .green, text: "3-5挡 舒适绿")
                legendDot(color: .orange, text: "6-8挡 速热橙")
                legendDot(color: .red, text: "9挡/除螨 高温红")
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func formatGearDuration(seconds: TimeInterval, percentage: Double) -> String {
        let totalSec = Int(round(seconds))
        guard totalSec > 0 else { return "0m (0%)" }
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let pctInt = Int(round(percentage * 100))
        if h > 0 {
            return String(format: "%dh %02dm (%d%%)", h, m, pctInt)
        } else {
            return String(format: "%dm (%d%%)", max(1, m), pctInt)
        }
    }

    // MARK: - 右上角「设置」独立面板 Sheet (收纳点对点连接缓存、后台断连策略与 Apple 官方 APNs 推送接入)
    private var settingsSheetView: some View {
        let currentDeviceID = device.id

        return NavigationStack {
            Form {
                // 0. 灵动岛与实时活动设置 Section
                Section {
                    Toggle(
                        "切入后台自动上岛 (仅设备开启时)",
                        systemImage: "platter.filled.top.and.arrow.up.iphone",
                        isOn: $liveActivityManager.autoStartLiveActivityInBackground
                    )

                    Picker(
                        "关机后自动关闭卡片延时",
                        systemImage: "timer.circle",
                        selection: $liveActivityManager.liveActivityAutoDismissMinutes
                    ) {
                        Text("1 分钟后").tag(1)
                        Text("3 分钟后").tag(3)
                        Text("5 分钟后").tag(5)
                        Text("10 分钟后").tag(10)
                    }

                    Button {
                        Task { @MainActor in
                            await liveActivityManager.startOrUpdateActivity(for: device)
                        }
                    } label: {
                        Label(device.isOn ? "立即更新灵动岛实时活动" : "请先开启电热毯后再上岛", systemImage: "sparkles.rectangle.stack.fill")
                    }
                    .disabled(!device.isOn)

                    Button(role: .destructive) {
                        Task { @MainActor in
                            await liveActivityManager.endAllActivitiesImmediately()
                        }
                    } label: {
                        Label("立即关闭当前实时活动卡片", systemImage: "xmark.circle")
                    }
                } header: {
                    Text("灵动岛与实时活动")
                } footer: {
                    Text("开启后，当电热毯处于加热状态并切入后台时自动上岛；灵动岛与通知中心液态玻璃卡片支持快捷开关机与滚轮式挡位切换，设备关机后将在设定延时后自动关闭卡片以节省电量。")
                }

                // 1. 点对点连接缓存与后台断连策略 Section
                Section {
                    Toggle(
                        "切入后台自动断开电热毯蓝牙",
                        systemImage: "hand.raised.slash.fill",
                        isOn: $bleManager.disconnectWhenEnteringBackground
                    )

                    Toggle(
                        "开机自动恢复上次挡位与定时",
                        systemImage: "memorychip.fill",
                        isOn: bleManager.binding(
                            for: currentDeviceID,
                            keyPath: \.restoreMemoryOnPowerOn,
                            default: true
                        )
                    )

                    LabeledContent {
                        Text("前台常连实时同步")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("前台蓝牙直连策略", systemImage: "bolt.horizontal.circle.fill")
                    }
                } header: {
                    Text("点对点连接缓存与后台断连策略")
                } footer: {
                    Text("前台打开 App 时自动保持连接并实时接收电热毯物理按键状态更新；App 切入后台时自动断开蓝牙并预埋硬件定时通知，重回前台时 0.15 秒命中连接缓存定向重连，绝不改动已绑定设备的 MAC 地址。")
                }

                // 2. Apple 官方 APNs 推送接入 Section
                Section {
                    Toggle(
                        "启用设备状态与定时到点推送",
                        systemImage: "bell.badge.fill",
                        isOn: $pushManager.enableStatusPushNotifications
                    )

                    LabeledContent("APNs 注册状态") {
                        Text(pushManager.effectiveStatusText)
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
                    }

                    Button {
                        pushManager.sendTestPushNotification(for: device)
                    } label: {
                        Label("发送一条 APNs 状态测试推送", systemImage: "paperplane.fill")
                    }
                } header: {
                    Text("Apple 官方 APNs 推送接入")
                } footer: {
                    Text("您的自签证书具备推送权限时，App 启动会自动向 Apple 注册并获取官方 APNs Device Token；无论是预约关机到点、物理线控调挡还是远程网关静默唤醒，均可第一时间收到系统级推送提醒。")
                }
            }
            .navigationTitle("连接与推送设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showingSettingsSheet = false
                    }
                }
            }
        }
    }

    // MARK: - 清除运行记录数据（可选日期时间范围）Sheet (Requirement 7)
    private var clearHistoryDateRangeSheet: some View {
        let matchingCount: Int = {
            let now = Date()
            let cal = Calendar.current
            switch selectedClearScope {
            case .allHistory:
                return device.usageRecords.count
            case .today:
                let s = cal.startOfDay(for: now)
                return device.usageRecords.filter { $0.endDate >= s && $0.endDate <= now }.count
            case .last7Days:
                let s = cal.date(byAdding: .day, value: -7, to: now) ?? now
                return device.usageRecords.filter { $0.endDate >= s && $0.endDate <= now }.count
            case .last30Days:
                let s = cal.date(byAdding: .day, value: -30, to: now) ?? now
                return device.usageRecords.filter { $0.endDate >= s && $0.endDate <= now }.count
            case .customRange:
                let lower = min(customClearStartDate, customClearEndDate)
                let upper = max(customClearStartDate, customClearEndDate)
                return device.usageRecords.filter { $0.endDate >= lower && $0.endDate <= upper }.count
            }
        }()

        return NavigationStack {
            Form {
                Section("选择要清除的时间范围") {
                    Picker("清除范围", selection: $selectedClearScope) {
                        ForEach(UsageHistoryClearScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if selectedClearScope == .customRange {
                    Section("自定义起止日期与时间") {
                        DatePicker(
                            "起始时间",
                            selection: $customClearStartDate,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )

                        DatePicker(
                            "结束时间",
                            selection: $customClearEndDate,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section {
                    LabeledContent("目标设备") {
                        Text(device.name)
                    }
                    LabeledContent("匹配到的历史会话条数") {
                        Text("\(matchingCount) 条记录")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        bleManager.clearUsageHistory(
                            for: device.id,
                            scope: selectedClearScope,
                            customStart: customClearStartDate,
                            customEnd: customClearEndDate
                        )
                        showingClearHistorySheet = false
                    } label: {
                        HStack {
                            Spacer()
                            Label("确认清除所选范围运行数据", systemImage: "trash.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                } footer: {
                    Text("清除后，所选日期时间范围内的累计开启时长、每日趋势柱状图与各挡位运行时间统计将同步扣除。")
                }
            }
            .navigationTitle("清除运行记录数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showingClearHistorySheet = false
                    }
                }
            }
        }
    }
}
