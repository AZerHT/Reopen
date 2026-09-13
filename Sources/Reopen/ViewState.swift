import ApplicationServices
import Foundation

/// What a window showed beyond its document: how far it was scrolled and what text was selected.
struct ViewState: Codable, Equatable {
    /// Position of the window's largest scroll area: 0 at the top, 1 at the bottom.
    var verticalScroll: Double?
    var selectionLocation: Int?
    var selectionLength: Int?

    var isEmpty: Bool {
        verticalScroll == nil && selectionLocation == nil
    }
}

/// Reads and applies a `ViewState` through Accessibility. Works where apps expose their scroll bars
/// and text views — most native apps, rarely web-based ones.
enum ViewStateAccess {
    static func read(from window: AXUIElement, pid: pid_t) -> ViewState? {
        AXUIElementSetMessagingTimeout(window, 0.15)
        var state = ViewState()

        if let bar = largest(role: kAXScrollAreaRole, in: window)?.element(kAXVerticalScrollBarAttribute),
           let value = bar.value(of: kAXValueAttribute) as? NSNumber {
            state.verticalScroll = value.doubleValue
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        if let focused = app.element(kAXFocusedUIElementAttribute),
           [kAXTextAreaRole, kAXTextFieldRole].contains(focused.string(kAXRoleAttribute) ?? ""),
           let owner = focused.element(kAXWindowAttribute), CFEqual(owner, window),
           let rangeValue = focused.value(of: kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                state.selectionLocation = range.location
                state.selectionLength = range.length
            }
        }
        return state.isEmpty ? nil : state
    }

    /// True when at least part of the state could be applied.
    static func apply(_ state: ViewState, to window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.3)
        var applied = false

        if let location = state.selectionLocation, let length = state.selectionLength,
           let textArea = largest(role: kAXTextAreaRole, in: window) {
            var range = CFRange(location: location, length: length)
            if let value = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                applied = true
            }
        }
        // Scroll last: moving the selection can scroll to it.
        if let scroll = state.verticalScroll,
           let bar = largest(role: kAXScrollAreaRole, in: window)?.element(kAXVerticalScrollBarAttribute),
           AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: scroll)) == .success {
            applied = true
        }
        return applied
    }

    static func largestTextArea(in window: AXUIElement) -> AXUIElement? {
        largest(role: kAXTextAreaRole, in: window)
    }

    private static func largest(role: String, in window: AXUIElement) -> AXUIElement? {
        descendants(of: window)
            .filter { $0.string(kAXRoleAttribute) == role }
            .max { area(of: $0) < area(of: $1) }
    }

    private static func area(of element: AXUIElement) -> CGFloat {
        element.frame.map { $0.width * $0.height } ?? 0
    }

    /// Breadth-first, bounded: a window's content view sits a few levels down, and deep trees are slow to walk.
    private static func descendants(of root: AXUIElement, limit: Int = 150, depth: Int = 7) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var level = [root]
        for _ in 0..<depth {
            var next: [AXUIElement] = []
            for element in level {
                for child in element.children {
                    found.append(child)
                    next.append(child)
                    if found.count >= limit { return found }
                }
            }
            guard !next.isEmpty else { break }
            level = next
        }
        return found
    }
}
