import AVFoundation
import Cocoa
import Observation
import TranscriberCore

/// Wires everything together: ⌥ gestures → microphone → Whisper → clean-up → paste.
final class DictationController {
    let state: AppState
    let models: ModelManager
    /// Called whenever `state.phase` or the model status changes (menu bar icon refresh).
    var onStateChange: (() -> Void)?
    /// Opens the settings window (from the floating indicator).
    var openSettings: ((SettingsTab?) -> Void)?

    private let hud = RecordingHUD()
    private let recorder = AudioRecorder()
    private let engine = WhisperEngine()
    private let paster = Paster()
    private let sounds = Sounds()
    private let hotkeys = HotkeyMonitor()
    private var recognizer = GestureRecognizer()

    /// The microphone was started for the current gesture.
    private var capturing = false
    /// The app and text field the current dictation belongs to.
    private var pasteTarget: PasteTarget?
    /// Why the current gesture can't record (no model, no mic permission); shown only once
    /// the user clearly meant to dictate, so ⌥ shortcuts never trigger error popups.
    private var blockedReason: String?
    /// Recordings that were stopped and are being (or about to be) transcribed.
    private var pendingJobs = 0
    private var loadedModelPath: String?
    private var unloadWork: DispatchWorkItem?
    private var maxDurationWork: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var lastTrigger = Prefs.triggerKey
    private var lastModelID = Prefs.modelID

    /// Hands-free sessions stop automatically after this long.
    private let maxRecordingDuration: TimeInterval = 15 * 60
    /// Extra recording after release so the final syllable isn't cut off.
    private let releaseTail: TimeInterval = 0.15

    init(state: AppState, models: ModelManager) {
        self.state = state
        self.models = models
    }

    func start() {
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        hotkeys.setTrigger(Prefs.triggerKey)
        recorder.onLevel = { [weak self] rms in self?.hud.updateLevel(rms) }
        models.onInstalled = { [weak self] model in self?.modelInstalled(model) }
        hud.onClick = { [weak self] in self?.indicatorClicked() }
        hud.menuProvider = { [weak self] in self?.indicatorMenu() }

        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)

        startHotkeys()
        updateModelStatus()
        observeState()
        hud.setIdleStyle(idleStyle)
        hud.start()
        // Load right away so the first dictation after launch is instant. It is unloaded
        // again after the configured idle time.
        preloadModel()
    }

    func openModelsFolder() {
        NSWorkspace.shared.open(ModelManager.directory)
    }

    func copyToClipboard(_ text: String) {
        paster.copyToClipboard(text)
    }

    func requestMicrophone() {
        Permissions.requestMicrophone { [weak self] _ in
            self?.state.refreshPermissions()
            self?.onStateChange?()
        }
    }

    // MARK: - Floating indicator

    private func indicatorClicked() {
        if state.needsSetup && !recognizer.isCapturing {
            openSettings?(.setup)
            return
        }
        handle(.toggleHandsFree)
    }

    private func indicatorMenu() -> NSMenu {
        let menu = NSMenu()
        switch recognizer.state {
        case .idle:
            menu.addItem(ClosureMenuItem("Start Hands-Free Dictation") { [weak self] in self?.indicatorClicked() })
        case .locked, .lockedPressed:
            menu.addItem(ClosureMenuItem("Finish Dictation") { [weak self] in self?.handle(.toggleHandsFree) })
        default:
            break
        }
        if recognizer.isCapturing {
            menu.addItem(ClosureMenuItem("Stop Without Pasting") { [weak self] in self?.handle(.cancel) })
        }
        menu.addItem(.separator())
        if let last = state.history.first {
            menu.addItem(ClosureMenuItem("Copy Last Transcription") { [weak self] in self?.copyToClipboard(last.text) })
        }
        menu.addItem(ClosureMenuItem("Open History…") { [weak self] in self?.openSettings?(.history) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Hide When Idle", checked: !Prefs.indicatorAlwaysVisible) {
            Prefs.indicatorAlwaysVisible.toggle()
        })
        menu.addItem(ClosureMenuItem("Reset Position") { [weak self] in self?.hud.resetPosition() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…") { [weak self] in self?.openSettings?(nil) })
        return menu
    }

    private var idleStyle: HUDModel.IdleStyle {
        if state.needsSetup { return .attention }
        if state.modelStatus == .loading { return .loading }
        return .ready
    }

    /// Keeps the resting indicator and the menu bar icon in sync with permissions and model
    /// status, whichever part of the app changed them. Costs nothing while nothing changes.
    private func observeState() {
        let controller = MainThreadWeak(self)
        withObservationTracking {
            _ = state.needsSetup
            _ = state.modelStatus
        } onChange: {
            DispatchQueue.main.async {
                guard let self = controller.value else { return }
                self.hud.setIdleStyle(self.idleStyle)
                self.onStateChange?()
                self.observeState()
            }
        }
    }

    // MARK: - Gestures

    private func handle(_ event: GestureRecognizer.Event) {
        for action in recognizer.handle(event) {
            perform(action)
        }
        updateKeyboardMonitor()
        updateLivePreview()
        refreshPhase()
    }

    // MARK: - Live text

    private var previewTimer: Timer?
    private var previewInFlight = false
    /// Language detected by the first live pass of this dictation, reused by later passes so
    /// each update skips language detection.
    private var previewLanguage: String?

    /// Runs while a dictation is committed: about once a second the most recent audio is
    /// transcribed and shown in the pill. The final text still comes from the full recording.
    private func updateLivePreview() {
        let wanted = recognizer.isCommitted && Prefs.liveText
        if wanted && previewTimer == nil {
            previewLanguage = nil
            // Short tick: a new pass starts as soon as the previous one is done.
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.refreshLivePreview()
            }
        } else if !wanted && previewTimer != nil {
            previewTimer?.invalidate()
            previewTimer = nil
            hud.setLiveText("")
        }
    }

    private func refreshLivePreview() {
        guard recognizer.isCommitted, capturing, !previewInFlight, pendingJobs == 0,
              state.modelStatus == .ready,
              let model = models.activeModel(preferred: Prefs.modelID) else { return }
        // The last 8 s keep each pass around 0.3 s; the pill only shows the newest words anyway.
        let audio = recorder.snapshot(lastSeconds: 8)
        let analysis = SpeechDetector.analyze(audio)
        guard analysis.duration >= 0.8, analysis.containsSpeech else { return }

        var options = WhisperEngine.Options(language: previewLanguage ?? Prefs.language, autoLanguages: Prefs.autoLanguages,
                                            prompt: Prefs.prompt, accurate: false)
        options.preview = true
        var textOptions = Prefs.textOptions
        textOptions.appendSpace = false
        let processor = TextProcessor(options: textOptions)

        previewInFlight = true
        engine.transcribe(audio, modelPath: models.path(for: model), options: options) { [weak self] result in
            guard let self else { return }
            self.previewInFlight = false
            guard self.previewTimer != nil, case .success(let transcript) = result else { return }
            if self.previewLanguage == nil, transcript.language != "auto" { self.previewLanguage = transcript.language }
            let text = processor.process(transcript.text, speechSeconds: analysis.speechSeconds, prompt: options.prompt)
            self.hud.setLiveText(text.replacingOccurrences(of: "\n", with: " "))
        }
    }

    private func updateKeyboardMonitor() {
        let escapeCancels: Bool
        switch recognizer.state {
        case .pressed, .holding: escapeCancels = true
        default: escapeCancels = false
        }
        hotkeys.setGestureActive(recognizer.isCapturing, escapeCancels: escapeCancels,
                                 holdingForDictation: recognizer.state == .holding)
    }

    private func perform(_ action: GestureRecognizer.Action) {
        switch action {
        case .beginCapture:
            blockedReason = readinessProblem()
            guard blockedReason == nil else { return }
            if Prefs.micStart == .instant { startCapture() }
            preloadModel() // loads while the user speaks if it was unloaded

        case .confirmPushToTalk:
            guard commit() else { return }
            pasteTarget = PasteTarget.current()
            sounds.play(.start)
            startMaxDurationTimer()

        case .lockHandsFree:
            guard commit() else { return }
            pasteTarget = PasteTarget.current()
            recorder.resetBuffer() // drop the key-tap noise; the dictation starts now
            sounds.play(.lock)
            startMaxDurationTimer()

        case .finish, .finishWithoutPaste:
            maxDurationWork?.cancel()
            guard capturing else { return }
            capturing = false
            pendingJobs += 1
            sounds.play(.stop)
            let delivery: Delivery = action == .finishWithoutPaste
                ? .historyOnly
                : .paste(into: Prefs.pasteIntoOrigin ? pasteTarget : nil)
            pasteTarget = nil
            recorder.stop(tail: releaseTail) { [weak self] samples in
                self?.transcribe(samples, delivery: delivery)
            }

        case .discard:
            maxDurationWork?.cancel()
            if capturing {
                recorder.discard()
                capturing = false
            }

        case .scheduleHoldTimer(let generation, let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.handle(.holdElapsed(generation: generation))
            }

        case .scheduleTapWindow(let generation, let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.handle(.tapWindowElapsed(generation: generation))
            }
        }
    }

    /// The user clearly wants to dictate. Returns false (and explains why) if we can't.
    private func commit() -> Bool {
        if let reason = blockedReason {
            if Permissions.microphoneStatus == .notDetermined { requestMicrophone() }
            recognizer.reset()
            hud.flash(reason, duration: 2.5)
            return false
        }
        if !capturing { startCapture() }
        return true
    }

    private func startCapture() {
        capturing = true
        recorder.start(deviceUID: Prefs.inputDeviceUID) { [weak self] error in
            guard let self, let error else { return }
            self.capturing = false
            if self.recognizer.isCapturing {
                self.recognizer.reset()
                self.updateKeyboardMonitor()
            }
            self.hud.flash(error.localizedDescription, symbol: "mic.slash")
            self.refreshPhase()
        }
    }

    private func readinessProblem() -> String? {
        if models.activeModel(preferred: Prefs.modelID) == nil {
            return "Download a speech model in Settings"
        }
        switch Permissions.microphoneStatus {
        case .authorized:
            return nil
        case .notDetermined:
            return "Allow microphone access, then try again"
        default:
            return "Microphone access is off (System Settings › Privacy)"
        }
    }

    private func startMaxDurationTimer() {
        maxDurationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recognizer.isCommitted else { return }
            self.recognizer.reset()
            self.updateKeyboardMonitor()
            self.perform(.finish)
            self.refreshPhase()
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingDuration, execute: work)
    }

    // MARK: - Transcription

    private enum Delivery {
        /// Paste into the given app/field (nil: whatever is in front when the text is ready).
        case paste(into: PasteTarget?)
        /// Cancelled: keep the text in History only.
        case historyOnly
    }

    private func transcribe(_ samples: [Float], delivery: Delivery) {
        let analysis = SpeechDetector.analyze(samples)
        guard analysis.duration >= 0.25, analysis.containsSpeech,
              let model = models.activeModel(preferred: Prefs.modelID) else {
            pendingJobs -= 1
            refreshPhase()
            if analysis.duration > 1.0, !recognizer.isCommitted {
                hud.flash("No speech detected", symbol: "waveform.slash", duration: 1.2)
            }
            return
        }

        let options = WhisperEngine.Options(language: Prefs.language, autoLanguages: Prefs.autoLanguages,
                                            prompt: Prefs.prompt, accurate: Prefs.accurateDecoding)
        let processor = TextProcessor(options: Prefs.textOptions)
        let restoreClipboard = Prefs.restoreClipboard
        let path = models.path(for: model)
        let stoppedAt = CFAbsoluteTimeGetCurrent()

        if loadedModelPath != path { preloadModel() }
        unloadWork?.cancel()

        engine.transcribe(samples, modelPath: path, options: options) { [weak self] result in
            guard let self else { return }
            self.pendingJobs -= 1

            switch result {
            case .success(let transcript):
                let text = processor.process(transcript.text, speechSeconds: analysis.speechSeconds, prompt: options.prompt)
                if !text.isEmpty {
                    let latency = CFAbsoluteTimeGetCurrent() - stoppedAt + self.releaseTail
                    self.state.record(text, audioSeconds: transcript.audioSeconds, latency: latency)
                    switch delivery {
                    case .historyOnly:
                        self.hud.flash("Saved to History, not pasted", symbol: "clock.arrow.circlepath", duration: 2)
                    case .paste(let target):
                        if let target {
                            target.restore { self.paster.paste(text, restoreClipboard: restoreClipboard) }
                        } else {
                            self.paster.paste(text, restoreClipboard: restoreClipboard)
                        }
                    }
                }
            case .failure(let error):
                self.loadedModelPath = nil
                self.state.modelStatus = .failed(error.localizedDescription)
                self.hud.flash(error.localizedDescription)
            }
            self.refreshPhase()
            self.scheduleUnload()
        }
    }

    // MARK: - Model lifecycle

    private func preloadModel() {
        guard let model = models.activeModel(preferred: Prefs.modelID) else {
            updateModelStatus()
            return
        }
        let path = models.path(for: model)
        guard loadedModelPath != path else { return }

        unloadWork?.cancel()
        loadedModelPath = path
        state.modelStatus = .loading
        onStateChange?()
        engine.preload(modelPath: path) { [weak self] result in
            guard let self, self.loadedModelPath == path else { return }
            switch result {
            case .success:
                self.state.modelStatus = .ready
                self.scheduleUnload()
            case .failure(let error):
                self.loadedModelPath = nil
                self.state.modelStatus = .failed(error.localizedDescription)
            }
            self.onStateChange?()
        }
    }

    private func scheduleUnload() {
        unloadWork?.cancel()
        let policy = Prefs.unloadPolicy
        guard policy != .never, loadedModelPath != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.recognizer.isCapturing, self.pendingJobs == 0 else {
                self.scheduleUnload() // busy right now; try again later
                return
            }
            self.engine.unload()
            self.loadedModelPath = nil
            self.state.modelStatus = .notLoaded
            self.onStateChange?()
        }
        unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(policy.rawValue) * 60, execute: work)
    }

    private func modelInstalled(_ model: WhisperModel) {
        // Adopt the freshly downloaded model if the selected one isn't available.
        if !models.installed.contains(Prefs.modelID) || Prefs.modelID == model.id {
            Prefs.modelID = model.id
            lastModelID = model.id
        }
        updateModelStatus()
        preloadModel()
    }

    private func updateModelStatus() {
        if models.activeModel(preferred: Prefs.modelID) == nil {
            state.modelStatus = .missing
        } else if state.modelStatus == .missing {
            state.modelStatus = .notLoaded
        }
        onStateChange?()
    }

    // MARK: - Settings & permissions

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [self] in
            let trigger = Prefs.triggerKey
            if trigger != lastTrigger {
                lastTrigger = trigger
                hotkeys.setTrigger(trigger)
            }
            hud.preferencesChanged()
            let modelID = Prefs.modelID
            if modelID != lastModelID {
                lastModelID = modelID
                updateModelStatus()
                if loadedModelPath != nil { preloadModel() }
            }
        }
    }

    private func startHotkeys() {
        state.refreshPermissions()
        if state.accessibilityGranted, hotkeys.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            onStateChange?()
            return
        }
        // Poll until the user grants Accessibility; creating the tap then just works.
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.startHotkeys()
        }
    }

    private func refreshPhase() {
        let phase: AppState.Phase
        switch recognizer.state {
        case .holding: phase = .recording
        case .locked, .lockedPressed: phase = .handsFree
        default: phase = pendingJobs > 0 ? .transcribing : .idle
        }

        switch phase {
        case .recording: hud.setActivity(.recording)
        case .handsFree: hud.setActivity(.handsFree)
        case .transcribing: hud.setActivity(.transcribing)
        case .idle: hud.setActivity(.none)
        }

        if phase != state.phase {
            state.phase = phase
            onStateChange?()
        }
    }
}

/// Hands a weak reference across a `@Sendable` boundary; only dereferenced on the main thread.
private final class MainThreadWeak<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}
