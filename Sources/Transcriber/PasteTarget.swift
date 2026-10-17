import Cocoa

/// Where a dictation started: the app and, when Accessibility exposes it, the exact text
/// field. If the user wanders off to other apps while dictating, the text is delivered back
/// here instead of into whatever happens to be in front when they finish.
struct PasteTarget {
    let app: NSRunningApplication
    let element: AXUIElement?

    /// The frontmost app and its focused element, or nil if that is Transcriber itself.
    static func current() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value)
        let element = result == .success && value != nil && CFGetTypeID(value) == AXUIElementGetTypeID()
            ? (value as! AXUIElement) : nil
        return PasteTarget(app: app, element: element)
    }

    /// Brings the original app, window and text field back to the front, then calls `ready`
    /// on the main thread. Calls it right away when nothing needs to move.
    func restore(then ready: @escaping () -> Void) {
        guard !app.isTerminated else { return ready() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sameApp = frontmost == app.processIdentifier
        if sameApp && !focusMoved { return ready() }

        if let window = elementWindow {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if !sameApp {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate()
        }
        waitUntilFrontmost(deadline: Date().addingTimeInterval(1.0)) {
            if let element {
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            // Give the app a moment to put the caret back before ⌘V arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: ready)
        }
    }

    /// True when a different element of the same app has focus now (another window or field).
    private var focusMoved: Bool {
        guard let element else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return false }
        return !CFEqual(value, element)
    }

    private var elementWindow: AXUIElement? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func waitUntilFrontmost(deadline: Date, then: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || Date() > deadline {
            return then()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            waitUntilFrontmost(deadline: deadline, then: then)
        }
    }
}
