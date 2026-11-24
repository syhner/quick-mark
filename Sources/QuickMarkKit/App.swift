import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var welcome = WelcomeWindow()

    /// Called at launch and on Dock click when no images are open.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        welcome.makeKeyAndOrderFront(nil)
        return true
    }

    @objc func paste(_ sender: Any?) {
        if !ImageDocument.open(from: .general) { NSSound.beep() }
    }
}

/// Installs the app delegate and menus on `NSApp`, which the caller must have created.
/// Returns the delegate: NSApplication only holds it weakly.
public func setUpApp() -> NSApplicationDelegate {
    _ = NSDocumentController.shared
    let delegate = AppDelegate()
    NSApp.delegate = delegate

    let windowMenu = menu("Window", [
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
    ])
    NSApp.mainMenu = NSMenu()
    NSApp.mainMenu!.items = [
        menu("QuickMark", [
            item("About QuickMark", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide QuickMark", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit QuickMark", #selector(NSApplication.terminate(_:)), "q"),
        ]),
        menu("File", [
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(NSDocument.save(_:)), "s"),
            item("Save As…", #selector(NSDocument.saveAs(_:)), "S"),  // Uppercase means Shift.
        ]),
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Copy", #selector(ImageDocument.copy(_:)), "c"),
            item("Paste", #selector(AppDelegate.paste(_:)), "v"),
        ]),
        menu("Tools", Tool.allCases.map { tool in
            let toolItem = item(tool.title, #selector(EditorWindowController.selectTool(_:)), tool.key, [])
            toolItem.tag = tool.rawValue
            return toolItem
        }),
        windowMenu,
    ]
    NSApp.windowsMenu = windowMenu.submenu
    return delegate
}

private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = NSMenu(title: title)
    item.submenu!.items = items
    return item
}

private func item(_ title: String, _ action: Selector, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
}
