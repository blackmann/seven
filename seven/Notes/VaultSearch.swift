import Foundation

struct FileSearchResult: Identifiable, Sendable {
  let file: VaultFile
  let matches: [SearchLineMatch]

  var id: String { file.id }
}

struct SearchLineMatch: Identifiable, Sendable {
  let lineNumber: Int
  let text: String

  var id: String { "\(lineNumber)|\(text)" }
}

enum VaultSearch {
    struct Request: Equatable {
        let query: String
        let files: [VaultFile]
        let isActive: Bool
    }

    static func results(for query: String, files: [VaultFile]) -> [FileSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return files.compactMap { file in
            let nameMatches = file.relativePath.localizedCaseInsensitiveContains(query)
            var seenLines: Set<String> = []
            let matches: [SearchLineMatch]
            if let contents = try? String(contentsOf: file.url, encoding: .utf8), !contents.contains("\0") {
                matches = contents.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, text.localizedCaseInsensitiveContains(query),
                          seenLines.insert(text).inserted else { return nil }
                    return SearchLineMatch(lineNumber: index + 1, text: text)
                }
            } else { matches = [] }
            return nameMatches || !matches.isEmpty ? FileSearchResult(file: file, matches: matches) : nil
        }
    }
}
