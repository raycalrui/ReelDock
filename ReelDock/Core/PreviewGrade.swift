import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import Observation

/// Puts a LUT on decoded frames for preview. Nothing here touches a file.
///
/// Color management is off from end to end, because a LUT has to see the raw log values, as it does in Resolve,
/// and not values Core Image converted from whatever tags the file carries. Sony's clips carry none.
nonisolated final class PreviewGrade: @unchecked Sendable {
    /// The most points Core Image's color cube takes. A 65-point LUT is sampled down to this.
    private static let longestCubeSide = 64

    let context: CIContext
    private let cubeDimension: Int
    private let cubeData: Data

    init(lut: CubeLUT) {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
        let cube = lut.colorCube(maxDimension: Self.longestCubeSide)
        cubeDimension = cube.dimension
        cubeData = cube.data
    }

    /// A picture tagged Rec. 709 is shown with a gamma of 1.961, but a video layer shows the same tag with a gamma of 2.4,
    /// so a frame looks darker once it plays. Measured on screen: the two differ by exactly 2.4 / 1.961 in linear light,
    /// and no tag a composition can carry makes the layer use 1.961. So frames for a video layer are re-encoded to match.
    static let videoLayerGamma = Float(1.961 / 2.4)

    func image(from buffer: CVPixelBuffer, forVideoLayer: Bool = false) -> CIImage {
        Self.ensureMatrix(on: buffer)
        let source = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let filter = CIFilter.colorCube()
        filter.inputImage = source
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = cubeData
        filter.extrapolate = false
        let graded = filter.outputImage ?? source
        guard forVideoLayer else { return graded }
        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = graded
        gamma.power = Self.videoLayerGamma
        return gamma.outputImage ?? graded
    }

    /// Fills `destination`, and tags it Rec. 709 so the system shows it as the LUT meant.
    func render(_ image: CIImage, into destination: CVPixelBuffer) throws {
        Self.tagRec709(destination)
        let target = CIRenderDestination(pixelBuffer: destination)
        target.colorSpace = nil
        try context.startTask(toRender: image, to: target).waitUntilCompleted()
    }

    /// Plays or draws an asset through this LUT. Nil for an asset with no video.
    /// `forVideoLayer` is for a player, and leaving it off is for pictures, so both look the same on screen.
    func composition(for asset: AVAsset, forVideoLayer: Bool = false) async -> AVVideoComposition? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, rate, range) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange),
              size.width > 0, size.height > 0 else { return nil }
        let orientation = Self.orientation(of: transform)
        let isSideways = orientation == .left || orientation == .right
        let instruction = GradeInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTimeMaximum(range.end, CMTime(value: 1, timescale: 1))),
            trackID: track.trackID,
            grade: self,
            orientation: orientation,
            forVideoLayer: forVideoLayer
        )
        // The player reads these and ignores tags on the frames themselves. `videoLayerGamma` is measured against them.
        // The compositor conforms its sources itself, so the log values still arrive untouched.
        return AVVideoComposition(configuration: AVVideoComposition.Configuration(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: GradeCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(1, (rate > 0 ? rate : 30).rounded()))),
            instructions: [instruction],
            renderSize: isSideways ? CGSize(width: size.height, height: size.width) : size,
            sourceTrackIDForFrameTiming: track.trackID
        ))
    }

    /// A frame for the display layer, for backward playback. Its size stays the same, and it's left unrotated like the rest.
    func gradedSample(_ sample: CMSampleBuffer, pool: inout CVPixelBufferPool?, forVideoLayer: Bool = true) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        guard (try? render(image(from: source, forVideoLayer: forVideoLayer), into: output)) != nil else { return nil }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            decodeTimeStamp: .invalid
        )
        var graded: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &graded)
        return graded
    }

    /// Without a matrix, Core Image assumes BT.601 and shifts hues. Apple Log is BT.2020, and anything else untagged gets 709.
    static func ensureMatrix(on buffer: CVPixelBuffer) {
        guard CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil else { return }
        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
        let matrix = primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
            ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }

    static func tagRec709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// The quarter turn a track asks for. Rotating a clip in ReelDock only ever changes this.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch Int((atan2(transform.b, transform.a) * 2 / .pi).rounded()) {
        case 1: .right
        case -1: .left
        case 2, -2: .down
        default: .up
        }
    }
}

/// Carries the grade to the compositor, which AVFoundation creates by itself from its class.
nonisolated final class GradeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let grade: PreviewGrade
    let orientation: CGImagePropertyOrientation
    let forVideoLayer: Bool

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, grade: PreviewGrade, orientation: CGImagePropertyOrientation, forVideoLayer: Bool = false) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.grade = grade
        self.orientation = orientation
        self.forVideoLayer = forVideoLayer
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Works on the decoder's own frames rather than a filter handler's color-managed image,
/// so it can set the matrix an untagged Sony clip is missing.
nonisolated final class GradeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc.raycal.ReelDock.grade", qos: .userInteractive)

    // All three keep the engine from converting frames first, which would turn log footage into something else.
    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true
    let canConformColorOfSourceFrames = true

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            Int(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
        ],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            do {
                guard let instruction = request.videoCompositionInstruction as? GradeInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID),
                      let output = request.renderContext.newPixelBuffer() else {
                    throw CocoaError(.fileReadUnknown)
                }
                var image = instruction.grade.image(from: source, forVideoLayer: instruction.forVideoLayer).oriented(instruction.orientation)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let width = CGFloat(CVPixelBufferGetWidth(output))
                let height = CGFloat(CVPixelBufferGetHeight(output))
                if image.extent.width != width || image.extent.height != height {
                    image = image.transformed(by: CGAffineTransform(scaleX: width / image.extent.width, y: height / image.extent.height))
                }
                try instruction.grade.render(image, into: output)
                #if DEBUG
                debugGradedFrames.increment()
                #endif
                request.finish(withComposedVideoFrame: output)
            } catch {
                request.finish(with: error)
            }
        }
    }
}

/// The LUTs chosen in Settings, one for each log curve, and whether previews use them.
@Observable
final class PreviewLUTs {
    static let shared = PreviewLUTs()

    private(set) var isEnabled = false
    private(set) var paths: [LogGamma: String] = [:]
    /// Changes whenever what a clip should look like changes.
    private(set) var generation = 0

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var grades: [String: PreviewGrade] = [:]

    private init() {}

    func configure(isEnabled: Bool, paths: [LogGamma: String]) {
        self.isEnabled = isEnabled
        self.paths = paths
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        changed()
    }

    /// Reads the file first, so a bad one is reported when it's chosen rather than leaving previews flat.
    func choose(_ url: URL, for gamma: LogGamma) async throws {
        let grade = try await Task.detached(priority: .userInitiated) {
            PreviewGrade(lut: try CubeLUT(data: try Data(contentsOf: url)))
        }.value
        grades[url.path] = grade
        paths[gamma] = url.path
        changed()
    }

    func clear(_ gamma: LogGamma) {
        paths[gamma] = nil
        changed()
    }

    private func changed() {
        generation &+= 1
        onChange?()
    }

    /// Nil unless previews are on, the clip is log footage, and that curve has a usable LUT.
    func grade(forClipAt url: URL) async -> PreviewGrade? {
        guard isEnabled, let gamma = await Task.detached(priority: .userInitiated, operation: { await LogFootage.gamma(of: url) }).value,
              let path = paths[gamma] else { return nil }
        if let grade = grades[path] { return grade }
        let lutURL = URL(fileURLWithPath: path)
        let grade = await Task.detached(priority: .userInitiated) { () -> PreviewGrade? in
            guard let data = try? Data(contentsOf: lutURL), let lut = try? CubeLUT(data: data) else { return nil }
            return PreviewGrade(lut: lut)
        }.value
        if let grade { grades[path] = grade }
        return grade
    }
}

#if DEBUG
nonisolated final class DebugCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
nonisolated let debugGradedFrames = DebugCounter()
#endif
