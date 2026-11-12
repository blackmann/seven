import Foundation

enum LauncherCommand: String, CaseIterable, Identifiable, Sendable {
    case toggleAppearance, lockScreen
    var id: String { "command." + rawValue }
    var title: String {
        switch self {
        case .toggleAppearance: "Toggle Light/Dark Mode"
        case .lockScreen: "Lock Screen"
        }
    }
    var symbol: String {
        switch self {
        case .toggleAppearance: "circle.lefthalf.filled"
        case .lockScreen: "lock"
        }
    }
    var names: [String] {
        switch self {
        case .toggleAppearance: [title, "dark mode", "light mode", "appearance", "theme", "toggle theme"]
        case .lockScreen: [title, "lock", "secure screen"]
        }
    }
}

struct LauncherGoogleSearch: Identifiable, Hashable, Sendable {
    let term: String
    var id: String { "google." + term }
    var title: String { "Search Google for “\(term)”" }

    static func term(in query: String) -> String? {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = input.prefix { !$0.isWhitespace }
        guard command.lowercased() == "google" else { return nil }
        return input.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        // Google treats a literal + as a space, even though URLComponents
        // allows it in a query. Preserve search terms such as C++.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

enum LauncherSearchResult: Identifiable, Hashable, Sendable {
    case application(LauncherApplication)
    case command(LauncherCommand)
    case googleSearch(LauncherGoogleSearch)
    var id: String {
        switch self {
        case .application(let app): return app.id
        case .command(let command): return command.id
        case .googleSearch(let search): return search.id
        }
    }
    var title: String {
        switch self {
        case .application(let app): return app.name
        case .command(let command): return command.title
        case .googleSearch(let search): return search.title
        }
    }
}

enum LauncherSearch {
    static func results(for query: String, applications: [LauncherApplication]) -> [LauncherSearchResult] {
        if let term = LauncherGoogleSearch.term(in: query) {
            return term.isEmpty ? [] : [.googleSearch(LauncherGoogleSearch(term: term))]
        }
        let apps = applications.compactMap { app -> (LauncherSearchResult, Int)? in
            guard let score = ApplicationSearch.matchScore(query: query, names: app.searchNames) else { return nil }
            return (.application(app), score)
        }
        let commands = LauncherCommand.allCases.compactMap { command -> (LauncherSearchResult, Int)? in
            guard let score = ApplicationSearch.matchScore(query: query, names: command.names) else { return nil }
            return (.command(command), score)
        }
        return (apps + commands).sorted {
            $0.1 == $1.1 ? $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending : $0.1 < $1.1
        }.map(\.0)
    }
}
