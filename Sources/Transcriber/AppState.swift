import AVFoundation
import Cocoa
import Observation
import TranscriberCore

/// Observable app-wide state shown in the menu and the settings window.
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle, recording, handsFree, transcribing
    }

    enum ModelStatus: Equatable {
        case missing, notLoaded, loading, ready
        case failed(String)
    }

    struct HistoryEntry: Identifiable, Codable {
        var id = UUID()
        let text: String
        let date: Date
        let audioSeconds: Double
        let latency: TimeInterval
    }

    static let historyLimit = 100
    private static let historyURL = ModelManager.directory.deletingLastPathComponent()
        .appendingPathComponent("history.json")

    var phase: Phase = .idle
    var modelStatus: ModelStatus = .notLoaded
    var accessibilityGranted = Permissions.accessibilityGranted
    var microphoneStatus = Permissions.microphoneStatus
    /// Newest first. Saved to disk unless "Keep history after quitting" is off.
    private(set) var history: [HistoryEntry] = []

    /// False for throwaway states (UI snapshots) that must never touch the saved history.
    private let persistent: Bool

    init(persistent: Bool = true) {
        self.persistent = persistent
        guard persistent, Prefs.keepHistory,
              let data = try? Data(contentsOf: Self.historyURL),
              let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = Array(saved.prefix(Self.historyLimit))
    }

    var needsSetup: Bool {
        !accessibilityGranted || microphoneStatus != .authorized || modelStatus == .missing
    }

    func refreshPermissions() {
        let accessibility = Permissions.accessibilityGranted
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        let microphone = Permissions.microphoneStatus
        if microphone != microphoneStatus { microphoneStatus = microphone }
    }

    func record(_ text: String, audioSeconds: Double, latency: TimeInterval) {
        history.insert(HistoryEntry(text: text, date: Date(), audioSeconds: audioSeconds, latency: latency), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        saveHistory()
    }

    /// Applies a correction to one saved dictation (case-insensitive, whole words).
    func correct(_ entryID: UUID, wrong: String, right: String) {
        guard let index = history.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = history[index]
        let fixed = TextProcessor.applyReplacements([Replacement(from: wrong, to: right)], to: entry.text)
        history[index] = HistoryEntry(id: entry.id, text: fixed, date: entry.date,
                                      audioSeconds: entry.audioSeconds, latency: entry.latency)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    /// Writes the history to disk, or deletes the file when keeping history is turned off.
    func saveHistory() {
        guard persistent else { return }
        guard Prefs.keepHistory, !history.isEmpty else {
            try? FileManager.default.removeItem(at: Self.historyURL)
            return
        }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: Self.historyURL, options: .atomic)
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to the Accessibility list.
    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static var microphoneStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

/// Short, quiet system sounds as feedback for starting and stopping.
final class Sounds {
    enum Effect { case start, lock, stop }

    private let start = NSSound(named: "Tink")
    private let lock = NSSound(named: "Morse")
    private let stop = NSSound(named: "Pop")

    func play(_ effect: Effect) {
        guard Prefs.playSounds else { return }
        let sound: NSSound?
        switch effect {
        case .start: sound = start
        case .lock: sound = lock
        case .stop: sound = stop
        }
        guard let sound else { return }
        sound.stop()
        sound.volume = 0.22
        sound.play()
    }
}
