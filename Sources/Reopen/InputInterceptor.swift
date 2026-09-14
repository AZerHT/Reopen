import AppKit
import ApplicationServices
import Carbon

private let replayMarker: Int64 = 0x524F_504E_5245_504C // 'ROPNREPL'

/// A session event tap, on its own thread: it sees keystrokes and clicks before the apps do.
///
/// Every keystroke and click on the Mac goes through it, so it never waits: no Accessibility request, no main
/// thread. It decides from `State`, which the app refreshes a few times a second, and hands the actual work to the
/// main thread. A keystroke or click it holds back is always delivered afterwards — replayed or performed —
/// unless a soft close replaced it.
final class InputInterceptor {
    struct State {
        var shortcut = Shortcut.default
        var backShortcut = Shortcut.back
        var forwardShortcut = Shortcut.forward
        var frontmostPID: pid_t = 0
        var frontmostIsSelf = true
        /// An app that keeps ⌘W and the shortcut for its own tabs.
        var frontmostLeavesShortcut = true
        var hasHistory = false
        var canGoBack = false
        var canGoForward = false
        var softCloseEnabled = false
        /// Close buttons of the frontmost app's windows, in top-left screen coordinates like `CGEvent.location`.
        var closeButtons: [CGRect] = []
    }

    var onReopen: (() -> Void)?
    var onHistory: ((_ back: Bool) -> Void)?
    /// ⌘W was held back: the handler replays it with `replayCloseKey()`, unless it soft-closed the window.
    var onCloseKey: ((_ pid: pid_t) -> Void)?
    /// A close button was clicked. When `heldBack`, the click never reached the app: the handler hides or closes the window.
    var onCloseButton: ((_ point: CGPoint, _ heldBack: Bool) -> Void)?
    var onQuitKey: ((_ pid: pid_t) -> Void)?

    private let lock = NSLock()
    private var state = State()
    private var tap: CFMachPort?
    // Only touched on the tap thread.
    private var shortcutSwallowed = false
    private var swallowMouseUp = false

    func update(_ newState: State) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    private func currentState() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<InputInterceptor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Reopen event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == replayMarker {
            return pass
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A held-back click is already being handled on the main thread: don't wait for a mouse-up that may be lost.
            swallowMouseUp = false

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = Shortcut.flags(from: event.flags)
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let state = currentState()

            if state.backShortcut.matches(keyCode: keyCode, flags: flags) {
                guard state.canGoBack else { return pass }
                if !repeating { deliver { $0.onHistory?(true) } }
                return nil
            }
            if state.forwardShortcut.matches(keyCode: keyCode, flags: flags) {
                guard state.canGoForward else { return pass }
                if !repeating { deliver { $0.onHistory?(false) } }
                return nil
            }
            if state.shortcut.matches(keyCode: keyCode, flags: flags) {
                // A held shortcut repeats: follow the first press's decision, without reopening once per repeat.
                if repeating { return shortcutSwallowed ? nil : pass }
                // With nothing to reopen, the keystroke goes on to the app (Finder's Show Tab Bar).
                shortcutSwallowed = !state.frontmostIsSelf && !state.frontmostLeavesShortcut && state.hasHistory
                if shortcutSwallowed { deliver { $0.onReopen?() } }
                return shortcutSwallowed ? nil : pass
            }
            if keyCode == Int64(kVK_ANSI_W), flags == .command, !repeating,
               !state.frontmostIsSelf, !state.frontmostLeavesShortcut {
                let pid = state.frontmostPID
                deliver { $0.onCloseKey?(pid) }
                return nil
            }
            if keyCode == Int64(kVK_ANSI_Q), flags == .command, !repeating, !state.frontmostIsSelf {
                let pid = state.frontmostPID
                deliver { $0.onQuitKey?(pid) }
            }

        case .leftMouseDown:
            swallowMouseUp = false
            let state = currentState()
            let location = event.location
            guard !state.frontmostIsSelf,
                  state.closeButtons.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(location) }) else { return pass }
            if state.softCloseEnabled {
                swallowMouseUp = true
                deliver { $0.onCloseButton?(location, true) }
                return nil
            }
            // Buttons act on mouse-up: reading the window now, the click goes on untouched.
            deliver { $0.onCloseButton?(location, false) }

        case .leftMouseUp:
            if swallowMouseUp {
                swallowMouseUp = false
                return nil
            }

        default:
            break
        }
        return pass
    }

    private func deliver(_ work: @escaping (InputInterceptor) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    // MARK: - Replay

    /// Sends a held-back ⌘W on to the frontmost app, past this tap.
    static func replayCloseKey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: isDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Gives a held-back click back to the app under it, past this tap.
    static func replayClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
