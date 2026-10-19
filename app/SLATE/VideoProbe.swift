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
    /// 上一版只看单帧的黑场抬升，室外 709 素材（天空/强光把 5% 分位抬高）
    /// 会被误判成灰片。现在改成：
    ///
    /// **正向证据**（灰片特征）
    ///  · 黑场落在对数特征窗口 0.05~0.14（S-Log3 把线性 0 编到 ≈0.09）；
    ///  · 平均彩度低（对数编码压平色差）；
    ///  · 极暗像素占比高（对数信号抬底后几乎没有纯黑）；
    ///  · 10bit 加权。
    ///
    /// **反向证据**（正常 709 特征）
    ///  · 高光裁切：709 室外常有超过 2% 的像素贴到 1.0，对数信号很少裁切；
    ///  · 对比跨度大：709 的 p95-p05 常 > 0.85，对数编码压缩后更小；
    ///  · HDR HLG/PQ 直接排除。
    ///
    /// 多帧取中位数，避免单帧（对着天空/黑场）造成误判。
    static func detectLogProfile(url: URL) async -> LogProfileDetection? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let total = CMTimeGetSeconds(duration)
        guard total.isFinite, total > 0 else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 192)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)

        // 取 5 个时间点（短素材自动减少）
        var fractions: [Double] = [0.15, 0.3, 0.5, 0.7, 0.85]
        if total < 1.0 { fractions = [0.5] }
        else if total < 3.0 { fractions = [0.3, 0.7] }

        var samples: [ImageStats] = []
        for fraction in fractions {
            let time = CMTime(seconds: total * fraction, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time),
                  let stats = Self.analyze(cgImage) else { continue }
            samples.append(stats)
        }
        guard !samples.isEmpty else { return nil }

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        let blackFloor = median(samples.map(\.p05))
        let meanChroma = median(samples.map(\.meanChroma))
        let highlightCeiling = median(samples.map(\.p99))
        let contrastSpan = median(samples.map { $0.p95 - $0.p05 })
        let deepShadowRatio = median(samples.map(\.deepShadowRatio))
        let clippedRatio = median(samples.map(\.clippedRatio))

        let info = try? await inspect(url: url)
        let isHDR = info?.isHDR ?? false
        let depth = info?.bitDepth ?? 8
        let hint = "\(depth)bit \(isHDR ? "HDR" : (info?.transfer ?? "—"))"

        var score = 0.0

        // 正向：黑场在对数窗口内
        if blackFloor >= 0.05 && blackFloor <= 0.14 {
            score += 0.38
        } else if blackFloor > 0.14 {
            // 抬得过高更像是低对比 709 / 雾天，而非对数信号
            score += 0.06
        }

        // 正向：低彩度
        if meanChroma < 0.16 {
            score += 0.22
        } else if meanChroma < 0.22 {
            score += 0.10
        }

        // 正向：几乎没有纯黑像素（对数抬高黑位）
        if deepShadowRatio < 0.02 {
            score += 0.12
        }

        // 正向：10bit
        if depth >= 10 { score += 0.08 }

        // 反向：高光裁切多 → 正常 709
        if clippedRatio > 0.06 {
            score -= 0.45
        } else if clippedRatio > 0.02 {
            score -= 0.30
        }

        // 反向：对比跨度大 → 正常 709
        if contrastSpan > 0.92 {
            score -= 0.25
        } else if contrastSpan > 0.80 {
            score -= 0.12
        }

        // 反向：HDR 直接排除
        if isHDR { score -= 0.60 }

        let confidence = min(max(score, 0), 1)
        return LogProfileDetection(
            isLikelyLog: confidence >= 0.62,
            confidence: confidence,
            blackFloor: blackFloor,
            meanChroma: meanChroma,
            highlightCeiling: highlightCeiling,
            hint: hint + String(format: " · 黑场%.2f 彩度%.2f 裁切%.0f%%",
                                blackFloor, meanChroma, clippedRatio * 100)
        )
    }

    /// 单帧统计量。
    struct ImageStats {
        var p05: Double
        var p95: Double
        var p99: Double
        var meanChroma: Double
        /// 亮度 < 0.02 的像素占比。
        var deepShadowRatio: Double
        /// 亮度 > 0.98 的像素占比。
        var clippedRatio: Double
    }

    /// 把一帧缩到 128×128 统计亮度分布与彩度。
    static func analyze(_ cgImage: CGImage) -> ImageStats? {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var lumas = [Double]()
        lumas.reserveCapacity(side * side)
        var chromaSum = 0.0
        var deepShadow = 0
        var clipped = 0

        var index = 0
        while index < pixels.count {
            let r = Double(pixels[index]) / 255.0
            let g = Double(pixels[index + 1]) / 255.0
            let b = Double(pixels[index + 2]) / 255.0
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumas.append(luma)
            chromaSum += (max(r, max(g, b)) - min(r, min(g, b)))
            if luma < 0.02 { deepShadow += 1 }
            if luma > 0.98 { clipped += 1 }
            index += 4
        }
        guard !lumas.isEmpty else { return nil }
        lumas.sort()

        func percentile(_ p: Double) -> Double {
            let clamped = min(max(p, 0), 1)
            return lumas[min(lumas.count - 1, Int(Double(lumas.count - 1) * clamped))]
        }

        let count = Double(lumas.count)
        return ImageStats(
            p05: percentile(0.05),
            p95: percentile(0.95),
            p99: percentile(0.99),
            meanChroma: chromaSum / count,
            deepShadowRatio: Double(deepShadow) / count,
            clippedRatio: Double(clipped) / count
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
