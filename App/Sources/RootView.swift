import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case descend = "Descend"
    case caches = "Caches"
    case apps = "Apps"
    case startup = "Startup"
    case ledger = "Ledger"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .descend: "square.stack.3d.down.right"
        case .caches: "arrow.3.trianglepath"
        case .apps: "square.grid.2x2"
        case .startup: "power"
        case .ledger: "book.closed"
        }
    }
}

struct RootView: View {
    @State private var selection: AppSection = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "shippingbox.fill")
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                    Text("Stockpile")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 6)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Text("0.1.0")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
        } detail: {
            ZStack {
                Backdrop()
                switch selection {
                case .overview: OverviewView()
                case .descend: DescendView()
                case .caches: CachesView()
                case .apps: AppsView()
                case .startup: StartupView()
                case .ledger: LedgerView()
                }
            }
        }
    }
}
