import AVFoundation
import Foundation

nonisolated struct MediaInfo: Equatable, Sendable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var codec: String?
    var audioChannels: Int?
    var audioSampleRate: Double?
}

nonisolated enum MediaInfoReader {
    static func read(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }

        var info = MediaInfo()
        if duration.isNumeric { info.duration = duration.seconds }

        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await video.load(.naturalSize) {
                // Vertical footage is stored sideways with a rotation.
                let transform = (try? await video.load(.preferredTransform)) ?? .identity
                let shown = size.applying(transform)
                info.width = Int(abs(shown.width))
                info.height = Int(abs(shown.height))
            }
            if let rate = try? await video.load(.nominalFrameRate), rate > 0 {
                info.frameRate = Double(rate)
            }
            if let format = try? await video.load(.formatDescriptions).first {
                info.codec = codecName(CMFormatDescriptionGetMediaSubType(format))
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await audio.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            info.audioChannels = Int(description.mChannelsPerFrame)
            info.audioSampleRate = description.mSampleRate
        }
        return info
    }

    static func codecName(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = String(bytes: bytes, encoding: .ascii) ?? ""
        switch fourCC {
        case "hvc1", "hev1": return "HEVC"
        case "avc1", "avc3": return "H.264"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes 422 Proxy"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        default: return fourCC.trimmingCharacters(in: .whitespaces)
        }
    }
}
