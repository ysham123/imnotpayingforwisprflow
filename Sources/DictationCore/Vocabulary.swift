import Foundation

public enum VocabularyError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct VocabularyEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let preferredSpelling: String
    public let aliases: [String]

    public static func normalized(preferredSpelling: String, aliases: [String] = [], id: UUID = UUID()) throws -> Self {
        func normalize(_ text: String) throws -> String {
            guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw VocabularyError.invalid("Custom words must be on one line without control characters.")
            }
            let value = text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !value.isEmpty, value.count <= 80, value.utf8.count <= 256,
                  value.contains(where: { $0.isLetter }) else {
                throw VocabularyError.invalid("Use a word or short phrase with letters, up to 80 characters.")
            }
            return value
        }
        let spelling = try normalize(preferredSpelling)
        guard aliases.count <= 8 else { throw VocabularyError.invalid("Use at most 8 alternate spellings per word.") }
        var seen: Set<String> = [Self.key(spelling)], cleaned: [String] = []
        for alias in aliases where !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let value = try normalize(alias)
            if seen.insert(Self.key(value)).inserted { cleaned.append(value) }
        }
        return Self(id: id, preferredSpelling: spelling, aliases: cleaned)
    }

    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct VocabularySnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let entries: [VocabularyEntry]
    public static let empty = try! Self(entries: [])

    public init(entries: [VocabularyEntry], revision: UInt64 = 0) throws {
        guard entries.count <= 100 else { throw VocabularyError.invalid("Use at most 100 custom words.") }
        var forms: [String: UUID] = [:], ids: Set<UUID> = []
        var normalized: [VocabularyEntry] = []
        for entry in entries {
            guard ids.insert(entry.id).inserted else { throw VocabularyError.invalid("A custom word has a duplicate ID.") }
            let clean = try VocabularyEntry.normalized(preferredSpelling: entry.preferredSpelling, aliases: entry.aliases, id: entry.id)
            for form in [clean.preferredSpelling] + clean.aliases {
                let key = VocabularyEntry.key(form)
                if let other = forms[key], other != clean.id {
                    throw VocabularyError.invalid("“\(form)” is already used by another custom word.")
                }
                forms[key] = clean.id
            }
            normalized.append(clean)
        }
        self.entries = normalized; self.revision = revision
    }

    /// Only source-backed forms are sent to cleanup. A saved word cannot grant
    /// the model permission to introduce it into an unrelated sentence.
    public func cleanupHints(for source: String) -> [[String: String]] {
        var seen: Set<String> = [], bytes = 0, hints: [[String: String]] = []
        for match in matches(in: source, aliases: true) {
            let recognized = match.rangeText(in: source), preferred = match.entry.preferredSpelling
            let key = VocabularyEntry.key(recognized) + "\u{1f}" + preferred
            let size = recognized.utf8.count + preferred.utf8.count
            guard seen.insert(key).inserted, hints.count < 32, bytes + size <= 1_600 else { continue }
            hints.append(["recognized": recognized, "preferred": preferred]); bytes += size
        }
        return hints
    }

    private struct Occurrence {
        let entry: VocabularyEntry
        let range: NSRange
        func rangeText(in text: String) -> String { (text as NSString).substring(with: range) }
    }

    private func matches(in text: String, aliases: Bool) -> [Occurrence] {
        let ns = text as NSString
        var found: [Occurrence] = []
        for entry in entries {
            for form in aliases ? [entry.preferredSpelling] + entry.aliases : [entry.preferredSpelling] {
                let phrase = form.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[^\\S\\r\\n]+")
                let regex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(phrase)(?![\\p{L}\\p{N}_])", options: .caseInsensitive)
                found += regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Occurrence(entry: entry, range: $0.range) }
            }
        }
        // Prefer the complete longest phrase over a shorter entry inside it.
        found.sort { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var end = 0, result: [Occurrence] = []
        for item in found where item.range.location >= end { result.append(item); end = NSMaxRange(item.range) }
        return result
    }

    /// Align source-backed output forms in order. Canonical output spans receive
    /// equal markers; an unchanged alias stays visible to the original validator.
    /// It still validates surrounding content, number positions, and negations.
    public func maskingAuthorizedEdits(source: String, output: String) -> (source: String, output: String) {
        let before = matches(in: source, aliases: true), after = matches(in: output, aliases: true)
        guard !before.isEmpty, !after.isEmpty else { return (source, output) }
        var cursor = 0, unchangedSources: Set<Int> = [], canonicalOutputs: Set<Int> = []
        for (outputIndex, item) in after.enumerated() {
            let canonical = VocabularyEntry.key(item.rangeText(in: output)) == VocabularyEntry.key(item.entry.preferredSpelling)
            let original = (cursor..<before.count).first { index in
                guard before[index].entry.id == item.entry.id else { return false }
                if canonical {
                    return Self.protectedTokens(before[index].rangeText(in: source)) == Self.protectedTokens(item.entry.preferredSpelling)
                }
                return VocabularyEntry.key(before[index].rangeText(in: source)) == VocabularyEntry.key(item.rangeText(in: output))
            }
            // An invented, duplicated, reversed, or unsafe form gets no spelling
            // exception. The original validator will decide the full result.
            guard let original else { return (source, output) }
            if canonical { canonicalOutputs.insert(outputIndex) } else { unchangedSources.insert(original) }
            cursor = original + 1
        }
        var markers: [UUID: String] = [:]
        var prefix = "vocabularymarker"
        while source.lowercased().contains(prefix) || output.lowercased().contains(prefix) { prefix += "q" }
        func letters(_ index: Int) -> String {
            var value = index, result = ""
            repeat { result = String(UnicodeScalar(97 + value % 26)!) + result; value = value / 26 - 1 } while value >= 0
            return result
        }
        for (index, item) in after.enumerated() where canonicalOutputs.contains(index) {
            let id = item.entry.id
            guard markers[id] == nil else { continue }
            markers[id] = prefix + letters(markers.count)
        }
        let left = NSMutableString(string: source), right = NSMutableString(string: output)
        for (index, item) in before.enumerated().reversed() {
            guard !unchangedSources.contains(index), let marker = markers[item.entry.id],
                  Self.protectedTokens(item.rangeText(in: source)) == Self.protectedTokens(item.entry.preferredSpelling) else { continue }
            left.replaceCharacters(in: item.range, with: marker)
        }
        for (index, item) in after.enumerated().reversed() {
            guard canonicalOutputs.contains(index), let marker = markers[item.entry.id] else { continue }
            right.replaceCharacters(in: item.range, with: marker)
        }
        return (left as String, right as String)
    }

    private static func protectedTokens(_ text: String) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let protected = Set("not no never cannot can't don't doesn't didn't won't without isn't aren't wasn't weren't shouldn't wouldn't couldn't haven't hasn't hadn't mustn't neither nor zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion monday tuesday wednesday thursday friday saturday sunday".split(separator: " ").map(String.init))
        let regex = try! NSRegularExpression(pattern: "[0-9]+(?:[.,:][0-9]+)*|[\\p{L}_]+(?:'[\\p{L}]+)?")
        return regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).compactMap {
            let value = (normalized as NSString).substring(with: $0.range)
            return value.first?.isNumber == true || protected.contains(value) ? value : nil
        }
    }
}
