import SwiftUI

@main
struct YansimLauncherApp: App {
    @StateObject private var game = GameManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("YanMac Launcher") {
            ContentView()
                .environmentObject(game)
                .onAppear { appDelegate.game = game }
        }
        .windowResizability(.contentSize)
    }
}
