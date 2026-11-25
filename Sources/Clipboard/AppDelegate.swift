import AppKit
import ClipboardCore
import SuiteCore
import ClipboardSettings
import SpotlightGuard

/// Ties the pieces together: the watcher records copies, holding ⌘V (or Explorer's Edit menu) opens
/// the panel, and choosing an item pastes it into the app that was in front. "Show All" opens the
/// whole history in a window. Its settings are a tab of Explorer's, which it hears about through
/// `ClipboardMessage`.
final class ClipboardAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = ClipboardSettings()
    private(set) lazy var model = HistoryModel(store: ClipboardStore(), limit: settings.historyLimit)
    private let watcher = ClipboardWatcher()
    private let holdToPaste = HoldToPaste()
    private lazy var listController = HistoryViewController(model: model)
    private lazy var panel = HistoryPanel(contentViewController: listController)
    private lazy var windowController = HistoryViewController(model: model, mode: .window)
    private lazy var historyWindow = HistoryWindow(contentViewController: windowController)
    private var statusTimer: Timer?
    private var expiryTimer: Timer?
    private var backupTimer: Timer?
    private var backsUp = false
    private let backupQueue = DispatchQueue(label: "local.suite.clipboard.backup", qos: .utility)
    /// Spotlight's own clipboard history (macOS 26), which Clipboard's replaces: off while Clipboard runs,
    /// so the two don't both keep the copies, back as the user had it when Clipboard stops. Suite Guard
    /// puts it back should Clipboard vanish (a crash, a forced quit).
    private let spotlightHistory = SpotlightHistoryManager()

    /// Clipboard keeps itself up to date from its own releases, once its panel and history window are
    /// closed; the new copy takes over from this one (`AppRelauncher`).
    static let updater = SuiteUpdater(appName: "Clipboard")

    func applicationWillTerminate(_ notification: Notification) {
        // Reopening itself (an update), the new copy takes over: Spotlight's history stays off.
        guard !AppRelauncher.isRelaunching else { return }
        putSpotlightHistoryBack()
    }

    private func putSpotlightHistoryBack() {
        spotlightHistory.restore()
        GuardAgent.update()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Turned off in Suite Settings: nothing to do (Spotlight's history back, should a crash have kept it off).
        guard settings.isEnabled else {
            putSpotlightHistoryBack()
            NSApp.terminate(nil)
            return
        }
        // Clipboard's history in place of Spotlight's.
        spotlightHistory.turnOff()
        GuardAgent.update()
        NSApp.mainMenu = makeMainMenu()
        Self.updater.start()

        watcher.filter = { [settings] in settings.filter }
        watcher.onCopy = { [weak self] snapshot, source, name in
            self?.model.record(snapshot, sourceApp: source, sourceName: name)
        }
        watcher.start()

        for controller in [listController, windowController] {
            controller.onPaste = { [weak self] item, plain in self?.choose(item, plainText: plain, paste: true) }
            controller.onCopy = { [weak self] item in self?.choose(item, plainText: false, paste: false) }
            controller.onShowSettings = { [weak self] in self?.showSettings() }
            controller.onAllowPasting = { [weak self] in
                self?.closePanel()
                Paster.openAccessibilitySettings()
            }
            controller.quickListSize = { [settings] in settings.quickListSize }
        }
        listController.onClose = { [weak self] in self?.closePanel() }
        listController.onShowAll = { [weak self] search in self?.showAll(search: search) }
        listController.onPinChanged = { [weak self] pinned in
            guard let self else { return }
            panel.setPinned(pinned, onTop: settings.pinnedListOnTop)
        }
        panel.keyEquivalentHandler = { [weak self] event in self?.listController.handleKeyEquivalent(event) ?? false }
        panel.keyDownHandler = { [weak self] event in self?.listController.handleKeyDown(event) ?? false }
        panel.delegate = self
        panel.onClose = { [weak self] in
            self?.listController.didClose()
            self?.holdToPaste.panelClosed()
        }
        windowController.onClose = { [weak self] in self?.historyWindow.performClose(nil) }
        historyWindow.keyEquivalentHandler = { [weak self] event in
            self?.windowController.handleKeyEquivalent(event) ?? false
        }
        historyWindow.keyDownHandler = { [weak self] event in self?.windowController.handleKeyDown(event) ?? false }
        historyWindow.delegate = self

        holdToPaste.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .openPanel:
                // Pinned and open already: brought to the front.
                self.panel.isVisible ? self.panel.orderFrontRegardless() : self.showPanel()
            case .selectNext: self.listController.selectNext()
            case .commit:
                if let item = self.listController.selectedItem { self.choose(item, plainText: false, paste: true) }
            default: break
            }
        }
        holdToPaste.setEnabled(settings.holdsCommandV)
        listenToExplorer()
        reportStatus()
        // Accessibility can be given or taken away at any time in System Settings.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reportStatus() }
        forgetExpiredItems()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.forgetExpiredItems()
        }
        // Another Space: the list stays behind and closes, unless it is pinned.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self, !listController.isPinned else { return }
            closePanel()
        }
        NotificationCenter.default.addObserver(forName: .clipboardHistoryDidChange, object: model, queue: .main) {
            [weak self] _ in self?.scheduleBackup()
        }
        updateBackup()
        // Pictures kept before text recognition existed, once launch is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.model.readTextOfPictures() }

        if CommandLine.arguments.contains("--show") {
            showPanel()
        }
    }

    // MARK: Explorer

    private func listenToExplorer() {
        ClipboardMessage.settingsDidChange.observe { [weak self] _ in
            Self.updater.bringSettingsUpToDate()
            guard let self else { return }
            settings.reload()
            guard settings.isEnabled else {
                NSApp.terminate(nil)
                return
            }
            model.setLimit(settings.historyLimit)
            forgetExpiredItems()
            updateBackup()
            holdToPaste.setEnabled(settings.holdsCommandV)
            panel.setPinned(listController.isPinned, onTop: settings.pinnedListOnTop)
            // The quick list's size.
            NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: model)
        }
        ClipboardMessage.clearHistory.observe { [weak self] _ in self?.model.clear() }
        ClipboardMessage.requestAccessibility.observe { _ in Paster.openAccessibilitySettings() }
        ClipboardMessage.setOpensAtLogin.observe { [weak self] note in
            LoginItem.set(note.userInfo?["on"] as? Bool == true)
            self?.reportStatus(force: true)
        }
    }

    // MARK: iCloud Drive backup

    private var backup: ClipboardBackup? {
        ClipboardBackup.defaultRoot.map { ClipboardBackup(store: model.store.folder, root: $0) }
    }

    /// Turned on: an empty history comes back from this Mac's backup (a reinstall) or the latest
    /// another Mac made (a new Mac); otherwise the history is backed up.
    private func updateBackup() {
        let on = settings.backsUpToICloud
        defer { backsUp = on }
        guard on, !backsUp, let backup else { return }
        if model.items.isEmpty, let source = backup.restoreSource {
            do {
                try backup.restore(from: source)
                model.reloadFromStore()
            } catch {
                NSLog("Clipboard: could not restore the history from iCloud Drive: \(error)")
            }
        } else {
            scheduleBackup(after: 1)
        }
    }

    /// A while after the last change, so a burst of copies makes one backup.
    private func scheduleBackup(after delay: TimeInterval = 20) {
        guard settings.backsUpToICloud, let backup else { return }
        backupTimer?.invalidate()
        backupTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.backupQueue.async {
                do {
                    try backup.backUp()
                } catch {
                    NSLog("Clipboard: could not back the history up to iCloud Drive: \(error)")
                }
            }
        }
    }

    private func forgetExpiredItems() {
        if let date = settings.expiryDate() { model.removeItems(copiedBefore: date) }
    }

    /// Tells Explorer's Settings what only this app can know.
    private func reportStatus(force: Bool = false) {
        let canPaste = Paster.canPostKeys, login = LoginItem.status
        guard force || canPaste != settings.canPaste || login != settings.loginStatus else { return }
        settings.canPaste = canPaste
        settings.loginStatus = login
        ClipboardMessage.statusDidChange.post()
    }

    /// Opened again (Explorer's Edit menu, a double-click, its Dock icon): the history window when it
    /// is open, else the list.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if historyWindow.isVisible {
            historyWindow.makeKeyAndOrderFront(nil)
        } else {
            showPanel()
        }
        return false
    }

    // MARK: Panel

    @objc func showPanel() {
        listController.prepareToShow()
        panel.setFrameTopLeftPoint(panelOrigin(for: panel.frame.size))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(listController.searchField)
    }

    private func closePanel() {
        panel.orderOut(nil)
    }

    /// A click elsewhere closes the list, unless it is pinned.
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel, !listController.isPinned { closePanel() }
        if (notification.object as? NSWindow) === historyWindow { windowController.hideTip() }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === historyWindow else { return }
        windowController.didClose()
        // Out of the Dock again with its window.
        NSApp.setActivationPolicy(.accessory)
        ClipboardMessage.dockPresenceDidChange.post()
    }

    /// The whole history in its window, with the search typed in the list.
    private func showAll(search: String) {
        if !listController.isPinned { closePanel() }
        // In the Dock and ⌘Tab while the window is open, like any app with a window.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            ClipboardMessage.dockPresenceDidChange.post()
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow.makeKeyAndOrderFront(nil)
        windowController.prepareToShow(search: search)
    }

    /// Above and to the right of the text caret (below it when there is no room above), else at the
    /// mouse; kept on screen. Returns the panel's top-left corner.
    private func panelOrigin(for size: NSSize) -> NSPoint {
        let caret = Paster.caretRect() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let anchor = NSPoint(x: caret.maxX, y: caret.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let gap: CGFloat = 4
        var top = caret.maxY + gap + size.height
        if top > visible.maxY {
            top = caret.minY - gap
        }
        top = min(max(top, visible.minY + size.height), visible.maxY)
        let left = min(max(caret.maxX + gap, visible.minX), visible.maxX - size.width)
        return NSPoint(x: left, y: top)
    }

    // MARK: Pasting

    /// Puts the item back on the pasteboard and, when it may, pastes it with Cmd+V.
    private func choose(_ item: ClipItem, plainText: Bool, paste: Bool) {
        guard let snapshot = model.snapshot(for: item.id) else {
            NSSound.beep()
            model.remove(item.id)
            return
        }
        watcher.ignore(changeCount: Paster.put(plainText ? Paster.plainText(of: snapshot) : snapshot))
        model.moveToTop(item.id)
        let staysOpen = listController.isPinned && panel.isVisible
        if !staysOpen { closePanel() }
        guard paste else { return }

        guard Paster.canPostKeys else {
            explainAccessibility()
            return
        }
        // From the history window, the app the user came from takes over before the paste.
        if NSApp.isActive { NSApp.hide(nil) }
        // A pinned list keeps the keyboard while it is the key window: it steps aside for the paste.
        if staysOpen && panel.isKeyWindow { panel.stepAside(for: 0.3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.postPaste() }
    }

    /// The first time an item can only be copied, says why and how to allow pasting; later, the
    /// panel's banner says it.
    private func explainAccessibility() {
        guard !settings.hasExplainedAccessibility else { return }
        settings.hasExplainedAccessibility = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The item is copied: press ⌘V to paste it."
        alert.informativeText = """
            To paste it for you into the app you were using, Clipboard needs Accessibility \
            access: in System Settings › Privacy & Security › Accessibility, turn on Clipboard.
            """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        let answer = alert.runModal()
        if answer == .alertFirstButtonReturn {
            Paster.openAccessibilitySettings()
        } else {
            NSApp.hide(nil)
        }
    }

    // MARK: Settings, menus

    /// The settings are Explorer's Clipboard tab.
    @objc func showSettings() {
        closePanel()
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.suite.explorer").isEmpty,
           let explorer = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.suite.explorer") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--clipboard-settings"]
            NSWorkspace.shared.openApplication(at: explorer, configuration: configuration)
        } else {
            ClipboardMessage.showSettings.post()
        }
    }

    /// Shown while one of its alerts is in front.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("Clipboard")
        app.addItem(withTitle: "About Clipboard",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Clipboard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Clipboard", action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = submenu("Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = window
        return main
    }
}
