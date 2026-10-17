import Foundation

/// Builds Whisper's initial prompt from the user's context text and vocabulary list.
///
/// Whisper treats the prompt as "text that came before this audio", so it is a strong hint
/// for spelling (names, jargon, product names) and for punctuation style. It is not an
/// instruction. Whisper only uses the last ~224 tokens, so we keep it to a safe length and
/// make sure the vocabulary (the part that matters most) is what survives.
public enum PromptBuilder {
    /// Roughly 224 tokens of typical English/technical text.
    public static let maxCharacters = 800

    /// Splits a vocabulary field on newlines and commas, dropping blanks and duplicates.
    public static func terms(from vocabulary: String) -> [String] {
        var seen = Set<String>()
        return vocabulary
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0.lowercased()).inserted }
    }

    public static func prompt(context: String, vocabulary: String) -> String {
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = terms(from: vocabulary)

        var vocabularyPart = terms.joined(separator: ", ")
        if !vocabularyPart.isEmpty, !vocabularyPart.hasSuffix(".") { vocabularyPart += "." }

        // Whisper keeps the *end* of an over-long prompt, so the context goes first and gets
        // trimmed first; the vocabulary sits right next to the audio where it has most effect.
        let budgetForContext = maxCharacters - vocabularyPart.count - 1
        var parts: [String] = []
        if !context.isEmpty, budgetForContext > 20 {
            parts.append(context.count > budgetForContext ? String(context.suffix(budgetForContext)) : context)
        }
        if !vocabularyPart.isEmpty {
            parts.append(vocabularyPart.count > maxCharacters ? String(vocabularyPart.prefix(maxCharacters)) : vocabularyPart)
        }
        return parts.joined(separator: " ")
    }
}
