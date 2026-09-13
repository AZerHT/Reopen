import AppKit
import ApplicationServices
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = HistoryStore()
    private let tracker = WindowTracker()
    private let reopener = Reopener()
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var hotKeyTaken = false

    /// Apps that already give ⇧⌘T a meaning of their own (closed tabs, closed editors) keep it.
    private let passthroughBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.uturn.backward.circle", accessibilityDescription: "Reopen")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.reopenLast()
        }
        updateHotKey(for: NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.updateHotKey(for: note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }

        tracker.onClosed = { [weak self] item in
            self?.store.push(item)
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        DebugLog.write("launch: accessibility trusted = \(trusted), hotkey taken = \(hotKeyTaken)")
        if trusted {
            tracker.start()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.tracker.start()
            }
        }
    }

    /// `reopen://last` does what ⇧⌘T does, for Shortcuts, Raycast or scripts.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "reopen" && url.host == "last" {
            reopenLast()
        }
    }

    private func updateHotKey(for app: NSRunningApplication?) {
        let bundleID = app?.bundleIdentifier ?? ""
        if passthroughBundleIDs.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") {
            hotKey.unregister()
        } else {
            // Retried on every app switch, so the shortcut comes back once the other app releases it.
            let taken = !hotKey.register()
            if taken != hotKeyTaken { DebugLog.write(taken ? "⇧⌘T unavailable (taken)" : "⇧⌘T registered") }
            hotKeyTaken = taken
        }
    }

    private func reopenLast() {
        DebugLog.write("reopen requested, \(store.items.count) in history")
        guard let window = store.popLatestAvailable() else {
            NSSound.beep()
            return
        }
        reopener.reopen(window)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        let reopenItem = item("Reopen Last Closed Window", #selector(reopenLastFromMenu), key: hotKeyTaken ? "" : "t")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
        reopenItem.isEnabled = !store.items.isEmpty
        menu.addItem(reopenItem)
        if hotKeyTaken {
            let warning = NSMenuItem(title: "⇧⌘T is already used by another app", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        if store.items.isEmpty {
            let empty = NSMenuItem(title: "No closed windows yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for closed in store.items.prefix(15) {
                let entry = item(closed.menuTitle, #selector(reopenFromMenu(_:)))
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
        guard let id = sender.representedObject as? UUID, let window = store.remove(id: id) else { return }
        guard window.isAvailable else {
            NSSound.beep()
            return
        }
        reopener.reopen(window)
    }

    @objc private func clearHistory() {
        store.clear()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
