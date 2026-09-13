import AppKit
import ApplicationServices

extension AXUIElement {
    func value(of attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(of: attribute) as? String
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(of: attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func bool(_ attribute: String) -> Bool? {
        (value(of: attribute) as? NSNumber)?.boolValue
    }

    var children: [AXUIElement] {
        (value(of: kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// A native tab bar holding several tabs: there ⌘W closes a tab, not the window.
    var hasSeveralTabs: Bool {
        children.contains { child in
            child.string(kAXRoleAttribute) == kAXTabGroupRole && ((child.value(of: kAXTabsAttribute) as? [AXUIElement])?.count ?? 0) > 1
        }
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    /// Windows of an application element. Only lists windows on the current Space.
    var windows: [AXUIElement] {
        (value(of: kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    var isStandardWindow: Bool {
        string(kAXRoleAttribute) == kAXWindowRole && string(kAXSubroleAttribute) == kAXStandardWindowSubrole
    }

    /// The file or URL a window represents — what AppKit shows as the title bar proxy icon.
    var documentURL: URL? {
        guard let raw = string(kAXDocumentAttribute), !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return URL(string: raw)
    }

    /// Frame in global screen coordinates, top-left origin (the Accessibility convention).
    var frame: CGRect? {
        guard let position = axValue(kAXPositionAttribute), let size = axValue(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Brings the window to the front of its app and its app to the front, on whatever Space it is.
    func focus(pid: pid_t) {
        AXUIElementSetMessagingTimeout(self, 0.3)
        if bool(kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(self, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(self, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    func setPosition(_ origin: CGPoint) {
        var point = origin
        guard let position = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, position)
    }

    func setFrame(_ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        // Position again after resizing: a window moving to a smaller screen may have been clamped.
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, position)
    }

    private func axValue(_ attribute: String) -> AXValue? {
        guard let value = value(of: attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}

extension URL {
    /// Comparable identity: `file:///a/b/` and `/a/b` are the same folder.
    var matchKey: String {
        isFileURL ? standardizedFileURL.resolvingSymlinksInPath().path : absoluteString
    }
}
