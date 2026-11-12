import CoreServices
import Foundation

enum LauncherDictionary {
    /// nil means normal search; an empty term waits silently for a word.
    static func term(in query: String) -> String? {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = input.prefix { !$0.isWhitespace }
        guard command.lowercased() == "define" else { return nil }
        return input.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LauncherDictionaryResult: Equatable {
    case prompt
    case loading(String)
    case definition(term: String, text: String)
    case notFound(String)

    var hasDefinition: Bool {
        if case .definition(_, let text) = self { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

/// Dictionary Services returns plain text. Recognize the English dictionary's
/// explicit separators, retaining unfamiliar formats as prose instead of
/// assuming every installed dictionary uses the same entry structure.
struct DictionaryEntry {
    struct Block {
        enum Kind { case meaning(String?), detail, partOfSpeech, section }
        let kind: Kind
        let text: String
        var examples: [String] = []
    }

    let word: String
    let pronunciation: String?
    let spelling: String?
    let blocks: [Block]

    init(term: String, text: String) {
        word = term
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let header = source.range(of: #"^.+? \| [^|]+ \| "#, options: .regularExpression) else {
            pronunciation = nil
            spelling = nil
            blocks = [Block(kind: .meaning(nil), text: source)]
            return
        }
        let fields = source[header].components(separatedBy: " | ")
        pronunciation = fields[1].trimmingCharacters(in: .whitespaces)
        let heading = fields[0]
        if let prefix = heading.range(of: term, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
            let remainder = heading[prefix.upperBound...].trimmingCharacters(in: .whitespaces)
            spelling = remainder.isEmpty ? nil : remainder
        } else {
            spelling = heading
        }

        let body = String(source[header.upperBound...])
        let partsOfSpeech = "noun|verb|adjective|adverb|pronoun|preposition|conjunction|exclamation|interjection|determiner|article|abbreviation|prefix|suffix"
        let sectionNames = "PHRASAL VERBS|DERIVATIVES|ORIGIN|PHRASES|USAGE"
        // Numbered senses start after sentence/inflection punctuation, so
        // quantities inside examples (such as “run 42 marathons”) stay intact.
        let afterPartOfSpeech = partsOfSpeech.components(separatedBy: "|").map { "(?<=\($0) )" }.joined(separator: "|")
        let pattern = #"(?<!\S)(?:"# + sectionNames + #")(?!\S)|•|(?:^|(?<=[.!?)] ))(?:"# + partsOfSpeech + #")(?!\S)|(?:^|(?<=[.!?)] )|"# + afterPartOfSpeech + #")[1-9][0-9]? (?=[\p{L}\[(])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var parsed: [Block] = []
        var position = body.startIndex
        var marker = ""
        var isSupplement = false

        func append(_ value: Substring) {
            let content = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if sectionNames.components(separatedBy: "|").contains(marker) {
                parsed.append(Block(kind: .section, text: marker.localizedCapitalized))
                if !content.isEmpty { parsed.append(Block(kind: .detail, text: content)) }
            } else if partsOfSpeech.components(separatedBy: "|").contains(marker) {
                parsed.append(Block(kind: .partOfSpeech, text: marker))
                if !content.isEmpty { appendMeaning(content) }
            } else if !content.isEmpty {
                if isSupplement { parsed.append(Block(kind: .detail, text: marker.isEmpty ? content : marker + " " + content)) }
                else { appendMeaning(content) }
            }
        }

        func appendMeaning(_ content: String) {
            let number = Int(marker) != nil ? marker : (marker == "•" ? "•" : nil)
            if let colon = content.range(of: ": ") {
                let meaning = String(content[..<colon.lowerBound])
                let examples = content[colon.upperBound...].components(separatedBy: " | ")
                parsed.append(Block(kind: .meaning(number), text: meaning, examples: examples))
            } else {
                parsed.append(Block(kind: .meaning(number), text: content))
            }
        }

        for match in matches {
            guard let range = Range(match.range, in: body) else { continue }
            append(body[position..<range.lowerBound])
            marker = body[range].trimmingCharacters(in: .whitespaces)
            if sectionNames.components(separatedBy: "|").contains(marker) { isSupplement = true }
            position = range.upperBound
        }
        append(body[position...])
        blocks = parsed
    }
}

/// Serialize system lookups away from the main actor so cold dictionary loads
/// cannot block typing. Only Apple's public plain-text API is used.
actor SystemDictionary {
    static let shared = SystemDictionary()

    func definition(for term: String) async -> String? {
        guard !term.isEmpty else { return nil }
        let text = term as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(text))
        guard let result = DCSCopyTextDefinition(nil, text, range)?.takeRetainedValue() else { return nil }
        let definition = (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return definition.isEmpty ? nil : definition
    }
}
