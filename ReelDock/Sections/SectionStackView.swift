import AppKit

final class SectionHeaderView: NSView {
    var onToggle: (() -> Void)?
    var onMaximize: (() -> Void)?
    var onReveal: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    var dropOperation: ((any NSDraggingInfo) -> NSDragOperation)?
    var acceptDrop: ((any NSDraggingInfo) -> Bool)?

    private let disclosure = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let tagDots = TagDotsView()
    private let maximizeButton = NSButton()
    private let revealButton = NSButton()
    private let separator = NSBox()
    private var canToggle = true
    private var opensOnHover = false
    private let springLoad = SpringLoad()
    private var isDropTarget = false {
        didSet {
            if isDropTarget != oldValue { needsDisplay = true }
        }
    }

    var tags: [FinderTag] {
        get { tagDots.tags }
        set { tagDots.tags = newValue }
    }

    var isActive = false {
        didSet {
            titleLabel.textColor = isActive ? .controlAccentColor : .labelColor
        }
    }

    init(title: String) {
        super.init(frame: .zero)

        disclosure.imageScaling = .scaleNone

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor

        maximizeButton.isBordered = false
        maximizeButton.bezelStyle = .accessoryBarAction
        maximizeButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Maximize Section")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        maximizeButton.contentTintColor = .secondaryLabelColor
        maximizeButton.imagePosition = .imageOnly
        maximizeButton.toolTip = "Maximize or restore this section"
        maximizeButton.target = self
        maximizeButton.action = #selector(maximize)

        revealButton.isBordered = false
        revealButton.bezelStyle = .accessoryBarAction
        revealButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Reveal in Finder")
        revealButton.contentTintColor = .secondaryLabelColor
        revealButton.imagePosition = .imageOnly
        revealButton.toolTip = "Reveal in Finder"
        revealButton.target = self
        revealButton.action = #selector(reveal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [disclosure, titleLabel, countLabel, tagDots, spacer, maximizeButton, revealButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        registerForDraggedTypes([.fileURL])

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 18),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        // Fill bounds, not dirtyRect: dirtyRect can extend past the view and would paint over other sections.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            bounds.fill()
        }
    }

    func update(count: Int?, expanded: Bool) {
        let isEmpty = count == 0
        countLabel.stringValue = isEmpty ? "Empty" : count.map(String.init) ?? "—"
        canToggle = !isEmpty
        opensOnHover = !isEmpty && !expanded
        maximizeButton.isHidden = isEmpty
        let symbol = expanded ? "chevron.down" : "chevron.right"
        disclosure.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        disclosure.contentTintColor = isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        titleLabel.alphaValue = isEmpty ? 0.55 : 1
    }

    /// Anywhere on the bar toggles the section, except its buttons.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : (hit == nil ? nil : self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, canToggle { onToggle?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?()
    }

    // MARK: Drop

    /// The way to drop into a section that's collapsed or empty, since neither shows a column.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isDropTarget = false
        springLoad.cancel()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isDropTarget = false
        springLoad.cancel()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        springLoad.cancel()
        return acceptDrop?(sender) ?? false
    }

    private func updateDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
        let operation = dropOperation?(info) ?? []
        isDropTarget = !operation.isEmpty
        // Resting on a collapsed section opens it, so its folders can be reached.
        if opensOnHover {
            springLoad.hover(over: "header") { [weak self] in self?.onToggle?() }
        } else {
            springLoad.cancel()
        }
        return operation
    }

    @objc private func maximize() { onMaximize?() }
    @objc private func reveal() { onReveal?() }
}

final class SectionPaneView: NSView {
    private(set) var section: FolderSection
    let header: SectionHeaderView
    let browser: ColumnBrowserView
    var count: Int?
    var isExpanded = true
    var weight: CGFloat = 1

    init(section: FolderSection, host: BrowserHost) {
        self.section = section
        self.count = section.itemCount
        header = SectionHeaderView(title: section.title)
        browser = ColumnBrowserView(rootURL: section.url, identifier: section.id, filesOnly: section.isFilesOnly, host: host)
        super.init(frame: .zero)
        addSubview(browser)
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: SectionStackView.headerHeight)
        browser.frame = NSRect(
            x: 0,
            y: SectionStackView.headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - SectionStackView.headerHeight)
        )
    }

    /// Used until the user drags a divider.
    var defaultWeight: CGFloat {
        CGFloat(section.defaultWeight(itemCount: count))
    }
}

final class SectionDividerView: NSView {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var isDraggable = false {
        didSet {
            if isDraggable != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }

    private var startY: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDraggable ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        if isDraggable { addCursorRect(bounds, cursor: .resizeUpDown) }
    }

    override func mouseDown(with event: NSEvent) {
        startY = event.locationInWindow.y
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Window coordinates grow upward, so dragging down is a positive height change.
        onDrag?(startY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

/// Stacks sections to fit the available height, with headers always visible.
final class SectionStackView: NSView {
    static let headerHeight: CGFloat = 28
    static let minimumExpandedHeight: CGFloat = 96
    private static let dividerGap: CGFloat = 1
    private static let dividerHitHeight: CGFloat = 7

    private(set) var panes: [SectionPaneView] = []
    private var dividers: [SectionDividerView] = []
    private var maximizedID: String?
    private var dragStartHeights: [CGFloat] = []
    private var dragPair: (upper: Int, lower: Int)?
    private var didDragDivider = false

    var onWeightChange: ((FolderSection, CGFloat) -> Void)?
    var onExpansionChange: ((FolderSection, Bool) -> Void)?
    var onConfigurePane: ((SectionPaneView) -> Void)?

    override var isFlipped: Bool { true }

    var requiredHeight: CGFloat {
        let expanded = panes.indices.filter(effectiveExpanded).count
        let collapsed = panes.count - expanded
        return CGFloat(expanded) * Self.minimumExpandedHeight
            + CGFloat(collapsed) * Self.headerHeight
            + CGFloat(max(0, panes.count - 1)) * Self.dividerGap
    }

    func setPanes(_ newPanes: [SectionPaneView]) {
        for pane in panes where !newPanes.contains(where: { $0 === pane }) {
            pane.removeFromSuperview()
        }
        for pane in newPanes where pane.superview !== self {
            addSubview(pane)
        }
        panes = newPanes
        if let maximizedID, !panes.contains(where: { $0.section.id == maximizedID }) {
            self.maximizedID = nil
        }
        rebuildDividers()
        refreshHeaders()
        needsLayout = true
    }

    private func rebuildDividers() {
        dividers.forEach { $0.removeFromSuperview() }
        dividers = panes.dropLast().indices.map { index in
            let divider = SectionDividerView()
            divider.onDragBegan = { [weak self] in self?.beginDrag(divider: index) }
            divider.onDrag = { [weak self] delta in self?.drag(by: delta) }
            divider.onDragEnded = { [weak self] in self?.endDrag() }
            addSubview(divider)
            return divider
        }
    }

    private func effectiveExpanded(_ index: Int) -> Bool {
        let pane = panes[index]
        if let maximizedID { return pane.section.id == maximizedID }
        return pane.isExpanded && pane.count != 0
    }

    func refreshHeaders() {
        for index in panes.indices {
            panes[index].header.update(count: panes[index].count, expanded: effectiveExpanded(index))
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        applyFrames(animated: false)
    }

    private func applyFrames(animated: Bool) {
        let heights = computeHeights(total: bounds.height)
        var y: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: heights[index])
            if animated {
                pane.animator().frame = frame
            } else {
                pane.frame = frame
            }
            y += heights[index]
            if index < dividers.count {
                let divider = dividers[index]
                divider.frame = NSRect(
                    x: 0,
                    y: y + Self.dividerGap / 2 - Self.dividerHitHeight / 2,
                    width: bounds.width,
                    height: Self.dividerHitHeight
                )
                divider.isDraggable = draggablePair(forDivider: index) != nil
                y += Self.dividerGap
            }
        }
    }

    private func computeHeights(total: CGFloat) -> [CGFloat] {
        var heights = [CGFloat](repeating: Self.headerHeight, count: panes.count)
        var open = panes.indices.filter(effectiveExpanded)
        var remaining = total
            - CGFloat(max(0, panes.count - 1)) * Self.dividerGap
            - CGFloat(panes.count - open.count) * Self.headerHeight

        // Give panes below the minimum exactly the minimum, and share the rest by weight.
        while !open.isEmpty {
            let totalWeight = open.reduce(CGFloat(0)) { $0 + panes[$1].weight }
            let tooSmall = open.filter {
                remaining * panes[$0].weight / totalWeight < Self.minimumExpandedHeight
            }
            if tooSmall.isEmpty {
                for index in open {
                    heights[index] = remaining * panes[index].weight / totalWeight
                }
                break
            }
            for index in tooSmall {
                heights[index] = Self.minimumExpandedHeight
                remaining -= Self.minimumExpandedHeight
            }
            open.removeAll { tooSmall.contains($0) }
        }
        return heights
    }

    // MARK: Divider dragging

    private func draggablePair(forDivider index: Int) -> (upper: Int, lower: Int)? {
        guard let upper = (0...index).reversed().first(where: effectiveExpanded),
              let lower = (index + 1..<panes.count).first(where: effectiveExpanded) else { return nil }
        return (upper, lower)
    }

    private func beginDrag(divider index: Int) {
        dragPair = draggablePair(forDivider: index)
        didDragDivider = false
        dragStartHeights = panes.map(\.frame.height)
    }

    private func drag(by delta: CGFloat) {
        guard let dragPair else { return }
        didDragDivider = true
        let upperStart = dragStartHeights[dragPair.upper]
        let lowerStart = dragStartHeights[dragPair.lower]
        let sum = upperStart + lowerStart
        let upperHeight = min(max(upperStart + delta, Self.minimumExpandedHeight), sum - Self.minimumExpandedHeight)

        let upper = panes[dragPair.upper]
        let lower = panes[dragPair.lower]
        let weightSum = upper.weight + lower.weight
        upper.weight = weightSum * upperHeight / sum
        lower.weight = weightSum - upper.weight
        needsLayout = true
    }

    private func endDrag() {
        defer { self.dragPair = nil }
        // A click without movement must not turn the current defaults into saved preferences.
        guard let dragPair, didDragDivider else { return }
        onWeightChange?(panes[dragPair.upper].section, panes[dragPair.upper].weight)
        onWeightChange?(panes[dragPair.lower].section, panes[dragPair.lower].weight)
    }

    // MARK: Expansion

    func toggle(_ pane: SectionPaneView) {
        if maximizedID != nil {
            maximizedID = nil
            pane.isExpanded = true
        } else {
            pane.isExpanded.toggle()
        }
        onExpansionChange?(pane.section, pane.isExpanded)
        settle()
    }

    /// Gives one section the available height. Doing it again restores the layout.
    func toggleMaximize(_ pane: SectionPaneView) {
        guard pane.count != 0 else { return }
        maximizedID = maximizedID == pane.section.id ? nil : pane.section.id
        settle()
    }

    private func settle() {
        refreshHeaders()
        superview?.needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            applyFrames(animated: true)
        }
    }

    /// Moves focus to the next or previous open section.
    func focusAdjacent(from browser: ColumnBrowserView?, delta: Int) {
        let open = panes.indices.filter(effectiveExpanded)
        guard !open.isEmpty else { return }
        let current = panes.firstIndex { $0.browser === browser }
        let position = current.flatMap { open.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        let next = (position + delta + open.count) % open.count
        panes[open[next]].browser.focus(selectingFirstRow: true)
    }
}

/// Hosts the stack in a scroll view that only scrolls when too many sections are open to fit.
final class SectionsHostView: NSView {
    let stack = SectionStackView()
    private let scrollView = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.documentView = stack
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let size = scrollView.contentSize
        stack.frame = NSRect(x: 0, y: 0, width: size.width, height: max(size.height, stack.requiredHeight))
    }
}
