import SwiftUI
import FleetKit

/// Local housekeeping tools (This Mac only).
enum LocalTool: String, CaseIterable, Identifiable {
    case descend = "Descend"
    case caches = "Caches"
    case apps = "Apps"
    case startup = "Startup"
    case ledger = "Ledger"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .descend: "square.stack.3d.down.right"
        case .caches: "arrow.3.trianglepath"
        case .apps: "square.grid.2x2"
        case .startup: "power"
        case .ledger: "book.closed"
        }
    }
}

/// What the sidebar can select: the fleet grid, a machine, or a local tool.
enum SidebarItem: Hashable {
    case fleet
    case machine(UUID)
    case tool(LocalTool)
}

struct RootView: View {
    @State private var store = MachineStore.shared
    @State private var selection: SidebarItem? = .fleet
    @State private var addingMachine = false

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(v)"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Fleet") {
                    Label("All machines", systemImage: "square.grid.3x3.fill")
                        .tag(SidebarItem.fleet)
                    ForEach(store.machines) { m in
                        HStack(spacing: 8) {
                            Label(m.name, systemImage: icon(for: m))
                            Spacer()
                            Circle()
                                .fill((store.online[m.id] ?? (m.kind == .local)) ? Theme.ok : Theme.inkTertiary.opacity(0.4))
                                .frame(width: 7, height: 7)
                        }
                        .tag(SidebarItem.machine(m.id))
                        .contextMenu {
                            if m.kind == .remote {
                                Button("Remove", role: .destructive) { store.remove(m) }
                            }
                        }
                    }
                    Button { addingMachine = true } label: {
                        Label("Add machine…", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Section("Tools · This Mac") {
                    ForEach(LocalTool.allCases) { tool in
                        Label(tool.rawValue, systemImage: tool.symbol)
                            .tag(SidebarItem.tool(tool))
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.body).foregroundStyle(Theme.accent)
                    Text("Fleetwatch").font(.system(size: 15, weight: .bold))
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Text(Self.appVersion).font(.caption2).foregroundStyle(Theme.inkTertiary)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
        } detail: {
            ZStack {
                Backdrop()
                detail
            }
        }
        .sheet(isPresented: $addingMachine) { AddMachineView() }
        .task {
            // Fleet heartbeat: sample every machine on a slow cadence so uptime
            // history accumulates and offline alerts fire even for machines
            // you're not currently viewing.
            while !Task.isCancelled {
                await store.refreshAll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .fleet {
        case .fleet:
            FleetGridView { selection = .machine($0.id) }
        case .machine(let id):
            if let m = store.machines.first(where: { $0.id == id }) {
                MachineDashboard(machine: m, onOpenCaches: { selection = .tool(.caches) })
                    .id(m.id)
            } else {
                FleetGridView { selection = .machine($0.id) }
            }
        case .tool(let tool):
            switch tool {
            case .descend: DescendView()
            case .caches: CachesView()
            case .apps: AppsView()
            case .startup: StartupView()
            case .ledger: LedgerView()
            }
        }
    }

    private func icon(for m: Machine) -> String {
        if m.kind == .local { return "laptopcomputer" }
        switch m.os { case .windows: return "pc"; case .linux: return "server.rack"; default: return "desktopcomputer" }
    }
}
