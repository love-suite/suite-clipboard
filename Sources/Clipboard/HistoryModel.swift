import AppKit
import ClipboardCore

extension Notification.Name {
    static let clipboardHistoryDidChange = Notification.Name("ClipboardHistoryDidChange")
}

/// The history as the app uses it: every change is saved at once and announced, and contents of
/// dropped entries are removed from the store.
final class HistoryModel {
    let store: ClipboardStore
    private(set) var history: ClipboardHistory

    init(store: ClipboardStore, limit: Int) {
        self.store = store
        history = store.loadHistory(limit: limit)
    }

    var items: [ClipItem] { history.items }

    /// After a restore from the backup.
    func reloadFromStore() {
        history = store.loadHistory(limit: history.limit)
        NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: self)
    }

    func record(_ snapshot: PasteboardSnapshot, sourceApp: String?, sourceName: String?) {
        guard let item = ClipClassifier.item(from: snapshot, sourceApp: sourceApp, sourceName: sourceName) else { return }
        do {
            try store.write(snapshot, for: item.id)
        } catch {
            NSLog("Clipboard: could not store an item: \(error)")
            return
        }
        commit(history.add(item))
        if item.kind == .image { readText(of: item.id, in: snapshot) }
    }

    /// Reads the text of the pictures not read yet (those kept before text recognition existed).
    func readTextOfPictures() {
        for item in items where item.kind == .image && item.recognizedText == nil {
            if let snapshot = snapshot(for: item.id) { readText(of: item.id, in: snapshot) }
        }
    }

    private func readText(of id: UUID, in snapshot: PasteboardSnapshot) {
        TextRecognizer.text(in: snapshot) { [weak self] text in
            guard let self, self.history.item(id) != nil else { return }
            self.history.setRecognizedText(text, for: id)
            self.commit([])
        }
    }

    /// Forgets the items last copied before `date`.
    func removeItems(copiedBefore date: Date) {
        let expired = history.removeItems(copiedBefore: date)
        if !expired.isEmpty { commit(expired) }
    }

    func moveToTop(_ id: UUID) {
        history.moveToTop(id)
        commit([])
    }

    func remove(_ id: UUID) {
        commit(history.remove(id).map { [$0] } ?? [])
    }

    func clear() {
        commit(history.clear())
    }

    func setLimit(_ limit: Int) {
        commit(history.setLimit(limit))
    }

    func snapshot(for id: UUID) -> PasteboardSnapshot? {
        store.snapshot(for: id)
    }

    private func commit(_ dropped: [ClipItem]) {
        store.removeContents(of: dropped.map(\.id))
        do {
            try store.save(history)
        } catch {
            NSLog("Clipboard: could not save the history: \(error)")
        }
        NotificationCenter.default.post(name: .clipboardHistoryDidChange, object: self)
    }
}
