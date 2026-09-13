import AppKit
import ApplicationServices

/// An untitled document only lives inside its app: macOS autosaves it while it's open, then deletes that copy
/// when the window closes. Just before such a window closes, Reopen reads its text — fonts and colours
/// included — through Accessibility and keeps it in a file that can be reopened.
enum UntitledRescue {
    private static let untitledWords = [
        "untitled", "sans titre", "ohne titel", "unbenannt", "sin título", "senza titolo", "sem título",
        "naamloos", "namnlös", "uden titel", "без названия", "未命名", "名称未設定", "제목 없음",
    ]

    static let directory: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reopen/Recovered", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func looksUntitled(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return untitledWords.contains { lowered.hasPrefix($0) }
    }

    /// Saves the window's main text as RTF. Nil when there's no text to save.
    static func rescue(from window: AXUIElement, title: String) -> URL? {
        guard let textArea = ViewStateAccess.largestTextArea(in: window),
              let count = (textArea.value(of: kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue, count > 0 else { return nil }
        AXUIElementSetMessagingTimeout(textArea, 0.3)

        var range = CFRange(location: 0, length: min(count, 500_000))
        var styled: CFTypeRef?
        let text: NSAttributedString
        if let rangeValue = AXValueCreate(.cfRange, &range),
           AXUIElementCopyParameterizedAttributeValue(textArea, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &styled) == .success,
           let accessibilityText = styled as? NSAttributedString {
            text = appKitText(from: accessibilityText)
        } else if let plain = textArea.string(kAXValueAttribute) {
            text = NSAttributedString(string: plain)
        } else {
            return nil
        }

        guard let data = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return nil }
        let url = directory.appendingPathComponent("\(fileName(for: title)) \(timestamp()).rtf")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Rescued documents are a safety net, not an archive.
    static func removeOlderThan(days: Int) {
        let limit = Date().addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < limit {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Accessibility describes styling with its own keys (AXFont, AXForegroundColor):
    /// turn fonts and colours into AppKit attributes.
    private static func appKitText(from source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source.string)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            if let font = attributes[NSAttributedString.Key("AXFont")] as? [String: Any],
               let name = font["AXFontName"] as? String,
               let size = (font["AXFontSize"] as? NSNumber)?.doubleValue,
               let appKitFont = NSFont(name: name, size: size) {
                result.addAttribute(.font, value: appKitFont, range: range)
            }
            if let color = attributes[NSAttributedString.Key("AXForegroundColor")],
               CFGetTypeID(color as CFTypeRef) == CGColor.typeID,
               let appKitColor = NSColor(cgColor: color as! CGColor) {
                result.addAttribute(.foregroundColor, value: appKitColor, range: range)
            }
        }
        return result
    }

    private static func fileName(for title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(60))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}
