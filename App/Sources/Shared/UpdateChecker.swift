import SwiftUI

/// The honest version of Sparkle for a brew-distributed app: check GitHub for
/// a newer release and *point* the user at the right update command, rather
/// than auto-updating behind brew's back and corrupting its state. Awareness
/// without the conflict.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    var latestVersion: String?      // e.g. "0.4.0" when newer than installed
    private var checked = false

    var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func checkIfNeeded() async {
        guard !checked else { return }
        checked = true
        guard let url = URL(string: "https://api.github.com/repos/kennykankush/stockpile/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isNewer(remote, than: current) {
            latestVersion = remote
        }
    }

    /// Semantic-ish compare: split on dots, compare numerically component-wise.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// A quiet update note — brew-aware, dismissible, never auto-acts.
struct UpdateBanner: View {
    let version: String
    @State private var copied = false

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "arrow.down.circle", tint: Theme.accent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stockpile \(version) is available")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Update with: brew upgrade --cask stockpile")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "Copied ✓" : "Copy command") {
                    SystemReport.copyToClipboard("brew upgrade --cask stockpile")
                    copied = true
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}
