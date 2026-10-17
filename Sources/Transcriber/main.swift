import Cocoa

Prefs.registerDefaults()

if let exitCode = CommandLineMode.runIfRequested() ?? UISnapshot.runIfRequested() {
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Starts as a menu bar app (LSUIElement); AppDelegate adds the Dock icon if enabled.
app.setActivationPolicy(.accessory)
app.run()
