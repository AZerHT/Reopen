import AppKit
import ApplicationServices

/// Brings back a closed window, or a quit app with its windows, then puts the windows back where they were.
final class Reopener {
    func reopen(_ item: ClosedItem) {
        let documents = item.windows.compactMap(\.documentURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        DebugLog.write("reopening \(item.menuTitle) (\(documents.count) documents)")

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
                FrameRestorer(windows: item.windows, pid: app.processIdentifier).start()
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

/// The app opens its windows asynchronously: poll until each saved window has a match, then move it into place.
private final class FrameRestorer {
    private var pending: [WindowState]
    private var placed: [AXUIElement] = []
    private let pid: pid_t
    private let deadline = Date().addingTimeInterval(5)

    init(windows: [WindowState], pid: pid_t) {
        // Documents first: they can be told apart, windows without one only take what is left.
        pending = windows.filter { $0.frame != nil }.sorted { $0.documentURL != nil && $1.documentURL == nil }
        self.pid = pid
    }

    func start() {
        var available = AXUIElementCreateApplication(pid).windows.filter { window in
            window.isStandardWindow && !placed.contains { CFEqual($0, window) }
        }
        pending.removeAll { state in
            guard let frame = state.frame, let index = matchIndex(for: state, in: available) else { return false }
            available[index].setFrame(frame)
            placed.append(available.remove(at: index))
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
