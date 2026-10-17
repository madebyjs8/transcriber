// Headless checks for the pure logic in TranscriberCore.
// Run with: swift run SelfTest
import Foundation
import TranscriberCore

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("✗ \(label) (line \(line))\n    expected: \(String(reflecting: expected))\n    actual:   \(String(reflecting: actual))")
    }
}

// Mirrors the app's default vocabulary (Preferences.swift lives in the app target).
let Prefs_defaultVocabulary = """
ChatGPT, OpenAI, Claude, Claude Code, Anthropic, Gemini, Llama, Mistral, Hugging Face
LLM, LLMs, GPT, AI agent, RAG, embeddings, fine-tuning, tokens, prompt, MCP, Whisper
API, SDK, JSON, YAML, CLI, GitHub, Docker, Kubernetes, TypeScript, JavaScript, Python
Swift, SwiftUI, Xcode, macOS, iOS, React, Next.js, Node.js, PostgreSQL, Supabase, Vercel
Slack, Notion, Figma, Cursor, VS Code
"""

// MARK: - Gestures

typealias G = GestureRecognizer

func run(_ events: [G.Event], on recognizer: inout G) -> [G.Action] {
    events.flatMap { recognizer.handle($0) }.filter {
        if case .scheduleHoldTimer = $0 { return false }
        if case .scheduleTapWindow = $0 { return false }
        return true
    }
}

do { // push-to-talk
    var g = G()
    _ = g.handle(.triggerDown)
    expect(g.state, .pressed, "press enters pressed")
    expect(run([.holdElapsed(generation: 1)], on: &g), [.confirmPushToTalk], "hold confirms push-to-talk")
    expect(run([.triggerUp], on: &g), [.finish], "release finishes push-to-talk")
    expect(g.state, .idle, "back to idle after push-to-talk")
}

do { // shortcut: ⌥ + key
    var g = G()
    expect(run([.triggerDown, .otherInput], on: &g), [.beginCapture, .discard], "⌥+key discards")
    expect(run([.triggerUp], on: &g), [], "release after shortcut does nothing")
    expect(g.state, .idle, "idle after shortcut")
}

do { // single tap is ignored
    var g = G()
    _ = g.handle(.triggerDown)
    _ = g.handle(.triggerUp)
    expect(g.state, .awaitingSecondTap, "single tap waits for a second")
    expect(run([.tapWindowElapsed(generation: 2)], on: &g), [.discard], "single tap discards after window")
}

do { // stale hold timer after a quick tap must not confirm
    var g = G()
    _ = g.handle(.triggerDown)
    _ = g.handle(.triggerUp)
    expect(run([.holdElapsed(generation: 1)], on: &g), [], "stale hold timer ignored")
}

do { // double tap → hands-free, next press stops
    var g = G()
    expect(run([.triggerDown, .triggerUp, .triggerDown], on: &g), [.beginCapture, .lockHandsFree], "double tap locks")
    expect(run([.triggerUp], on: &g), [], "release of locking tap ignored")
    expect(run([.tapWindowElapsed(generation: 2)], on: &g), [], "tap window ignored when locked")
    expect(run([.otherInput], on: &g), [], "typing while locked keeps recording")
    expect(run([.triggerDown, .triggerUp], on: &g), [.finish], "next press finishes hands-free")
    expect(g.state, .idle, "idle after hands-free")
}

do { // ⌥ used as a modifier during hands-free keeps recording
    var g = G()
    _ = run([.triggerDown, .triggerUp, .triggerDown, .triggerUp], on: &g)
    expect(run([.triggerDown, .otherInput, .triggerUp], on: &g), [], "⌥+key while locked continues")
    expect(g.isCommitted, true, "still locked")
    expect(run([.triggerDown, .triggerUp], on: &g), [.finish], "plain press finishes")
}

do { // escape cancels anywhere
    var g = G()
    _ = run([.triggerDown, .holdElapsed(generation: 1)], on: &g)
    expect(run([.cancel], on: &g), [.finishWithoutPaste], "escape stops push-to-talk but keeps the words")
    expect(run([.cancel], on: &g), [], "escape when idle does nothing")
    _ = run([.triggerDown, .triggerUp, .triggerDown], on: &g)
    expect(run([.cancel], on: &g), [.finishWithoutPaste], "cancel stops hands-free but keeps the words")
    expect(run([.triggerDown, .cancel], on: &g), [.beginCapture, .discard], "escape during a tentative press discards")
}

do { // tap then typing discards immediately
    var g = G()
    expect(run([.triggerDown, .triggerUp, .otherInput], on: &g), [.beginCapture, .discard], "tap then typing discards")
}

do { // clicking the indicator starts and finishes hands-free dictation
    var g = G()
    expect(run([.toggleHandsFree], on: &g), [.beginCapture, .lockHandsFree], "click starts hands-free")
    expect(run([.triggerDown, .otherInput, .triggerUp], on: &g), [], "⌥ shortcut during click-started dictation continues")
    expect(run([.toggleHandsFree], on: &g), [.finish], "second click finishes")
    expect(run([.triggerDown], on: &g), [.beginCapture], "⌥ works normally afterwards")
    expect(run([.toggleHandsFree], on: &g), [], "click ignored mid-press")
}

do { // switching apps mid-dictation never throws it away
    var g = G()
    _ = run([.triggerDown, .holdElapsed(generation: 1)], on: &g)
    expect(run([.otherInput, .otherInput], on: &g), [], "clicks and ⌘-Tab during push-to-talk keep recording")
    expect(run([.triggerUp], on: &g), [.finish], "release still finishes and pastes")
    _ = run([.triggerDown, .triggerUp, .triggerDown, .triggerUp], on: &g)
    expect(run([.otherInput, .otherInput, .otherInput], on: &g), [], "browsing during hands-free keeps recording")
    expect(g.isCommitted, true, "still recording hands-free")
}

// MARK: - Text processing

let processor = TextProcessor(options: .init(removeFillers: true, voiceCommands: true,
                                             replacements: Replacement.parse("chat gpt => ChatGPT\ncloud code => Claude Code\n# comment"),
                                             appendSpace: false))
func clean(_ s: String, speech: Double = 5) -> String { processor.process(s, speechSeconds: speech) }

expect(clean(" Hello, world."), "Hello, world.", "trims whisper's leading space")
expect(clean(" [BLANK_AUDIO]"), "", "blank audio is empty")
expect(clean(" (music) Let's start. [Music]"), "Let's start.", "annotations removed")
expect(clean(" Um, so I think we should ship it."), "So I think we should ship it.", "leading filler removed + capitalised")
expect(clean(" I was, uh, thinking about it."), "I was thinking about it.", "inner filler with commas")
expect(clean(" That works, um."), "That works.", "trailing filler keeps sentence end")
expect(clean(" Wir treffen uns um 5 Uhr, um das zu besprechen."), "Wir treffen uns um 5 Uhr, um das zu besprechen.", "German 'um' preserved")
expect(clean(" Ähm, das ist gut."), "Das ist gut.", "German filler removed")
expect(clean(" I asked chat GPT and Cloud Code."), "I asked ChatGPT and Claude Code.", "replacements applied")
expect(clean(" Hello there. New line. How are you?"), "Hello there.\nHow are you?", "new line command")
expect(clean(" Dear Anna, new paragraph, thanks for the notes."), "Dear Anna,\n\nThanks for the notes.", "new paragraph command")
expect(clean(" Add a new line to the file."), "Add a new line to the file.", "literal 'new line' kept")
expect(clean(" Thank you.", speech: 0.2), "", "short hallucination on near-silence dropped")
expect(clean(" Thank you.", speech: 1.0), "Thank you.", "real 'thank you' kept")
expect(clean(" Thanks for watching!"), "", "subtitle hallucination dropped")
expect(clean(" Untertitel im Auftrag des ZDF, 2017"), "", "German subtitle credit dropped")
expect(clean(" iOS apps are great."), "iOS apps are great.", "no forced capitalisation")
expect(clean(" Hello  world ,  again ."), "Hello world, again.", "spacing tidied")

expect(clean(" I think the pipeline needs better embeddings, new paragraph, thanks, Anna."),
       "I think the pipeline needs better embeddings.\n\nThanks, Anna.", "dangling comma before break becomes a full stop")

let vocabularyProcessor = TextProcessor(options: .init(vocabulary: PromptBuilder.terms(from: Prefs_defaultVocabulary), appendSpace: false))
func casing(_ s: String) -> String { vocabularyProcessor.process(s) }
expect(casing(" Ask chatGPT about the rag setup on Macos."), "Ask ChatGPT about the RAG setup on macOS.", "distinctive vocabulary casing enforced")
expect(casing(" We use claude code and next.js with typescript."), "We use Claude Code and Next.js with TypeScript.", "multi-word and dotted terms")
expect(casing(" Swift decisions help, and slack time matters."), "Swift decisions help, and slack time matters.", "ordinary words left alone")
expect(casing(" Fine-tuning works."), "Fine-tuning works.", "lowercase terms never lower sentence starts")
expect(casing(" The Llama and chatgpt-like models."), "The Llama and ChatGPT-like models.", "casing fixed inside hyphenated compounds")
expect(casing(" The ragged edge and a Kubernetes-ready API."), "The ragged edge and a Kubernetes-ready API.", "no match inside longer words")

let spaced = TextProcessor(options: .init(appendSpace: true))
expect(spaced.process(" Done."), "Done. ", "trailing space appended")
expect(spaced.process(" Hello. New line."), "Hello.\n", "no space after trailing newline")
expect(processor.process(" ChatGPT, Claude, Anthropic, Gemini, Llama.", speechSeconds: 0.3,
                         prompt: "ChatGPT, Claude, Anthropic, Gemini, Llama, Mistral."), "", "prompt echo dropped")

// MARK: - Prompt

expect(PromptBuilder.terms(from: "ChatGPT, Claude\nClaude\n\nKubernetes; # note"), ["ChatGPT", "Claude", "Kubernetes"], "vocabulary parsing")
expect(PromptBuilder.prompt(context: "Notes about AI.", vocabulary: "ChatGPT\nClaude"), "Notes about AI. ChatGPT, Claude.", "prompt assembly")
let longPrompt = PromptBuilder.prompt(context: String(repeating: "context ", count: 200), vocabulary: "Anthropic")
expect(longPrompt.count <= PromptBuilder.maxCharacters, true, "prompt length bounded")
expect(longPrompt.hasSuffix("Anthropic."), true, "vocabulary survives truncation")

// MARK: - Vocabulary learning

let common: Set<String> = ["Monday", "The", "Präsentation", "Montag", "Quartal", "Hello"]
let dictations = [
    "We should move the agents to LangChain and Supabase next week.",
    "Supabase handles auth, and LangChain does the orchestration with GPT5.",
    "Wir besprechen die Präsentation am Montag. Supabase ist schon fertig.",
    "Ask Docker about it. The MCP server and LangChain are ready, GPT5 too.",
    "I met Priya on Monday.",
]
let learned = VocabularyLearner.suggestions(from: dictations, existing: ["Docker", "MCP"], dismissed: [],
                                            isCommonWord: { common.contains($0) })
expect(learned, ["LangChain", "Supabase", "GPT5"], "suggests repeated jargon, skips known, common and one-off words")
expect(VocabularyLearner.suggestions(from: dictations, existing: [], dismissed: ["langchain"],
                                     isCommonWord: { common.contains($0) }).contains("LangChain"), false, "dismissed terms stay hidden")
expect(VocabularyLearner.replacementLine(wrong: " darker ", right: "Docker", existing: ""), "darker => Docker", "correction becomes a rule")
expect(VocabularyLearner.replacementLine(wrong: "darker", right: "Docker", existing: "Darker => Docker"), nil, "no duplicate rules")
expect(VocabularyLearner.replacementLine(wrong: "Docker", right: "Docker", existing: ""), nil, "no-op corrections ignored")

// MARK: - Speech detection

let silence = [Float](repeating: 0, count: 16_000)
expect(SpeechDetector.analyze(silence).containsSpeech, false, "silence has no speech")
var tone = [Float](repeating: 0.0005, count: 16_000)
for i in 4_000..<12_000 { tone[i] = 0.2 * sin(Float(i) * 0.05) }
let toneAnalysis = SpeechDetector.analyze(tone)
expect(toneAnalysis.containsSpeech, true, "loud section counts as speech")
expect(abs(toneAnalysis.speechSeconds - 0.5) < 0.05, true, "speech duration measured")

print(failures == 0 ? "✓ all \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
