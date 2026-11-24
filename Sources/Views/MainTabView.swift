import SwiftUI

/// iOS 26 / iOS 27 原生顶层导航容器 (`MainTabView`)
/// 严格采用 iOS 26+ 原生 `TabView` + `Tab` 语法与 `.tabBarMinimizeBehavior(.onScrollDown)`
/// 系统自动渲染悬浮胶囊形态的 Liquid Glass 标签栏，向下滚动时自动丝滑收缩
public struct MainTabView: View {
    @ObservedObject var bleManager: BlanketBLEManager
    @State private var selectedTab: AppTab = .control

    public enum AppTab: Hashable {
        case control
        case status
        case devices
    }

    public init(bleManager: BlanketBLEManager) {
        self.bleManager = bleManager
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("温控", systemImage: "thermometer.medium", value: AppTab.control) {
                if let active = bleManager.activeDevice {
                    NavigationStack {
                        DeviceControlView(bleManager: bleManager, deviceID: active.id)
                    }
                } else {
                    NavigationStack {
                        ContentUnavailableView {
                            Label("尚未添加电热毯", systemImage: "bed.double.fill")
                        } description: {
                            Text("请前往「设备」标签页扫描并绑定您的晶合物联蓝牙电热毯。")
                        } actions: {
                            Button("前往添加设备") {
                                selectedTab = .devices
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                }
            }

            Tab("状态与时长", systemImage: "clock.badge.checkmark", value: AppTab.status) {
                NavigationStack {
                    RuntimeStatusView(bleManager: bleManager)
                }
            }

            Tab("设备", systemImage: "bed.double.fill", value: AppTab.devices) {
                DeviceListView(bleManager: bleManager, onSelectDeviceForControl: { deviceID in
                    bleManager.activeDeviceID = deviceID
                    selectedTab = .control
                })
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .alert(
            "蓝牙连接未响应",
            isPresented: Binding(
                get: { bleManager.connectionFailureAlertMessage != nil },
                set: { if !$0 { bleManager.connectionFailureAlertMessage = nil } }
            )
        ) {
            Button("我知道了", role: .cancel) {
                bleManager.connectionFailureAlertMessage = nil
            }
        } message: {
            Text(bleManager.connectionFailureAlertMessage ?? "")
        }
    }
}
