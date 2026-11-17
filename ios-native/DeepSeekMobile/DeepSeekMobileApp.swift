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
                .onOpenURL { url in
                    client.handleDeepLink(url)
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background, .inactive:
                        LiveActivityController.shared.setSceneBackground(true)
                    case .active:
                        LiveActivityController.shared.setSceneBackground(false)
                        if client.isAuthenticated {
                            Task {
                                await client.recoverRouteAndSocket(reason: "foreground_resume")
                            }
                        }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
