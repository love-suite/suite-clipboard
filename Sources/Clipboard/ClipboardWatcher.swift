import AppKit
import ClipboardCore

/// Watches the general pasteboard. macOS sends no notification when it changes, so its change count
/// is checked twice a second, as every clipboard manager does.
final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?
    /// The change made by pasting from the history, which is not a new copy.
    private var ownChangeCount: Int?

    /// Asked on every change, so a new setting applies at once.
    var filter: () -> ClipboardFilter = { ClipboardFilter() }
    var onCopy: ((PasteboardSnapshot, _ sourceApp: String?, _ sourceName: String?) -> Void)?

    init() {
        changeCount = pasteboard.changeCount
    }

    func start() {
        changeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func ignore(changeCount: Int) {
        ownChangeCount = changeCount
    }

    private func check() {
        let current = pasteboard.changeCount
        guard current != changeCount else { return }
        changeCount = current
        guard current != ownChangeCount else { return }

        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !types.isEmpty else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let named = pasteboard.string(forType: NSPasteboard.PasteboardType(PasteboardType.source))
        let source = named.flatMap { $0.isEmpty ? nil : $0 } ?? frontmost?.bundleIdentifier
        // Checked on the types first: a password manager's secret is never read.
        guard filter().shouldRecord(types: types, source: source) else { return }

        guard let snapshot = Self.read(pasteboard), let trimmed = ClipClassifier.trimmed(snapshot) else { return }
        let name = source.flatMap(Self.appName) ?? frontmost?.localizedName
        onCopy?(trimmed, source, name)
    }

    /// Everything on the pasteboard, item by item, but app-private `dyn.` types. A big TIFF (screenshots,
    /// pictures copied from apps) is stored as PNG, a tenth of its size.
    static func read(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        let snapshot = items.map { item -> [String: Data] in
            var entry: [String: Data] = [:]
            for type in item.types where !type.rawValue.hasPrefix("dyn.") {
                entry[type.rawValue] = item.data(forType: type)
            }
            if let tiff = entry[PasteboardType.tiff], tiff.count > 1_000_000, entry[PasteboardType.png] == nil,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                entry[PasteboardType.tiff] = nil
                entry[PasteboardType.png] = png
            }
            return entry
        }
        return PasteboardSnapshot(items: snapshot)
    }

    static func appName(_ bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
