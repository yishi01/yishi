import SwiftUI

@main
struct DeepSeekMobileApp: App {
    @StateObject private var client = BridgeClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.light)
                .task {
                    await client.bootstrap()
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background, .inactive:
                        // Doubao-style Dynamic Island: only appears when switched to background while AI is running
                        LiveActivityController.shared.setSceneBackground(true)
                    case .active:
                        // Immediately retract Dynamic Island when returning to foreground
                        LiveActivityController.shared.setSceneBackground(false)
                        if client.isAuthenticated {
                            client.connectWebSocket(reset: false)
                        }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
