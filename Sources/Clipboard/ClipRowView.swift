import AppKit
import ClipboardCore

/// The selection keeps the accent colour while typing in the search field, as in Spotlight.
final class AlwaysEmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    /// Drawn here so it shows the same in the panel and in the history window, key or not.
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

/// One item: its text (or a small preview of a picture), then on the right when it was copied and its
/// ⌘ number, which a × to delete it replaces under the mouse. Where it was copied shows on hover
/// (`HoverTip`).
final class ClipRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipRow")
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let picture = NSSize(width: 72, height: 46)

    private let preview = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    /// "iCloud", on what Universal Clipboard brought from an iPhone, an iPad or another Mac.
    private let deviceTag = NSTextField(labelWithString: "iCloud")
    var onDelete: (() -> Void)?
    private var deviceTagBox: NSView!
    private var previewWidth: NSLayoutConstraint!
    private var titleLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 4
        preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 0.5
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.cell?.truncatesLastVisibleLine = true
        title.font = Self.titleFont
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [timeLabel, shortcutLabel] {
            label.font = Self.detailFont
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        deviceTag.font = .systemFont(ofSize: 10, weight: .medium)
        deviceTag.wantsLayer = true
        deviceTag.layer?.cornerRadius = 4
        deviceTag.setContentHuggingPriority(.required, for: .horizontal)
        deviceTag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let tag = NSView()
        tag.wantsLayer = true
        tag.layer?.cornerRadius = 4
        tag.translatesAutoresizingMaskIntoConstraints = false
        deviceTag.translatesAutoresizingMaskIntoConstraints = false
        tag.addSubview(deviceTag)
        NSLayoutConstraint.activate([
            deviceTag.leadingAnchor.constraint(equalTo: tag.leadingAnchor, constant: 5),
            deviceTag.trailingAnchor.constraint(equalTo: tag.trailingAnchor, constant: -5),
            deviceTag.topAnchor.constraint(equalTo: tag.topAnchor, constant: 1),
            deviceTag.bottomAnchor.constraint(equalTo: tag.bottomAnchor, constant: -1),
        ])
        deviceTagBox = tag
        let details = NSStackView(views: [tag, timeLabel, shortcutLabel])
        details.orientation = .horizontal
        details.alignment = .centerY
        details.spacing = 6
        shortcutLabel.widthAnchor.constraint(equalToConstant: Self.shortcutWidth).isActive = true
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        deleteButton.isBordered = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isHidden = true
        for view in [preview, title, details, deleteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        previewWidth = preview.widthAnchor.constraint(equalToConstant: Self.picture.width)
        titleLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            previewWidth,
            preview.heightAnchor.constraint(equalToConstant: Self.picture.height),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLeading,
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: details.leadingAnchor, constant: -Self.gap),
            details.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            details.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.centerXAnchor.constraint(equalTo: shortcutLabel.centerXAnchor, constant: 3),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
    }

    required init?(coder: NSCoder) { fatalError() }

    static let gap: CGFloat = 10

    /// Under the mouse: the × in place of the ⌘ number.
    var showsDelete = false {
        didSet {
            deleteButton.isHidden = !showsDelete
            shortcutLabel.alphaValue = showsDelete ? 0 : 1
        }
    }

    @objc private func deleteClicked() {
        onDelete?()
    }
    static let shortcutWidth: CGFloat = 22

    func configure(_ item: ClipItem, thumbnail: Thumbnails.Result, time: String, shortcut: String?) {
        timeLabel.stringValue = time
        shortcutLabel.stringValue = shortcut ?? ""
        let isPicture = item.kind == .image
        preview.isHidden = !isPicture
        preview.image = isPicture ? thumbnail.image : nil
        preview.layer?.borderColor = NSColor.separatorColor.cgColor
        titleLeading.constant = isPicture ? 6 + Self.picture.width + Self.gap : 8
        title.stringValue = Self.title(of: item, thumbnail: thumbnail)
        deviceTagBox.isHidden = !item.isFromOtherDevice
        title.maximumNumberOfLines = Self.lineCount(of: item)
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        timeLabel.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        shortcutLabel.textColor = timeLabel.textColor
        deleteButton.contentTintColor = selected ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        deviceTag.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        deviceTagBox.layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(0.2)
                                                : NSColor.quaternaryLabelColor).cgColor
    }

    static func title(of item: ClipItem, thumbnail: Thumbnails.Result) -> String {
        if item.kind == .image {
            return thumbnail.pixelSize.map { "Picture, \(Int($0.width)) × \(Int($0.height))" } ?? "Picture"
        }
        return preview(of: item)
    }

    /// Whether the row shows the whole item: text whose every line fits, nothing left out. Pictures
    /// and files never (the preview shows them at full size, with their paths).
    func showsAll(of item: ClipItem) -> Bool {
        guard [.text, .richText, .link].contains(item.kind) else { return false }
        let lines = item.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count <= Self.lineCount(of: item), lines.joined().count <= 400 else { return false }
        layoutSubtreeIfNeeded()
        let room = timeLabel.superview!.frame.minX - Self.gap - title.frame.minX
        return lines.allSatisfy { ($0 as NSString).size(withAttributes: [.font: Self.titleFont]).width <= room - 4 }
    }

    static func lineCount(of item: ClipItem) -> Int {
        item.kind == .text || item.kind == .richText ? 2 : 1
    }

    /// As high as its text: one line, two for text over two lines, or a picture.
    static func height(of item: ClipItem, thumbnail: Thumbnails.Result) -> CGFloat {
        if item.kind == .image { return picture.height + 8 }
        // Each line of the preview is one line of the row, cut short when too long.
        let line = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let lines = min(lineCount(of: item), title(of: item, thumbnail: thumbnail).split(separator: "\n").count)
        return CGFloat(max(lines, 1)) * line + 12
    }

    /// The text with its runs of blank space folded, so two lines show as much as possible.
    static func preview(of item: ClipItem) -> String {
        if item.kind == .files { return item.title }
        let lines = item.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.prefix(4).joined(separator: "\n").prefix(400).description
    }
}

/// The last row of the quick list when the history holds more: it opens the history window.
final class ShowAllRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ShowAllRow")
    static let height: CGFloat = 28
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(more count: Int) {
        label.stringValue = "Show All (\(count) more)"
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
    }
}

/// Small previews of the pictures in the list.
final class Thumbnails {
    struct Result {
        var image: NSImage?
        var pixelSize: CGSize?
    }

    private let model: HistoryModel
    private var cache: [UUID: Result] = [:]

    init(model: HistoryModel) {
        self.model = model
    }

    func thumbnail(for item: ClipItem) -> Result {
        guard item.kind == .image else { return Result() }
        if let cached = cache[item.id] { return cached }
        let result = picture(for: item)
        cache[item.id] = result
        return result
    }

    private func picture(for item: ClipItem) -> Result {
        guard let snapshot = model.snapshot(for: item.id),
              let data = PasteboardType.images.lazy.compactMap({ snapshot.data($0) }).first,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return Result(image: Self.symbol("photo"))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let size = (properties?[kCGImagePropertyPixelWidth] as? Int).flatMap { width in
            (properties?[kCGImagePropertyPixelHeight] as? Int).map { CGSize(width: width, height: $0) }
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 240,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return Result(image: Self.symbol("photo"), pixelSize: size)
        }
        return Result(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
                      pixelSize: size)
    }

    private static func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

/// A small tooltip window next to the mouse.
final class HoverTip {
    private lazy var window: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        panel.contentView = background
        return panel
    }()
    private let label = NSTextField(labelWithString: "")
    private var hiddenAt = Date.distantPast

    /// Just after another tip closed, the next one shows at once, as the system's do.
    var isRecent: Bool { window.isVisible || Date().timeIntervalSince(hiddenAt) < 0.5 }

    func show(_ text: String, at point: NSPoint, over parent: NSWindow) {
        label.stringValue = text
        let size = window.contentView!.fittingSize
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x + 10, y: point.y - 22 - size.height)
        if origin.y < screen.minY { origin.y = point.y + 16 }
        origin.x = min(origin.x, screen.maxX - size.width)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.level = NSWindow.Level(parent.level.rawValue + 1)
        window.orderFront(nil)
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        hiddenAt = Date()
    }
}
