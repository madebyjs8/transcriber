import Foundation

/// A user-defined "heard → written" correction, e.g. "chat gpt" → "ChatGPT".
public struct Replacement: Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// Parses lines of the form `heard => written` (also accepts `->` and `→`).
    /// Blank lines and lines starting with `#` are ignored.
    public static func parse(_ text: String) -> [Replacement] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            for separator in ["=>", "->", "→"] {
                if let range = line.range(of: separator) {
                    let from = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let to = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    return from.isEmpty ? nil : Replacement(from: from, to: to)
                }
            }
            return nil
        }
    }
}

/// Turns raw Whisper output into text that is ready to paste.
public struct TextProcessor {
    public struct Options {
        public var removeFillers = true
        public var voiceCommands = true
        public var replacements: [Replacement] = []
        /// Vocabulary terms whose distinctive spelling is enforced (see `applyVocabularyCasing`).
        public var vocabulary: [String] = []
        public var appendSpace = true

        public init(removeFillers: Bool = true, voiceCommands: Bool = true,
                    replacements: [Replacement] = [], vocabulary: [String] = [], appendSpace: Bool = true) {
            self.removeFillers = removeFillers
            self.voiceCommands = voiceCommands
            self.replacements = replacements
            self.vocabulary = vocabulary
            self.appendSpace = appendSpace
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// - Parameters:
    ///   - raw: concatenated Whisper segment text.
    ///   - speechSeconds: how much of the recording actually contained voice energy;
    ///     used to reject Whisper's classic hallucinations on near-silent audio.
    ///   - prompt: the vocabulary prompt that was given to Whisper, used to detect echoes of it.
    public func process(_ raw: String, speechSeconds: Double = .infinity, prompt: String = "") -> String {
        var text = raw

        text = Self.removeNonSpeechAnnotations(text)
        text = Self.collapseSpaces(text).trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.isHallucination(text, speechSeconds: speechSeconds, prompt: prompt) {
            return ""
        }

        if options.removeFillers {
            text = Self.removeFillers(text)
        }
        if options.voiceCommands {
            text = Self.applyVoiceCommands(text)
        }
        text = Self.applyVocabularyCasing(options.vocabulary, to: text)
        text = Self.applyReplacements(options.replacements, to: text)
        text = Self.tidy(text)

        guard !text.isEmpty, text.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        if options.appendSpace, let last = text.last, !last.isNewline {
            text += " "
        }
        return text
    }

    // MARK: - Steps

    private static let annotationPatterns: [NSRegularExpression] = [
        // [BLANK_AUDIO], [Music], [ Silence ], [inaudible] …
        #"\[[^\]\n]{0,40}\]"#,
        // (music), (laughs), (Applaus) … but not arbitrary parenthesised dictation
        #"\(\s*(?:music|applause|laughs?|laughter|laughing|silence|inaudible|noise|background noise|coughs?|coughing|sighs?|sniffs?|typing|keyboard(?: clicking)?|clicking|clears throat|musik|applaus|lachen|stille|unverständlich|räuspern)[^)\n]{0,20}\)"#,
        // *laughs*, *music*
        #"\*[^*\n]{1,30}\*"#,
        // ♪ lyrics ♪
        #"[♪♫♬][^♪♫♬\n]*[♪♫♬]"#,
        #"[♪♫♬]"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func removeNonSpeechAnnotations(_ text: String) -> String {
        annotationPatterns.reduce(text) { $1.replace(in: $0, with: " ") }
    }

    /// Phrases Whisper is known to produce on silence or noise (it was trained on subtitles).
    private static let creditPhrases = [
        "thanks for watching", "thank you for watching", "thank you so much for watching",
        "please subscribe", "subtitles by", "amara.org", "untertitel", "untertitelung",
        "copyright", "www.", "vielen dank fürs zuschauen", "bis zum nächsten mal",
    ]
    private static let shortHallucinations: Set<String> = [
        "you", "thank you", "thanks", "bye", "okay", "ok", "so", "danke", "vielen dank",
        "tschüss", "ja", "the end", "hmm", "uh", "um",
    ]

    static func isHallucination(_ text: String, speechSeconds: Double, prompt: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if normalized.isEmpty { return true }

        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        if wordCount <= 8, creditPhrases.contains(where: { normalized.contains($0) }) {
            return true
        }
        // Very short "Thank you." style outputs are only trusted when there was real speech.
        if speechSeconds < 0.45, shortHallucinations.contains(normalized) {
            return true
        }
        // Whisper sometimes regurgitates its prompt when the audio is unclear.
        if wordCount >= 5, !prompt.isEmpty {
            let promptNormalized = prompt.lowercased()
            if promptNormalized.contains(normalized) { return true }
        }
        return false
    }

    // Group 1: optional comma before, 2: the filler, 3: punctuation after, 4: spaces after.
    private static let fillerRegex = try! NSRegularExpression(
        pattern: #"(,[ \t]*)?(?<![\p{L}\p{N}'’-])(u+m+|u+h+m*|e+r+m+|h+m+|m+h+m+|ä+h+m*|ö+h+m*)(?![\p{L}\p{N}'’-])([,.!?…]*)([ \t]*)"#,
        options: [.caseInsensitive]
    )

    static func removeFillers(_ text: String) -> String {
        let result = NSMutableString(string: text)
        let matches = fillerRegex.matches(in: text, range: NSRange(location: 0, length: result.length))

        // Walk backwards so the ranges of earlier matches stay valid.
        for match in matches.reversed() {
            let filler = result.substring(with: match.range(at: 2)).lowercased()
            let hasLeadingComma = match.range(at: 1).location != NSNotFound
            let trailing = result.substring(with: match.range(at: 3))

            // "um" is also a German preposition ("um 5 Uhr", ", um zu …"). Only treat it as a
            // filler when Whisper punctuated it like one ("Um, …", "…, um, …").
            if filler == "um" && trailing.isEmpty { continue }

            let before = result.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            let afterIsEmpty = match.range.upperBound >= result.length
            let atSentenceStart = before.isEmpty || before.last.map { ".!?\n".contains($0) } == true
            let trailingEnd = trailing.first(where: { ".!?…".contains($0) })

            var replacement: String
            if atSentenceStart {
                replacement = ""
            } else if let end = trailingEnd {
                replacement = String(end) + " "
            } else if hasLeadingComma && trailing.contains(",") {
                replacement = " "
            } else if hasLeadingComma || trailing.contains(",") {
                replacement = ", "
            } else {
                replacement = " "
            }
            if afterIsEmpty { replacement = replacement.trimmingCharacters(in: .whitespaces) }

            result.replaceCharacters(in: match.range, with: replacement)

            // Capitalise the word that now starts the sentence ("Um, so …" → "So …").
            if atSentenceStart {
                var index = match.range.location + (replacement as NSString).length
                while index < result.length,
                      let scalar = UnicodeScalar(result.character(at: index)),
                      CharacterSet.whitespaces.contains(scalar) {
                    index += 1
                }
                if index < result.length {
                    let charRange = result.rangeOfComposedCharacterSequence(at: index)
                    let character = result.substring(with: charRange)
                    if character != character.uppercased(), character.lowercased() == character {
                        result.replaceCharacters(in: charRange, with: character.uppercased())
                    }
                }
            }
        }
        return result as String
    }

    // "new line" / "new paragraph" only count when spoken as their own phrase, i.e.
    // bounded by punctuation or the start/end of the text, so "add a new line" stays literal.
    private static let paragraphRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.,!?;:\n]))\s*(?:new paragraph|neuer absatz)\s*(?:[.,!?;:]+|$)[ \t]*"#,
        options: [.caseInsensitive]
    )
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.,!?;:\n]))\s*(?:new ?line|next line|neue zeile)\s*(?:[.,!?;:]+|$)[ \t]*"#,
        options: [.caseInsensitive]
    )
    private static let capitalizeAfterNewline = try! NSRegularExpression(pattern: #"\n[ \t]*(\p{Ll})"#)

    static func applyVoiceCommands(_ text: String) -> String {
        var result = replaceCommands(paragraphRegex, in: text, with: "\n\n")
        result = replaceCommands(lineRegex, in: result, with: "\n")
        // Uppercase the first letter of each new line.
        let ns = result as NSString
        var output = result
        for match in capitalizeAfterNewline.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let r = Range(match.range(at: 1), in: output) {
                output.replaceSubrange(r, with: output[r].uppercased())
            }
        }
        return output
    }

    /// Replaces spoken line-break commands. Whisper often writes the pause before a command
    /// as a comma ("…better embeddings, new paragraph, thanks"); a comma left dangling before
    /// the break becomes a full stop, except after a short salutation ("Dear Anna,").
    private static func replaceCommands(_ regex: NSRegularExpression, in text: String, with breakText: String) -> String {
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            result.replaceCharacters(in: match.range, with: breakText)
            let before = result.substring(to: match.range.location)
            guard before.hasSuffix(",") else { continue }
            let clauseStart = before.dropLast().lastIndex(where: { ".!?\n".contains($0) })
            let clause = clauseStart.map { before[before.index(after: $0)...] } ?? Substring(before)
            let words = clause.split(whereSeparator: \.isWhitespace).count
            if words > 3 {
                result.replaceCharacters(in: NSRange(location: match.range.location - 1, length: 1), with: ".")
            }
        }
        return result as String
    }

    /// Whether a vocabulary term's spelling is distinctive enough to enforce everywhere:
    /// inner capitals (ChatGPT, macOS, RAG), digits/punctuation (Next.js, GPT-4o) or several
    /// words (Claude Code). Plain capitalised words (Swift, Slack, React) are also ordinary
    /// words and are left to Whisper; all-lowercase terms have nothing to enforce.
    static func hasDistinctiveSpelling(_ term: String) -> Bool {
        guard term.contains(where: \.isUppercase) else { return false }
        if term.dropFirst().contains(where: \.isUppercase) { return true }
        return term.contains(where: { !$0.isLetter })
    }

    static func applyVocabularyCasing(_ vocabulary: [String], to text: String) -> String {
        vocabulary.filter(hasDistinctiveSpelling).reduce(text) { current, term in
            let words = term.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let leading = term.first.map { $0.isLetter || $0.isNumber } == true ? #"(?<![\p{L}\p{N}])"# : ""
            let trailing = term.last.map { $0.isLetter || $0.isNumber } == true ? #"(?![\p{L}\p{N}])"# : ""
            let pattern = leading + words.joined(separator: #"\s+"#) + trailing
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return current }
            return regex.replace(in: current, with: NSRegularExpression.escapedTemplate(for: term))
        }
    }

    public static func applyReplacements(_ replacements: [Replacement], to text: String) -> String {
        replacements.reduce(text) { current, replacement in
            let escaped = NSRegularExpression.escapedPattern(for: replacement.from)
            // Only enforce word boundaries on sides that start/end with a word character.
            let leading = replacement.from.first.map { $0.isLetter || $0.isNumber } == true ? #"(?<![\p{L}\p{N}])"# : ""
            let trailing = replacement.from.last.map { $0.isLetter || $0.isNumber } == true ? #"(?![\p{L}\p{N}])"# : ""
            guard let regex = try? NSRegularExpression(pattern: leading + escaped + trailing, options: [.caseInsensitive]) else {
                return current
            }
            let template = NSRegularExpression.escapedTemplate(for: replacement.to)
            return regex.replace(in: current, with: template)
        }
    }

    private static let spaceRuns = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"[ \t]+([,.!?;:…])"#)
    private static let doubledCommas = try! NSRegularExpression(pattern: #",\s*,"#)
    private static let spacesAroundNewlines = try! NSRegularExpression(pattern: #"[ \t]*\n[ \t]*"#)
    private static let leadingPunctuation = try! NSRegularExpression(pattern: #"^[ \t,;:]+"#)

    static func collapseSpaces(_ text: String) -> String {
        spaceRuns.replace(in: text, with: " ")
    }

    static func tidy(_ text: String) -> String {
        var result = collapseSpaces(text)
        result = doubledCommas.replace(in: result, with: ",")
        result = spaceBeforePunctuation.replace(in: result, with: "$1")
        result = spacesAroundNewlines.replace(in: result, with: "\n")
        result = leadingPunctuation.replace(in: result, with: "")
        // Newlines at either end come from spoken commands ("new paragraph. Dear …") and are
        // intentional; other surrounding whitespace is not.
        let leadingNewlines = String(result.prefix(while: \.isNewline))
        let trailingNewlines = String(result.reversed().prefix(while: \.isNewline))
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "" : leadingNewlines + result + trailingNewlines
    }
}

extension NSRegularExpression {
    func replace(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
