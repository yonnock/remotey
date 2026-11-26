import AppKit

/// The menu of an app without a menu bar of its own: nobody sees it, but its key equivalents work while one of
/// Remotey's windows has the keyboard. Without it ⌘V would not paste into a password field and ⌘W would not
/// close a window.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(Texts.Menu.name, [
            item(Texts.Menu.settings, #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item(Texts.Menu.quit, #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu(Texts.MainMenu.edit, [
            item(Texts.MainMenu.undo, Selector(("undo:")), "z"),
            item(Texts.MainMenu.redo, Selector(("redo:")), "Z"),
            .separator(),
            item(Texts.MainMenu.cut, #selector(NSText.cut(_:)), "x"),
            item(Texts.MainMenu.copy, #selector(NSText.copy(_:)), "c"),
            item(Texts.MainMenu.paste, #selector(NSText.paste(_:)), "v"),
            item(Texts.MainMenu.selectAll, #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu(Texts.MainMenu.window, [
            item(Texts.MainMenu.close, #selector(NSWindow.performClose(_:)), "w"),
            item(Texts.MainMenu.minimize, #selector(NSWindow.performMiniaturize(_:)), "m"),
        ]))
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }
}
