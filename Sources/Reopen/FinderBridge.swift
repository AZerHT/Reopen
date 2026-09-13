import AppKit

/// Finder windows don't expose their folder through Accessibility (AXDocument is nil),
/// so Finder is asked over Apple Events. The first call triggers macOS's Automation consent prompt.
enum FinderBridge {
    static let bundleID = "com.apple.finder"

    typealias Target = (frame: CGRect, url: URL)

    private static let script = NSAppleScript(source: """
        tell application id "com.apple.finder"
            set output to ""
            -- Index the windows: a `repeat with … in` loop variable is a lazy reference that Finder resolves badly.
            repeat with i from 1 to (count Finder windows)
                try
                    set b to bounds of Finder window i
                    set folderPath to POSIX path of (target of Finder window i as alias)
                    set output to output & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & tab & folderPath & linefeed
                on error errorMessage number errorNumber
                    -- Windows without a folder (Recents, AirDrop, searches) land here; kept for the debug log.
                    set output to output & "error" & tab & (errorNumber as text) & " " & errorMessage & linefeed
                end try
            end repeat
            return output
        end tell
        """)

    /// Several windows are refreshed in a row on app activation: one Apple Event is enough.
    private static var cache: (date: Date, targets: [Target])?

    static func windowTargets() -> [Target] {
        if let cache, Date().timeIntervalSince(cache.date) < 0.3 { return cache.targets }
        var error: NSDictionary?
        let output = script?.executeAndReturnError(&error).stringValue
        if let error { DebugLog.write("Finder script failed: \(error)") }
        DebugLog.write("Finder script output: \(output.map { "\"\($0)\"" } ?? "nil")")

        let targets = (output ?? "").split(separator: "\n").compactMap { line -> Target? in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let edges = parts[0].split(separator: ",").compactMap { Double($0) }
            guard edges.count == 4, parts[1].hasPrefix("/") else { return nil }
            // Finder bounds are {left, top, right, bottom}, top-left origin like Accessibility.
            let frame = CGRect(x: edges[0], y: edges[1], width: edges[2] - edges[0], height: edges[3] - edges[1])
            return (frame, URL(fileURLWithPath: String(parts[1])))
        }
        cache = (Date(), targets)
        return targets
    }

    /// The folder shown by the Finder window whose bounds match `frame`.
    static func folder(near frame: CGRect?) -> URL? {
        let targets = windowTargets()
        guard let frame else { return targets.count == 1 ? targets[0].url : nil }
        guard let best = targets.min(by: { distance($0.frame, frame) < distance($1.frame, frame) }),
              distance(best.frame, frame) < 60 else {
            if !targets.isEmpty { DebugLog.write("Finder: no window matches \(frame) among \(targets.map { $0.frame })") }
            return nil
        }
        return best.url
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
