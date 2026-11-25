import Foundation
import ClipboardSettings

/// A copy of the history in iCloud Drive (an option, off by default): the store's folder mirrored to
/// `iCloud Drive/Explorer/Clipboard/<this Mac's name>` after changes, one backup per Mac, and brought
/// back into an empty history (a reinstall: this Mac's; a new Mac: the latest another made).
public struct ClipboardBackup {
    /// iCloud Drive's folder, when iCloud Drive is on.
    public static var iCloudDrive: URL? { ClipboardBackupPlace.iCloudDrive }

    /// The folder holding each Mac's backup.
    public static var defaultRoot: URL? { ClipboardBackupPlace.root }

    /// This Mac's name (System Settings › General › Sharing), as a folder name.
    public static var machineName: String { ClipboardBackupPlace.machineName }

    public let store: URL
    public let root: URL
    public let machine: String

    public init(store: URL, root: URL, machine: String = ClipboardBackup.machineName) {
        self.store = store
        self.root = root
        self.machine = machine
    }

    /// This Mac's backup.
    public var backup: URL { root.appendingPathComponent(machine, isDirectory: true) }

    private static let history = "history.json"
    private static let items = "Items"

    public var exists: Bool {
        Self.hasHistory(backup)
    }

    private static func hasHistory(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(history).path)
    }

    /// What an empty history comes back from: this Mac's backup, else the one another Mac saved last.
    public var restoreSource: URL? {
        if exists { return backup }
        let others = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return others.filter(Self.hasHistory).max { date(of: $0) < date(of: $1) }
    }

    private func date(of folder: URL) -> Date {
        let file = folder.appendingPathComponent(Self.history)
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Copies the store to the backup: the list every time, each item's contents once (they never
    /// change), and removes the backup's copies of items the history no longer has. Only ever
    /// touches the backup folder's own files.
    public func backUp() throws {
        let manager = FileManager.default
        let backupItems = backup.appendingPathComponent(Self.items, isDirectory: true)
        try manager.createDirectory(at: backupItems, withIntermediateDirectories: true)
        let local = Set(files(in: store.appendingPathComponent(Self.items)))
        let saved = Set(files(in: backupItems))
        for name in local.subtracting(saved) {
            try manager.copyItem(at: store.appendingPathComponent(Self.items).appendingPathComponent(name),
                                 to: backupItems.appendingPathComponent(name))
        }
        for name in saved.subtracting(local) where name.hasSuffix(".plist") {
            try? manager.removeItem(at: backupItems.appendingPathComponent(name))
        }
        let list = try Data(contentsOf: store.appendingPathComponent(Self.history))
        try list.write(to: backup.appendingPathComponent(Self.history), options: .atomic)
    }

    /// Brings a backup into the store; for an empty history only, so nothing is overwritten.
    public func restore(from source: URL) throws {
        let manager = FileManager.default
        let storeItems = store.appendingPathComponent(Self.items, isDirectory: true)
        try manager.createDirectory(at: storeItems, withIntermediateDirectories: true)
        let present = Set(files(in: storeItems))
        for name in files(in: source.appendingPathComponent(Self.items)) where !present.contains(name) {
            try manager.copyItem(at: source.appendingPathComponent(Self.items).appendingPathComponent(name),
                                 to: storeItems.appendingPathComponent(name))
        }
        let list = try Data(contentsOf: source.appendingPathComponent(Self.history))
        try list.write(to: store.appendingPathComponent(Self.history), options: .atomic)
    }

    private func files(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
    }
}
