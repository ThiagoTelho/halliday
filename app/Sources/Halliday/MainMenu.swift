// The app's menu bar (ROADMAP W11.A). Without one, AppKit has no key equivalents at all: ⌘C/⌘V/⌘A
// did nothing in the browser and in text fields. Browser commands act on Halliday's browser,
// opening it when needed.

import AppKit

extension AppDelegate {
    func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        let name = RuntimePaths.displayName
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if Updates.shared.available { appMenu.addItem(item("Check for Updates…", #selector(menuCheckForUpdates), "", [], target: self)) }
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(menuSettings), ",", .command, target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: name, to: main)

        let file = NSMenu(title: "File")
        file.addItem(item("New Browser Window", #selector(menuNewWindow), "n", .command, target: self))
        file.addItem(item("New Tab", #selector(menuNewTab), "t", .command, target: self))
        file.addItem(item("New Private Tab", #selector(menuNewPrivateTab), "n", [.command, .shift], target: self))
        file.addItem(item("Open Location…", #selector(menuOpenLocation), "l", .command, target: self))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(menuCloseTab), "w", .command, target: self))
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(item("Find in Page…", #selector(menuFind), "f", .command, target: self))
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(item("Fill the Screen", #selector(toggleFillScreen), "f", [.command, .control], target: self))
        view.addItem(.separator())
        view.addItem(item("Reload Page", #selector(menuReload), "r", .command, target: self))
        view.addItem(item("Zoom In", #selector(menuZoomIn), "=", .command, target: self))
        view.addItem(item("Zoom Out", #selector(menuZoomOut), "-", .command, target: self))
        view.addItem(item("Actual Size", #selector(menuZoomReset), "0", .command, target: self))
        view.addItem(item("Bookmark This Page", #selector(menuBookmark), "d", .command, target: self))
        view.addItem(item("Show History", #selector(menuHistory), "y", .command, target: self))
        view.addItem(item("Back", #selector(menuBack), "[", .command, target: self))
        view.addItem(item("Forward", #selector(menuForward), "]", .command, target: self))
        view.addItem(.separator())
        view.addItem(item("Show Next Tab", #selector(menuNextTab), "\t", [.control], target: self))
        view.addItem(item("Show Previous Tab", #selector(menuPreviousTab), "\t", [.control, .shift], target: self))
        view.addItem(item("Show Next Tab", #selector(menuNextTab), "]", [.command, .shift], target: self))
        view.addItem(item("Show Previous Tab", #selector(menuPreviousTab), "[", [.command, .shift], target: self))
        add(view, title: "View", to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Companion", #selector(menuCompanion), "c", [.command, .shift], target: self))
        add(windowMenu, title: "Window", to: main)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    /// A menu item; with no target, its action goes down the responder chain (editing commands),
    /// with `self`, to the app delegate (browser commands).
    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                      target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.target = target
        i.tag = tag
        return i
    }

    /// The browser when its window is the one being used (so ⌘W doesn't close a tab from elsewhere).
    private var focusedBrowser: BrowserWindow? {
        guard let b = browser, b.window.isKeyWindow || isEditingAddress else { return nil }
        return b
    }

    @objc func menuNewTab() {
        if let b = browser { b.openNewTab(private: false) } else { openBrowser()?.focusAddressBar() }
    }
    @objc func menuNewPrivateTab() { openBrowser()?.openNewTab(private: true) }
    @objc func menuOpenLocation() { openBrowser()?.focusAddressBar() }
    @objc func menuCloseTab() { focusedBrowser?.closeActiveTab() }
    @objc func menuNewWindow() { handleKey("b") }
    @objc func menuCompanion() { showCompanion() }
    @objc func menuCheckForUpdates() { Updates.shared.checkNow() }
    @objc func menuSettings() { handleKey(".") }
    @objc func menuReload() { focusedBrowser?.reloadPage() }
    @objc func menuHistory() { (focusedBrowser ?? openBrowser())?.showHistory() }
    @objc func menuZoomIn() { browser?.zoom(1) }
    @objc func menuZoomOut() { browser?.zoom(-1) }
    @objc func menuZoomReset() { browser?.zoom(0) }
    @objc func menuBookmark() { browser?.toggleBookmark() }
    @objc func menuFind() { findInPage() }
    @objc func menuBack() { focusedBrowser?.goBack() }
    @objc func menuForward() { focusedBrowser?.goForward() }
    @objc func menuNextTab() { focusedBrowser?.selectNextTab(1) }
    @objc func menuPreviousTab() { focusedBrowser?.selectNextTab(-1) }
}
