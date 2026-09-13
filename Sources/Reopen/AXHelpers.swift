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
