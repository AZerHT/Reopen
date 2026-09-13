import AppKit
import ApplicationServices

/// Brings back a closed window, or a quit app with its windows, then puts each window back where it was
/// and scrolls it back to where it was.
final class Reopener {
    func reopen(_ item: ClosedItem) {
        let documents = item.windows.compactMap(\.documentURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        DebugLog.write("reopening \(item.menuTitle) (\(documents.count) documents)")
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == item.appURL.standardizedFileURL }

        // A window without a document, from an app that still has others: ask the app for a new window.
        if !item.appQuit, documents.isEmpty, let app = running {
            let existing = AXUIElementCreateApplication(app.processIdentifier).windows.filter(\.isStandardWindow)
            if !existing.isEmpty {
                app.activate(options: [])
                if AppMenu.pressNewWindow(pid: app.processIdentifier) {
                    DebugLog.write("asked \(item.appName) for a new window")
                    FrameRestorer(windows: item.windows, pid: app.processIdentifier, excluding: existing).start()
                    return
                }
                DebugLog.write("\(item.appName) has no New Window command")
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
            DispatchQueue.main.async {
                if let error {
                    DebugLog.write("could not reopen \(item.menuTitle): \(error.localizedDescription)")
                    NSSound.beep()
                    return
                }
                guard let app else { return }
                FrameRestorer(windows: item.windows, pid: app.processIdentifier, excluding: []).start()
            }
        }

        if documents.isEmpty {
            // Launches a quit app or, like clicking its Dock icon, makes a running app without windows show its main window.
            NSWorkspace.shared.openApplication(at: item.appURL, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(documents, withApplicationAt: item.appURL, configuration: configuration, completionHandler: completion)
        }
    }
}

/// The app opens its windows asynchronously: poll until each saved window has a match, then put it in place.
private final class FrameRestorer {
    private var pending: [WindowState]
    /// Windows already matched, or that existed before the reopen.
    private var placed: [AXUIElement]
    private let pid: pid_t
    private let deadline = Date().addingTimeInterval(5)

    init(windows: [WindowState], pid: pid_t, excluding existing: [AXUIElement]) {
        // Documents first: they can be told apart, windows without one only take what is left.
        pending = windows.sorted { $0.documentURL != nil && $1.documentURL == nil }
        placed = existing
        self.pid = pid
    }

    func start() {
        var available = AXUIElementCreateApplication(pid).windows.filter { window in
            window.isStandardWindow && !placed.contains { CFEqual($0, window) }
        }
        pending.removeAll { state in
            guard let index = matchIndex(for: state, in: available) else { return false }
            let window = available.remove(at: index)
            if let frame = state.frame { window.setFrame(frame) }
            if let viewState = state.viewState { ViewStateRestorer(state: viewState, window: window).start() }
            placed.append(window)
            return true
        }
        guard !pending.isEmpty, Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.start() }
    }

    private func matchIndex(for state: WindowState, in windows: [AXUIElement]) -> Int? {
        guard let documentURL = state.documentURL else {
            return windows.firstIndex { !($0.documentURL?.isFileURL ?? false) }
        }
        let key = documentURL.matchKey
        // Finder windows have no AXDocument: recognise them by their title, the folder's display name.
        let title = FileManager.default.displayName(atPath: documentURL.path)
        return windows.firstIndex { $0.documentURL?.matchKey == key }
            ?? windows.firstIndex { $0.documentURL == nil && $0.string(kAXTitleAttribute) == title }
    }
}

/// A reopened window fills in its content a moment after it appears: retry a few times.
private final class ViewStateRestorer {
    private let state: ViewState
    private let window: AXUIElement
    private var attempts = 0

    init(state: ViewState, window: AXUIElement) {
        self.state = state
        self.window = window
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.attempts += 1
            if ViewStateAccess.apply(self.state, to: self.window) {
                DebugLog.write("restored scroll/selection")
            } else if self.attempts < 6 {
                self.start()
            }
        }
    }
}
