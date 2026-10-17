import Cocoa
import Observation
import SwiftUI

@Observable
final class HUDModel {
    enum IdleStyle: Equatable {
        case ready, attention, loading
    }

    enum Mode: Equatable {
        case idle(IdleStyle)
        case recording
        case handsFree
        case transcribing
        case message(String, symbol: String)

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var isListening: Bool { self == .recording || self == .handsFree }
    }

    static let barCount = 11

    var mode: Mode = .idle(.ready)
    /// Name of the configured trigger key, for the hands-free hint.
    var triggerName = "⌥"
    /// Words recognised so far while recording (empty when live text is off or not ready yet).
    var liveText = ""
    var theme: PillTheme = .graphite
    /// Recent loudness values (0…1), newest last, drawn as a scrolling waveform.
    var levels: [CGFloat] = Array(repeating: 0, count: barCount)

    func push(rms: Float) {
        // Map roughly -55 dBFS…-10 dBFS onto 0…1.
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = CGFloat(min(max((db + 55) / 45, 0), 1))
        levels.removeFirst()
        levels.append(normalized)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// The floating pill that shows Transcriber is running.
///
/// It rests as a small pill (always visible by default), slides out from the nearest screen
/// edge when it appears, and expands while recording or transcribing. The user can drag it
/// anywhere (the position is remembered), click it to start or finish hands-free dictation,
/// and right-click it for options. It is a non-activating panel, so clicking it never takes
/// focus away from the text field being dictated into.
final class RecordingHUD {
    enum Activity: Equatable {
        case none, recording, handsFree, transcribing
    }

    let model = HUDModel()
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    /// Transparent space around the pill for its shadow.
    static let margin: CGFloat = 8

    private var panel: NSPanel?
    private var isShown = false
    private var activity: Activity = .none
    private var idleStyle: HUDModel.IdleStyle = .ready
    private var message: (text: String, symbol: String)?
    private var messageWork: DispatchWorkItem?
    private var drag: (mouse: NSPoint, origin: NSPoint)?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.render(animated: false)
        }
    }

    // MARK: - API

    func start() {
        model.triggerName = Prefs.triggerKey.keyName
        model.theme = PillTheme.current
        render()
    }

    func setActivity(_ activity: Activity) {
        guard activity != self.activity else { return }
        self.activity = activity
        if activity != .none {
            message = nil
            messageWork?.cancel()
        }
        render()
    }

    func setIdleStyle(_ style: HUDModel.IdleStyle) {
        guard style != idleStyle else { return }
        idleStyle = style
        render()
    }

    /// Shows a short message, then returns to the resting pill.
    func flash(_ text: String, symbol: String = "exclamationmark.circle", duration: TimeInterval = 1.8) {
        message = (text, symbol)
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.message = nil
            self?.render()
        }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        render()
    }

    /// Shows the words recognised so far; the pill widens to fit (up to a limit).
    func setLiveText(_ text: String) {
        guard text != model.liveText else { return }
        model.liveText = text
        render()
    }

    func updateLevel(_ rms: Float) {
        guard isShown, model.mode.isListening else { return }
        model.push(rms: rms)
    }

    /// Visibility or position settings changed.
    func preferencesChanged() {
        model.triggerName = Prefs.triggerKey.keyName
        if model.theme != PillTheme.current { model.theme = PillTheme.current }
        render()
    }

    func resetPosition() {
        IndicatorPosition.reset()
        render()
    }

    // MARK: - Rendering

    private var displayMode: HUDModel.Mode {
        switch activity {
        case .recording: return .recording
        case .handsFree: return .handsFree
        case .transcribing: return .transcribing
        case .none: break
        }
        if let message { return .message(message.text, symbol: message.symbol) }
        return .idle(idleStyle)
    }

    private func render(animated: Bool = true) {
        let mode = displayMode
        if mode != model.mode {
            if mode.isListening && !model.mode.isListening { model.resetLevels() }
            model.mode = mode
        }

        let visible = !mode.isIdle || Prefs.indicatorAlwaysVisible
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let target = frame(for: mode)

        if visible && !isShown {
            isShown = true
            emerge(panel, to: target, animated: animated)
        } else if visible {
            resize(panel, to: target, animated: animated)
        } else if isShown {
            isShown = false
            retreat(panel)
        }
    }

    /// Widest the live text gets before it scrolls (older words drop off the left).
    static let maxLiveTextWidth: CGFloat = 380

    static func liveTextWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        return min(maxLiveTextWidth, ceil(width) + 2)
    }

    static func pillSize(for mode: HUDModel.Mode, liveText: String = "") -> NSSize {
        let live = liveTextWidth(liveText)
        switch mode {
        case .idle: return NSSize(width: 46, height: 24)
        case .recording: return NSSize(width: live > 0 ? 106 + 9 + live : 104, height: 34)
        case .handsFree where live > 0:
            return NSSize(width: 100 + 9 + live, height: 34)
        case .handsFree:
            let hint = "\(Prefs.triggerKey.keyName) to finish" as NSString
            let hintWidth = hint.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            return NSSize(width: ceil(hintWidth) + 118, height: 34)
        case .transcribing: return NSSize(width: 134, height: 34)
        case .message(let text, _):
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            return NSSize(width: min(440, ceil(textWidth) + 54), height: 34)
        }
    }

    /// Window frame for a mode, centred on the anchor and kept on screen.
    private func frame(for mode: HUDModel.Mode) -> NSRect {
        let pill = Self.pillSize(for: mode, liveText: model.liveText)
        let m = Self.margin
        let size = NSSize(width: pill.width + 2 * m, height: pill.height + 2 * m)
        let (anchor, screen) = currentAnchor()
        let bounds = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let x = min(max(anchor.x - size.width / 2, bounds.minX - m), bounds.maxX - size.width + m)
        let y = min(max(anchor.y - size.height / 2, bounds.minY - m), bounds.maxY - size.height + m)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func currentAnchor() -> (NSPoint, NSScreen) {
        if drag != nil, let panel {
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            return (center, IndicatorPosition.screen(containing: center))
        }
        return IndicatorPosition.anchor()
    }

    /// Where the pill hides: just past the nearest screen edge, or (away from the edges)
    /// shrunk into its own centre.
    private func hiddenFrame(for frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let visible = IndicatorPosition.screen(containing: center).visibleFrame
        let distances: [(CGFloat, CGVector)] = [
            (center.y - visible.minY, CGVector(dx: 0, dy: -1)),
            (visible.maxY - center.y, CGVector(dx: 0, dy: 1)),
            (center.x - visible.minX, CGVector(dx: -1, dy: 0)),
            (visible.maxX - center.x, CGVector(dx: 1, dy: 0)),
        ]
        let (distance, direction) = distances.min { $0.0 < $1.0 }!
        if distance < 160 {
            let travel = distance + max(frame.width, frame.height) / 2
            return frame.offsetBy(dx: direction.dx * travel, dy: direction.dy * travel)
        }
        return NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
    }

    private func emerge(_ panel: NSPanel, to target: NSRect, animated: Bool) {
        guard animated else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.setFrame(hiddenFrame(for: target), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.15, 0.35, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func resize(_ panel: NSPanel, to target: NSRect, animated: Bool) {
        guard panel.frame != target || panel.alphaValue < 1 else { return }
        guard animated, drag == nil else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.2, 0.4, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func retreat(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame(for: panel.frame), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // It may have been asked to show again while sliding away.
            if self?.isShown == false { panel.orderOut(nil) }
        })
    }

    // MARK: - Dragging

    private func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if drag == nil { drag = (mouse, panel.frame.origin) }
        guard let drag else { return }
        panel.setFrameOrigin(NSPoint(x: drag.origin.x + mouse.x - drag.mouse.x,
                                     y: drag.origin.y + mouse.y - drag.mouse.y))
    }

    private func dragEnded() {
        guard let panel, drag != nil else { return }
        IndicatorPosition.save(center: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        drag = nil
        render() // settles back on screen if it was dropped partly outside
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false // dragged manually so clicks and drags can be told apart
        panel.animationBehavior = .none

        let actions = IndicatorActions(
            tap: { [weak self] in self?.onClick?() },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() }
        )
        let host = IndicatorHostingView(rootView: IndicatorView(model: model, actions: actions))
        host.sizingOptions = [] // the window size is driven by us, not by the SwiftUI content
        host.menuProvider = { [weak self] in self?.menuProvider?() }
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// For offscreen rendering (see UISnapshot).
    static func previewView(model: HUDModel) -> some View {
        IndicatorView(model: model, actions: IndicatorActions(tap: {}, dragChanged: {}, dragEnded: {}))
            .background(Color.gray.opacity(0.35))
    }
}

/// Remembers where the user dragged the indicator, relative to that screen's usable area so
/// it survives resolution changes and unplugged displays.
enum IndicatorPosition {
    private static let key = "indicatorPosition"

    static func anchor() -> (NSPoint, NSScreen) {
        let primary = NSScreen.screens.first ?? NSScreen.main!
        if let saved = UserDefaults.standard.dictionary(forKey: key),
           let fx = saved["fx"] as? Double, let fy = saved["fy"] as? Double {
            let screen = NSScreen.screens.first { $0.displayID == saved["screen"] as? Int } ?? primary
            let visible = screen.visibleFrame
            return (NSPoint(x: visible.minX + fx * visible.width, y: visible.minY + fy * visible.height), screen)
        }
        // Default: bottom centre of the main display, just above the Dock.
        let visible = primary.visibleFrame
        return (NSPoint(x: visible.midX, y: visible.minY + 26), primary)
    }

    static func save(center: NSPoint) {
        let screen = screen(containing: center)
        let visible = screen.visibleFrame
        let fx = min(max((center.x - visible.minX) / visible.width, 0), 1)
        let fy = min(max((center.y - visible.minY) / visible.height, 0), 1)
        UserDefaults.standard.set(["screen": screen.displayID, "fx": fx, "fy": fy], forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func screen(containing point: NSPoint) -> NSScreen {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen }
        // Off every screen (dropped past an edge): use the closest one.
        return NSScreen.screens.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        } ?? NSScreen.main!
    }
}

private extension NSScreen {
    var displayID: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct IndicatorActions {
    let tap: () -> Void
    let dragChanged: () -> Void
    let dragEnded: () -> Void
}

private final class IndicatorHostingView: NSHostingView<IndicatorView> {
    var menuProvider: (() -> NSMenu?)?

    // React to the first click even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private struct IndicatorView: View {
    let model: HUDModel
    let actions: IndicatorActions

    var body: some View {
        content
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(Capsule()) // reveals the content as the pill expands
            .background(PillBackground(theme: model.theme, idle: model.mode.isIdle, animate: model.mode.isListening))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .contentShape(Capsule())
            .onTapGesture { actions.tap() }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in actions.dragChanged() }
                    .onEnded { _ in actions.dragEnded() }
            )
            .padding(RecordingHUD.margin)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .animation(.easeOut(duration: 0.15), value: model.mode)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .idle(let style):
            switch style {
            case .ready:
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            case .loading:
                ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12)
            }
        case .recording:
            HStack(spacing: 9) {
                PulsingDot(color: model.theme.recordingDot)
                Waveform(levels: model.levels)
                LiveText(text: model.liveText)
            }
        case .handsFree:
            HStack(spacing: 9) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                Waveform(levels: model.levels)
                if model.liveText.isEmpty {
                    Text("\(model.triggerName) to finish").foregroundStyle(.white.opacity(0.55)).font(.system(size: 11))
                } else {
                    LiveText(text: model.liveText)
                }
            }
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                Text("Transcribing").foregroundStyle(.white.opacity(0.85))
            }
        case .message(let text, let symbol):
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(.yellow)
                Text(text).lineLimit(1)
            }
        }
    }
}

/// The words so far, newest on the right; when too long, the start is cut off.
private struct LiveText: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: RecordingHUD.liveTextWidth(text), alignment: .trailing)
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: 3 + levels[index] * 15)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.09), value: levels)
    }
}
