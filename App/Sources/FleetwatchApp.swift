import SwiftUI

@main
struct FleetwatchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.light)
                .task {
                    MemoryPressureMonitor.shared.start()
                    SystemWatcher.shared.start()
                    TrashSentinel.shared.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
