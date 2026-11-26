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
        if let i = args.firstIndex(of: "--export-ios-icon"), i + 1 < args.count {
            // Used by CI to (re)generate the iPhone app's icon from the same artwork.
            IconRenderer.exportIOSIcon(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--demo-capture"), i + 1 < args.count {
            DemoOptions.captureDirectory = URL(fileURLWithPath: args[i + 1])
        }
        if let i = args.firstIndex(of: "--demo-speed"), i + 1 < args.count, let s = Double(args[i + 1]), s > 0 {
            DemoOptions.songSpeed = s
        }
        SwiftSaberApp.main()
    }
}

enum DemoOptions {
    static var captureDirectory: URL?
    /// Playback speed for CI capture runs. Above 1 the song clock free-runs from the
    /// wall clock at this rate (music stays silent — only screenshots care), so the
    /// capture run finishes proportionally sooner. Player sessions never set this.
    static var songSpeed: Double = 1
}

struct SwiftSaberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel = {
        let m = AppModel()
        m.demoCaptureDirectory = DemoOptions.captureDirectory
        return m
    }()

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
    /// Motion controls generate no keyboard or mouse input, so macOS would think the player is
    /// idle and dim (then sleep) the display mid-song. Hold the display awake while the game is
    /// frontmost; let it sleep normally once the player switches away.
    private var displayAwake: NSObjectProtocol?

    func applicationDidBecomeActive(_ notification: Notification) {
        guard displayAwake == nil else { return }
        displayAwake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Playing Swift Saber with motion controls")
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let displayAwake { ProcessInfo.processInfo.endActivity(displayAwake) }
        displayAwake = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.applicationIconImage = IconRenderer.image(size: 512)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
