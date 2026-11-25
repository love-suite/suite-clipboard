import AppKit
import ClipboardCore

/// The whole item next to the list (space bar): the full text, a picture at a readable size, the
/// paths of copied files. It never takes the keyboard, so the list keeps it, but it scrolls.
final class PreviewWindow {
    static let maxSize = NSSize(width: 460, height: 480)

    private(set) lazy var window: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.maxSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // The window sets the size, not the picture.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(.defaultLow, for: axis)
            imageView.setContentHuggingPriority(.defaultLow, for: axis)
        }
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        for view in [textScroll, imageView, caption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            textScroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
            textScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            imageView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            imageView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -6),
            caption.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            caption.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            caption.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])
        return panel
    }()
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")

    var isVisible: Bool { window.isVisible }

    /// Shows the item beside `parent`, on the side with room.
    func show(_ item: ClipItem, snapshot: PasteboardSnapshot?, beside parent: NSWindow) {
        _ = window // Sets up the views before they are measured.
        var size = Self.maxSize
        if item.kind == .image, let data = snapshot.flatMap({ s in PasteboardType.images.lazy.compactMap { s.data($0) }.first }),
           let image = NSImage(data: data), let rep = image.representations.first {
            let pixels = NSSize(width: max(rep.pixelsWide, 1), height: max(rep.pixelsHigh, 1))
            // At the size it has on screen (a screenshot's pixels are halved on a Retina screen), smaller if need be.
            let density = parent.backingScaleFactor
            let natural = NSSize(width: pixels.width / density, height: pixels.height / density)
            let scale = min(1, (Self.maxSize.width - 20) / natural.width, (Self.maxSize.height - 44) / natural.height)
            imageView.image = image
            size = NSSize(width: max(200, natural.width * scale + 20), height: max(120, natural.height * scale + 44))
            caption.stringValue = "\(Int(pixels.width)) × \(Int(pixels.height))"
                + (item.recognizedText?.isEmpty == false ? "  ·  Text found: search finds it" : "")
            textScroll.isHidden = true
            imageView.isHidden = false
            caption.isHidden = false
        } else {
            textView.textStorage?.setAttributedString(Self.text(of: item, snapshot: snapshot))
            textView.scrollToBeginningOfDocument(nil)
            textScroll.isHidden = false
            imageView.isHidden = true
            caption.isHidden = true
            // As high as the text, up to the maximum.
            textView.frame.size.width = size.width
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? size.height
            size.height = min(Self.maxSize.height, max(60, used + 28))
        }
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let anchor = parent.frame
        var x = anchor.maxX + 8
        if x + size.width > screen.maxX { x = anchor.minX - 8 - size.width }
        let top = min(anchor.maxY, screen.maxY)
        let y = max(screen.minY, top - size.height)
        window.level = parent.level
        window.setFrame(NSRect(x: max(screen.minX, x), y: y, width: size.width, height: size.height), display: true)
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    private static func text(of item: ClipItem, snapshot: PasteboardSnapshot?) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        if item.kind == .richText, let snapshot {
            if let rtfd = snapshot.data(PasteboardType.rtfd), let text = NSAttributedString(rtfd: rtfd, documentAttributes: nil) {
                return text
            }
            if let rtf = snapshot.data(PasteboardType.rtf), let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                return text
            }
        }
        let body = item.kind == .files ? item.fileURLs.map(\.path).joined(separator: "\n") : item.text
        return NSAttributedString(string: body, attributes: plain)
    }
}
