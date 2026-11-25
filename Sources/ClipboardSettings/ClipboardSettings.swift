import Foundation
import SuiteCore

/// Clipboard's settings, kept in its user defaults. Clipboard reads them as its own; Explorer, whose
/// Settings window has the Clipboard tab, reads and writes them through `forExplorer`.
public final class ClipboardSettings {
    public static let bundleID = ClipboardApp.bundleID
    /// The sizes offered in Settings.
    public static let limitChoices = [10, 25, 50, 100, 200, 500]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clipboard's settings as another app (Explorer) sees them.
    public static func forExplorer() -> ClipboardSettings {
        ClipboardSettings(defaults: UserDefaults(suiteName: bundleID) ?? .standard)
    }

    /// Picks up what the other app just wrote.
    public func reload() {
        defaults.synchronize()
    }

    /// Whether the history is kept at all: off, Clipboard doesn't run.
    public var isEnabled: Bool {
        get { defaults.object(forKey: "isEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isEnabled") }
    }

    /// How many items the history keeps unless the user changes it.
    public static let defaultHistoryLimit = 50

    /// How many items the history keeps.
    public var historyLimit: Int {
        get {
            let value = defaults.integer(forKey: "historyLimit")
            return value > 0 ? min(value, 1000) : Self.defaultHistoryLimit
        }
        set { defaults.set(max(1, min(newValue, 1000)), forKey: "historyLimit") }
    }

    /// The ages offered in Settings, in days; 0 keeps items until the limit pushes them out.
    public static let expiryChoices = [0, 1, 7, 30]
    /// The sizes of the list ⌘V opens; "Show All" opens the whole history in a window.
    public static let quickListChoices = [10, 20, 30, 50]
    public static let defaultQuickListSize = 20

    /// Items last copied more than this many days ago are forgotten; 0, the default, never.
    public var expiryDays: Int {
        get { max(0, defaults.integer(forKey: "expiryDays")) }
        set { defaults.set(max(0, newValue), forKey: "expiryDays") }
    }

    /// When items expire: those copied before this date go. Nil when they never do.
    public func expiryDate(now: Date = Date()) -> Date? {
        expiryDays > 0 ? now.addingTimeInterval(-Double(expiryDays) * 86_400) : nil
    }

    /// How many items the list ⌘V opens shows.
    public var quickListSize: Int {
        get {
            let value = defaults.integer(forKey: "quickListSize")
            return value > 0 ? value : Self.defaultQuickListSize
        }
        set { defaults.set(max(1, newValue), forKey: "quickListSize") }
    }

    /// Whether the list, once pinned open, stays above other windows.
    public var pinnedListOnTop: Bool {
        get { defaults.object(forKey: "pinnedListOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pinnedListOnTop") }
    }

    /// Whether the history is copied to iCloud Drive (`ClipboardBackup`). Off by default: what is
    /// copied can be private.
    public var backsUpToICloud: Bool {
        get { defaults.bool(forKey: "backsUpToICloud") }
        set { defaults.set(newValue, forKey: "backsUpToICloud") }
    }

    /// Holding ⌘V opens the history (see `PasteHoldGesture`); the only way in from the keyboard.
    public var holdsCommandV: Bool {
        get { defaults.object(forKey: "holdsCommandV") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "holdsCommandV") }
    }

    /// Bundle identifiers of the apps whose copies are not recorded.
    public var ignoredApps: [String] {
        get { defaults.stringArray(forKey: "ignoredApps") ?? Self.defaultIgnoredApps }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { seen.insert($0).inserted }, forKey: "ignoredApps")
        }
    }

    // MARK: Reported by Clipboard, shown by Explorer

    /// Whether Clipboard has Accessibility access, which only it can check.
    public var canPaste: Bool {
        get { defaults.bool(forKey: "canPaste") }
        set { defaults.set(newValue, forKey: "canPaste") }
    }

    public enum LoginStatus: String, Sendable {
        case off, on, needsApproval
    }

    /// Clipboard's login item, which only it can register.
    public var loginStatus: LoginStatus {
        get { defaults.string(forKey: "loginStatus").flatMap(LoginStatus.init) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "loginStatus") }
    }

    /// Set once the Accessibility explanation has been shown, so it isn't shown at every paste.
    public var hasExplainedAccessibility: Bool {
        get { defaults.bool(forKey: "hasExplainedAccessibility") }
        set { defaults.set(newValue, forKey: "hasExplainedAccessibility") }
    }

    /// Apps whose copies are never recorded unless the user changes the list: Keychain Access and Passwords.
    public static let defaultIgnoredApps = ["com.apple.keychainaccess", "com.apple.Passwords"]
}
