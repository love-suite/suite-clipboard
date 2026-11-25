import AppKit
import ClipboardCore
import ClipboardSettings

/// The list, in the panel holding ⌘V opens (`.quick`: the latest items, "Show All" at the end, a
/// pin to keep it open) or in the history window (`.window`: everything). Enter or a click pastes
/// (a double-click in the window), Shift+Enter pastes plain text, the space bar shows the whole
/// item, Cmd+Delete or the × deletes, Cmd+1…9 pastes the nine latest copies in order; items drag
/// out to other apps, folders and the desktop.
final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSMenuDelegate {
    enum Mode { case quick, window }

    let mode: Mode
    let model: HistoryModel
    let thumbnails: Thumbnails
    var onPaste: ((ClipItem, _ plainText: Bool) -> Void)?
    var onCopy: ((ClipItem) -> Void)?
    var onShowSettings: (() -> Void)?
    var onClose: (() -> Void)?
    /// "Show All": the history window, with the search typed so far.
    var onShowAll: ((String) -> Void)?
    var onPinChanged: ((Bool) -> Void)?
    /// Whether Cmd+V can be posted; when not, a banner explains it.
    var canPaste: () -> Bool = { Paster.canPostKeys }
    var onAllowPasting: (() -> Void)?
    /// How many items the quick list shows.
    var quickListSize: () -> Int = { ClipboardSettings.defaultQuickListSize }

    private(set) var shown: [ClipItem] = []
    /// The quick list has more than it shows: its last row is "Show All".
    private var hiddenCount = 0
    private var crowdedMinutes: Set<Date> = []
    private(set) var isPinned = false
    let searchField = NSSearchField()
    let table = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton(title: NSLocalizedString("Clear All", comment: ""), target: nil, action: nil)
    private let pinButton = NSButton()
    private let banner = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private let preview = PreviewWindow()

    init(model: HistoryModel, mode: Mode = .quick) {
        self.model = model
        self.mode = mode
        thumbnails = Thumbnails(model: model)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .clipboardHistoryDidChange, object: model)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        if mode == .quick {
            let background = NSVisualEffectView()
            background.material = .popover
            background.blendingMode = .behindWindow
            background.state = .active
            background.maskImage = Self.roundedMask(radius: 12)
            view = background
        } else {
            let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
            background.material = .windowBackground
            background.blendingMode = .withinWindow
            background.state = .followsWindowActiveState
            view = background
        }

        let title = NSTextField(labelWithString: NSLocalizedString("Clipboard", comment: ""))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.isHidden = mode == .window
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.isBordered = false
        clearButton.attributedTitle = NSAttributedString(string: NSLocalizedString("Clear All", comment: ""), attributes: [
            .foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 12),
        ])
        clearButton.toolTip = NSLocalizedString("Delete every item", comment: "")
        pinButton.isBordered = false
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.isHidden = mode == .window
        updatePinButton()
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                                target: self, action: #selector(showSettings))
        settings.isBordered = false
        settings.toolTip = NSLocalizedString("Settings", comment: "")
        let header = NSStackView(views: [title, NSView(), clearButton, pinButton, settings])
        header.spacing = 10

        searchField.placeholderString = NSLocalizedString("Search", comment: "")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.focusRingType = .none

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        if mode == .quick {
            table.action = #selector(rowClicked)
        } else {
            table.action = #selector(rowSelectedByClick)
            table.doubleAction = #selector(rowClicked)
        }
        table.refusesFirstResponder = true
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor

        let bannerText = NSTextField(wrappingLabelWithString:
            NSLocalizedString("Holding ⌘V and pasting need Accessibility access. Until then, items are copied: press ⌘V.", comment: ""))
        bannerText.font = .systemFont(ofSize: 11)
        bannerText.textColor = .secondaryLabelColor
        let allow = NSButton(title: NSLocalizedString("Allow", comment: ""), target: self, action: #selector(allowPasting))
        allow.controlSize = .small
        allow.bezelStyle = .rounded
        banner.setViews([NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                    accessibilityDescription: nil)!), bannerText, allow], in: .leading)
        (banner.views[0] as? NSImageView)?.contentTintColor = .systemOrange
        banner.spacing = 6
        bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail

        // A hidden banner takes no room: the list goes down to the hints.
        let footer = NSStackView(views: [banner, hint])
        footer.orientation = .vertical
        footer.alignment = .centerX
        footer.spacing = 6
        for subview in [header, searchField, scrollView, emptyLabel, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            banner.widthAnchor.constraint(equalTo: footer.widthAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: footer.widthAnchor),
        ])
        let hover = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                   owner: self)
        table.addTrackingArea(hover)
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        reload(keeping: nil)
    }

    /// Called each time the list opens: the search given (empty for the quick list), first item selected.
    func prepareToShow(search: String = "") {
        _ = view
        searchField.stringValue = search
        banner.isHidden = canPaste()
        let pasteKey = canPaste() ? NSLocalizedString("↩ Paste", comment: "") : NSLocalizedString("↩ Copy", comment: "")
        hint.stringValue = mode == .quick
            ? String(format: NSLocalizedString("%@   ⇧↩ Plain text   Space Preview   ⌘1-9   ⌘⌫ Delete", comment: ""), pasteKey)
            : String(format: NSLocalizedString("%@   ⇧↩ Plain text   Space Preview   ⌘⌫ Delete   Drag out to a folder or an app", comment: ""), pasteKey)
        reload(keeping: nil)
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        fitHeight()
        table.scrollRowToVisible(0)
        view.window?.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() { editor.selectedRange = NSRange(location: search.utf16.count, length: 0) }
    }

    /// The list closed: no preview, no tooltip, not pinned any more.
    func didClose() {
        hideTip()
        preview.hide()
        setHovered(-1)
        if isPinned { togglePin() }
    }

    static let maxHeight: CGFloat = 360

    /// The quick list is as high as its rows, up to `maxHeight`, so there is no empty space above the
    /// hints. Keeps the top where it is.
    private func fitHeight() {
        guard mode == .quick else { return }
        view.layoutSubtreeIfNeeded()
        let list = rowCount == 0 ? 100 : table.rect(ofRow: rowCount - 1).maxY + 8
        let height = min(Self.maxHeight, view.frame.height - scrollView.frame.height + list).rounded()
        guard abs(height - view.frame.height) > 0.5 else { return }
        if let window = view.window {
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        } else {
            view.setFrameSize(NSSize(width: view.frame.width, height: height))
        }
    }

    var selectedItem: ClipItem? {
        shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
    }

    private var rowCount: Int { shown.count + (hiddenCount > 0 ? 1 : 0) }

    private func isShowAllRow(_ row: Int) -> Bool {
        hiddenCount > 0 && row == shown.count
    }

    private func reload(keeping id: UUID?) {
        let previousRow = table.selectedRow
        let found = model.history.matching(searchField.stringValue)
        let limit = mode == .quick ? max(1, quickListSize()) : found.count
        shown = Array(found.prefix(limit))
        hiddenCount = found.count - shown.count
        crowdedMinutes = ClipTime.crowdedMinutes(model.items.map(\.date))
        table.reloadData()
        let row = id.flatMap { id in shown.firstIndex { $0.id == id } } ?? min(max(previousRow, 0), rowCount - 1)
        if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        clearButton.isHidden = model.items.isEmpty
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.stringValue = model.items.isEmpty
            ? NSLocalizedString("Nothing copied yet.\nWhat you copy shows up here.", comment: "")
            : String(format: NSLocalizedString("Nothing matches \u{201C}%@\u{201D}.", comment: ""), searchField.stringValue)
        updatePreview()
    }

    @objc private func historyChanged() {
        guard isViewLoaded else { return }
        reload(keeping: selectedItem?.id)
        if view.window?.isVisible == true { fitHeight() }
    }

    // MARK: Hover

    private let tip = HoverTip()
    private var hoveredRow = -1
    private var tipTimer: Timer?

    /// The item under the mouse shows its × and is selected, as in a menu. Where
    /// and when it was copied shows in a tooltip of our own: the system's only show in the active
    /// app, and the quick list leaves the app in front active.
    override func mouseMoved(with event: NSEvent) {
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row != hoveredRow else { return }
        hideTip()
        setHovered(row)
        guard row >= 0, row < rowCount else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        guard shown.indices.contains(row) else { return }
        let item = shown[row]
        tipTimer = Timer.scheduledTimer(withTimeInterval: tip.isRecent ? 0.05 : 0.6, repeats: false) { [weak self] _ in
            guard let self, let window = self.view.window, window.isVisible else { return }
            var lines = [ClipTime.fullLabel(for: item.date, locale: Self.locale)]
            if item.isFromOtherDevice {
                lines.insert(NSLocalizedString("Copied on another device (iPhone, iPad or Mac), through iCloud's Universal Clipboard", comment: ""), at: 0)
            } else if let source = item.sourceName {
                lines.insert(String(format: NSLocalizedString("Copied in %@", comment: ""), source), at: 0)
            }
            self.tip.show(lines.joined(separator: "\n"), at: NSEvent.mouseLocation, over: window)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hideTip()
        setHovered(-1)
    }

    @objc private func listScrolled() {
        hideTip()
        setHovered(-1)
    }

    private func setHovered(_ row: Int) {
        let previous = hoveredRow
        hoveredRow = row
        for changed in [previous, row] where shown.indices.contains(changed) {
            (table.view(atColumn: 0, row: changed, makeIfNecessary: false) as? ClipRowView)?.showsDelete = changed == row
        }
    }

    func hideTip() {
        tipTimer?.invalidate()
        tipTimer = nil
        tip.hide()
    }

    // MARK: Preview

    /// The space bar, with nothing typed in the search field.
    func togglePreview() {
        if preview.isVisible {
            preview.hide()
        } else {
            showPreview()
        }
    }

    /// Only for an item the list cuts short: a picture, files, text longer than its row.
    private func showPreview() {
        guard let item = selectedItem, let window = view.window, isCutShort(item) else { return preview.hide() }
        preview.show(item, snapshot: model.snapshot(for: item.id), beside: window)
    }

    private func updatePreview() {
        guard preview.isVisible else { return }
        showPreview()
    }

    private func isCutShort(_ item: ClipItem) -> Bool {
        guard let row = shown.firstIndex(of: item),
              let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ClipRowView else { return true }
        return !view.showsAll(of: item)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = table.clickedRow
        if isShowAllRow(row) { return showAll() }
        guard shown.indices.contains(row) else { return }
        onPaste?(shown[row], false)
    }

    @objc private func rowSelectedByClick() {
        if isShowAllRow(table.clickedRow) { showAll() }
    }

    private func showAll() {
        onShowAll?(searchField.stringValue)
    }

    @objc func clearAll() {
        model.clear()
    }

    @objc private func togglePin() {
        isPinned.toggle()
        updatePinButton()
        onPinChanged?(isPinned)
    }

    private func updatePinButton() {
        let symbol = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isPinned ? NSLocalizedString("Unpin", comment: "") : NSLocalizedString("Pin", comment: ""))
        pinButton.contentTintColor = isPinned ? .controlAccentColor : nil
        pinButton.toolTip = isPinned ? NSLocalizedString("Close the list when you click elsewhere", comment: "") : NSLocalizedString("Keep the list open", comment: "")
    }

    @objc private func showSettings() {
        onShowSettings?()
    }

    @objc private func allowPasting() {
        onAllowPasting?()
    }

    private func delete(_ item: ClipItem) {
        model.remove(item.id)
    }

    @objc private func menuPaste(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        onPaste?(item, sender.tag == 1)
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        onCopy?(item)
    }

    @objc private func menuPreview(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem, let row = shown.firstIndex(of: item) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        showPreview()
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? ClipItem else { return }
        delete(item)
    }

    /// Keys before the search field gets them: the space bar previews when nothing is typed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 49, flags.isEmpty, searchField.stringValue.isEmpty, selectedItem != nil {
            togglePreview()
            return true
        }
        return false
    }

    /// The list's Cmd shortcuts.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        if event.keyCode == KeyboardLayout.delete, let item = selectedItem {
            delete(item)
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            onShowSettings?()
            return true
        case "w":
            onClose?()
            return true
        case _ where Self.numberKeys.contains(UInt32(event.keyCode)):
            // The latest copies in order, whatever the search shows. Matched by key position, since
            // the number row types "&é\"'(" on a French keyboard.
            let index = Self.numberKeys.firstIndex(of: UInt32(event.keyCode))!
            if model.items.indices.contains(index) { onPaste?(model.items[index], false) }
            return true
        default:
            return false
        }
    }

    /// The number row's 1 to 9, by position.
    private static let numberKeys: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    // MARK: Search field keys

    func controlTextDidChange(_ obj: Notification) {
        reload(keeping: nil)
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: 8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -8)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if isShowAllRow(table.selectedRow) { showAll(); break }
            let plain = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            if let item = selectedItem { onPaste?(item, plain) }
        case #selector(NSResponder.cancelOperation(_:)):
            if preview.isVisible {
                preview.hide()
            } else if searchField.stringValue.isEmpty {
                onClose?()
            } else {
                searchField.stringValue = ""
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            }
        default:
            return false
        }
        return true
    }

    /// One item further, back to the top after the last, as ⌘Tab does (hold ⌘V, press V).
    func selectNext() {
        guard !shown.isEmpty else { return }
        let row = table.selectedRow < shown.count ? (table.selectedRow + 1) % shown.count : 0
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(by offset: Int) {
        guard rowCount > 0 else { return }
        let row = min(max(table.selectedRow + offset, 0), rowCount - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard shown.indices.contains(row) else { return ShowAllRowView.height }
        let item = shown[row]
        return ClipRowView.height(of: item, thumbnail: thumbnails.thumbnail(for: item))
    }

    private func shortcut(of item: ClipItem) -> String? {
        model.items.firstIndex { $0.id == item.id }.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil }
    }

    private func time(of item: ClipItem) -> String {
        ClipTime.label(for: item.date, withSeconds: crowdedMinutes.contains(ClipTime.minute(of: item.date)),
                       locale: Self.locale)
    }

    /// In the app's language, like the rest of the list, not only the system's.
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AlwaysEmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else {
            let view = tableView.makeView(withIdentifier: ShowAllRowView.identifier, owner: self) as? ShowAllRowView
                ?? ShowAllRowView()
            view.configure(more: hiddenCount)
            return view
        }
        let view = tableView.makeView(withIdentifier: ClipRowView.identifier, owner: self) as? ClipRowView ?? ClipRowView()
        let item = shown[row]
        view.configure(item, thumbnail: thumbnails.thumbnail(for: item), time: time(of: item),
                       shortcut: shortcut(of: item))
        view.showsDelete = row == hoveredRow
        view.onDelete = { [weak self] in self?.delete(item) }
        return view
    }

    // MARK: Dragging out

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard shown.indices.contains(row), let snapshot = model.snapshot(for: shown[row].id) else { return nil }
        return ClipDrag.writer(for: shown[row], snapshot: snapshot)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        hideTip()
        preview.hide()
        // Several copied files drag as several files.
        if let row = rowIndexes.first, shown.indices.contains(row) {
            let extra = ClipDrag.extraFiles(of: shown[row])
            if !extra.isEmpty { session.draggingPasteboard.writeObjects(extra) }
        }
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard shown.indices.contains(table.clickedRow) else { return }
        let item = shown[table.clickedRow]
        func add(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.target = self
            menuItem.representedObject = item
            menuItem.tag = tag
            menu.addItem(menuItem)
        }
        add(canPaste() ? NSLocalizedString("Paste", comment: "") : NSLocalizedString("Copy", comment: ""), #selector(menuPaste(_:)), key: "\r")
        if [.text, .richText, .link].contains(item.kind) {
            add(canPaste() ? NSLocalizedString("Paste as Plain Text", comment: "") : NSLocalizedString("Copy as Plain Text", comment: ""), #selector(menuPaste(_:)), tag: 1)
            menu.items.last?.keyEquivalent = "\r"
            menu.items.last?.keyEquivalentModifierMask = .shift
        }
        if canPaste() { add(NSLocalizedString("Copy", comment: ""), #selector(menuCopy(_:))) }
        if isCutShort(item) {
            add(NSLocalizedString("Preview", comment: ""), #selector(menuPreview(_:)), key: " ")
            menu.items.last?.keyEquivalentModifierMask = []
        }
        menu.addItem(.separator())
        add(NSLocalizedString("Delete", comment: ""), #selector(menuDelete(_:)), key: "\u{8}")
        menu.addItem(.separator())
        let clear = NSMenuItem(title: NSLocalizedString("Clear All", comment: ""), action: #selector(clearAll), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
