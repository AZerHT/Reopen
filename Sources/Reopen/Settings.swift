import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Device-independent modifier flags, as `NSEvent.ModifierFlags` raw value.
    var modifiers: UInt
    /// What the key prints, for display.
    var key: String

    static let `default` = Shortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "T")
    // ⌃← and ⌃→ already switch Spaces: history adds ⌥.
    static let back = Shortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "←")
    static let forward = Shortcut(keyCode: UInt16(kVK_RightArrow), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "→")

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// What `NSMenuItem.keyEquivalent` expects: arrows and other special keys are function-key characters.
    var menuKeyEquivalent: String {
        let special: [Int: Int] = [
            kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
            kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        ]
        if let code = special[Int(keyCode)], let scalar = UnicodeScalar(code) { return String(Character(scalar)) }
        return key.count == 1 ? key.lowercased() : ""
    }

    /// A readable name for a key: arrows and special keys have no printable character.
    static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        default: return characters?.uppercased() ?? "?"
        }
    }

    var display: String {
        var text = ""
        if modifierFlags.contains(.control) { text += "⌃" }
        if modifierFlags.contains(.option) { text += "⌥" }
        if modifierFlags.contains(.shift) { text += "⇧" }
        if modifierFlags.contains(.command) { text += "⌘" }
        return text + key
    }

    func matches(keyCode: Int64, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == Int64(self.keyCode) && flags == modifierFlags
    }

    static func flags(from eventFlags: CGEventFlags) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if eventFlags.contains(.maskCommand) { flags.insert(.command) }
        if eventFlags.contains(.maskShift) { flags.insert(.shift) }
        if eventFlags.contains(.maskAlternate) { flags.insert(.option) }
        if eventFlags.contains(.maskControl) { flags.insert(.control) }
        return flags
    }
}

/// User settings, kept in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Apps that already give ⇧⌘T a meaning of their own (closed tabs, closed editors). A trailing `*` matches a prefix.
    static let defaultPassthrough = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.*",
    ]

    private let defaults = UserDefaults.standard

    @Published var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }
    @Published var backShortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(backShortcut), forKey: "backShortcut") }
    }
    @Published var forwardShortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(forwardShortcut), forKey: "forwardShortcut") }
    }
    @Published var passthroughBundleIDs: [String] {
        didSet { defaults.set(passthroughBundleIDs, forKey: "passthroughBundleIDs") }
    }
    @Published var softCloseEnabled: Bool {
        didSet { defaults.set(softCloseEnabled, forKey: "softCloseEnabled") }
    }
    /// Seconds a soft-closed window stays hidden before it is closed for real.
    @Published var softCloseDelay: Double {
        didSet { defaults.set(softCloseDelay, forKey: "softCloseDelay") }
    }

    private init() {
        shortcut = Self.shortcut(forKey: "shortcut", defaults: defaults) ?? .default
        backShortcut = Self.shortcut(forKey: "backShortcut", defaults: defaults) ?? .back
        forwardShortcut = Self.shortcut(forKey: "forwardShortcut", defaults: defaults) ?? .forward
        passthroughBundleIDs = defaults.stringArray(forKey: "passthroughBundleIDs") ?? Self.defaultPassthrough
        softCloseEnabled = defaults.bool(forKey: "softCloseEnabled")
        let delay = defaults.double(forKey: "softCloseDelay")
        softCloseDelay = delay > 0 ? delay : 30
    }

    private static func shortcut(forKey key: String, defaults: UserDefaults) -> Shortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    func leavesShortcut(to bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return passthroughBundleIDs.contains { pattern in
            pattern.hasSuffix("*") ? bundleID.hasPrefix(pattern.dropLast()) : bundleID == pattern
        }
    }
}
