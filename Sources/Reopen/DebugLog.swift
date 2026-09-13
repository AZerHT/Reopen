import Foundation

/// Plain-text trace in `~/Library/Application Support/Reopen/debug.log`, to diagnose what an app exposes.
/// It records window titles and paths, so it is off unless enabled:
/// `defaults write io.github.azerht.reopen DebugLog -bool true`.
enum DebugLog {
    private static let enabled = UserDefaults.standard.bool(forKey: "DebugLog")

    private static let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reopen", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug.log")
    }()

    static func write(_ message: String) {
        guard enabled else { return }
        let line = Data("\(Date()) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
