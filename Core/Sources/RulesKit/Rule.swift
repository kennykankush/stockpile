import Foundation

/// One entry in the allowlist registry: a recognizable piece of reclaimable
/// storage, described in plain words, with the safety conditions required to
/// match it.
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    /// Plain words, e.g. "Node.js dependencies" — never an identifier.
    public let title: String
    /// What this thing is and who put it there.
    public let explanation: String
    /// What clearing it costs, e.g. "next `npm install` re-downloads them".
    public let regeneration: String
    public let tier: Tier
    public let match: Match

    public struct Match: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            /// Matches any directory with this exact name (e.g. `node_modules`).
            case directoryName
            /// Matches one exact path relative to the user's home directory.
            case homeRelativePath
            /// Matches any direct child of a home-relative path — for
            /// directories that are cache by OS convention (`~/Library/Caches`,
            /// XDG `~/.cache`). Specific rules win by ordering; this is the
            /// generic fallback.
            case homeRelativeParent
        }

        public let kind: Kind
        public let value: String
        /// If set, a file/dir of this name must exist *next to* the candidate
        /// (e.g. `target` only counts as a Rust build dir beside `Cargo.toml`).
        public let requiresSibling: String?
        /// If set, a file/dir of this name must exist *inside* the candidate
        /// (e.g. `.venv` must contain `pyvenv.cfg`).
        public let requiresChild: String?

        public init(kind: Kind, value: String, requiresSibling: String? = nil, requiresChild: String? = nil) {
            self.kind = kind
            self.value = value
            self.requiresSibling = requiresSibling
            self.requiresChild = requiresChild
        }
    }

    public init(id: String, title: String, explanation: String, regeneration: String, tier: Tier, match: Match) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.regeneration = regeneration
        self.tier = tier
        self.match = match
    }
}
