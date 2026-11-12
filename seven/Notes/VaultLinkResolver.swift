import Foundation
import MarkdownEngine

struct VaultLinkResolver: WikiLinkResolver {
    let paths: [String]
    let currentFolder: String

    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        guard let path = matchingPath(for: displayName) else { return nil }
        return WikiLinkResolution(id: path, exists: true)
    }

    func name(forID id: String) -> String? {
        guard let path = paths.first(where: { $0 == id }) else { return nil }
        return (path as NSString).lastPathComponent.deletingMarkdownExtension
    }

    func fingerprint() -> AnyHashable { paths.joined(separator: "\0") }

    func matchingPath(for target: String) -> String? {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let exact = paths.first(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }

        let normalized = name.deletingMarkdownExtension
        let matches = paths.filter { path in
            let relativeStem = path.deletingMarkdownExtension
            let fileStem = (path as NSString).lastPathComponent.deletingMarkdownExtension
            return (name.contains("/") ? relativeStem : fileStem)
                .localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }
        if matches.count == 1 { return matches.first }
        if let local = matches.first(where: { ($0 as NSString).deletingLastPathComponent == currentFolder }) {
            return local
        }
        return matches.first
    }
}

extension String {
    var deletingMarkdownExtension: String {
        lowercased().hasSuffix(".md") ? String(dropLast(3)) : self
    }
}
