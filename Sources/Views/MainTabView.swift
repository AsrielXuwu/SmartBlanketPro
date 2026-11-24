import SwiftUI

/// iOS 26 / iOS 27 原生顶层导航与左右滑动分页容器 (`MainTabView`)
/// 严格实现 (Requirement 5)：
/// 1. 在单一共享 `NavigationStack` 内部采用 `TabView(selection: $selectedTab)` + `.tabViewStyle(.page(indexDisplayMode: .never))`，实现「温控」「状态与时长」「设备」三页跟手左右滑动无缝切换；
/// 2. 顶部导航栏标题与右上角操作按钮采用持久化 `ToolbarItem` + `.contentTransition(.symbolEffect(.replace))` 与弹簧动画，页面左右滑动切换时顶栏按钮原地执行 Apple 官方无缝图标形变过渡；
/// 3. 底部采用原生 iOS 26 `GlassEffectContainer` 悬浮胶囊标签栏与 `.glassEffectID` 流体选中滑块，点击底栏与手势左右滑动 100% 双向实时同步。
public struct MainTabView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @State private var selectedTab: AppTab = .control
    @State private var showingScannerSheet = false
    @State private var showingStatusSettingsSheet = false
    @Namespace private var tabGlassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public enum AppTab: Int, Hashable, CaseIterable {
        case control = 0
        case status = 1
        case devices = 2

        var title: String {
            switch self {
            case .control: return "温控"
            case .status:  return "状态与时长"
            case .devices: return "设备"
            }
        }

        var symbolName: String {
            switch self {
            case .control: return "thermometer.medium"
            case .status:  return "clock.badge.checkmark"
            case .devices: return "bed.double.fill"
            }
        }
    }

    public init(bleManager: BlanketBLEManager) {
        self.bleManager = bleManager
    }

    private var activeNavigationTitle: String {
        switch selectedTab {
        case .control:
            return bleManager.activeDevice?.name ?? "温控中心"
        case .status:
            return "状态与时长"
        case .devices:
            return "设备管理"
        }
    }

    private var tabSwitchAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.14)
    }

    public var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                // 1. 温控页
                Group {
                    if let active = bleManager.activeDevice {
                        DeviceControlView(bleManager: bleManager, deviceID: active.id)
                    } else {
                        ContentUnavailableView {
                            Label("尚未添加电热毯", systemImage: "bed.double.fill")
                        } description: {
                            Text("请向左滑动或前往「设备」标签页扫描并绑定您的晶合物联蓝牙电热毯。")
                        } actions: {
                            Button("前往添加设备") {
                                withAnimation(tabSwitchAnimation) {
                                    selectedTab = .devices
                                }
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                }
                .tag(AppTab.control)

                // 2. 状态与时长页
                RuntimeStatusView(
                    bleManager: bleManager,
                    showingSettingsSheet: $showingStatusSettingsSheet
                )
                .tag(AppTab.status)

                // 3. 设备管理页
                DeviceListView(
                    bleManager: bleManager,
                    showingScannerSheet: $showingScannerSheet,
                    onSelectDeviceForControl: { deviceID in
                        bleManager.activeDeviceID = deviceID
                        withAnimation(tabSwitchAnimation) {
                            selectedTab = .control
                        }
                    }
                )
                .tag(AppTab.devices)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(activeNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .animation(tabSwitchAnimation, value: selectedTab)
            .toolbar {
                // 左上角：温控页且多设备时显示房间快速切换菜单
                if selectedTab == .control,
                   bleManager.devices.count > 1,
                   let active = bleManager.activeDevice {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(bleManager.devices) { item in
                                Button {
                                    bleManager.activeDeviceID = item.id
                                } label: {
                                    Label(
                                        "\(item.name) (\(item.roomName))",
                                        systemImage: item.id == active.id ? "checkmark.circle.fill" : "bed.double"
                                    )
                                }
                            }
                        } label: {
                            Label(active.roomName, systemImage: "chevron.up.chevron.down")
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    }
                }

                // 右上角主操作按钮（持久化按钮实例 + .contentTransition(.symbolEffect(.replace)) 无缝过渡）
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        handlePrimaryToolbarAction()
                    } label: {
                        Image(systemName: primaryToolbarSymbol)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                    .accessibilityLabel(primaryToolbarLabel)
                }

                ToolbarSpacer(.fixed)

                // 右上角次操作按钮（持久化按钮实例 + .contentTransition(.symbolEffect(.replace)) 无缝过渡）
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        handleSecondaryToolbarAction()
                    } label: {
                        Image(systemName: secondaryToolbarSymbol)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                    .accessibilityLabel(secondaryToolbarLabel)
                }
            }
            .overlay(alignment: .bottom) {
                liquidGlassFloatingTabBar
            }
            .sheet(isPresented: $showingScannerSheet) {
                ScannerSheetView(bleManager: bleManager)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - 顶栏动态按钮映射（配合符号替换过渡动画）
    private var primaryToolbarSymbol: String {
        switch selectedTab {
        case .control, .status: return "arrow.clockwise"
        case .devices:          return "plus"
        }
    }

    private var primaryToolbarLabel: String {
        switch selectedTab {
        case .control: return "同步状态"
        case .status:  return "刷新状态"
        case .devices: return "添加设备"
        }
    }

    private var secondaryToolbarSymbol: String {
        switch selectedTab {
        case .control: return "plus"
        case .status:  return "gearshape.fill"
        case .devices: return "arrow.clockwise"
        }
    }

    private var secondaryToolbarLabel: String {
        switch selectedTab {
        case .control: return "扫描新设备"
        case .status:  return "设置"
        case .devices: return "全部刷新"
        }
    }

    private func handlePrimaryToolbarAction() {
        switch selectedTab {
        case .control, .status:
            if let targetID = bleManager.activeDevice?.id {
                Task { @MainActor in
                    await bleManager.queryStatus(for: targetID)
                }
            }
        case .devices:
            showingScannerSheet = true
        }
    }

    private func handleSecondaryToolbarAction() {
        switch selectedTab {
        case .control:
            showingScannerSheet = true
        case .status:
            showingStatusSettingsSheet = true
        case .devices:
            let snapshotIDs = bleManager.devices.map(\.id)
            for id in snapshotIDs {
                Task { @MainActor in
                    await bleManager.queryStatus(for: id)
                }
            }
        }
    }

    // MARK: - 底部悬浮 iOS 26 Liquid Glass 胶囊 Tab 栏（与手势左右滑动双向实时同步）
    private var liquidGlassFloatingTabBar: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    let isSelected = (selectedTab == tab)
                    Button {
                        withAnimation(tabSwitchAnimation) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 14, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                    .glassEffectID("activeTabPill", in: tabGlassNamespace)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: selectedTab)
                }
            }
            .padding(5)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }
}
