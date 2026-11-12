import Foundation

struct LauncherApplication: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let alternateNames: [String]

    init(url: URL, name: String, bundleIdentifier: String? = nil, alternateNames: [String] = []) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.alternateNames = alternateNames
    }

    var id: String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    var searchNames: [String] {
        [name, url.deletingPathExtension().lastPathComponent] + alternateNames + [bundleIdentifier].compactMap { $0 }
    }
}

enum ApplicationCatalog {
    static var searchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
    }

    static func discover(in searchRoots: [URL]? = nil) -> [LauncherApplication] {
        let manager = FileManager.default
        let roots = searchRoots ?? self.searchRoots
        var applications: [LauncherApplication] = []
        var seen = Set<String>()
        func addApplication(at url: URL) {
            // Safari and other apps can be links to bundles on another system volume.
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  seen.insert(resolved.path).inserted else { return }
            let bundle = Bundle(url: resolved)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let alternateNames = [
                bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                resolved.deletingPathExtension().lastPathComponent
            ].compactMap { $0 }
            applications.append(LauncherApplication(url: url, name: name, bundleIdentifier: bundle?.bundleIdentifier, alternateNames: alternateNames))
        }
        for root in roots {
            // Finder lives directly in CoreServices, outside its Applications
            // folder. Accept individual bundles without indexing system helpers.
            if root.pathExtension.lowercased() == "app" {
                addApplication(at: root)
                continue
            }
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                addApplication(at: url)
            }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum ApplicationSearch {
    static func matchScore(query: String, names: [String]) -> Int? {
        let query = normalized(query)
        guard !query.isEmpty else { return nil }
        return names.compactMap { score(query: query, name: normalized($0)) }.min()
    }
    static func results(for query: String, in applications: [LauncherApplication], limit: Int = .max) -> [LauncherApplication] {
        let query = normalized(query)
        guard !query.isEmpty, limit > 0 else { return [] }
        return applications.compactMap { application -> (LauncherApplication, Int)? in
            guard let score = application.searchNames.compactMap({ score(query: query, name: normalized($0)) }).min() else { return nil }
            return (application, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let order = $0.0.name.localizedStandardCompare($1.0.name)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private static func score(query: String, name: String) -> Int? {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 10 + name.count - query.count }
        if let range = name.range(of: query) { return 50 + name.distance(from: name.startIndex, to: range.lowerBound) + name.count - query.count }
        // Subsequence matching supports abbreviations such as "gc" and "vsc".
        let letters = Array(name)
        var cursor = 0
        var gaps = 0
        var first = 0
        for (index, character) in query.enumerated() {
            guard let match = letters[cursor...].firstIndex(of: character) else { return nil }
            if index == 0 { first = match }
            gaps += match - cursor
            cursor = match + 1
        }
        return 120 + first * 2 + gaps * 3 + letters.count - query.count
    }
}
