import Cocoa
import TranscriberCore

/// Turns the user's corrections and dictation history into vocabulary and replacement rules.
enum Learning {
    /// Remembers a correction: future dictations write `right` where Whisper heard `wrong`,
    /// and `right` becomes a spelling hint for Whisper.
    static func learn(wrong: String, right: String) {
        let defaults = UserDefaults.standard
        let replacements = defaults.string(forKey: Prefs.Key.replacements) ?? ""
        if let line = VocabularyLearner.replacementLine(wrong: wrong, right: right, existing: replacements) {
            let separator = replacements.isEmpty || replacements.hasSuffix("\n") ? "" : "\n"
            defaults.set(replacements + separator + line, forKey: Prefs.Key.replacements)
        }
        addToVocabulary(right.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func addToVocabulary(_ term: String) {
        let defaults = UserDefaults.standard
        let vocabulary = defaults.string(forKey: Prefs.Key.vocabulary) ?? ""
        guard !term.isEmpty,
              !PromptBuilder.terms(from: vocabulary).contains(where: { $0.lowercased() == term.lowercased() }) else { return }
        let trimmed = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed.isEmpty ? term : trimmed + "\n" + term, forKey: Prefs.Key.vocabulary)
    }

    static func dismiss(_ term: String) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Prefs.Key.dismissedSuggestions) ?? []
        dismissed.append(term)
        UserDefaults.standard.set(dismissed, forKey: Prefs.Key.dismissedSuggestions)
    }

    static func suggestions(from history: [AppState.HistoryEntry]) -> [String] {
        let defaults = UserDefaults.standard
        return VocabularyLearner.suggestions(
            from: history.map(\.text),
            existing: PromptBuilder.terms(from: defaults.string(forKey: Prefs.Key.vocabulary) ?? ""),
            dismissed: Set(defaults.stringArray(forKey: Prefs.Key.dismissedSuggestions) ?? []),
            isCommonWord: isCommonWord
        )
    }

    private static var commonWordCache: [String: Bool] = [:]

    /// A word the English or German dictionary knows (as written or in lowercase), so it is
    /// not a name. German capitalises every noun, hence both checks.
    static func isCommonWord(_ word: String) -> Bool {
        if let cached = commonWordCache[word] { return cached }
        let checker = NSSpellChecker.shared
        let known = ["en", "de"].contains { language in
            [word, word.lowercased()].contains { candidate in
                checker.checkSpelling(of: candidate, startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
        commonWordCache[word] = known
        return known
    }
}
