import CryptoKit
import Foundation

/// Turns what was copied into a history entry: decides whether it is text, rich text, a link, a
/// picture or files, and what makes two copies the same.
public enum ClipClassifier {
    /// Above this, only the types needed to paste the item back are kept; above it even then, the
    /// item is not recorded.
    public static let maxBytes = 50 * 1024 * 1024

    /// The types worth keeping: app-private `dyn.` types are dropped, and a snapshot too big to keep
    /// is cut down to its essential types, or to nothing.
    public static func trimmed(_ snapshot: PasteboardSnapshot, maxBytes: Int = maxBytes) -> PasteboardSnapshot? {
        var result = PasteboardSnapshot(items: snapshot.items.map { $0.filter { !$0.key.hasPrefix("dyn.") } })
        if result.byteCount > maxBytes {
            let essential = Set([PasteboardType.plainText, PasteboardType.fileURL, PasteboardType.url,
                                 PasteboardType.rtf, PasteboardType.source] + PasteboardType.images)
            result.items = result.items.map { item in
                var kept = item.filter { essential.contains($0.key) }
                // One picture format is enough to paste it back.
                if let image = PasteboardType.images.first(where: { kept[$0] != nil }) {
                    for other in PasteboardType.images where other != image { kept[other] = nil }
                }
                return kept
            }
        }
        result.items.removeAll(where: \.isEmpty)
        guard !result.isEmpty, result.byteCount <= maxBytes else { return nil }
        return result
    }

    /// The history entry for a snapshot, or nil when it holds nothing the history can show.
    public static func item(from snapshot: PasteboardSnapshot, id: UUID = UUID(), date: Date = Date(),
                            sourceApp: String? = nil, sourceName: String? = nil) -> ClipItem? {
        // From another device, the app in front on this Mac had nothing to do with it.
        let isRemote = snapshot.types.contains(PasteboardType.remoteClipboard)
        func make(_ kind: ClipItem.Kind, _ text: String, _ fingerprint: String) -> ClipItem {
            var item = ClipItem(id: id, kind: kind, date: date, text: text, fingerprint: fingerprint,
                                sourceApp: isRemote ? nil : sourceApp, sourceName: isRemote ? nil : sourceName,
                                byteCount: snapshot.byteCount)
            if isRemote { item.copiedOnOtherDevice = true }
            return item
        }

        let files = snapshot.items.compactMap { item -> URL? in
            guard let data = item[PasteboardType.fileURL], let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        if !files.isEmpty {
            let paths = files.map(\.path).joined(separator: "\n")
            return make(.files, paths, "files:" + paths)
        }

        if let plain = snapshot.string(PasteboardType.plainText),
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind: ClipItem.Kind
            if link(in: plain) != nil {
                kind = .link
            } else if !snapshot.types.isDisjoint(with: PasteboardType.richText) {
                kind = .richText
            } else {
                kind = .text
            }
            return make(kind, plain, "text:" + plain)
        }

        if let url = snapshot.string(PasteboardType.url), !url.isEmpty {
            return make(.link, url, "text:" + url)
        }

        if let image = PasteboardType.images.lazy.compactMap({ snapshot.data($0) }).first {
            return make(.image, "", "image:" + digest(image))
        }

        if let rich = PasteboardType.richText.lazy.compactMap({ snapshot.data($0) }).first {
            return make(.richText, "", "rich:" + digest(rich))
        }
        return nil
    }

    /// The web or mail address that a copied text is, if it is nothing but that.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "ftp": return url.host?.isEmpty == false ? url : nil
        case "mailto": return trimmed.count > "mailto:".count ? url : nil
        default: return nil
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
