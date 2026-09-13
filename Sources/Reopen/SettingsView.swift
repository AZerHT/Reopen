import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: .shared)))
            window.title = "Reopen Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var selectedApps = Set<String>()

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Text("Reopen the last closed window")
                    Spacer()
                    ShortcutRecorder(shortcut: $settings.shortcut, defaultShortcut: .default)
                }
            }

            Section {
                HStack {
                    Text("Previous window")
                    Spacer()
                    ShortcutRecorder(shortcut: $settings.backShortcut, defaultShortcut: .back)
                }
                HStack {
                    Text("Next window")
                    Spacer()
                    ShortcutRecorder(shortcut: $settings.forwardShortcut, defaultShortcut: .forward)
                }
            } header: {
                Text("Window history")
            } footer: {
                Text("Go back through the windows you used, across all apps, like a browser's Back and Forward buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide closed windows instead of closing them", isOn: $settings.softCloseEnabled)
                Picker("Close them for real after", selection: $settings.softCloseDelay) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                }
                .disabled(!settings.softCloseEnabled)
            } header: {
                Text("Soft close (beta)")
            } footer: {
                Text("Within the delay, the shortcut brings a window back exactly as it was, even an untitled document. A hidden window keeps running, so apps playing or recording sound are closed normally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                List(selection: $selectedApps) {
                    ForEach(settings.passthroughBundleIDs, id: \.self) { bundleID in
                        AppRow(bundleID: bundleID)
                    }
                }
                .frame(height: 180)
                HStack {
                    Button("Add App…", action: addApp)
                    Button("Remove") {
                        settings.passthroughBundleIDs.removeAll { selectedApps.contains($0) }
                        selectedApps.removeAll()
                    }
                    .disabled(selectedApps.isEmpty)
                    Spacer()
                    Button("Restore Defaults") {
                        settings.passthroughBundleIDs = Settings.defaultPassthrough
                    }
                }
            } header: {
                Text("Leave the shortcut to these apps")
            } footer: {
                Text("They already use it for closed tabs. Soft close doesn't intercept ⌘W in them either, since it closes a tab there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !settings.passthroughBundleIDs.contains($0) }
        settings.passthroughBundleIDs.append(contentsOf: added)
    }
}

private struct AppRow: View {
    let bundleID: String

    var body: some View {
        HStack {
            if let url = appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 16, height: 16)
                Text(bundleID)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appURL: URL? {
        bundleID.hasSuffix("*") ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let defaultShortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Type a shortcut…" : shortcut.display) {
                recording ? stop() : start()
            }
            .frame(minWidth: 130)
            if shortcut != defaultShortcut {
                Button {
                    shortcut = defaultShortcut
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Back to \(defaultShortcut.display)")
            }
        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // Without ⌘, ⌃ or ⌥ the shortcut would swallow ordinary typing.
            guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
            let key = Shortcut.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            shortcut = Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue, key: key)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
