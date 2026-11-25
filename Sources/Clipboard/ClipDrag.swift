import AppKit
import ClipboardCore
import UniformTypeIdentifiers

/// Dragging an item out of the list. Files drag as themselves. Text, links and pictures drag both as
/// their contents, for apps (a text field, a mail), and as a file made at the drop, for folders and
/// the desktop (Explorer's and Finder's).
enum ClipDrag {
    static func writer(for item: ClipItem, snapshot: PasteboardSnapshot) -> NSPasteboardWriting? {
        if item.kind == .files { return item.fileURLs.first as NSURL? }
        guard let file = file(for: item, snapshot: snapshot) else { return nil }
        let provider = ClipPromise(fileType: file.type.identifier, delegate: ClipPromiseDelegate.shared)
        provider.contents = snapshot.items.first ?? [:]
        provider.fileName = file.name
        provider.fileData = file.data
        return provider
    }

    /// The files after the first, which the table's single writer per row can't carry.
    static func extraFiles(of item: ClipItem) -> [NSURL] {
        item.kind == .files ? item.fileURLs.dropFirst().map { $0 as NSURL } : []
    }

    /// The file a drop on a folder makes.
    static func file(for item: ClipItem, snapshot: PasteboardSnapshot) -> (name: String, type: UTType, data: Data)? {
        switch item.kind {
        case .files:
            return nil
        case .image:
            guard let data = PasteboardType.images.lazy.compactMap({ snapshot.data($0) }).first,
                  let png = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? data
                    : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return ("Picture \(formatter.string(from: item.date)).png", .png, png)
        case .link:
            let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": item.text], format: .xml,
                                                            options: 0)
            let host = URL(string: item.text)?.host ?? "Link"
            return plist.map { (safeName(host) + ".webloc", UTType(filenameExtension: "webloc") ?? .url, $0) }
        case .richText:
            if let rtf = snapshot.data(PasteboardType.rtf) {
                return (safeName(item.title) + ".rtf", .rtf, rtf)
            }
            return (safeName(item.title) + ".txt", .plainText, Data(item.text.utf8))
        case .text:
            return (safeName(item.title) + ".txt", .plainText, Data(item.text.utf8))
        }
    }

    /// The first words, without the characters a file name can't hold.
    private static func safeName(_ text: String) -> String {
        let cleaned = text.map { "/:\\\n\r\t".contains($0) ? " " : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return name.isEmpty ? "Text" : String(name.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
}

/// A file promise that also carries the item's contents.
final class ClipPromise: NSFilePromiseProvider {
    var contents: [String: Data] = [:]
    var fileName = "Text.txt"
    var fileData = Data()

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let promise: [NSPasteboard.PasteboardType] = super.writableTypes(for: pasteboard)
        let extra: [NSPasteboard.PasteboardType] = contents.keys.map { NSPasteboard.PasteboardType(rawValue: $0) }
        return promise + extra.filter { !promise.contains($0) }
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        contents[type.rawValue] != nil ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        contents[type.rawValue] ?? super.pasteboardPropertyList(forType: type)
    }
}

final class ClipPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    static let shared = ClipPromiseDelegate()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider as? ClipPromise)?.fileName ?? "Text.txt"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let promise = provider as? ClipPromise else { return completionHandler(nil) }
        do {
            // Never over an existing file: "Name 2.txt", "Name 3.txt"…
            var target = url
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var number = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = url.deletingLastPathComponent().appendingPathComponent("\(base) \(number)")
                    .appendingPathExtension(ext)
                number += 1
            }
            try promise.fileData.write(to: target, options: .withoutOverwriting)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}
