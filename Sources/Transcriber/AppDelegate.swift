import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let models = ModelManager()
    private var controller: DictationController!
    private var statusMenu: StatusMenu!
    private var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would both paste every dictation.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        installMainMenu()
        applyDockPreference()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)

        controller = DictationController(state: state, models: models)
        settings = SettingsWindowController(state: state, models: models, controller: controller)
        statusMenu = StatusMenu(state: state, models: models, controller: controller) { [weak self] tab in
            self?.settings.show(tab: tab)
        }
        controller.onStateChange = { [weak self] in self?.statusMenu.refresh() }
        controller.openSettings = { [weak self] tab in self?.settings.show(tab: tab) }
        controller.start()

        if !Prefs.didOnboard || state.needsSetup {
            Prefs.didOnboard = true
            settings.show(tab: .setup)
        }
    }

    /// Clicking the Dock icon or launching the app again (Finder, Spotlight) opens History,
    /// or Setup while something is still missing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(tab: state.needsSetup ? .setup : .history)
        return false
    }

    // MARK: - Dock and menus

    private var showsInDock: Bool?

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { self.applyDockPreference() }
    }

    /// With a Dock icon the app behaves like a normal app (Dock, ⌘-Tab); without one it
    /// lives only in the menu bar.
    private func applyDockPreference() {
        let show = Prefs.showInDock
        guard show != showsInDock else { return }
        showsInDock = show
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if !show, let settings, settings.isVisible {
            // Turning the Dock icon off deactivates the app; keep the settings window in front.
            DispatchQueue.main.async { settings.show(tab: nil) }
        }
    }

    /// Standard menus. Even without a Dock icon these matter: ⌘C, ⌘V, ⌘A and ⌘Z in text
    /// fields are dispatched through the main menu's Edit items.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Transcriber", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem("Settings…", keyEquivalent: ",") { [weak self] in self?.settings.show(tab: .general) })
        appMenu.addItem(ClosureMenuItem("History", keyEquivalent: "y") { [weak self] in self?.settings.show(tab: .history) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Transcriber", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Transcriber", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        for menu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
