import AVFoundation
import Foundation
import UIKit

struct VideoInfo {
    var width: Int
    var height: Int
    var fps: Double
    var seconds: Double
    var codec: String
    var bitDepth: Int?
    var transfer: String?
    var isHDR: Bool
}

enum ProbeError: LocalizedError {
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频轨"
        }
    }
}

enum VideoProbe {
    static func inspect(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ProbeError.noVideoTrack }

        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)

        // 旋转 90/270 时宽高互换，按显示方向报数
        let rotated = abs(transform.b) > 0.5
        let w = Int(rotated ? size.height : size.width)
        let h = Int(rotated ? size.width : size.height)

        var codec = "—"
        var depth: Int?
        var transfer: String?
        var hdr = false

        if let fd = formats.first {
            codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
            if let n = CMFormatDescriptionGetExtension(
                fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent
            ) as? NSNumber {
                depth = n.intValue
            }
            if let t = CMFormatDescriptionGetExtension(
                fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String {
                transfer = t
                hdr = (t == "ITU_R_2100_HLG" || t == "SMPTE_ST_2084_PQ")
            }
        }

        return VideoInfo(
            width: w,
            height: h,
            fps: Double(fps),
            seconds: CMTimeGetSeconds(duration),
            codec: codec,
            bitDepth: depth,
            transfer: transfer,
            isHDR: hdr
        )
    }

    /// 取一帧用于预览
    static func thumbnail(url: URL, maxPixel: CGFloat = 1800) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // 避开片头全黑，取 0.15s；素材过短则退回 0
        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        let target = total > 0.4 ? CMTime(seconds: 0.15, preferredTimescale: 600) : .zero
        let (cg, _) = try await generator.image(at: target)
        return UIImage(cgImage: cg)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .isoLatin1) ?? "\(code)"
    }
}
