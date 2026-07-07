import SwiftUI

@main
struct StockpileApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
                .task {
                    MemoryPressureMonitor.shared.start()
                    SystemWatcher.shared.start()
                    TrashSentinel.shared.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
