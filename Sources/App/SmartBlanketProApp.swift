import SwiftUI
import AppIntents

@main
struct SmartBlanketProApp: App {
    @StateObject private var bleManager = BlanketBLEManager.shared

    init() {
        // 向 iOS 系统注册预置快捷指令与 Siri 短语
        BlanketShortcutsProvider.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            DeviceListView(bleManager: bleManager)
        }
    }
}
