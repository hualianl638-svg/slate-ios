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

/// 视频伽马（对数灰片 vs 标准 709）的启发式识别结果。
///
/// 为什么不能只靠元数据：S-Log3 素材在容器里通常被标成 `ITU_R_709_2`，
/// 没有标准字段声明"这是对数编码"。所以只能看画面统计特征。
struct LogProfileDetection {
    /// 是否判定为对数灰片（S-Log3 / C-Log 等）。
    var isLikelyLog: Bool
    /// 判定可信度 0...1。
    var confidence: Double
    /// 暗部底噪（分位数）—— 灰片被抬高到 ~0.09，709 接近 0。
    var blackFloor: Double
    /// 平均彩度 —— 灰片整体发灰、彩度低。
    var meanChroma: Double
    /// 高光上限（99 分位）。
    var highlightCeiling: Double
    /// 元数据提示（位深 / 传输函数）。
    var hint: String
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

    /// 识别一段视频是"对数灰片"还是"标准 709"。
    ///
    /// 判据（都是 S-Log3 的典型特征）：
    ///  1. 黑场被抬高：S-Log3 把线性 0 编码到约 0.09，709 接近 0；
    ///  2. 彩度偏低：对数编码压平了色差信号；
    ///  3. 高光压缩：99 分位通常到不了 1.0；
    ///  4. 元数据加权：10bit 更常见于灰片，HDR(HLG/PQ) 则直接排除。
    static func detectLogProfile(url: URL) async -> LogProfileDetection? {
        // 取一帧缩略图做统计
        guard let image = try? await thumbnail(url: url, maxPixel: 192),
              let cgImage = image.cgImage else { return nil }

        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var lumas = [Double]()
        lumas.reserveCapacity(width * height)
        var chromaSum = 0.0
        var index = 0
        while index < pixels.count {
            let r = Double(pixels[index]) / 255.0
            let g = Double(pixels[index + 1]) / 255.0
            let b = Double(pixels[index + 2]) / 255.0
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            chromaSum += (max(r, max(g, b)) - min(r, min(g, b)))
            index += 4
        }
        guard !lumas.isEmpty else { return nil }
        lumas.sort()

        func percentile(_ p: Double) -> Double {
            let clamped = min(max(p, 0), 1)
            return lumas[min(lumas.count - 1, Int(Double(lumas.count - 1) * clamped))]
        }

        let blackFloor = percentile(0.05)
        let highlightCeiling = percentile(0.99)
        let meanChroma = chromaSum / Double(lumas.count)

        // 元数据提示
        let info = try? await inspect(url: url)
        let isHDR = info?.isHDR ?? false
        let depth = info?.bitDepth ?? 8
        let hint = "\(depth)bit \(isHDR ? "HDR" : (info?.transfer ?? "—"))"

        var score = 0.0
        if blackFloor > 0.055 { score += 0.45 }
        if blackFloor > 0.080 { score += 0.15 }
        if meanChroma < 0.22 { score += 0.20 }
        if highlightCeiling < 0.94 { score += 0.10 }
        if depth >= 10 { score += 0.10 }
        if isHDR { score -= 0.50 }

        let confidence = min(max(score, 0), 1)
        return LogProfileDetection(
            isLikelyLog: confidence >= 0.55,
            confidence: confidence,
            blackFloor: blackFloor,
            meanChroma: meanChroma,
            highlightCeiling: highlightCeiling,
            hint: hint
        )
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
