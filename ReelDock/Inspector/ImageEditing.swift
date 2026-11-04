import Observation
import SwiftUI

/// The edits made so far to one image, held in memory until they're saved.
@Observable
final class ImageEditSession {
    let url: URL
    /// Nil until the full-size image has loaded.
    private(set) var image: CGImage?
    private(set) var isEdited = false
    private(set) var isWorking = false
    /// The selection while cropping.
    var crop: CGRect?
    @ObservationIgnored var onError: ((any Error) -> Void)?

    init(url: URL) {
        self.url = url
    }

    var canEdit: Bool { !isWorking && crop == nil }

    func rotate(clockwise: Bool) {
        guard canEdit else { return }
        run { try ImageEditor.rotated($0, clockwise: clockwise) }
    }

    func beginCrop() {
        guard canEdit else { return }
        run(marksEdited: false, then: { [weak self] in self?.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }) { $0 }
    }

    func applyCrop() {
        guard let crop, !isWorking else { return }
        self.crop = nil
        guard crop != CGRect(x: 0, y: 0, width: 1, height: 1) else { return }
        run { image in
            try ImageEditor.cropped(image, to: CropGeometry.pixelRect(crop, imageWidth: image.width, imageHeight: image.height))
        }
    }

    func setWorking(_ working: Bool) {
        isWorking = working
    }

    private func run(
        marksEdited: Bool = true,
        then: (() -> Void)? = nil,
        _ edit: @escaping @Sendable (CGImage) throws -> CGImage
    ) {
        isWorking = true
        let url = url
        let current = image
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try edit(try current ?? ImageEditor.load(url)) }
            }.value
            isWorking = false
            switch result {
            case let .success(edited):
                image = edited
                if marksEdited { isEdited = true }
                then?()
            case let .failure(error):
                onError?(error)
            }
        }
    }
}

/// Rotate and crop, then save or discard, under the preview.
struct ImageEditBar: View {
    let session: ImageEditSession?
    weak var controller: WorkspaceWindowController?

    var body: some View {
        HStack(spacing: 4) {
            let canEdit = session?.canEdit ?? true
            Button { controller?.rotateImage(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .buttonStyle(.borderless)
                .help("Rotate Left (⌘L)")
                .disabled(!canEdit)
            Button { controller?.beginImageCrop() } label: { Image(systemName: "crop") }
                .buttonStyle(.borderless)
                .help("Crop (⌘K)")
                .disabled(!canEdit)
            Spacer(minLength: 4)
            if let session {
                if session.crop != nil {
                    Button("Cancel") { session.crop = nil }
                    Button("Crop") { session.applyCrop() }
                        .buttonStyle(.borderedProminent)
                } else if session.isEdited {
                    Button("Revert") { controller?.discardImageEdit() }
                        .disabled(session.isWorking)
                    Button("Save Copy") { controller?.saveImageEdit(asCopy: true) }
                        .help("Save as a new file, and leave the original as it is (⇧⌘S)")
                        .disabled(session.isWorking)
                    Button("Save") { controller?.saveImageEdit(asCopy: false) }
                        .help("Replace the file. The original goes to the Trash, and Undo brings it back (⌘S)")
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isWorking)
                }
            }
        }
        .controlSize(.small)
    }
}

/// Dims what a crop would remove, with grips on the selection. Drag a grip to resize, inside to move, or outside to start over.
struct CropOverlay: View {
    let session: ImageEditSession
    let imageSize: CGSize

    @State private var dragStart: (rect: CGRect, grip: CropGeometry.Grip, point: CGPoint)?

    var body: some View {
        GeometryReader { proxy in
            let fitted = CropGeometry.fittedRect(imageSize, in: proxy.size)
            let selection = session.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let shown = CGRect(
                x: fitted.minX + selection.minX * fitted.width,
                y: fitted.minY + selection.minY * fitted.height,
                width: selection.width * fitted.width,
                height: selection.height * fitted.height
            )
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(fitted)
                    path.addRect(shown)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { $0.addRect(shown) }
                    .stroke(.white, lineWidth: 1)
                ForEach(Self.gripPoints(of: shown), id: \.self) { point in
                    Rectangle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .position(point)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: fitted))
        }
    }

    private static func gripPoints(of rect: CGRect) -> [CGPoint] {
        [rect.minX, rect.midX, rect.maxX].flatMap { x in
            [rect.minY, rect.midY, rect.maxY].compactMap { y in
                x == rect.midX && y == rect.midY ? nil : CGPoint(x: x, y: y)
            }
        }
    }

    private func drag(in fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard fitted.width > 0, fitted.height > 0, let current = session.crop else { return }
                func fraction(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: (point.x - fitted.minX) / fitted.width, y: (point.y - fitted.minY) / fitted.height)
                }
                if dragStart == nil {
                    let start = fraction(value.startLocation)
                    dragStart = (current, CropGeometry.grip(at: start, of: current, toleranceX: 8 / fitted.width, toleranceY: 8 / fitted.height), start)
                }
                guard let dragStart else { return }
                session.crop = CropGeometry.dragged(dragStart.rect, grip: dragStart.grip, from: dragStart.point, to: fraction(value.location))
            }
            .onEnded { _ in dragStart = nil }
    }
}
