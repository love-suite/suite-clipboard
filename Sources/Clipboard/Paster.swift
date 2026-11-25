import AppKit
import ApplicationServices
import ClipboardCore

/// Puts an item back on the pasteboard and pastes it into the app in front, by posting Cmd+V. Posting
/// keys needs Accessibility access; without it the item is only copied.
enum Paster {
    /// Writes the snapshot as it was copied, and returns the pasteboard's new change count.
    static func put(_ snapshot: PasteboardSnapshot) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            // Pasted from here, it no longer comes from another device.
            for (type, data) in entry where type != PasteboardType.remoteClipboard {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// Only the plain text, for Paste as Plain Text.
    static func plainText(of snapshot: PasteboardSnapshot) -> PasteboardSnapshot {
        guard let text = snapshot.data(PasteboardType.plainText) else { return snapshot }
        return PasteboardSnapshot(items: [[PasteboardType.plainText: text]])
    }

    static var canPostKeys: Bool {
        AXIsProcessTrusted()
    }

    /// Cmd+V, on the key that types "v" in the current layout.
    static func postPaste() {
        let keyCode = CGKeyCode(KeyboardLayout.keyCode(typing: "v") ?? KeyboardLayout.ansiV)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = .maskCommand
            // So the hold-⌘V watcher lets it through.
            event?.setIntegerValueField(.eventSourceUserData, value: HoldToPaste.marker)
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Adds the app to the Accessibility list (so the user only has to turn it on) and opens it.
    static func openAccessibilitySettings() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where text goes in the app in front, in screen coordinates: the caret when the app says where
    /// it is, else the text field being typed in. Needs Accessibility access, like pasting.
    static func caretRect() -> NSRect? {
        guard canPostKeys, let element = focusedElement() else { return nil }
        if let rect = caretBounds(in: element) ?? fieldBounds(of: element) {
            // Accessibility counts from the top of the main screen, AppKit from its bottom.
            let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
            return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    private static var askedForAccessibility: Set<pid_t> = []

    private static func focusedElement() -> AXUIElement? {
        var candidates: [AXUIElement] = []
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // Electron and Chromium apps only describe their text once an assistive app asks
            // (a public attribute of theirs, ignored by other apps).
            if askedForAccessibility.insert(app.processIdentifier).inserted {
                AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            candidates.append(element)
        }
        candidates.append(AXUIElementCreateSystemWide())
        for candidate in candidates {
            AXUIElementSetMessagingTimeout(candidate, 0.25)
            if let focused = value(of: kAXFocusedUIElementAttribute, in: candidate),
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                return (focused as! AXUIElement)
            }
        }
        return nil
    }

    /// The caret: the selection's bounds, or for an empty selection (which many apps measure as
    /// nothing) the character before or after it.
    private static func caretBounds(in element: AXUIElement) -> CGRect? {
        guard let rangeValue = value(of: kAXSelectedTextRangeAttribute, in: element),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        if let rect = bounds(of: range, in: element) { return rect }
        guard range.length == 0 else { return nil }
        if range.location > 0, let before = bounds(of: CFRange(location: range.location - 1, length: 1), in: element) {
            return CGRect(x: before.maxX, y: before.minY, width: 1, height: before.height)
        }
        if let after = bounds(of: CFRange(location: range.location, length: 1), in: element) {
            return CGRect(x: after.minX, y: after.minY, width: 1, height: after.height)
        }
        return nil
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.origin != .zero,
              rect.height > 0, rect.height < 200 else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
    }

    /// A one-line text field when the caret can't be found: its start.
    private static func fieldBounds(of element: AXUIElement) -> CGRect? {
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"] as [String]
        guard let role = value(of: kAXRoleAttribute, in: element) as? String, textRoles.contains(role),
              let positionValue = value(of: kAXPositionAttribute, in: element),
              let sizeValue = value(of: kAXSizeAttribute, in: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.height > 0, size.height < 200 else { return nil }
        return CGRect(x: position.x, y: position.y, width: 1, height: size.height)
    }

    private static func value(of attribute: String, in element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
