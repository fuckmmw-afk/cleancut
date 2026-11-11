import SwiftUI

@main
struct CleanCutApp: App {
    @State private var settings = AppSettings()
    @State private var store = ProjectStore()
    @State private var thermal = ThermalMonitor()

    init() {
        BackgroundKeeper.shared.registerIfPossible()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(settings)
                .environment(store)
                .environment(thermal)
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
        }
    }
}
