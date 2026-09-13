import AppKit
import ApplicationServices
import Carbon

/// A session event tap: it sees keystrokes and clicks before the apps do.
///
/// Used to catch the shortcut (and let it through when Reopen has nothing to do with it),
/// and to notice a window about to close while it can still be read — or hide it instead.
final class InputInterceptor {
    /// The shortcut was pressed. Return true to swallow it.
    var onShortcut: (() -> Bool)?
    /// The Previous / Next window shortcut was pressed. Return true to swallow it.
    var onHistory: ((_ back: Bool) -> Bool)?
    /// ⌘W is about to reach the frontmost app. Return true to swallow it.
    var onCloseKey: ((_ pid: pid_t) -> Bool)?
    /// A window's close button is being clicked. Return true to swallow the click.
    var onCloseButton: ((_ window: AXUIElement, _ pid: pid_t) -> Bool)?
    /// ⌘Q is about to reach the frontmost app.
    var onQuitKey: ((_ pid: pid_t) -> Void)?

    private var tap: CFMachPort?
    private var swallowMouseUp = false
    private var shortcutSwallowed = false
    private let systemWide = AXUIElementCreateSystemWide()

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
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Every click asks the app under the pointer what it is: never wait long for an answer.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = Shortcut.flags(from: event.flags)
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

            if Settings.shared.backShortcut.matches(keyCode: keyCode, flags: flags) {
                return (onHistory?(true) ?? false) ? nil : pass
            }
            if Settings.shared.forwardShortcut.matches(keyCode: keyCode, flags: flags) {
                return (onHistory?(false) ?? false) ? nil : pass
            }
            if Settings.shared.shortcut.matches(keyCode: keyCode, flags: flags) {
                // A held shortcut repeats: follow the first press's decision, without reopening once per repeat.
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return shortcutSwallowed ? nil : pass
                }
                shortcutSwallowed = onShortcut?() ?? false
                return shortcutSwallowed ? nil : pass
            }
            if keyCode == Int64(kVK_ANSI_W), flags == .command, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                return (onCloseKey?(pid) ?? false) ? nil : pass
            }
            if keyCode == Int64(kVK_ANSI_Q), flags == .command {
                onQuitKey?(pid)
            }

        case .leftMouseDown:
            var hit: AXUIElement?
            let location = event.location
            if AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &hit) == .success,
               let button = hit, button.string(kAXSubroleAttribute) == kAXCloseButtonSubrole,
               let window = button.element(kAXWindowAttribute), let pid = window.pid,
               onCloseButton?(window, pid) == true {
                swallowMouseUp = true
                return nil
            }

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
}
