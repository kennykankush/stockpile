import SwiftUI
import FleetKit

/// The System Information spec sheet — msinfo32 / About This Mac for any
/// machine. Static metadata grouped into sections of label/value rows.
struct SystemInfoView: View {
    let machineName: String
    let info: SystemInfo?
    let loading: Bool
    let error: String?
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "info.circle", tint: Theme.accent, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("System Information").font(.system(size: 15, weight: .bold))
                    Text(machineName).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose).buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Divider().overlay(Theme.hairline)

            if let info, !info.sections.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(info.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title.uppercased())
                                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                                Card(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                                            HStack(alignment: .top, spacing: 12) {
                                                Text(row.label)
                                                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                                                    .frame(width: 140, alignment: .leading)
                                                Text(row.value)
                                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                                    .textSelection(.enabled)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .padding(.horizontal, 14).padding(.vertical, 9)
                                            if i < section.rows.count - 1 { Divider().overlay(Theme.hairline).padding(.leading, 14) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            } else if loading {
                center { ProgressView(); Text("Reading system information…").font(.callout).foregroundStyle(.secondary) }
            } else {
                center {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.inkTertiary)
                    Text(error ?? "Couldn't read system information.").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                }
            }
        }
        .frame(width: 480, height: 620)
        .background(Theme.canvas)
    }

    @ViewBuilder private func center(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 10) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
