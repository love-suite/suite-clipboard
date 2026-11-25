import AppKit
import SuiteCore

/// Clipboard: Windows' clipboard history (Win+V) for macOS. It runs in the background, started by
/// Explorer, keeps what is copied, and holding ⌘V shows the list next to the caret.

// Reopened by the previous copy (an update): once it is gone, this copy carries on.
AppRelauncher.waitForPreviousCopy()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = ClipboardAppDelegate()
app.delegate = delegate
app.run()
