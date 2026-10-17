import AVFoundation
import Observation
import ServiceManagement
import SwiftUI
import TranscriberCore

enum SettingsTab: String, Hashable {
    case setup, general, model, vocabulary, history
}

@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

/// Hosts the settings UI in a regular window (menu bar apps have no main window).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let navigation = SettingsNavigation()
    private let state: AppState
    private let models: ModelManager
    private let controller: DictationController
    private var window: NSWindow?

    init(state: AppState, models: ModelManager, controller: DictationController) {
        self.state = state
        self.models = models
        self.controller = controller
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(tab: SettingsTab?) {
        if let tab { navigation.tab = tab }
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(navigation: navigation, state: state, models: models, controller: controller)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Transcriber"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let state: AppState
    let models: ModelManager
    let controller: DictationController

    var body: some View {
        TabView(selection: $navigation.tab) {
            SetupTab(state: state, models: models, controller: controller)
                .tabItem { Label("Setup", systemImage: "checklist") }
                .tag(SettingsTab.setup)
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ModelTab(state: state, models: models, controller: controller)
                .tabItem { Label("Model", systemImage: "cpu") }
                .tag(SettingsTab.model)
            VocabularyTab(state: state)
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
                .tag(SettingsTab.vocabulary)
            HistoryTab(state: state, controller: controller)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
        }
        .padding(.top, 8)
        .frame(width: 620, height: 560)
    }
}

// MARK: - Setup

private struct SetupTab: View {
    let state: AppState
    let models: ModelManager
    let controller: DictationController
    @AppStorage(Prefs.Key.triggerKey) private var trigger: TriggerKey = .either
    @AppStorage(Prefs.Key.pillTheme) private var pillTheme = "graphite"

    private var recommended: WhisperModel { ModelManager.catalog[0] }

    var body: some View {
        Form {
            Section("How it works") {
                GestureRow(keys: "Hold \(trigger.keyName)", text: "Talk while holding. Release to transcribe and paste.")
                GestureRow(keys: "Double-tap \(trigger.keyName)", text: "Hands-free dictation. Press \(trigger.keyName) again to finish.")
                GestureRow(keys: "esc", text: "While holding: stop without pasting (the text is kept in History).")
                GestureRow(keys: "Click the pill", text: "Start or finish hands-free. Drag it anywhere; right-click for options.")
            }

            Section {
                PillThemePicker(selection: $pillTheme)
            } header: {
                Text("Make it yours")
            } footer: {
                Text("The color of the little pill that shows Transcriber is running. You can change it any time in General.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                SetupStep(
                    done: state.microphoneStatus == .authorized,
                    title: "Microphone",
                    detail: "Audio is only recorded while you dictate and never leaves your Mac."
                ) {
                    if state.microphoneStatus == .notDetermined {
                        Button("Allow…") { controller.requestMicrophone() }
                    } else {
                        Button("Open Settings") { Permissions.openMicrophoneSettings() }
                    }
                }

                SetupStep(
                    done: state.accessibilityGranted,
                    title: "Accessibility",
                    detail: "Lets Transcriber notice the \(trigger.keyName) key and paste text into the app you are using. If it is already switched on but not working, select Transcriber in the list, remove it with −, then add it again with +."
                ) {
                    Button("Open Settings") {
                        Permissions.promptForAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }

                SetupStep(
                    done: !models.installed.isEmpty,
                    title: "Speech model",
                    detail: "\(recommended.name), \(recommended.sizeText). Runs entirely on this Mac's GPU."
                ) {
                    if let progress = models.progress[recommended.id] {
                        ProgressView(value: progress).frame(width: 90)
                    } else if models.installed.isEmpty {
                        Button("Download") { models.download(recommended) }
                    }
                }
                if let error = models.errors[recommended.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Setup")
            }
        }
        .formStyle(.grouped)
        .task {
            // Permissions are granted in System Settings; poll while this tab is visible.
            while !Task.isCancelled {
                state.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct GestureRow: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .frame(width: 118, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct SetupStep<Accessory: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { accessory() }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(Prefs.Key.triggerKey) private var trigger: TriggerKey = .either
    @AppStorage(Prefs.Key.pillTheme) private var pillTheme = "graphite"
    @AppStorage(Prefs.Key.micStart) private var micStart: MicStartMode = .instant
    @AppStorage(Prefs.Key.language) private var language = "auto"
    @AppStorage(Prefs.Key.inputDeviceUID) private var inputDevice = ""
    @AppStorage(Prefs.Key.removeFillers) private var removeFillers = true
    @AppStorage(Prefs.Key.voiceCommands) private var voiceCommands = true
    @AppStorage(Prefs.Key.appendSpace) private var appendSpace = true
    @AppStorage(Prefs.Key.restoreClipboard) private var restoreClipboard = true
    @AppStorage(Prefs.Key.pasteIntoOrigin) private var pasteIntoOrigin = true
    @AppStorage(Prefs.Key.liveText) private var liveText = false
    @AppStorage(Prefs.Key.playSounds) private var playSounds = true
    @AppStorage(Prefs.Key.indicatorAlwaysVisible) private var indicatorAlwaysVisible = true
    @AppStorage(Prefs.Key.showInDock) private var showInDock = true
    @State private var devices: [AudioDevices.Device] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Trigger key", selection: $trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Start microphone", selection: $micStart) {
                    ForEach(MicStartMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text(shortcutHint)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(Language.all) { Text($0.name).tag($0.code) }
                }
                Picker("Microphone", selection: $inputDevice) {
                    Text("Automatic (avoids Bluetooth mics)").tag("")
                    Text("System default").tag("system")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                    if !["", "system"].contains(inputDevice), !devices.contains(where: { $0.uid == inputDevice }) {
                        Text("Unavailable device").tag(inputDevice)
                    }
                }
            } header: {
                Text("Speech")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if language == "auto" {
                        Text(autoLanguagesHint)
                    }
                    if inputDevice.isEmpty {
                        Text("Automatic uses your Mac's built-in mic while Bluetooth headphones (like AirPods) are the default, so your music keeps playing in full quality while you dictate.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Text") {
                Toggle("Remove filler words (um, uh, ähm)", isOn: $removeFillers)
                Toggle("Spoken “new line” and “new paragraph” insert line breaks", isOn: $voiceCommands)
                Toggle("Add a space after inserted text", isOn: $appendSpace)
                Toggle("Show live text in the pill while you talk", isOn: $liveText)
                Toggle("Restore clipboard after pasting", isOn: $restoreClipboard)
                Picker("If you switch apps while dictating", selection: $pasteIntoOrigin) {
                    Text("Paste where you started").tag(true)
                    Text("Paste where you finish").tag(false)
                }
            }

            Section {
                LabeledContent("Pill color") { PillThemePicker(selection: $pillTheme) }
                Picker("Floating indicator", selection: $indicatorAlwaysVisible) {
                    Text("Always visible").tag(true)
                    Text("Only while dictating").tag(false)
                }
                LabeledContent("Indicator position") {
                    Button("Reset") { IndicatorPosition.reset() }
                }
                Toggle("Show in Dock", isOn: $showInDock)
                Toggle("Play start and stop sounds", isOn: $playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("App")
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
    }

    private var shortcutHint: String {
        let key = trigger.keyName
        var hint = micStart == .instant
            ? "Nothing you say is lost, but the mic briefly switches on whenever you use \(key) in a shortcut. If that bothers you, pick “Once the key is clearly held”."
            : "The mic starts about 0.2 s after you press \(key), so shortcuts never switch it on. Start speaking right after pressing."
        if trigger.isOption {
            hint += " Another dictation app using ⌥ (like Monologue) must be quit, or pick a different key here."
        } else if trigger == .fn {
            hint += " Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing” so macOS doesn't also react."
        }
        return hint
    }

    private var autoLanguagesHint: String {
        let names = Prefs.autoLanguages.compactMap { code in Language.all.first { $0.code == code }?.name }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count > 1
            ? "Auto-detect chooses between \(list), your Mac's languages (System Settings › General › Language & Region). A fixed language is a little faster."
            : "Auto-detect considers every language. If you always dictate in one language, choosing it is a little faster and more reliable for short phrases."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription). Move Transcriber to /Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Model

private struct ModelTab: View {
    let state: AppState
    let models: ModelManager
    let controller: DictationController
    @AppStorage(Prefs.Key.modelID) private var modelID = Prefs.defaultModelID
    @AppStorage(Prefs.Key.unloadPolicy) private var unloadPolicy: UnloadPolicy = .after15
    @AppStorage(Prefs.Key.accurateDecoding) private var accurate = false

    var body: some View {
        Form {
            Section("Speech model") {
                ForEach(models.models) { model in
                    ModelRow(model: model, models: models,
                             isActive: models.activeModel(preferred: modelID)?.id == model.id,
                             select: { modelID = model.id })
                }
            }

            Section {
                Picker("When idle", selection: $unloadPolicy) {
                    ForEach(UnloadPolicy.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Accurate decoding (beam search, slightly slower)", isOn: $accurate)
                LabeledContent("Status", value: statusText)
            } header: {
                Text("Performance")
            } footer: {
                Text("The model runs on the GPU with Metal. An unloaded model is reloaded the moment you start dictating, while you speak.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Open Models Folder") { controller.openModelsFolder() }
            } footer: {
                Text("Other whisper.cpp models (ggml-*.bin) placed in this folder show up in the list above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
    }

    private var statusText: String {
        switch state.modelStatus {
        case .missing: return "No model downloaded"
        case .notLoaded: return "Not in memory (loads on demand)"
        case .loading: return "Loading…"
        case .ready: return "Loaded and ready"
        case .failed(let message): return message
        }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let models: ModelManager
    let isActive: Bool
    let select: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    Text(model.sizeText).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                if let error = models.errors[model.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
        .contextMenu {
            if models.installed.contains(model.id) {
                Button("Delete", role: .destructive) { models.delete(model) }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if models.verifying.contains(model.id) {
            Text("Verifying…").font(.caption).foregroundStyle(.secondary)
        } else if let progress = models.progress[model.id] {
            HStack(spacing: 6) {
                ProgressView(value: progress).frame(width: 90)
                Button { models.cancelDownload(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        } else if models.installed.contains(model.id) {
            if isActive {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Use", action: select)
            }
        } else {
            Button("Download") { models.download(model) }
        }
    }
}

// MARK: - Vocabulary

private struct VocabularyTab: View {
    let state: AppState
    @AppStorage(Prefs.Key.vocabulary) private var vocabulary = Prefs.defaultVocabulary
    /// Bumped when a suggestion is dismissed (that list isn't observable through @AppStorage).
    @State private var dismissals = 0
    @AppStorage(Prefs.Key.contextPrompt) private var context = ""
    @AppStorage(Prefs.Key.replacements) private var replacements = Prefs.defaultReplacements

    private var promptLength: Int { PromptBuilder.prompt(context: context, vocabulary: vocabulary).count }

    var body: some View {
        Form {
            let suggestions = dismissals >= 0 ? Learning.suggestions(from: state.history) : []
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { term in
                        HStack {
                            Text(term).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button("Add") { Learning.addToVocabulary(term) }
                            Button {
                                Learning.dismiss(term)
                                dismissals += 1
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .help("Not a term, don't suggest it again")
                        }
                    }
                } header: {
                    Text("Suggested from your dictations")
                } footer: {
                    Text("Names and jargon you used repeatedly that aren't in your vocabulary yet. Add the ones that are real terms.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $vocabulary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names, products, jargon and words you use often, separated by commas or new lines. Whisper uses them as spelling hints.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Context", text: $context,
                          prompt: Text("e.g. Slack messages and notes about our iOS app, the Claude API and RAG pipelines."),
                          axis: .vertical)
                    .lineLimit(2...4)
                    .labelsHidden()
            } header: {
                Text("Context")
            } footer: {
                Text("Optional. A sentence or two in the style you usually dictate. Whisper continues its tone, punctuation and spelling.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $replacements)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Replacements")
            } footer: {
                Text("One per line as heard => written. Applied after transcription for words Whisper keeps getting wrong.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Prompt size") {
                    Text("\(promptLength) / \(PromptBuilder.maxCharacters) characters")
                        .foregroundStyle(promptLength >= PromptBuilder.maxCharacters ? .orange : .secondary)
                }
            } footer: {
                Text("Whisper only reads about 220 tokens of prompt. If you go over, the context is shortened first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

/// "This word came out wrong": fixes the entry and teaches the app the right spelling.
private struct FixWordButton: View {
    let entry: AppState.HistoryEntry
    let state: AppState
    @State private var isPresented = false
    @State private var wrong = ""
    @State private var right = ""

    var body: some View {
        Button { isPresented = true } label: { Image(systemName: "pencil") }
            .buttonStyle(.borderless)
            .help("Fix a word and teach Transcriber the right spelling")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Fix a word").font(.headline)
                    TextField("It wrote (e.g. darker)", text: $wrong)
                    TextField("It should be (e.g. Docker)", text: $right)
                        .onSubmit(save)
                    Text("Fixes this dictation and all future ones, and adds the word to your vocabulary.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { isPresented = false }
                        Button("Fix & Learn", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(wrong.trimmingCharacters(in: .whitespaces).isEmpty
                                      || right.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
                .frame(width: 300)
            }
    }

    private func save() {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty else { return }
        Learning.learn(wrong: wrong, right: right)
        state.correct(entry.id, wrong: wrong, right: right)
        self.wrong = ""
        self.right = ""
        isPresented = false
    }
}

private struct HistoryTab: View {
    let state: AppState
    let controller: DictationController
    @AppStorage(Prefs.Key.keepHistory) private var keepHistory = true

    var body: some View {
        Form {
            Section {
                if state.history.isEmpty {
                    Text("Nothing dictated yet.").foregroundStyle(.secondary)
                }
                ForEach(state.history) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text).textSelection(.enabled)
                            Text("\(entry.date.formatted(date: .omitted, time: .shortened)) · \(String(format: "%.1f", entry.audioSeconds)) s audio · ready in \(Int(entry.latency * 1000)) ms")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FixWordButton(entry: entry, state: state)
                        Button { controller.copyToClipboard(entry.text) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy")
                    }
                }
            } header: {
                HStack {
                    Text("Recent dictations")
                    Spacer()
                    if !state.history.isEmpty {
                        Button("Clear") { state.clearHistory() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            } footer: {
                Text("Your last \(AppState.historyLimit) dictations, newest first. Handy when you dictated without a text field selected: copy it from here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep history after quitting", isOn: $keepHistory)
                    .onChange(of: keepHistory) { _, _ in state.saveHistory() }
            } footer: {
                Text(keepHistory
                     ? "Stored only on this Mac, in ~/Library/Application Support/Transcriber."
                     : "History is kept in memory only and cleared when Transcriber quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
