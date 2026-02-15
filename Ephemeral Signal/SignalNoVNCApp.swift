// SignalNoVNCApp

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: SignalRuntime?

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Clear badge + count when user returns to the app
        runtime?.clearNotifications()
    }
}

@main
struct SignalNoVNCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtime = SignalRuntime()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(runtime)
                .task {
                    appDelegate.runtime = runtime
                    await runtime.start()
                }
                .onChange(of: runtime.hasActivity) { old, active in
                    guard active else { return }
                    guard !NSApp.isActive else { return }

                    // Bounce Dock icon — badge is managed solely by handleNotifyLine
                    NSApp.requestUserAttention(.informationalRequest)
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    runtime.stop()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Logs") {
                    openWindow(id: "logs")
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }

        Window("Logs", id: "logs") {
            LogWindowView()
                .environmentObject(runtime)
        }
        .defaultSize(width: 700, height: 500)
    }
}
