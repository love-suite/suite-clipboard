import AppKit
import ApplicationServices
import ClipboardCore

/// Hold ⌘V to open the history. A keyboard event tap sees ⌘V before the app in front does: it holds
/// it back until it knows whether it is a tap (then posts it again, so it pastes as usual) or a hold
/// (then opens the list). `PasteHoldGesture` makes every decision.
///
/// An event tap that can hold keys back needs Accessibility access, which pasting needs anyway. Until
/// it is given, ⌘V is left alone and the list opens from the menu bar or Explorer's Edit menu. In
/// password fields macOS hides keys from taps, so ⌘V pastes there as usual.
final class HoldToPaste {
    /// Set on the events this app posts, so the tap lets them through.
    static let marker: Int64 = 0x4558_4350

    var onAction: ((PasteHoldGesture.Action) -> Void)?
    private var gesture = PasteHoldGesture()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var holdTimer: Timer?
    private var heldKeyCode: Int64?

    var isRunning: Bool { tap != nil }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    /// The list closed (Escape, a click elsewhere, an item chosen): the gesture is over.
    func panelClosed() {
        perform(gesture.handle(.panelClosed).action)
    }

    private func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            // Starts by itself once the user allows Accessibility.
            guard retryTimer == nil else { return }
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard AXIsProcessTrusted() else { return }
                self?.retryTimer?.invalidate()
                self?.retryTimer = nil
                self?.start()
            }
            return
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HoldToPaste>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Clipboard: could not watch ⌘V")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        gesture = PasteHoldGesture()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return pass }

        let gestureEvent: PasteHoldGesture.Event
        switch type {
        case .keyDown:
            guard Self.isCommandV(event) else { return pass }
            heldKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            gestureEvent = .pasteDown(isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            guard heldKeyCode == event.getIntegerValueField(.keyboardEventKeycode) else { return pass }
            gestureEvent = .pasteUp
        case .flagsChanged:
            guard !event.flags.contains(.maskCommand) else { return pass }
            gestureEvent = .commandReleased
        default:
            return pass
        }
        let (passThrough, action) = gesture.handle(gestureEvent)
        // The tap must answer at once; the work happens right after.
        DispatchQueue.main.async { self.perform(action) }
        return passThrough ? pass : nil
    }

    private func perform(_ action: PasteHoldGesture.Action?) {
        switch action {
        case .startTimer?:
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: PasteHoldGesture.holdDelay, repeats: false) {
                [weak self] _ in
                guard let self else { return }
                self.perform(self.gesture.handle(.holdElapsed).action)
            }
        case .paste?:
            holdTimer?.invalidate()
            Paster.postPaste()
        case let action?:
            holdTimer?.invalidate()
            onAction?(action)
        case nil:
            break
        }
    }

    /// ⌘V alone: ⌘⇧V (Paste and Match Style) and ⌘⌥V (Move Item Here) stay the apps'.
    private static func isCommandV(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskCommand),
              flags.intersection([.maskShift, .maskControl, .maskAlternate]).isEmpty else { return false }
        return NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() == "v"
    }
}
