import Foundation

/// The versioned allowlist of everything Stockpile recognizes as reclaimable.
///
/// Matching is allowlist-only by design: an unmatched path is user data and
/// must never be suggested for deletion, no matter how large.
public struct RulesRegistry: Sendable {
    public let version: Int
    public let rules: [Rule]

    public init(version: Int, rules: [Rule]) {
        self.version = version
        self.rules = rules
    }

    /// Loads the registry bundled with the app.
    public static func bundled() throws -> RulesRegistry {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json") else {
            throw RegistryError.missingBundledRules
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RulesRegistry.self, from: data)
    }

    /// Returns the rule matching a directory, or nil (= user data, untouchable).
    public func match(
        directoryAt url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Rule? {
        let fm = FileManager.default
        let standardized = url.standardizedFileURL

        for rule in rules {
            switch rule.match.kind {
            case .homeRelativePath:
                let target = home.appending(path: rule.match.value).standardizedFileURL
                if standardized.path == target.path {
                    return rule
                }
            case .homeRelativeParent:
                let parent = home.appending(path: rule.match.value).standardizedFileURL
                if standardized.deletingLastPathComponent().path == parent.path {
                    return rule
                }
            case .directoryName:
                guard standardized.lastPathComponent == rule.match.value else { continue }
                if let sibling = rule.match.requiresSibling {
                    let siblingURL = standardized.deletingLastPathComponent().appending(path: sibling)
                    guard fm.fileExists(atPath: siblingURL.path) else { continue }
                }
                if let child = rule.match.requiresChild {
                    let childURL = standardized.appending(path: child)
                    guard fm.fileExists(atPath: childURL.path) else { continue }
                }
                return rule
            }
        }
        return nil
    }

    public enum RegistryError: Error {
        case missingBundledRules
    }
}

extension RulesRegistry: Codable {}
