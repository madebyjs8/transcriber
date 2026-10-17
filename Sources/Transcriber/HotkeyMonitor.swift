import Cocoa
import os
import TranscriberCore

/// Watches the keyboard system-wide for the trigger key (⌥) with a CGEventTap.
///
/// The tap runs on its own thread with its own run loop so that a busy main thread can
/// never delay the user's typing. The callback only inspects a few fields and forwards
/// gesture events to the main thread; it never blocks.
final class HotkeyMonitor {
    /// Delivered on the main thread.
    var onEvent: ((GestureRecognizer.Event) -> Void)?

    /// Marks events we synthesise ourselves (the ⌘V paste) so the tap ignores them.
    static let syntheticEventMarker: Int64 = 0x5452_4E53 // "TRNS"

    private static let escapeKeyCode: Int64 = 53

    /// A physical modifier key. Left and right keys share a flag (e.g. ⌥), so they are told
    /// apart by IOKit's device-dependent bits (NX_DEVICELALTKEYMASK etc.).
    private struct ModifierKey {
        let keyCode: Int64
        let deviceMask: UInt64?
        let family: CGEventFlags

        func isDown(_ flags: CGEventFlags) -> Bool {
            if let deviceMask { return flags.rawValue & deviceMask != 0 }
            return flags.contains(family)
        }

        static let leftOption = ModifierKey(keyCode: 58, deviceMask: 0x20, family: .maskAlternate)
        static let rightOption = ModifierKey(keyCode: 61, deviceMask: 0x40, family: .maskAlternate)
        static let leftCommand = ModifierKey(keyCode: 55, deviceMask: 0x08, family: .maskCommand)
        static let rightCommand = ModifierKey(keyCode: 54, deviceMask: 0x10, family: .maskCommand)
        static let fn = ModifierKey(keyCode: 63, deviceMask: nil, family: .maskSecondaryFn)

        static func triggers(for trigger: TriggerKey) -> [ModifierKey] {
            switch trigger {
            case .either: return [.leftOption, .rightOption]
            case .right: return [.rightOption]
            case .left: return [.leftOption]
            case .rightCommand: return [.rightCommand]
            case .fn: return [.fn]
            }
        }

        /// The other key(s) that set the same flag, e.g. left ⌘ for right ⌘.
        var siblings: [ModifierKey] {
            [ModifierKey.leftOption, .rightOption, .leftCommand, .rightCommand]
                .filter { $0.family == family && $0.keyCode != keyCode }
        }
    }

    private struct Shared {
        var trigger: TriggerKey = .either
        /// Set by the controller while a gesture/recording is in progress.
        var gestureActive = false
        /// Esc cancels only while the trigger is held (push-to-talk); during hands-free
        /// dictation it belongs to the apps the user is browsing.
        var escapeCancels = false
        /// Push-to-talk is under way: the held trigger key is for dictation, not a modifier,
        /// so it is removed from mouse events (a click stays a click, not a ⌘-click).
        var holdingForDictation = false
        var heldTriggerKeyCode: Int64?
        var swallowedEscapeDown = false
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    var isRunning: Bool { tap != nil }

    func setTrigger(_ trigger: TriggerKey) {
        shared.withLock {
            $0.trigger = trigger
            $0.heldTriggerKeyCode = nil
        }
    }

    /// While active, keys/clicks are reported (to detect shortcuts) and Escape is swallowed.
    func setGestureActive(_ active: Bool, escapeCancels: Bool, holdingForDictation: Bool) {
        shared.withLock {
            $0.gestureActive = active
            $0.escapeCancels = escapeCancels
            $0.holdingForDictation = holdingForDictation
        }
    }

    /// Returns false when the tap cannot be created (Accessibility permission missing).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Transcriber.HotkeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoop { CFRunLoopStop(runLoop) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoop = nil
        self.thread = nil
    }

    // MARK: - Tap thread

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .flagsChanged:
            handleFlagsChanged(event)
            return pass

        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker { return pass }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let (active, triggerHeld, escapeCancels) = shared.withLock {
                ($0.gestureActive, $0.heldTriggerKeyCode != nil, $0.escapeCancels)
            }
            if keyCode == Self.escapeKeyCode && escapeCancels {
                shared.withLock { $0.swallowedEscapeDown = true }
                deliver(.cancel)
                return nil
            }
            // Report keys while the trigger is physically held (⌥+key shortcut) or a gesture
            // is in progress. Otherwise stay silent so idle typing costs nothing.
            if active || triggerHeld { deliver(.otherInput) }
            return pass

        case .keyUp:
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
                let swallow = shared.withLock { state -> Bool in
                    defer { state.swallowedEscapeDown = false }
                    return state.swallowedEscapeDown
                }
                if swallow { return nil }
            }
            return pass

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let report = shared.withLock { $0.gestureActive || $0.heldTriggerKeyCode != nil }
            if report { deliver(.otherInput) }
            removeTriggerModifier(from: event)
            return pass

        case .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel:
            removeTriggerModifier(from: event)
            return pass

        default:
            return pass
        }
    }

    /// While push-to-talk holds the trigger, mouse events shouldn't carry it: with right ⌘ as
    /// trigger, clicking a Dock icon would otherwise "Show in Finder" and links would open in
    /// new tabs. Left alone if the sibling key (e.g. left ⌘) is genuinely held as well.
    private func removeTriggerModifier(from event: CGEvent) {
        let key: ModifierKey? = shared.withLock { state in
            guard state.holdingForDictation, let code = state.heldTriggerKeyCode else { return nil }
            return ModifierKey.triggers(for: state.trigger).first { $0.keyCode == code }
        }
        guard let key else { return }
        var flags = event.flags
        guard !key.siblings.contains(where: { $0.isDown(flags) }) else { return }
        flags.remove(key.family)
        if let deviceMask = key.deviceMask {
            flags = CGEventFlags(rawValue: flags.rawValue & ~deviceMask)
        }
        event.flags = flags
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let output: GestureRecognizer.Event? = shared.withLock { state in
            let reportOther = state.gestureActive || state.heldTriggerKeyCode != nil
            guard let key = ModifierKey.triggers(for: state.trigger).first(where: { $0.keyCode == keyCode }) else {
                // Another modifier changed (⇧, ⌃, the other ⌥/⌘…): a shortcut is being formed.
                return reportOther ? .otherInput : nil
            }

            // "Alone" means no other modifier family is held (fn is ignored unless it is the
            // trigger, since arrow and function keys set it), and not the sibling key either.
            let otherFamilies = CGEventFlags([.maskCommand, .maskControl, .maskShift, .maskAlternate]).subtracting(key.family)
            let otherModifiersHeld = !flags.intersection(otherFamilies).isEmpty
                || key.siblings.contains { $0.isDown(flags) }

            if key.isDown(flags) {
                if state.heldTriggerKeyCode == nil && !otherModifiersHeld {
                    state.heldTriggerKeyCode = keyCode
                    return .triggerDown
                }
                return reportOther ? .otherInput : nil
            }
            if state.heldTriggerKeyCode == keyCode {
                state.heldTriggerKeyCode = nil
                return .triggerUp
            }
            return nil
        }
        if let output { deliver(output) }
    }

    private func deliver(_ event: GestureRecognizer.Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
