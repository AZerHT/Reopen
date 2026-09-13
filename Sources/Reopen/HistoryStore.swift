import Foundation

struct WindowState: Codable, Equatable {
    let title: String
    /// The file or folder the window showed; nil for a window without one (Spotify, Messages…).
    let documentURL: URL?
    let frame: CGRect?
}

/// A closed window, or a quit app with the windows it had.
struct ClosedItem: Codable, Identifiable, Equatable {
    let id: UUID
    let appName: String
    let bundleID: String?
    let appURL: URL
    let windows: [WindowState]
    let appQuit: Bool
    let closedAt: Date

    var menuTitle: String {
        guard appQuit else { return "\(windows.first?.title ?? appName) — \(appName)" }
        return windows.count == 1 ? "\(appName) — quit, 1 window" : "\(appName) — quit, \(windows.count) windows"
    }

    /// An uninstalled app, or a closed window whose file was deleted, can't come back.
    var isAvailable: Bool {
        guard FileManager.default.fileExists(atPath: appURL.path) else { return false }
        if appQuit { return true }
        return windows.allSatisfy { state in
            state.documentURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        }
    }
}

/// Recently closed windows and quit apps, newest first, persisted so they survive a restart.
final class HistoryStore {
    private(set) var items: [ClosedItem] = []
    private let limit = 30
    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reopen", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ClosedItem].self, from: data) {
            items = saved
        }
    }

    func push(_ item: ClosedItem) {
        // The same document closed twice, or the same app quit twice, keeps only its latest entry.
        items.removeAll { old in
            old.bundleID == item.bundleID && old.appQuit == item.appQuit
                && (item.appQuit || old.windows.first?.documentURL?.matchKey == item.windows.first?.documentURL?.matchKey)
        }
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    func popLatestAvailable() -> ClosedItem? {
        defer { save() }
        while !items.isEmpty {
            let item = items.removeFirst()
            if item.isAvailable { return item }
        }
        return nil
    }

    func remove(id: UUID) -> ClosedItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        defer { save() }
        return items.remove(at: index)
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
