import AppKit
import ClipboardCore

/// The floating list holding ⌘V opens. It is a non-activating panel: the app in front stays in
/// front with its caret, so Cmd+V lands where the user was typing. Pinned, it stays open.
final class HistoryPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    /// Keys the list handles before the search field (the space bar for the preview).
    var keyDownHandler: ((NSEvent) -> Bool)?
    /// However it closes.
    var onClose: (() -> Void)?
    private var isSteppingAside = false

    init(contentViewController: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: HistoryViewController.maxHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.contentViewController = contentViewController
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = Self.openBehavior
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        acceptsMouseMovedEvents = true
        setContentSize(NSSize(width: 360, height: HistoryViewController.maxHeight))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Opens on the Space in use and stays on it: a Space change closes it (see the app delegate),
    /// rather than carrying it along.
    private static let openBehavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary,
                                                                    .transient, .ignoresCycle]
    private static let pinnedBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                                                      .ignoresCycle]

    /// Pinned, it stays open when another window is clicked, an item is pasted or the Space changes
    /// (it is on every Space); it floats above other windows or not, as Settings say.
    func setPinned(_ pinned: Bool, onTop: Bool) {
        level = !pinned ? .popUpMenu : onTop ? .floating : .normal
        collectionBehavior = pinned ? Self.pinnedBehavior : Self.openBehavior
    }

    /// Out of the way for a moment, without closing, so the app in front gets the keyboard back
    /// (for a paste) while the list stays pinned.
    func stepAside(for duration: TimeInterval) {
        isSteppingAside = true
        orderOut(nil)
        isSteppingAside = false
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { self.orderFrontRegardless() }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyDownHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        // The app usually isn't active, so its Edit menu doesn't see these: the search field gets
        // them here.
        let editing: [String: Selector] = [
            "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
            "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)), "z": Selector(("undo:")),
        ]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(), let action = editing[key] {
            return NSApp.sendAction(action, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        super.orderOut(sender)
        if wasVisible && !isSteppingAside { onClose?() }
    }
}

/// The whole history in a window of its own ("Show All" at the end of the list): an ordinary
/// window, which can be moved, resized and kept open.
final class HistoryWindow: NSWindow {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var keyDownHandler: ((NSEvent) -> Bool)?

    init(contentViewController: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        self.contentViewController = contentViewController
        title = NSLocalizedString("Clipboard History", comment: "")
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        minSize = NSSize(width: 360, height: 300)
        setContentSize(NSSize(width: 520, height: 600))
        center()
        setFrameAutosaveName("ClipboardHistory")
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyDownHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event)
    }
}
