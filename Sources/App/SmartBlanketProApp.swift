import SwiftUI

@main
struct SmartBlanketProApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationManager.self) private var pushManager
    @StateObject private var bleManager = BlanketBLEManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView(bleManager: bleManager)
                .onAppear {
                    bleManager.activateBluetoothIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    bleManager.handleScenePhaseChange(newPhase)
                }
        }
    }
}
