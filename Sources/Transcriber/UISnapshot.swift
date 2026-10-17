import Cocoa
import SwiftUI

/// Developer tool: renders the settings tabs and HUD states to PNG files without showing
/// any windows (no Screen Recording permission needed).
///
///     Transcriber --snapshot-ui /path/to/output-dir
enum UISnapshot {
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot-ui"), index + 1 < args.count else { return nil }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let state = AppState(persistent: false)
        let models = ModelManager()
        let controller = DictationController(state: state, models: models)
        state.modelStatus = models.installed.isEmpty ? .missing : .ready
        state.record("Can you ask ChatGPT and Claude to review the Kubernetes deployment?", audioSeconds: 4.2, latency: 0.41)
        state.record("Wir treffen uns morgen um fünf Uhr.", audioSeconds: 2.1, latency: 0.33)
        state.record("Let's move the auth to Supabase and wire it up with LangChain.", audioSeconds: 3.8, latency: 0.38)
        state.record("Supabase is ready, and LangChain runs locally with Ollama and Ollama tools.", audioSeconds: 4.4, latency: 0.41)

        let navigation = SettingsNavigation()
        for tab in [SettingsTab.setup, .general, .model, .vocabulary, .history] {
            navigation.tab = tab
            let view = SettingsView(navigation: navigation, state: state, models: models, controller: controller)
            write(render(view, size: NSSize(width: 620, height: 560)), to: directory.appendingPathComponent("settings-\(tab.rawValue).png"))
        }

        let hudModel = HUDModel()
        for level in [0.02, 0.05, 0.12, 0.2, 0.08, 0.3, 0.15, 0.06, 0.1, 0.25, 0.04] as [Float] { hudModel.push(rms: level) }
        let modes: [(String, HUDModel.Mode)] = [
            ("idle", .idle(.ready)), ("idle-attention", .idle(.attention)), ("idle-loading", .idle(.loading)),
            ("recording", .recording), ("handsfree", .handsFree), ("transcribing", .transcribing),
            ("message", .message("No speech detected", symbol: "waveform.slash")),
            ("live", .recording), ("live-handsfree", .handsFree),
        ] + PillTheme.allCases.map { ("theme-\($0.rawValue)", HUDModel.Mode.recording) }
        for (name, mode) in modes {
            hudModel.mode = mode
            hudModel.theme = PillTheme(rawValue: String(name.dropFirst(6))) ?? .graphite
            hudModel.liveText = name.hasPrefix("live") || name.hasPrefix("theme")
                ? "So the plan is to move the auth over to Supabase and then test the MCP server tomorrow" : ""
            let pill = RecordingHUD.pillSize(for: mode, liveText: hudModel.liveText)
            let size = NSSize(width: pill.width + 2 * RecordingHUD.margin, height: pill.height + 2 * RecordingHUD.margin)
            write(render(RecordingHUD.previewView(model: hudModel), size: size),
                  to: directory.appendingPathComponent("hud-\(name).png"))
        }
        print("Wrote snapshots to \(directory.path)")
        return 0
    }

    private static func render<V: View>(_ view: V, size: NSSize) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to url: URL) {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
