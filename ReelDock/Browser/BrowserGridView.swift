import AppKit
import QuickLookThumbnailing

/// The grid form of a column, which suits pictures. Selection, menus, and file operations stay with the column.
final class BrowserGridView: NSCollectionView {
    static let tileSize = NSSize(width: 148, height: 138)
    /// Blank space past the last row, so a full grid still has somewhere to right-click.
    static let bottomPadding: CGFloat = 44

    weak var column: BrowserColumnView?

    init() {
        super.init(frame: .zero)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.tileSize
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: Self.bottomPadding, right: 8)
        collectionViewLayout = layout
        isSelectable = true
        allowsMultipleSelection = true
        allowsEmptySelection = true
        backgroundColors = [.controlBackgroundColor]
        register(GridTileItem.self, forItemWithIdentifier: GridTileItem.identifier)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { column?.tableDidGainFocus() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            column?.openItem(at: path.item)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return column?.backgroundMenu() }
        if !selectionIndexPaths.contains(path) {
            column?.selectRows(IndexSet(integer: path.item))
        }
        return column?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let command = flags.contains(.command)
        switch event.keyCode {
        case 124 where !command: // Right arrow
            moveSelection(.right, extending: flags.contains(.shift))
        case 123 where !command: // Left arrow
            moveSelection(.left, extending: flags.contains(.shift))
        case 125 where command: // Command-Down
            column?.openSelection()
        case 125: // Down arrow
            moveSelection(.down, extending: flags.contains(.shift))
        case 126: // Up arrow
            moveSelection(.up, extending: flags.contains(.shift))
        case 49: // Space belongs to the player.
            break
        case 36 where !command, 76 where !command: // Return and Enter
            column?.browser?.renameSelection()
        case 48: // Tab
            column?.moveFocusToAdjacentSection(flags.contains(.shift) ? -1 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    /// For the full-screen preview, which goes through the pictures in order.
    func stepSelection(by delta: Int) {
        guard let column, let current = delta > 0 ? column.selectedRows.last : column.selectedRows.first,
              column.items.indices.contains(current + delta) else { return }
        column.selectRows(IndexSet(integer: current + delta))
        scrollToItems(at: [IndexPath(item: current + delta, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    private enum Direction {
        case left, right, up, down
    }

    private var tilesPerRow: Int {
        // Opening or closing a folder beside this one changes the width, in a layout pass that may not have run yet.
        column?.browser?.layoutSubtreeIfNeeded()
        let layout = collectionViewLayout as? NSCollectionViewFlowLayout
        let inset = (layout?.sectionInset.left ?? 0) + (layout?.sectionInset.right ?? 0)
        let spacing = layout?.minimumInteritemSpacing ?? 0
        return max(1, Int((bounds.width - inset + spacing) / (Self.tileSize.width + spacing)))
    }

    /// Left from the first tile in a row, and right from a folder, cross to the next column, as in the list.
    private func moveSelection(_ direction: Direction, extending: Bool) {
        guard let column, !column.items.isEmpty else { return }
        let selected = column.selectedRows
        guard let current = direction == .left || direction == .up ? selected.first : selected.last else {
            column.selectRows(IndexSet(integer: 0))
            return
        }
        let target: Int
        switch direction {
        case .right:
            if column.items[current].isFolder, !extending {
                column.moveFocusRight()
                return
            }
            target = current + 1
        case .left:
            if current % tilesPerRow == 0, !extending {
                column.moveFocusLeft()
                return
            }
            target = current - 1
        case .up: target = current - tilesPerRow
        case .down: target = min(current + tilesPerRow, column.items.count - 1)
        }
        guard column.items.indices.contains(target) else { return }
        column.selectRows(extending ? selected.union(IndexSet(integer: target)) : IndexSet(integer: target))
        scrollToItems(at: [IndexPath(item: target, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    // MARK: Drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        column?.updateSpringLoad(sender)
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        column?.updateSpringLoad(sender)
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        column?.cancelSpringLoad()
        super.draggingExited(sender)
    }

    // No super call: AppKit's views don't implement this, so calling it would crash.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        column?.cancelSpringLoad()
    }
}

final class GridTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GridTile")

    private var tile: GridTileView? { view as? GridTileView }

    override func loadView() {
        view = GridTileView(frame: NSRect(origin: .zero, size: BrowserGridView.tileSize))
    }

    override var isSelected: Bool {
        didSet { tile?.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tile?.cancelThumbnail()
        tile?.isSelected = false
    }

    func configure(with item: FolderItem) {
        tile?.configure(with: item)
    }

    func beginEditingName(delegate: any NSTextFieldDelegate, isFolder: Bool) {
        tile?.beginEditingName(delegate: delegate, isFolder: isFolder)
    }
}

/// A picture above its name, with the same tag dots and size as a list row.
final class GridTileView: NSView, NameEditing {
    private static let thumbnailSide: CGFloat = 132
    private static let thumbnailHeight: CGFloat = 92
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let tagDots = TagDotsView()
    private let detailLabel = NSTextField(labelWithString: "")
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var representedPath: String?

    var isSelected = false {
        didSet {
            if isSelected != oldValue { needsDisplay = true }
            nameLabel.textColor = isSelected && !isEditing ? .selectedMenuItemTextColor : .labelColor
            detailLabel.textColor = isSelected ? .selectedMenuItemTextColor : .secondaryLabelColor
        }
    }

    private var isEditing: Bool { nameLabel.isEditable }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment = .center
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        let nameRow = NSStackView(views: [tagDots, nameLabel])
        nameRow.orientation = .horizontal
        nameRow.spacing = 4
        nameRow.alignment = .centerY

        let stack = NSStackView(views: [imageView, nameRow, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            imageView.widthAnchor.constraint(equalToConstant: Self.thumbnailSide),
            imageView.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),
            nameRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let color: NSColor = window?.firstResponder is BrowserGridView ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    /// Clicks go to the grid, which handles selection and dragging, except while the name is being typed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return isEditing && hit.isDescendant(of: nameLabel) ? hit : self
    }

    func cancelThumbnail() {
        if let thumbnailRequest { ThumbnailCache.shared.cancel(thumbnailRequest) }
        thumbnailRequest = nil
    }

    func configure(with item: FolderItem) {
        cancelThumbnail()
        representedPath = item.url.path
        nameLabel.stringValue = item.name
        toolTip = item.name
        tagDots.tags = item.tags
        detailLabel.stringValue = item.size.map(Self.sizeFormatter.string(fromByteCount:)) ?? ""
        imageView.image = NSWorkspace.shared.icon(forFile: item.url.path)

        guard item.hasVisualThumbnail else { return }
        if let cached = ThumbnailCache.shared.cached(item.url, modified: item.modified, size: Self.thumbnailSide) {
            imageView.image = cached
            return
        }
        let path = item.url.path
        thumbnailRequest = ThumbnailCache.shared.request(
            item.url,
            modified: item.modified,
            size: Self.thumbnailSide,
            scale: window?.backingScaleFactor ?? 2
        ) { [weak self] image in
            guard let self, self.representedPath == path else { return }
            self.imageView.image = image
        }
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
        nameLabel.textColor = isSelected ? .selectedMenuItemTextColor : .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
    }
}
