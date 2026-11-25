import Foundation

/// Hold ⌘V for the history, the way ⌘Tab works for apps: a short ⌘V still pastes; held, it opens
/// the list; with ⌘ still down, each V goes one item further, and letting go of ⌘ pastes the item
/// reached. Letting go of ⌘ before pressing V again leaves the list open, to pick
/// with the mouse, the arrows or the search field.
///
/// The app feeds it the key events it sees and does what it answers; it decides nothing else.
public struct PasteHoldGesture: Equatable, Sendable {
    /// How long ⌘V must be held before the list opens. A tap is far shorter (about 0.1 s).
    public static let holdDelay: TimeInterval = 0.3

    public enum Event: Equatable, Sendable {
        /// V pressed with ⌘ alone (⌘⇧V, Paste and Match Style, is left to the apps).
        case pasteDown(isRepeat: Bool)
        /// The V of that ⌘V let go.
        case pasteUp
        case commandReleased
        /// `holdDelay` has passed since ⌘V went down.
        case holdElapsed
        /// The list closed, whatever closed it.
        case panelClosed
    }

    public enum Action: Equatable, Sendable {
        /// Call back with `.holdElapsed` after `holdDelay`.
        case startTimer
        /// An ordinary ⌘V: post it to the app, since the real one was held back.
        case paste
        case openPanel
        case selectNext
        /// Paste the selected item and close the list.
        case commit
    }

    public enum State: Equatable, Sendable {
        case idle
        /// ⌘V is down, not long enough yet to be a hold.
        case pressed
        /// The list opened from a hold, ⌘ still down; `stepped` once V was pressed again.
        case open(stepped: Bool)
    }

    public private(set) var state: State = .idle

    public init() {}

    /// Whether the key event goes on to the app, and what to do.
    public mutating func handle(_ event: Event) -> (passThrough: Bool, action: Action?) {
        switch (state, event) {
        case (.idle, .pasteDown(isRepeat: false)):
            state = .pressed
            return (false, .startTimer)

        case (.pressed, .pasteUp):
            state = .idle
            return (false, .paste)
        case (.pressed, .pasteDown(isRepeat: true)), (.pressed, .holdElapsed):
            state = .open(stepped: false)
            return (false, .openPanel)
        case (.pressed, .pasteDown):
            return (false, nil)
        case (.pressed, .commandReleased):
            // ⌘ let go before V: still a tap.
            state = .idle
            return (true, .paste)

        case (.open, .pasteDown(isRepeat: false)):
            state = .open(stepped: true)
            return (false, .selectNext)
        case (.open, .pasteDown), (.open, .pasteUp):
            return (false, nil)
        case (.open(let stepped), .commandReleased):
            state = .idle
            return (true, stepped ? .commit : nil)
        case (.open, .panelClosed):
            state = .idle
            return (true, nil)

        default:
            return (true, nil)
        }
    }
}
