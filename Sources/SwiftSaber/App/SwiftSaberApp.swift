import SwiftUI
import AppKit
import SaberCore

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count {
            // Used by Scripts/build-app.sh to produce the .icns file.
            IconRenderer.exportIconset(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        SwiftSaberApp.main()
    }
}

struct SwiftSaberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Swift Saber") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Game") {
                Button("Recenter Sabers") { model.recenter() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Calibrate AirPods…") { model.openCalibration() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.applicationIconImage = IconRenderer.image(size: 512)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
