import SwiftUI

@main
struct SaberControllerApp: App {
    @StateObject private var model = ControllerModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ControllerView()
                .environmentObject(model)
                .onAppear { model.start() }
                .onChange(of: phase) { _, newPhase in
                    if newPhase == .active { model.start() }
                }
        }
    }
}
