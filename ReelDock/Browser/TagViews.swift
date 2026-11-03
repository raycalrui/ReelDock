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
        let y = (bounds.height - Self.diameter) / 2
        for (index, tag) in tags.enumerated() {
            let rect = NSRect(x: CGFloat(index) * Self.step, y: y, width: Self.diameter, height: Self.diameter)
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

/// The tag choices for a context menu or the inspector's tag button.
struct TagMenuItems: View {
    weak var controller: WorkspaceWindowController?
    let urls: [URL]

    var body: some View {
        ForEach(controller?.tagChoices(for: urls) ?? []) { choice in
            Toggle(isOn: Binding(
                get: { choice.state == .all },
                set: { _ in controller?.toggle(choice, on: urls) }
            )) {
                Label {
                    Text(choice.tag.name)
                } icon: {
                    Image(nsImage: choice.tag.menuImage)
                }
            }
        }
        Divider()
        Button("New Tag…") { controller?.promptForNewTag(on: urls) }
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
            Menu {
                TagMenuItems(controller: controller, urls: items.map(\.url))
            } label: {
                Image(systemName: "tag")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change tags")
            Spacer(minLength: 0)
        }
    }
}
