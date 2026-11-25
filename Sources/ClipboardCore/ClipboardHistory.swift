import Foundation
import ClipboardSettings

/// The clipboard history, newest first, like Windows' (Win+V): a copy of something already in it
/// moves it back to the top, and the oldest items go beyond the limit.
///
/// Changes return the entries they dropped, so the caller can delete their stored contents.
public struct ClipboardHistory: Codable, Equatable, Sendable {
    public static var defaultLimit: Int { ClipboardSettings.defaultHistoryLimit }

    public private(set) var items: [ClipItem]
    /// How many items are kept.
    public private(set) var limit: Int

    public init(items: [ClipItem] = [], limit: Int = defaultLimit) {
        self.items = items.sorted { $0.date > $1.date }
        self.limit = max(1, limit)
        _ = trim()
    }

    public func item(_ id: UUID) -> ClipItem? {
        items.first { $0.id == id }
    }

    /// Adds a new copy at the top. One with the same fingerprint is replaced.
    @discardableResult
    public mutating func add(_ item: ClipItem) -> [ClipItem] {
        var dropped: [ClipItem] = []
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint && $0.id != item.id }) {
            dropped.append(items.remove(at: index))
        }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        return dropped + trim()
    }

    /// An item copied again from the history goes back to the top.
    public mutating func moveToTop(_ id: UUID, date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = date
        items.insert(item, at: 0)
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ClipItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// The text found in a picture.
    public mutating func setRecognizedText(_ text: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].recognizedText = text
    }

    /// Items last copied before `date` go.
    @discardableResult
    public mutating func removeItems(copiedBefore date: Date) -> [ClipItem] {
        let expired = items.filter { $0.date < date }
        items.removeAll { $0.date < date }
        return expired
    }

    /// Clear All: everything goes.
    @discardableResult
    public mutating func clear() -> [ClipItem] {
        defer { items.removeAll() }
        return items
    }

    @discardableResult
    public mutating func setLimit(_ limit: Int) -> [ClipItem] {
        self.limit = max(1, limit)
        return trim()
    }

    /// The items whose text, file names, source app or text in a picture contain every word of the
    /// query, ignoring case and accents.
    public func matching(_ query: String) -> [ClipItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = [item.text, item.sourceName ?? "", item.kind == .image ? "picture image" : "",
                            item.recognizedText ?? "", item.isFromOtherDevice ? "icloud other device iphone ipad" : ""]
                .joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Drops the oldest items beyond the limit.
    private mutating func trim() -> [ClipItem] {
        guard items.count > limit else { return [] }
        defer { items.removeSubrange(limit...) }
        return Array(items[limit...])
    }
}
