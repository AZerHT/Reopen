import ApplicationServices
import Foundation

/// Drives an app's own menus through Accessibility, without opening them.
enum AppMenu {
    private static let windowWords = ["window", "fenêtre", "fenster", "ventana", "finestra", "janela", "venster", "fönster", "vindue", "окно", "窗口", "ウインドウ", "윈도우"]
    private static let newWords = ["new", "nouvelle", "nouveau", "neues", "neue", "nueva", "nuova", "nova", "nieuw", "ny", "новое", "新建", "新規", "새"]

    /// Presses the app's "New Window" item. False if the app has none.
    static func pressNewWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar = app.element(kAXMenuBarAttribute) else { return false }

        var fallback: AXUIElement?
        // Skip the Apple menu.
        for menuBarItem in menuBar.children.dropFirst() {
            for menu in menuBarItem.children {
                for item in menu.children {
                    let title = (item.string(kAXTitleAttribute) ?? "").lowercased()
                    guard windowWords.contains(where: title.contains), item.bool(kAXEnabledAttribute) != false else { continue }
                    let isCommandN = item.string(kAXMenuItemCmdCharAttribute) == "N"
                        && (item.value(of: kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
                    if isCommandN {
                        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                    }
                    if fallback == nil, newWords.contains(where: title.contains) {
                        fallback = item
                    }
                }
            }
        }
        guard let fallback else { return false }
        return AXUIElementPerformAction(fallback, kAXPressAction as CFString) == .success
    }
}
