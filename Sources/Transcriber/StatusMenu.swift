import Cocoa

/// The menu bar icon and its menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let state: AppState
    private let models: ModelManager
    private let controller: DictationController
    private let openSettings: (SettingsTab?) -> Void

    private static let quickLanguages = ["auto", "en", "de", "fr", "es"]

    init(state: AppState, models: ModelManager, controller: DictationController,
         openSettings: @escaping (SettingsTab?) -> Void) {
        self.state = state
        self.models = models
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Transcriber"
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        let symbol: String
        var tint: NSColor?
        switch state.phase {
        case .recording, .handsFree:
            symbol = "waveform.circle.fill"
            tint = .systemRed
        case .transcribing:
            symbol = "ellipsis.circle"
        case .idle:
            symbol = state.needsSetup ? "exclamationmark.triangle" : "waveform"
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Transcriber")
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.appearsDisabled = state.phase == .idle && state.modelStatus == .loading
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        state.refreshPermissions()
        menu.removeAllItems()

        menu.addItem(disabled(statusLine()))
        if state.needsSetup {
            menu.addItem(action("Finish Setup…", #selector(showSetup)))
        }

        let recent = state.history.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("Recent (click to copy)"))
            for entry in recent {
                let title = entry.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                let menuItem = action(title.count > 48 ? String(title.prefix(47)) + "…" : title, #selector(copyEntry(_:)))
                menuItem.representedObject = entry.text
                menuItem.toolTip = entry.text
                menu.addItem(menuItem)
            }
        }

        menu.addItem(.separator())
        if let last = state.history.first {
            let copyLast = action("Copy Last Transcription", #selector(copyEntry(_:)))
            copyLast.representedObject = last.text
            menu.addItem(copyLast)
        }
        menu.addItem(action("Open History…", #selector(showHistory)))
        menu.addItem(.separator())
        menu.addItem(submenuItem("Model", buildModelMenu()))
        menu.addItem(submenuItem("Language", buildLanguageMenu()))

        menu.addItem(.separator())
        let settings = action("Settings…", #selector(showSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Transcriber", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        if !state.accessibilityGranted { return "Needs Accessibility permission" }
        if state.microphoneStatus != .authorized { return "Needs microphone access" }
        switch state.phase {
        case .recording: return "Recording…"
        case .handsFree: return "Recording hands-free (press \(Prefs.triggerKey.keyName) to finish)"
        case .transcribing: return "Transcribing…"
        case .idle: break
        }
        switch state.modelStatus {
        case .missing: return "No speech model downloaded"
        case .loading: return "Loading model…"
        case .failed(let message): return message
        case .ready, .notLoaded: return "Ready: hold \(Prefs.triggerKey.keyName) to dictate"
        }
    }

    private func buildModelMenu() -> NSMenu {
        let submenu = NSMenu()
        let active = models.activeModel(preferred: Prefs.modelID)?.id
        for model in models.models where models.installed.contains(model.id) {
            let menuItem = action(model.name, #selector(selectModel(_:)))
            menuItem.representedObject = model.id
            menuItem.state = model.id == active ? .on : .off
            submenu.addItem(menuItem)
        }
        if submenu.items.isEmpty { submenu.addItem(disabled("No models downloaded")) }
        submenu.addItem(.separator())
        submenu.addItem(action("Manage Models…", #selector(showModels)))
        return submenu
    }

    private func buildLanguageMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = Prefs.language
        var codes = Self.quickLanguages
        if !codes.contains(current) { codes.append(current) }
        for code in codes {
            guard let language = Language.all.first(where: { $0.code == code }) else { continue }
            let menuItem = action(language.name, #selector(selectLanguage(_:)))
            menuItem.representedObject = code
            menuItem.state = code == current ? .on : .off
            submenu.addItem(menuItem)
        }
        submenu.addItem(.separator())
        submenu.addItem(action("More Languages…", #selector(showSettings)))
        return submenu
    }

    // MARK: - Actions

    @objc private func copyEntry(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { controller.copyToClipboard(text) }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Prefs.modelID = id }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { UserDefaults.standard.set(code, forKey: Prefs.Key.language) }
    }

    @objc private func showSettings() { openSettings(.general) }
    @objc private func showSetup() { openSettings(.setup) }
    @objc private func showHistory() { openSettings(.history) }
    @objc private func showModels() { openSettings(.model) }

    // MARK: - Helpers

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }
}
