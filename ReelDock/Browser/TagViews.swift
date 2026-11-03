import AppKit
import SwiftUI

extension FinderTag {
    /// A colored dot for menus. Not a template, so the menu keeps its color.
    var menuImage: NSImage {
        let color = color
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color {
                color.setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

private final class MenuClosure: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}

extension NSMenuItem {
    /// An item that runs a closure, for menus built on the spot.
    static func closure(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let closure = MenuClosure(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuClosure.run), keyEquivalent: "")
        item.target = closure
        // The target is weak, so the item has to keep it alive.
        item.representedObject = closure
        return item
    }
}

/// Finder-style overlapping dots. A tag with no color shows as a hollow dot, so no tag goes unseen.
final class TagDotsView: NSView {
    private static let diameter: CGFloat = 10
    private static let step: CGFloat = 6

    var tags: [FinderTag] = [] {
        didSet {
            guard tags != oldValue else { return }
            isHidden = tags.isEmpty
            toolTip = tags.map(\.name).joined(separator: ", ")
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        guard !tags.isEmpty else { return NSSize(width: 0, height: Self.diameter) }
        return NSSize(width: Self.diameter + CGFloat(tags.count - 1) * Self.step, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(tags, y: (bounds.height - Self.diameter) / 2)
    }

    /// The same dots as an image, for text. Not a template, so they keep their color.
    static func image(of tags: [FinderTag]) -> NSImage {
        let width = diameter + CGFloat(max(tags.count - 1, 0)) * step
        let image = NSImage(size: NSSize(width: width, height: diameter), flipped: false) { _ in
            draw(tags, y: 0)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(_ tags: [FinderTag], y: CGFloat) {
        for (index, tag) in tags.enumerated() {
            let rect = NSRect(x: CGFloat(index) * step, y: y, width: diameter, height: diameter)
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let color = tag.color {
                color.setFill()
                path.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
            }
        }
    }
}

struct TagDots: View {
    let tags: [FinderTag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: -4) {
                ForEach(tags) { TagDot(tag: $0) }
            }
            .help(tags.map(\.name).joined(separator: ", "))
        }
    }
}

private struct TagDot: View {
    let tag: FinderTag

    var body: some View {
        Group {
            if let color = tag.color {
                Circle().fill(Color(nsColor: color))
            } else {
                Circle().strokeBorder(.secondary, lineWidth: 1)
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// Dots in front of a title. The space stays when there are none, so titles in a list line up.
struct LeadingTagDots: View {
    let tags: [FinderTag]

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 10, height: 10)
            TagDots(tags: tags)
        }
        // Centers the dots on the first line of text.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}

/// The inspector's row: the selection's tags by name, and a button to change them.
struct TagRow: View {
    weak var controller: WorkspaceWindowController?
    let items: [FolderItem]

    private var tags: [FinderTag] {
        var seen = Set<String>()
        return items.flatMap(\.tags).filter { seen.insert($0.name).inserted }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tags) { tag in
                HStack(spacing: 4) {
                    TagDot(tag: tag)
                    Text(tag.name)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            Button {
                controller?.showTagMenu(for: items.map(\.url))
            } label: {
                Image(systemName: "tag")
            }
            .buttonStyle(.borderless)
            .help("Change tags")
            Spacer(minLength: 0)
        }
    }
}
