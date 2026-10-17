import Foundation

/// Turns raw trigger-key activity into dictation intents.
///
///  - Hold the trigger key → push-to-talk; releasing it finishes.
///  - Double-tap the trigger key → hands-free (locked) recording; the next press finishes.
///  - Trigger key combined with any other key/modifier/click → it was a shortcut; discard.
///  - Escape while recording → discard.
///
/// Recording starts tentatively on the very first press so no speech is lost; the
/// recognizer later decides whether that audio is kept or thrown away.
///
/// The recognizer is a pure value type. It never touches timers directly: it asks the
/// caller to schedule them and expects the matching `*Elapsed(generation)` event back.
/// Stale timers are ignored by comparing generations.
public struct GestureRecognizer {
    public enum Event: Equatable {
        /// Trigger key went down while no other modifier was held.
        case triggerDown
        /// Trigger key went up.
        case triggerUp
        /// Another key, modifier or mouse button was used.
        case otherInput
        /// Escape was pressed.
        case cancel
        /// The floating indicator was clicked: start or finish hands-free dictation.
        case toggleHandsFree
        case holdElapsed(generation: Int)
        case tapWindowElapsed(generation: Int)
    }

    public enum Action: Equatable {
        /// Start capturing audio tentatively (could still turn out to be a tap or shortcut).
        case beginCapture
        /// The key has been held long enough: this is push-to-talk, show the indicator.
        case confirmPushToTalk
        /// Double tap detected: keep recording hands-free until the next press.
        case lockHandsFree
        /// Stop, transcribe and paste.
        case finish
        /// Stop and transcribe into History without pasting (a cancelled dictation is never lost).
        case finishWithoutPaste
        /// Stop and throw the audio away.
        case discard
        case scheduleHoldTimer(generation: Int, after: TimeInterval)
        case scheduleTapWindow(generation: Int, after: TimeInterval)
    }

    public enum State: Equatable {
        case idle
        /// Trigger is down; not yet known whether this is a hold, a tap or a shortcut.
        case pressed
        /// Push-to-talk confirmed.
        case holding
        /// A quick tap happened; waiting to see whether a second tap follows.
        case awaitingSecondTap
        /// Hands-free recording. `ignoreNextUp` swallows the release of the tap that locked it.
        case locked(ignoreNextUp: Bool)
        /// Trigger pressed during hands-free recording; releasing it finishes.
        case lockedPressed
    }

    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    public private(set) var state: State = .idle
    private var generation = 0

    public init(holdThreshold: TimeInterval = 0.2, doubleTapWindow: TimeInterval = 0.4) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    /// True while audio is (tentatively or definitely) being captured.
    public var isCapturing: Bool { state != .idle }

    /// True once the user has clearly committed to dictating (indicator visible).
    public var isCommitted: Bool {
        switch state {
        case .holding, .locked, .lockedPressed: return true
        default: return false
        }
    }

    public mutating func reset() {
        state = .idle
        generation += 1
    }

    public mutating func handle(_ event: Event) -> [Action] {
        switch (state, event) {
        case (.idle, .triggerDown):
            state = .pressed
            generation += 1
            return [.beginCapture, .scheduleHoldTimer(generation: generation, after: holdThreshold)]

        case (.pressed, .holdElapsed(let g)) where g == generation:
            state = .holding
            return [.confirmPushToTalk]

        case (.pressed, .triggerUp):
            // Quick tap. Keep the microphone running in case a second tap locks recording.
            state = .awaitingSecondTap
            generation += 1
            return [.scheduleTapWindow(generation: generation, after: doubleTapWindow)]

        case (.holding, .triggerUp):
            state = .idle
            return [.finish]

        case (.pressed, .otherInput), (.awaitingSecondTap, .otherInput):
            // The trigger was used as a modifier (e.g. ⌥← or ⌥L), or typing continued after a tap.
            state = .idle
            return [.discard]

        case (.holding, .otherInput):
            // Push-to-talk is under way: clicking around or switching apps (⌘-Tab) while
            // talking must not throw the dictation away.
            return []

        case (.awaitingSecondTap, .tapWindowElapsed(let g)) where g == generation:
            state = .idle
            return [.discard]

        case (.awaitingSecondTap, .triggerDown):
            state = .locked(ignoreNextUp: true)
            return [.lockHandsFree]

        case (.locked(ignoreNextUp: true), .triggerUp):
            state = .locked(ignoreNextUp: false)
            return []

        case (.locked, .triggerDown):
            // Also covers a missed key-up while ignoreNextUp is still set.
            state = .lockedPressed
            return []

        case (.lockedPressed, .triggerUp):
            state = .idle
            return [.finish]

        case (.lockedPressed, .otherInput):
            // The trigger was used as a modifier mid-dictation; keep recording.
            state = .locked(ignoreNextUp: true)
            return []

        case (.idle, .toggleHandsFree):
            state = .locked(ignoreNextUp: false)
            generation += 1
            return [.beginCapture, .lockHandsFree]

        case (.locked, .toggleHandsFree), (.lockedPressed, .toggleHandsFree):
            state = .idle
            return [.finish]

        case (.idle, .cancel):
            return []

        case (.holding, .cancel), (.locked, .cancel), (.lockedPressed, .cancel):
            // Cancelling a real dictation keeps the words (in History) but doesn't paste them.
            state = .idle
            return [.finishWithoutPaste]

        case (_, .cancel):
            state = .idle
            return [.discard]

        default:
            return []
        }
    }
}
