import AppKit
import ApplicationServices

/// Back and Forward through the windows you used, across all apps, like a browser's history.
///
/// Each window appears once: going back from a window lands on the one used before it, not on a
/// window that was only visited in between.
final class WindowHistory {
    struct Entry {
        let element: AXUIElement
        let pid: pid_t
    }

    private var entries: [Entry] = []
    private var index = -1
    /// Focus changes caused by our own navigation aren't new history: ignored until the target window gets focus.
    private var navigation: (target: AXUIElement, deadline: Date)?
    private let limit = 50

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    func record(_ window: AXUIElement, pid: pid_t) {
        if let navigation, Date() < navigation.deadline {
            if CFEqual(navigation.target, window) { self.navigation = nil }
            DebugLog.write("history: focus during navigation ignored (\(CFEqual(navigation.target, window) ? "target reached" : "other window"))")
            return
        }
        navigation = nil
        if index >= 0, CFEqual(entries[index].element, window) { return }

        // A new window after going back drops the forward history, as in a browser.
        if canGoForward { entries.removeSubrange((index + 1)...) }
        entries.removeAll { CFEqual($0.element, window) }
        entries.append(Entry(element: window, pid: pid))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        index = entries.count - 1
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        DebugLog.write("history: recorded \(name) \"\(window.string(kAXTitleAttribute) ?? "")\", \(entries.count) entries")
    }

    /// The previous window still worth going to, skipping closed ones. `isUsable` filters out hidden windows.
    func back(isUsable: (Entry) -> Bool) -> Entry? {
        while index > 0 {
            let candidate = index - 1
            if isAlive(entries[candidate]), isUsable(entries[candidate]) {
                index = candidate
                return navigate(to: entries[candidate])
            }
            entries.remove(at: candidate)
            index -= 1
        }
        return nil
    }

    func forward(isUsable: (Entry) -> Bool) -> Entry? {
        while canGoForward {
            let candidate = index + 1
            if isAlive(entries[candidate]), isUsable(entries[candidate]) {
                index = candidate
                return navigate(to: entries[candidate])
            }
            entries.remove(at: candidate)
        }
        return nil
    }

    private func navigate(to entry: Entry) -> Entry {
        navigation = (entry.element, Date().addingTimeInterval(1))
        return entry
    }

    private func isAlive(_ entry: Entry) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return false }
        AXUIElementSetMessagingTimeout(entry.element, 0.2)
        return entry.element.string(kAXRoleAttribute) != nil
    }
}
