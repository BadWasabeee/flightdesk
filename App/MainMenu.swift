import Cocoa

/// The app's main menu bar, built in code (there is no storyboard).
@MainActor
enum MainMenu {
    /// Installs the main menu. App-level items go to `app`; window items to its main window controller.
    static func install(for app: AppDelegate) {
        let main = NSMenu()
        let name = "FlightDesk"
        let window = app.mainWindow

        let appMenu = submenu(of: main, name)
        appMenu.addItem(item("About \(name)", #selector(AppDelegate.about), target: app))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppDelegate.showSettings), ",", target: app))
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(of: main, "File")
        file.addItem(item("New Window", #selector(MainWindowController.showWindow(_:)), "n", target: window))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))

        let edit = submenu(of: main, "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        let view = submenu(of: main, "View")
        view.addItem(item("Refresh", #selector(MainWindowController.refresh(_:)), "r", target: window))
        view.addItem(item("Hide Sidebar", #selector(MainWindowController.toggleFlightList(_:)), "s", [.command, .control], target: window))

        let windows = submenu(of: main, "Window")
        windows.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windows.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windows.addItem(.separator())
        windows.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))

        let help = submenu(of: main, "Help")
        help.addItem(item("\(name) on GitHub", #selector(AppDelegate.openGitHub), target: app))

        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
        NSApp.helpMenu = help
    }

    private static func submenu(of bar: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    /// A menu item; with no `target` the action goes to the first responder.
    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
