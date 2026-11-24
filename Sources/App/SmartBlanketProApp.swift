import SwiftUI

@main
struct SmartBlanketProApp: App {
    @StateObject private var bleManager = BlanketBLEManager.shared

    var body: some Scene {
        WindowGroup {
            MainTabView(bleManager: bleManager)
                .onAppear {
                    bleManager.activateBluetoothIfNeeded()
                }
        }
    }
}
