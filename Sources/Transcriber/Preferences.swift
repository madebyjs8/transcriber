import Foundation
import TranscriberCore

enum TriggerKey: String, CaseIterable, Identifiable {
    case either, right, left, rightCommand, fn
    var id: String { rawValue }
    var title: String {
        switch self {
        case .either: return "Either Option key (⌥)"
        case .right: return "Right Option key only"
        case .left: return "Left Option key only"
        case .rightCommand: return "Right Command key (⌘)"
        case .fn: return "Fn / Globe key (🌐)"
        }
    }

    /// Short name for hints such as "Hold ⌥ to dictate".
    var keyName: String {
        switch self {
        case .either: return "⌥"
        case .right: return "right ⌥"
        case .left: return "left ⌥"
        case .rightCommand: return "right ⌘"
        case .fn: return "fn"
        }
    }

    var isOption: Bool { self == .either || self == .right || self == .left }
}

enum MicStartMode: String, CaseIterable, Identifiable {
    case instant, afterHold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instant: return "Instantly on key press"
        case .afterHold: return "Once the key is clearly held"
        }
    }
}

enum UnloadPolicy: Int, CaseIterable, Identifiable {
    case never = 0, after5 = 5, after15 = 15, after60 = 60
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .never: return "Keep loaded (fastest)"
        case .after5: return "Unload after 5 min idle"
        case .after15: return "Unload after 15 min idle"
        case .after60: return "Unload after 1 hour idle"
        }
    }
}

struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [Language] = [
        Language(code: "auto", name: "Auto-detect"),
        Language(code: "en", name: "English"),
        Language(code: "de", name: "German"),
        Language(code: "fr", name: "French"),
        Language(code: "es", name: "Spanish"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "pl", name: "Polish"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "da", name: "Danish"),
        Language(code: "no", name: "Norwegian"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "ru", name: "Russian"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "ar", name: "Arabic"),
    ]
}

/// UserDefaults keys and typed accessors. SwiftUI views bind to the same keys via @AppStorage.
enum Prefs {
    enum Key {
        static let triggerKey = "triggerKey"
        static let micStart = "micStartMode"
        static let language = "language"
        static let modelID = "modelID"
        static let inputDeviceUID = "inputDeviceUID"
        static let playSounds = "playSounds"
        static let removeFillers = "removeFillers"
        static let voiceCommands = "voiceCommands"
        static let appendSpace = "appendSpace"
        static let restoreClipboard = "restoreClipboard"
        static let unloadPolicy = "unloadAfterMinutes"
        static let accurateDecoding = "accurateDecoding"
        static let contextPrompt = "contextPrompt"
        static let vocabulary = "vocabulary"
        static let replacements = "replacements"
        static let didOnboard = "didOnboard"
        static let indicatorAlwaysVisible = "indicatorAlwaysVisible"
        static let showInDock = "showInDock"
        static let keepHistory = "keepHistory"
        static let dismissedSuggestions = "dismissedSuggestions"
        static let pasteIntoOrigin = "pasteIntoOrigin"
        static let liveText = "liveText"
        static let pillTheme = "pillTheme"
    }

    static let defaultModelID = "large-v3-turbo-q5_0"

    static let defaultVocabulary = """
    Docker, Docker Compose, MCP, MCP server, Claude, Claude Code, Anthropic, Opus, Sonnet
    ChatGPT, OpenAI, Codex, GPT, Gemini, Antigravity, Cursor, Perplexity, Ollama, Hugging Face
    LLM, LLMs, AI agent, agentic, RAG, embeddings, vector database, fine-tuning, LoRA, tokens
    prompt, system prompt, context window, Whisper, Monologue, n8n, Zapier, LangChain
    API, API key, SDK, CLI, JSON, YAML, OAuth, webhook, GitHub, GitHub Actions, pull request, npm, Homebrew
    TypeScript, JavaScript, Python, Swift, Xcode, macOS, iOS, React, Next.js, Node.js, Tailwind
    Supabase, Firebase, Vercel, Prisma, PostgreSQL, Redis, Kubernetes, Slack, Notion, Figma
    """

    static let defaultReplacements = """
    # heard => written (case-insensitive, whole words)
    chat GPT => ChatGPT
    open AI => OpenAI
    cloud code => Claude Code
    pool request => pull request
    pool requests => pull requests
    # If a word keeps coming out wrong, map it here, e.g.:
    # darker => Docker
    """

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.triggerKey: TriggerKey.either.rawValue,
            Key.micStart: MicStartMode.instant.rawValue,
            Key.language: "auto",
            Key.modelID: defaultModelID,
            Key.inputDeviceUID: "",
            Key.playSounds: true,
            Key.removeFillers: true,
            Key.voiceCommands: true,
            Key.appendSpace: true,
            Key.restoreClipboard: true,
            Key.unloadPolicy: UnloadPolicy.after15.rawValue,
            Key.accurateDecoding: false,
            Key.contextPrompt: "",
            Key.vocabulary: defaultVocabulary,
            Key.replacements: defaultReplacements,
            Key.didOnboard: false,
            Key.indicatorAlwaysVisible: true,
            Key.showInDock: true,
            Key.keepHistory: true,
            Key.pasteIntoOrigin: true,
            Key.liveText: false,
            Key.pillTheme: PillTheme.graphite.rawValue,
        ])
    }

    private static var d: UserDefaults { .standard }

    static var triggerKey: TriggerKey { TriggerKey(rawValue: d.string(forKey: Key.triggerKey) ?? "") ?? .either }
    static var micStart: MicStartMode { MicStartMode(rawValue: d.string(forKey: Key.micStart) ?? "") ?? .instant }
    static var language: String { d.string(forKey: Key.language) ?? "auto" }
    static var modelID: String {
        get { d.string(forKey: Key.modelID) ?? defaultModelID }
        set { d.set(newValue, forKey: Key.modelID) }
    }
    static var inputDeviceUID: String { d.string(forKey: Key.inputDeviceUID) ?? "" }
    static var playSounds: Bool { d.bool(forKey: Key.playSounds) }
    static var restoreClipboard: Bool { d.bool(forKey: Key.restoreClipboard) }
    static var unloadPolicy: UnloadPolicy { UnloadPolicy(rawValue: d.integer(forKey: Key.unloadPolicy)) ?? .after15 }
    static var accurateDecoding: Bool { d.bool(forKey: Key.accurateDecoding) }
    static var indicatorAlwaysVisible: Bool {
        get { d.bool(forKey: Key.indicatorAlwaysVisible) }
        set { d.set(newValue, forKey: Key.indicatorAlwaysVisible) }
    }
    static var showInDock: Bool { d.bool(forKey: Key.showInDock) }
    static var keepHistory: Bool { d.bool(forKey: Key.keepHistory) }
    static var pasteIntoOrigin: Bool { d.bool(forKey: Key.pasteIntoOrigin) }
    static var liveText: Bool { d.bool(forKey: Key.liveText) }
    static var pillTheme: String { d.string(forKey: Key.pillTheme) ?? "graphite" }
    static var didOnboard: Bool {
        get { d.bool(forKey: Key.didOnboard) }
        set { d.set(newValue, forKey: Key.didOnboard) }
    }

    /// Languages "Auto-detect" chooses between: the Mac's preferred languages (System
    /// Settings › General › Language & Region) that Whisper supports. With only one,
    /// auto-detect considers every language instead.
    static var autoLanguages: [String] {
        var codes: [String] = []
        for identifier in Locale.preferredLanguages {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier,
                  Language.all.contains(where: { $0.code == code }), !codes.contains(code) else { continue }
            codes.append(code)
        }
        return codes.isEmpty ? ["en"] : codes
    }

    static var prompt: String {
        PromptBuilder.prompt(context: d.string(forKey: Key.contextPrompt) ?? "",
                             vocabulary: d.string(forKey: Key.vocabulary) ?? "")
    }

    static var textOptions: TextProcessor.Options {
        TextProcessor.Options(
            removeFillers: d.bool(forKey: Key.removeFillers),
            voiceCommands: d.bool(forKey: Key.voiceCommands),
            replacements: Replacement.parse(d.string(forKey: Key.replacements) ?? ""),
            vocabulary: PromptBuilder.terms(from: d.string(forKey: Key.vocabulary) ?? ""),
            appendSpace: d.bool(forKey: Key.appendSpace)
        )
    }
}
