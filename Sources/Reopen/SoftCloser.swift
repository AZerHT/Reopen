import AppKit
import ApplicationServices

/// Soft close: a window is parked out of sight instead of closed, so it can come back untouched.
/// Once the delay runs out, it is closed for real.
final class SoftCloser {
    /// Just before a hidden window is closed for real, so its destruction isn't recorded as a new close.
    var willCloseForReal: ((AXUIElement) -> Void)?
    /// A hidden window refused to close silently (a save sheet, usually) and was put back on screen.
    var didPutBack: ((UUID) -> Void)?

    private struct HiddenWindow {
        let element: AXUIElement
        let pid: pid_t
        let frame: CGRect
        let minimized: Bool
        let timer: Timer
    }

    private var hidden: [UUID: HiddenWindow] = [:]

    func isHidden(_ element: AXUIElement) -> Bool {
        hidden.values.contains { CFEqual($0.element, element) }
    }

    func contains(_ token: UUID) -> Bool {
        hidden[token] != nil
    }

    func hide(_ window: AXUIElement, pid: pid_t, frame: CGRect, delay: TimeInterval) -> UUID? {
        // Park the window beyond the right edge of every screen.
        let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setPosition(CGPoint(x: rightEdge + 400, y: frame.minY))

        var minimized = false
        if let parked = window.frame, isOnScreen(parked) {
            // macOS kept it reachable on a screen: minimise it instead.
            window.setPosition(frame.origin)
            guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else { return nil }
            minimized = true
        }

        let token = UUID()
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.closeForReal(token)
        }
        hidden[token] = HiddenWindow(element: window, pid: pid, frame: frame, minimized: minimized, timer: timer)
        DebugLog.write("hid window (\(minimized ? "minimized" : "parked off screen")) for \(Int(delay)) s")
        return token
    }

    /// Puts a hidden window back where it was. False if it is gone.
    func restore(_ token: UUID) -> Bool {
        guard let window = hidden.removeValue(forKey: token) else { return false }
        window.timer.invalidate()
        guard window.element.string(kAXRoleAttribute) != nil else { return false }

        if window.minimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        window.element.setFrame(window.frame)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        return true
    }

    /// The app closed a hidden window itself (it quit, for instance).
    func forget(_ element: AXUIElement) {
        for (token, window) in hidden where CFEqual(window.element, element) {
            window.timer.invalidate()
            hidden[token] = nil
        }
    }

    /// When Reopen quits: as far as the user knows these windows are closed, so don't leave them parked.
    func closeAllForReal() {
        for token in Array(hidden.keys) {
            closeForReal(token)
        }
    }

    private func closeForReal(_ token: UUID) {
        guard let window = hidden[token] else { return }
        guard let closeButton = window.element.element(kAXCloseButtonAttribute) else {
            hidden[token] = nil
            return
        }
        willCloseForReal?(window.element)
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)

        // A window that survives is asking something, like saving changes: show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.hidden[token] != nil else { return }
            if window.element.string(kAXRoleAttribute) != nil, self.restore(token) {
                DebugLog.write("hidden window needs attention: put back on screen")
                self.didPutBack?(token)
            } else {
                self.hidden[token] = nil
            }
        }
    }

    /// Whether an Accessibility frame (top-left origin) still shows on a screen.
    private func isOnScreen(_ frame: CGRect) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        return NSScreen.screens.contains { screen in
            let screenFrame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            let overlap = screenFrame.intersection(frame)
            return !overlap.isNull && overlap.width > 40 && overlap.height > 40
        }
    }
}
