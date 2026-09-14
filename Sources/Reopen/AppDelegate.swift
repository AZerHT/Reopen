import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let store = HistoryStore()
    private let tracker = WindowTracker()
    private let reopener = Reopener()
    private let softCloser = SoftCloser()
    private let interceptor = InputInterceptor()
    private let history = WindowHistory()
    private let settingsWindow = SettingsWindowController()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var inputStateTimer: Timer?
    /// Every keystroke and click waits on the event tap: App Nap must never slow this windowless app down.
    private var latencyCriticalActivity: NSObjectProtocol?
    private let ownBundleID = Bundle.main.bundleIdentifier

    /// The frontmost app's close buttons, matched against the clicks the event tap reports.
    private struct CloseButtonTarget {
        let rect: CGRect
        let window: AXUIElement
        let button: AXUIElement
        let pid: pid_t
    }
    private var closeButtonTargets: [CloseButtonTarget] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: "Reopen")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        connect()
        UntitledRescue.removeOlderThan(days: 14)

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        DebugLog.write("launch: accessibility trusted = \(trusted)")
        if trusted {
            startWatching()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startWatching()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        softCloser.closeAllForReal()
    }

    /// `reopen://last`, `reopen://back` and `reopen://forward` do what the shortcuts do, for Shortcuts, Raycast or scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "reopen" {
            switch url.host {
            case "last": reopenLast()
            case "back": goThroughHistory(back: true)
            case "forward": goThroughHistory(back: false)
            default: break
            }
        }
    }

    private func startWatching() {
        latencyCriticalActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Event tap on keystrokes and clicks"
        )
        tracker.start()
        refreshInputState()
        DebugLog.write("event tap started = \(interceptor.start())")
        // The event tap decides from this snapshot: keep it current without ever making the tap wait.
        inputStateTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refreshInputState()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshInputState()
        }
    }

    private func refreshInputState() {
        var state = InputInterceptor.State()
        state.shortcut = settings.shortcut
        state.backShortcut = settings.backShortcut
        state.forwardShortcut = settings.forwardShortcut
        let frontmost = NSWorkspace.shared.frontmostApplication
        state.frontmostPID = frontmost?.processIdentifier ?? 0
        state.frontmostIsSelf = frontmost == nil || frontmost?.bundleIdentifier == ownBundleID
        state.frontmostLeavesShortcut = settings.leavesShortcut(to: frontmost?.bundleIdentifier)
        state.hasHistory = !store.items.isEmpty
        state.canGoBack = history.canGoBack
        state.canGoForward = history.canGoForward
        state.softCloseEnabled = settings.softCloseEnabled

        var targets: [CloseButtonTarget] = []
        if let frontmost, !state.frontmostIsSelf, AXIsProcessTrusted() {
            let pid = frontmost.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            // Polled on the main thread: a busy app must not stall Reopen.
            AXUIElementSetMessagingTimeout(app, 0.1)
            for window in app.windows {
                AXUIElementSetMessagingTimeout(window, 0.1)
                guard window.isStandardWindow, let button = window.element(kAXCloseButtonAttribute) else { continue }
                AXUIElementSetMessagingTimeout(button, 0.1)
                if let rect = button.frame {
                    targets.append(CloseButtonTarget(rect: rect, window: window, button: button, pid: pid))
                }
            }
        }
        closeButtonTargets = targets
        state.closeButtons = targets.map(\.rect)
        interceptor.update(state)
    }

    private func connect() {
        tracker.onClosed = { [weak self] item in self?.store.push(item) }
        tracker.isSoftClosed = { [weak self] element in self?.softCloser.isHidden(element) ?? false }
        tracker.softClosedWindowDestroyed = { [weak self] element in self?.softCloser.forget(element) }
        tracker.onWindowFocused = { [weak self] window, pid in self?.history.record(window, pid: pid) }
        softCloser.willCloseForReal = { [weak self] element in self?.tracker.expectDestroy(element) }
        softCloser.didPutBack = { [weak self] token in self?.store.remove(softCloseToken: token) }

        interceptor.onReopen = { [weak self] in self?.reopenLast() }
        interceptor.onHistory = { [weak self] back in self?.goThroughHistory(back: back) }
        interceptor.onCloseKey = { [weak self] pid in self?.closeKeyHeldBack(pid: pid) }
        interceptor.onCloseButton = { [weak self] point, heldBack in self?.closeButtonClicked(at: point, heldBack: heldBack) }
        interceptor.onQuitKey = { [weak self] pid in self?.tracker.captureBeforeQuit(pid: pid) }
    }

    // MARK: - Input

    private func goThroughHistory(back: Bool) {
        defer { refreshInputState() }
        let isUsable: (WindowHistory.Entry) -> Bool = { [softCloser] entry in !softCloser.isHidden(entry.element) }
        guard let entry = back ? history.back(isUsable: isUsable) : history.forward(isUsable: isUsable) else {
            DebugLog.write("history: nothing to go \(back ? "back" : "forward") to")
            NSSound.beep()
            return
        }
        let name = NSRunningApplication(processIdentifier: entry.pid)?.localizedName ?? "?"
        DebugLog.write("history: going \(back ? "back" : "forward") to \(name) \"\(entry.element.string(kAXTitleAttribute) ?? "")\"")
        entry.element.focus(pid: entry.pid)
    }

    @objc private func goBackFromMenu() {
        goThroughHistory(back: true)
    }

    @objc private func goForwardFromMenu() {
        goThroughHistory(back: false)
    }

    /// ⌘W, held back by the event tap so the window can be read before it closes. It always reaches the app
    /// afterwards, unless the window was soft-closed instead.
    private func closeKeyHeldBack(pid: pid_t) {
        if let window = WindowTracker.focusedWindow(pid: pid), window.isStandardWindow {
            // ⌘W closes a tab in tabbed windows: no soft close there.
            if settings.softCloseEnabled, !window.hasSeveralTabs, softClose(window, pid: pid) {
                return
            }
            tracker.captureBeforeClose(window, pid: pid)
        }
        InputInterceptor.replayCloseKey()
    }

    private func closeButtonClicked(at point: CGPoint, heldBack: Bool) {
        guard let target = closeButtonTargets.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) else {
            // The window moved or went away since the last snapshot: the click must still happen.
            if heldBack { InputInterceptor.replayClick(at: point) }
            return
        }
        guard heldBack else {
            tracker.captureBeforeClose(target.window, pid: target.pid)
            return
        }
        if softClose(target.window, pid: target.pid) { return }
        // Not hidden (an app using audio, say): close it, as the click would have.
        AXUIElementPerformAction(target.button, kAXPressAction as CFString)
    }

    /// Hides the window instead of letting it close. False lets the close go ahead.
    private func softClose(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard !AudioActivity.isActive(pid: pid) else {
            DebugLog.write("no soft close: the app is using audio")
            tracker.captureBeforeClose(window, pid: pid)
            return false
        }
        tracker.captureBeforeClose(window, pid: pid)
        guard var item = tracker.closedItem(for: window, pid: pid), let frame = window.frame,
              let token = softCloser.hide(window, pid: pid, frame: frame, delay: settings.softCloseDelay) else { return false }
        item.softCloseToken = token
        store.push(item)
        return true
    }

    // MARK: - Reopening

    private func reopenLast() {
        defer { refreshInputState() }
        DebugLog.write("reopen requested, \(store.items.count) in history")
        guard let item = store.popLatestAvailable() else {
            NSSound.beep()
            return
        }
        reopen(item)
    }

    private func reopen(_ item: ClosedItem) {
        if let token = item.softCloseToken, softCloser.restore(token) {
            DebugLog.write("brought back hidden \(item.menuTitle)")
            return
        }
        reopener.reopen(item)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        let reopenItem = item("Reopen Last Closed Window", #selector(reopenLastFromMenu), key: settings.shortcut.menuKeyEquivalent)
        reopenItem.keyEquivalentModifierMask = settings.shortcut.modifierFlags
        reopenItem.isEnabled = !store.items.isEmpty
        menu.addItem(reopenItem)

        let backItem = item("Previous Window", #selector(goBackFromMenu), key: settings.backShortcut.menuKeyEquivalent)
        backItem.keyEquivalentModifierMask = settings.backShortcut.modifierFlags
        backItem.isEnabled = history.canGoBack
        menu.addItem(backItem)
        let forwardItem = item("Next Window", #selector(goForwardFromMenu), key: settings.forwardShortcut.menuKeyEquivalent)
        forwardItem.keyEquivalentModifierMask = settings.forwardShortcut.modifierFlags
        forwardItem.isEnabled = history.canGoForward
        menu.addItem(forwardItem)
        menu.addItem(.separator())

        if store.items.isEmpty {
            let empty = NSMenuItem(title: "No closed windows yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for closed in store.items.prefix(15) {
                let hidden = closed.softCloseToken.map(softCloser.contains) ?? false
                let entry = item(closed.menuTitle + (hidden ? " (hidden)" : ""), #selector(reopenFromMenu(_:)))
                entry.representedObject = closed.id
                let paths = closed.windows.compactMap { $0.documentURL?.path }
                entry.toolTip = paths.isEmpty ? closed.appURL.path : paths.joined(separator: "\n")
                let icon = NSWorkspace.shared.icon(forFile: closed.appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(item("Clear History", #selector(clearHistory)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        let quit = NSMenuItem(title: "Quit Reopen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func reopenLastFromMenu() {
        reopenLast()
    }

    @objc private func reopenFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let closed = store.remove(id: id) else { return }
        guard closed.isAvailable else {
            NSSound.beep()
            return
        }
        reopen(closed)
    }

    @objc private func clearHistory() {
        store.clear()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
