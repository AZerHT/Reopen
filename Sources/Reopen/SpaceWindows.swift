import ApplicationServices
import CoreGraphics
import Darwin

/// Accessibility lists an app's windows on the current Space only. The app still answers for elements
/// on other Spaces, if one has their id: window switchers build them with the private
/// `_AXUIElementCreateWithRemoteToken` and probe the first ids. Reopen does the same, once per app.
enum SpaceWindows {
    private static let createWithRemoteToken: ((CFData) -> AXUIElement?)? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else { return nil }
        typealias Function = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
        let function = unsafeBitCast(symbol, to: Function.self)
        return { function($0)?.takeRetainedValue() }
    }()

    /// Whether WindowServer holds more normal-level windows for `pid` than Accessibility shows here.
    static func hasWindowsElsewhere(pid: pid_t, visibleCount: Int) -> Bool {
        guard createWithRemoteToken != nil,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let count = list.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            // Tiny layer-0 windows are helpers, not document windows.
            return (bounds["Width"] ?? 0) > 100 && (bounds["Height"] ?? 0) > 100
        }.count
        return count > visibleCount
    }

    /// Standard windows of `pid` on every Space. Slow (up to a thousand requests): call off the main thread.
    static func all(pid: pid_t) -> [AXUIElement] {
        guard let create = createWithRemoteToken else { return [] }
        // Token layout: pid, 0, 'coco', element id.
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            bytes.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            bytes.storeBytes(of: Int32(0x636F_636F), toByteOffset: 8, as: Int32.self)
        }

        var windows: [AXUIElement] = []
        for id in UInt64(0)..<1000 {
            token.withUnsafeMutableBytes { $0.storeBytes(of: id, toByteOffset: 12, as: UInt64.self) }
            guard let element = create(token as CFData) else { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            if element.isStandardWindow {
                windows.append(element)
            }
        }
        return windows
    }
}
