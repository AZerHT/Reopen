import AppKit
import ApplicationServices

/// Watches the standard windows of every regular app, on every Space, and reports the windows that get
/// closed and the apps that get quit, with the windows they had.
///
/// A destroyed Accessibility element can no longer be queried, so each window's document, title and frame
/// are cached while it is alive — and its scroll position, selection and untitled text just before it closes.
final class WindowTracker {
    var onClosed: ((ClosedItem) -> Void)?
    /// Soft-closed windows are parked off screen: their moves aren't real, and their end is handled elsewhere.
    var isSoftClosed: ((AXUIElement) -> Bool)?
    var softClosedWindowDestroyed: ((AXUIElement) -> Void)?
    /// The window with keyboard focus changed, in the frontmost app.
    var onWindowFocused: ((AXUIElement, pid_t) -> Void)?

    private struct Snapshot {
        var title: String
        var documentURL: URL?
        /// The copy of an untitled document's text, made just before closing.
        var rescuedURL: URL?
        var frame: CGRect?
        var viewState: ViewState?

        /// Only files and folders count as documents: web views (Spotify, Electron) report an https one.
        var state: WindowState {
            let document = documentURL.flatMap { $0.isFileURL ? $0 : nil } ?? rescuedURL
            return WindowState(title: title, documentURL: document, frame: frame, viewState: viewState)
        }
    }

    private struct TrackedWindow {
        let element: AXUIElement
        var snapshot: Snapshot
    }

    /// A window destroyed moments ago, which may turn out to be part of its app quitting.
    private struct DestroyedWindow {
        let id = UUID()
        let date = Date()
        let snapshot: Snapshot
    }

    private var observers: [pid_t: AXObserver] = [:]
    private var windows: [pid_t: [TrackedWindow]] = [:]
    private var recentlyDestroyed: [pid_t: [DestroyedWindow]] = [:]
    private var expectedDestroys: [AXUIElement] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let discoveryQueue = DispatchQueue(label: "Reopen.SpaceWindows", qos: .utility)
    private var started = false
    private var poweringOff = false

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return app.element(kAXFocusedWindowAttribute)
    }

    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.track(app, attempt: 0)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appTerminated(app)
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.refreshAll(pid: app.processIdentifier)
            self?.reportFocus(pid: app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // Leaving an app is the last sure moment to read how its window was scrolled.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let window = WindowTracker.focusedWindow(pid: app.processIdentifier) else { return }
            self?.captureViewState(of: window, pid: app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for pid in self.observers.keys { self.refreshAll(pid: pid) }
        }
        // A shutdown or logout quits every app: that's not something to undo.
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.poweringOff = true
        }

        for app in NSWorkspace.shared.runningApplications {
            track(app, attempt: 0)
        }
    }

    // MARK: - Before a close

    /// A window is about to close (⌘W, close button): read what can't be read afterwards.
    func captureBeforeClose(_ window: AXUIElement, pid: pid_t) {
        watch(window, pid: pid)
        captureViewState(of: window, pid: pid)
        rescueIfUntitled(window, pid: pid)
    }

    /// An app is about to quit (⌘Q).
    func captureBeforeQuit(pid: pid_t) {
        for tracked in (windows[pid] ?? []).prefix(6) {
            captureViewState(of: tracked.element, pid: pid)
            rescueIfUntitled(tracked.element, pid: pid)
        }
    }

    func expectDestroy(_ element: AXUIElement) {
        expectedDestroys.append(element)
    }

    /// The history entry a window would get if it closed now, for soft close.
    func closedItem(for window: AXUIElement, pid: pid_t) -> ClosedItem? {
        guard let snapshot = windows[pid]?.first(where: { CFEqual($0.element, window) })?.snapshot,
              let app = NSRunningApplication(processIdentifier: pid), let appURL = app.bundleURL else { return nil }
        return item(for: snapshot.state, app: app, appURL: appURL)
    }

    private func captureViewState(of window: AXUIElement, pid: pid_t) {
        guard isSoftClosed?(window) != true,
              windows[pid]?.contains(where: { CFEqual($0.element, window) }) == true,
              let state = ViewStateAccess.read(from: window, pid: pid),
              let index = windows[pid]?.firstIndex(where: { CFEqual($0.element, window) }) else { return }
        windows[pid]![index].snapshot.viewState = state
    }

    private func rescueIfUntitled(_ window: AXUIElement, pid: pid_t) {
        guard isSoftClosed?(window) != true,
              let snapshot = windows[pid]?.first(where: { CFEqual($0.element, window) })?.snapshot,
              snapshot.documentURL == nil, UntitledRescue.looksUntitled(snapshot.title),
              let url = UntitledRescue.rescue(from: window, title: snapshot.title),
              let index = windows[pid]?.firstIndex(where: { CFEqual($0.element, window) }) else { return }
        windows[pid]![index].snapshot.rescuedURL = url
        DebugLog.write("rescued untitled \"\(snapshot.title)\" to \(url.lastPathComponent)")
    }

    // MARK: - Apps

    private func track(_ app: NSRunningApplication, attempt: Int) {
        let pid = app.processIdentifier
        guard pid != ownPID, app.activationPolicy == .regular, observers[pid] == nil, !app.isTerminated else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        guard result == .success else {
            // A freshly launched app doesn't answer Accessibility requests yet: retry a few times.
            DebugLog.write("track \(app.localizedName ?? "?") failed (AXError \(result.rawValue)), attempt \(attempt)")
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(attempt + 1)) { [weak self] in
                    self?.track(app, attempt: attempt + 1)
                }
            }
            return
        }
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        // Common modes, so windows closed while a menu is open are still caught.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer

        let visible = appElement.windows
        DebugLog.write("tracking \(app.localizedName ?? "?") (\(visible.count) windows)")
        for window in visible {
            watch(window, pid: pid)
        }
        discoverOtherSpaces(pid: pid, visibleCount: visible.count)
    }

    /// Windows on Spaces other than the current one are invisible to plain Accessibility: look for them.
    private func discoverOtherSpaces(pid: pid_t, visibleCount: Int) {
        guard SpaceWindows.hasWindowsElsewhere(pid: pid, visibleCount: visibleCount) else { return }
        discoveryQueue.async { [weak self] in
            let found = SpaceWindows.all(pid: pid)
            DispatchQueue.main.async {
                guard let self, self.observers[pid] != nil else { return }
                let before = self.windows[pid]?.count ?? 0
                for window in found {
                    self.watch(window, pid: pid)
                }
                DebugLog.write("pid \(pid): \(found.count) windows across Spaces, \((self.windows[pid]?.count ?? 0) - before) newly tracked")
            }
        }
    }

    private func appTerminated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        defer {
            stopTracking(pid: pid)
            recentlyDestroyed[pid] = nil
        }
        guard observers[pid] != nil, !poweringOff, let appURL = app.bundleURL else { return }
        let name = app.localizedName ?? appURL.deletingPathExtension().lastPathComponent

        // The quit destroys the windows just before the app terminates: count those too.
        // Soft-closed windows already have their own history entry.
        let alive = (windows[pid] ?? []).filter { isSoftClosed?($0.element) != true }.map(\.snapshot)
        let justDestroyed = recentlyDestroyed[pid, default: []].filter { Date().timeIntervalSince($0.date) < 2 }.map(\.snapshot)
        let snapshots = alive + justDestroyed
        // An app that quits with no window left is usually macOS terminating it on its own (TextEdit, Preview).
        guard !snapshots.isEmpty else {
            DebugLog.write("ignored \(name) quitting: no window")
            return
        }
        DebugLog.write("quit \(name) with \(snapshots.count) windows → history")

        onClosed?(ClosedItem(
            id: UUID(),
            appName: name,
            bundleID: app.bundleIdentifier,
            appURL: appURL,
            windows: snapshots.map(\.state),
            appQuit: true,
            closedAt: Date(),
            softCloseToken: nil
        ))
    }

    private func stopTracking(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        windows[pid] = nil
    }

    // MARK: - Windows

    private func watch(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        guard window.isStandardWindow else {
            DebugLog.write("skip pid \(pid): role \(window.string(kAXRoleAttribute) ?? "nil") subrole \(window.string(kAXSubroleAttribute) ?? "nil")")
            return
        }
        if windows[pid, default: []].contains(where: { CFEqual($0.element, window) }) {
            refresh(window, pid: pid, askFinder: true)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
        // Register before asking Finder: the Apple Event spins the run loop and can re-enter `watch`.
        windows[pid, default: []].append(TrackedWindow(element: window, snapshot: snapshot(of: window, pid: pid, askFinder: false)))
        if isFinder(pid) { refresh(window, pid: pid, askFinder: true) }

        let initial = windows[pid]?.first(where: { CFEqual($0.element, window) })?.snapshot
        DebugLog.write("watch pid \(pid) \"\(initial?.title ?? "")\" document=\(initial?.documentURL?.absoluteString ?? "nil") frame=\(initial?.frame.map { "\($0)" } ?? "nil")")
    }

    /// `askFinder` costs an Apple Event: only on events that can change the folder, never on moves.
    private func snapshot(of window: AXUIElement, pid: pid_t, askFinder: Bool) -> Snapshot {
        var snapshot = Snapshot(title: window.string(kAXTitleAttribute) ?? "", documentURL: window.documentURL, frame: window.frame)
        if snapshot.documentURL == nil, askFinder, isFinder(pid) {
            snapshot.documentURL = FinderBridge.folder(near: snapshot.frame)
        }
        return snapshot
    }

    private func isFinder(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == FinderBridge.bundleID
    }

    private func refresh(_ window: AXUIElement, pid: pid_t, askFinder: Bool = false) {
        guard windows[pid]?.contains(where: { CFEqual($0.element, window) }) == true else {
            watch(window, pid: pid)
            return
        }
        let fresh = snapshot(of: window, pid: pid, askFinder: askFinder)
        // Asking Finder spins the run loop, so the list may have changed meanwhile: look the window up again.
        guard let index = windows[pid]?.firstIndex(where: { CFEqual($0.element, window) }) else { return }
        // A window that is closing can answer with empty values: keep the last known ones.
        if !fresh.title.isEmpty { windows[pid]![index].snapshot.title = fresh.title }
        if let url = fresh.documentURL {
            windows[pid]![index].snapshot.documentURL = url
            windows[pid]![index].snapshot.rescuedURL = nil
        }
        // A soft-closed window is parked off screen: that position isn't where it belongs.
        if let frame = fresh.frame, isSoftClosed?(window) != true {
            windows[pid]![index].snapshot.frame = frame
        }
    }

    private func reportFocus(pid: pid_t) {
        guard pid != ownPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let window = WindowTracker.focusedWindow(pid: pid), window.isStandardWindow,
              isSoftClosed?(window) != true else { return }
        onWindowFocused?(window, pid)
    }

    private func refreshAll(pid: pid_t) {
        guard observers[pid] != nil else { return }
        for window in AXUIElementCreateApplication(pid).windows {
            watch(window, pid: pid)
        }
    }

    private func windowDestroyed(_ element: AXUIElement, pid: pid_t) {
        guard let index = windows[pid]?.firstIndex(where: { CFEqual($0.element, element) }) else {
            DebugLog.write("destroyed pid \(pid): unknown window")
            return
        }
        let snapshot = windows[pid]!.remove(at: index).snapshot
        DebugLog.write("destroyed pid \(pid) \"\(snapshot.title)\" document=\(snapshot.documentURL?.absoluteString ?? "nil")")

        if let expected = expectedDestroys.firstIndex(where: { CFEqual($0, element) }) {
            // A soft close running out: its history entry already exists.
            expectedDestroys.remove(at: expected)
            return
        }
        if isSoftClosed?(element) == true {
            // Its app closed it while it was hidden (quitting, usually): the history entry stays.
            softClosedWindowDestroyed?(element)
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid), let appURL = app.bundleURL else { return }

        let destroyed = DestroyedWindow(snapshot: snapshot)
        recentlyDestroyed[pid, default: []].removeAll { Date().timeIntervalSince($0.date) > 5 }
        recentlyDestroyed[pid, default: []].append(destroyed)
        let state = snapshot.state
        let name = state.documentURL?.lastPathComponent ?? app.localizedName ?? appURL.deletingPathExtension().lastPathComponent

        // Wait a moment: an app quitting (see `appTerminated`), or recreating the window
        // (full screen, merging tabs), destroys windows too, and neither is a close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !app.isTerminated, self.observers[pid] != nil else {
                DebugLog.write("\(name): part of the app quitting")
                return
            }
            self.recentlyDestroyed[pid]?.removeAll { $0.id == destroyed.id }

            if let documentURL = state.documentURL {
                var openKeys = Set((self.windows[pid] ?? []).compactMap { $0.snapshot.documentURL?.matchKey })
                if app.bundleIdentifier == FinderBridge.bundleID {
                    openKeys.formUnion(FinderBridge.windowTargets().map { $0.url.matchKey })
                }
                guard !openKeys.contains(documentURL.matchKey) else {
                    DebugLog.write("ignored \(name): still open in another window")
                    return
                }
            }
            DebugLog.write("closed \(name) → history")
            self.onClosed?(self.item(for: state, app: app, appURL: appURL))
        }
    }

    private func item(for state: WindowState, app: NSRunningApplication, appURL: URL) -> ClosedItem {
        let name = state.documentURL?.lastPathComponent ?? app.localizedName ?? appURL.deletingPathExtension().lastPathComponent
        return ClosedItem(
            id: UUID(),
            appName: app.localizedName ?? name,
            bundleID: app.bundleIdentifier,
            appURL: appURL,
            windows: [WindowState(title: state.title.isEmpty ? name : state.title, documentURL: state.documentURL, frame: state.frame, viewState: state.viewState)],
            appQuit: false,
            closedAt: Date(),
            softCloseToken: nil
        )
    }

    fileprivate func handle(_ element: AXUIElement, notification: String) {
        guard let pid = element.pid else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            watch(element, pid: pid)
        case kAXFocusedWindowChangedNotification:
            refreshAll(pid: pid)
            reportFocus(pid: pid)
        case kAXUIElementDestroyedNotification:
            windowDestroyed(element, pid: pid)
        case kAXTitleChangedNotification:
            // In Finder, the title changes when the window navigates to another folder.
            refresh(element, pid: pid, askFinder: true)
        default:
            refresh(element, pid: pid)
        }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue().handle(element, notification: notification as String)
}
