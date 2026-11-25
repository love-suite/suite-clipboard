import Foundation

/// Where the history lives between launches: `history.json` for the list, and one property list per
/// item with what was copied, in `~/Library/Application Support/Explorer/Clipboard`.
public final class ClipboardStore {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Explorer/Clipboard", isDirectory: true)
    }

    public let folder: URL
    private var historyFile: URL { folder.appendingPathComponent("history.json") }
    private var contentsFolder: URL { folder.appendingPathComponent("Items", isDirectory: true) }

    public init(folder: URL = ClipboardStore.defaultFolder) {
        self.folder = folder
    }

    /// The saved history. Entries whose contents are gone are left out, and contents no entry refers
    /// to are removed (both only happen after a crash between two writes).
    public func loadHistory(limit: Int) -> ClipboardHistory {
        let decoder = JSONDecoder()
        let saved = (try? Data(contentsOf: historyFile)).flatMap { try? decoder.decode([ClipItem].self, from: $0) } ?? []
        let present = Set(contentFiles().map { $0.deletingPathExtension().lastPathComponent })
        let items = saved.filter { present.contains($0.id.uuidString) }
        let kept = Set(items.map(\.id.uuidString))
        for file in contentFiles() where !kept.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        var history = ClipboardHistory(items: items, limit: .max)
        // A smaller limit set while the app wasn't running.
        removeContents(of: history.setLimit(limit).map(\.id))
        return history
    }

    public func save(_ history: ClipboardHistory) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history.items).write(to: historyFile, options: .atomic)
    }

    public func write(_ snapshot: PasteboardSnapshot, for id: UUID) throws {
        try FileManager.default.createDirectory(at: contentsFolder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(snapshot).write(to: contentsFile(id), options: .atomic)
    }

    public func snapshot(for id: UUID) -> PasteboardSnapshot? {
        guard let data = try? Data(contentsOf: contentsFile(id)) else { return nil }
        return try? PropertyListDecoder().decode(PasteboardSnapshot.self, from: data)
    }

    /// Removes the stored contents of entries that left the history. Only ever touches this store's
    /// own files.
    public func removeContents(of ids: [UUID]) {
        for id in ids {
            try? FileManager.default.removeItem(at: contentsFile(id))
        }
    }

    private func contentsFile(_ id: UUID) -> URL {
        contentsFolder.appendingPathComponent(id.uuidString).appendingPathExtension("plist")
    }

    private func contentFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: contentsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "plist" }
    }
}
