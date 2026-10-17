import Foundation

/// Learns the user's vocabulary from what they dictate.
public enum VocabularyLearner {
    /// Terms worth adding to the vocabulary: names and jargon that show up repeatedly in the
    /// user's dictations but aren't in their vocabulary yet.
    ///
    /// A word qualifies if its spelling is distinctive (inner capitals like "LangChain",
    /// all-caps like "MCP", digits like "GPT5") or if it is capitalised mid-sentence and
    /// `isCommonWord` doesn't know it (a name like "Supabase"). Ordinary words, German nouns
    /// included, are filtered out by `isCommonWord`.
    public static func suggestions(from texts: [String], existing vocabulary: [String], dismissed: Set<String>,
                                   minimumCount: Int = 2, limit: Int = 12,
                                   isCommonWord: (String) -> Bool) -> [String] {
        let known = Set(vocabulary.map { $0.lowercased() }).union(dismissed.map { $0.lowercased() })
        let allWords = texts.flatMap(words(in:))

        // A capitalised word counts as a name once it has appeared mid-sentence; after that,
        // its sentence-initial uses count too.
        var names = Set<String>()
        for (word, startsSentence) in allWords where !startsSentence && word.first?.isUppercase == true {
            names.insert(word)
        }

        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, (word, _)) in allWords.enumerated() {
            guard word.count >= 2, word.contains(where: \.isLetter), !known.contains(word.lowercased()) else { continue }
            let distinctive = word.dropFirst().contains(where: \.isUppercase)
                || (word.contains(where: \.isNumber) && word.contains(where: \.isLetter))
            guard distinctive || (names.contains(word) && !isCommonWord(word)) else { continue }
            counts[word, default: 0] += 1
            if firstSeen[word] == nil { firstSeen[word] = index }
        }

        return counts
            .filter { $0.value >= minimumCount }
            .sorted { ($0.value, -firstSeen[$0.key]!) > ($1.value, -firstSeen[$1.key]!) }
            .prefix(limit)
            .map(\.key)
    }

    /// Words with surrounding punctuation trimmed (keeping inner "." and "-", as in Next.js),
    /// and whether each one starts a sentence.
    static func words(in text: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var startsSentence = true
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !word.isEmpty { result.append((word, startsSentence)) }
            startsSentence = raw.last.map { ".!?:".contains($0) } ?? false
        }
        return result
    }

    /// Records a correction: "heard => written" for the replacement list. Returns nil if the
    /// rule would be a no-op or already exists.
    public static func replacementLine(wrong: String, right: String, existing: String) -> String? {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return nil }
        let alreadyThere = Replacement.parse(existing).contains {
            $0.from.lowercased() == wrong.lowercased() && $0.to == right
        }
        return alreadyThere ? nil : "\(wrong) => \(right)"
    }
}
