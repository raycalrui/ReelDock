import AppKit
import QuickLookThumbnailing

final class FileRowView: NSTableCellView, NameEditing {
    static let identifier = NSUserInterfaceItemIdentifier("FileRow")
    private static let iconSize: CGFloat = 20
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let tagDots = TagDotsView()
    private let detailLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var representedPath: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, nameLabel, tagDots, detailLabel, chevron])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = nameLabel
        imageView = iconView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
    }

    private func cancelThumbnail() {
        if let thumbnailRequest { ThumbnailCache.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
    }

    func beginEditingName(delegate: any NSTextFieldDelegate, isFolder: Bool) {
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = .textBackgroundColor
        nameLabel.textColor = .textColor
        nameLabel.focusRingType = .exterior
        nameLabel.lineBreakMode = .byClipping
        nameLabel.cell?.isScrollable = true
        nameLabel.delegate = delegate
        detailLabel.isHidden = true
        window?.makeFirstResponder(nameLabel)
        let name = nameLabel.stringValue as NSString
        let length = isFolder || name.pathExtension.isEmpty ? name.length : name.deletingPathExtension.count
        nameLabel.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
    }

    func endEditingName() {
        nameLabel.delegate = nil
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.drawsBackground = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
    }

    func configure(with item: FolderItem) {
        cancelThumbnail()
        representedPath = item.url.path
        nameLabel.stringValue = item.name
        toolTip = item.name
        tagDots.tags = item.tags
        chevron.isHidden = !item.isFolder
        detailLabel.isHidden = item.isFolder || item.size == nil
        detailLabel.stringValue = item.size.map(Self.sizeFormatter.string(fromByteCount:)) ?? ""
        iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)

        guard item.hasVisualThumbnail else { return }
        let scale = window?.backingScaleFactor ?? 2
        if let cached = ThumbnailCache.shared.cached(item.url, modified: item.modified, size: Self.iconSize) {
            iconView.image = cached
            return
        }
        let path = item.url.path
        thumbnailRequest = ThumbnailCache.shared.request(item.url, modified: item.modified, size: Self.iconSize, scale: scale) { [weak self] image in
            guard let self, self.representedPath == path else { return }
            self.iconView.image = image
        }
    }
}
