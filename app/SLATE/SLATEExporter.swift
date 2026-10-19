//
//  SLATEExporter.swift
//  SLATE
//
//  导出管线：照片 JPG 与视频（HEVC / H.264）。
//
//  设计要点（这些决定"能不能真的导出成功"）：
//  · 逐帧渲染后用 AVAssetWriter 重编码，而不是 AVAssetExportSession——
//    后者无法把逐帧的自定义调色合进去；
//  · 输出尺寸从 `preferredTransform` 算出（竖屏视频是旋转过的），
//    并强制取偶数（H.264/HEVC 都要求）；
//  · 每帧把 CIImage 先按 transform 旋转再平移到原点，避免竖屏导出歪掉；
//  · 音轨本期不透传（见文件末尾"已知限制"）。
//

import AVFoundation
import CoreImage
import Foundation
import Photos
import UIKit

// MARK: - 设置与错误

/// 导出设置。
struct ExportSettings {
    enum Kind {
        case photoJPEG
        case videoHEVC
        case videoH264
    }

    var kind: Kind = .videoHEVC
    /// 视频码率（bps）。
    var bitrate: Int = 20_000_000
    /// 照片 JPEG 质量 0...1。
    var jpegQuality: Double = 0.95
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case pixelBufferFailed
    case renderFailed
    case photoLibraryDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这段素材没有视频轨道。"
        case .readerFailed(let d): return "读取素材失败：\(d)"
        case .writerFailed(let d): return "编码失败：\(d)"
        case .pixelBufferFailed: return "无法创建输出帧缓冲。"
        case .renderFailed: return "单帧渲染失败。"
        case .photoLibraryDenied: return "没有相册写入权限，请在系统设置里允许。"
        case .saveFailed(let d): return "保存到相册失败：\(d)"
        }
    }
}

// MARK: - 导出器

final class SLATEExporter {

    static let shared = SLATEExporter()

    private let renderer = SLATERenderer.shared
    private let ciContext = CIContext()

    // MARK: 照片

    /// 导出单帧为 JPG 并写入相册。
    ///
    /// - Returns: 临时文件 URL（也用于分享）。
    @discardableResult
    func exportPhoto(image: CIImage,
                     state: EditState,
                     lut: LUT3D?,
                     settings: ExportSettings) async throws -> URL {
        guard let cg = renderer.render(image, state: state, lut: lut) else {
            throw ExportError.renderFailed
        }
        let uiImage = UIImage(cgImage: cg)
        guard let data = uiImage.jpegData(compressionQuality: settings.jpegQuality) else {
            throw ExportError.saveFailed("JPEG 编码失败")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLATE-\(Self.stamp()).jpg")
        try data.write(to: url, options: .atomic)

        try await savePhotoToLibrary(data: data, fileName: url.lastPathComponent)
        return url
    }

    // MARK: 视频

    /// 逐帧渲染并导出视频。
    ///
    /// - Parameters:
    ///   - timeRange: 只导出这段时间（实况图需要截取 3 秒）；nil 表示整段。
    ///   - progress: 0...1 进度回调（主线程）。
    /// - Returns: 输出的 .mov 临时文件。
    func exportVideo(sourceURL: URL,
                     state: EditState,
                     lut: LUT3D?,
                     settings: ExportSettings,
                     timeRange: CMTimeRange? = nil,
                     progress: @escaping (Double) -> Void) async throws -> URL {

        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let frameRate = nominalFPS > 0 ? Double(nominalFPS) : 30.0

        // 旋转后的显示尺寸，取偶数（H.264/HEVC 的硬性要求）
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        var outWidth = Int(abs(rotated.width).rounded())
        var outHeight = Int(abs(rotated.height).rounded())
        if outWidth % 2 != 0 { outWidth -= 1 }
        if outHeight % 2 != 0 { outHeight -= 1 }
        guard outWidth > 1, outHeight > 1 else {
            throw ExportError.writerFailed("素材尺寸异常（\(outWidth)×\(outHeight)）")
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLATE-\(Self.stamp()).mov")
        try? FileManager.default.removeItem(at: outURL)

        // ---- Reader ----
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw ExportError.readerFailed("无法添加视频读取输出")
        }
        reader.add(readerOutput)
        if let timeRange { reader.timeRange = timeRange }

        // 音频透传（outputSettings: nil 表示不重新编码）
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioReaderOutput = out
            }
        }

        // ---- Writer ----
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let codec: AVVideoCodecType = settings.kind == .videoH264 ? .h264 : .hevc
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
        ]
        if settings.kind == .videoH264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outWidth,
                kCVPixelBufferHeightKey as String: outHeight,
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw ExportError.writerFailed("无法添加视频写入输入")
        }
        writer.add(writerInput)

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            } else {
                audioReaderOutput = nil
            }
        }

        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        // 会话起点取素材的真实起点：实况图只导中间 3 秒时，
        // PTS 不是从 0 开始，直接 startSession(.zero) 会在片头留一段空白。
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let effectiveDuration = timeRange.map { CMTimeGetSeconds($0.duration) }
            ?? CMTimeGetSeconds(duration)
        let totalFrames = max(1.0, effectiveDuration * frameRate)
        let outputSize = CGSize(width: outWidth, height: outHeight)

        let queue = DispatchQueue(label: "com.slate.export.video", qos: .userInitiated)
        let relay = ExportProgressRelay(callback: progress)

        // ---- 官方推荐的非实时写法：requestMediaDataWhenReady ----
        //
        // 早期版本用 `while !isReadyForMoreMediaData { try? await Task.sleep }` 忙等：
        // `try?` 会吞掉取消异常，一旦任务被取消 sleep 立刻返回，循环变成空转，
        // 表现为"进度卡住不动"。这里改由 AVFoundation 在就绪时回调，不再轮询。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frameIndex = 0
            var pendingAudio: CMSampleBuffer?
            var resumed = false

            func finishWithError(_ error: Error) {
                guard !resumed else { return }
                resumed = true
                writerInput.markAsFinished()
                audioWriterInput?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(throwing: error)
                }
            }

            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        // 视频读完：排空音频后收尾
                        writerInput.markAsFinished()
                        if let audioOut = audioReaderOutput, let audioIn = audioWriterInput {
                            while let audioSample = pendingAudio ?? audioOut.copyNextSampleBuffer() {
                                pendingAudio = nil
                                guard audioIn.isReadyForMoreMediaData else { break }
                                audioIn.append(audioSample)
                            }
                            audioIn.markAsFinished()
                        }
                        writer.finishWriting {
                            if resumed { return }
                            resumed = true
                            if writer.status == .completed {
                                relay.report(1.0)
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: ExportError.writerFailed(
                                    writer.error?.localizedDescription ?? "编码未完成"
                                ))
                            }
                        }
                        return
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)

                    // 音轨按时间戳交织写入
                    if let audioOut = audioReaderOutput, let audioIn = audioWriterInput {
                        while true {
                            if pendingAudio == nil {
                                pendingAudio = audioOut.copyNextSampleBuffer()
                            }
                            guard let audioSample = pendingAudio else { break }
                            let audioPTS = CMSampleBufferGetPresentationTimeStamp(audioSample)
                            guard CMTimeCompare(audioPTS, pts) <= 0 else { break }
                            guard audioIn.isReadyForMoreMediaData else { break }
                            audioIn.append(audioSample)
                            pendingAudio = nil
                        }
                    }

                    guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    guard let pool = adaptor.pixelBufferPool else {
                        finishWithError(ExportError.pixelBufferFailed)
                        return
                    }
                    var destination: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
                    guard let outBuffer = destination else {
                        finishWithError(ExportError.pixelBufferFailed)
                        return
                    }

                    var image = CIImage(cvPixelBuffer: sourceBuffer)
                    if !transform.isIdentity {
                        image = image.transformed(by: transform)
                        image = image.transformed(by: CGAffineTransform(
                            translationX: -image.extent.origin.x,
                            y: -image.extent.origin.y
                        ))
                    }

                    // 直接渲染进目标缓冲：避免 createCGImage 的整幅拷贝
                    SLATERenderer.shared.render(
                        image, state: state, lut: lut,
                        into: outBuffer, size: outputSize
                    )

                    if !adaptor.append(outBuffer, withPresentationTime: pts) {
                        finishWithError(ExportError.writerFailed(
                            writer.error?.localizedDescription ?? "写入帧失败"
                        ))
                        return
                    }

                    frameIndex += 1
                    if frameIndex % 3 == 0 {
                        relay.report(min(1.0, Double(frameIndex) / totalFrames))
                    }
                }
            }
        }

        reader.cancelReading()
        return outURL
    }

    // MARK: 实况图

    /// 导出 Apple 实况照片（Live Photo）。
    ///
    /// 实况照片在系统里不是"一个文件"，而是**成对的两个资源**：
    ///   · 一张静止图（JPEG/HEIC）
    ///   · 一段 ~3 秒的 MOV
    /// 两者必须在**同一个 `PHPhotoLibrary.performChanges` 事务**里添加，
    /// 且 `originalFilename` 去掉扩展名后必须完全同名，系统才认成一对
    /// （相机就是这么存的：IMG_0001.HEIC + IMG_0001.MOV）。
    /// 分成两次事务写，结果会是"一张照片 + 一段视频"，没有 LIVE 角标。
    ///
    /// - Parameters:
    ///   - targetDuration: 实况图时长，默认 3 秒（Apple 的惯例值）。
    ///   - progress: 视频部分 0...1 进度。
    /// - Returns: 静帧 JPG 的临时文件（用于分享/预览）。
    @discardableResult
    func exportLivePhoto(sourceURL: URL,
                         state: EditState,
                         lut: LUT3D?,
                         settings: ExportSettings,
                         targetDuration: Double = 3.0,
                         progress: @escaping (Double) -> Void) async throws -> URL {

        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let duration = try await asset.load(.duration)
        let window = Self.livePhotoWindow(assetDuration: duration, target: targetDuration)
        let midpoint = CMTimeAdd(
            window.start,
            CMTimeMultiplyByFloat64(window.duration, multiplier: 0.5)
        )

        // ---- 1. 静帧：取窗口中点那一帧，按当前调色渲染 ----
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 4096, height: 4096)

        let stillCGImage: CGImage
        do {
            let (image, _) = try await generator.image(at: midpoint)
            stillCGImage = image
        } catch {
            throw ExportError.renderFailed
        }
        guard let renderedStill = renderer.render(CIImage(cgImage: stillCGImage), state: state, lut: lut),
              let stillData = UIImage(cgImage: renderedStill)
                .jpegData(compressionQuality: settings.jpegQuality) else {
            throw ExportError.renderFailed
        }

        // ---- 2. 3 秒视频（复用视频导出，只截窗口）----
        // 实况图的视频部分要小一些：3 秒 4K 用 20Mbps 会偏大，这里按 12Mbps。
        var liveSettings = settings
        liveSettings.bitrate = min(settings.bitrate, 12_000_000)
        let videoURL = try await exportVideo(
            sourceURL: sourceURL,
            state: state,
            lut: lut,
            settings: liveSettings,
            timeRange: window,
            progress: progress
        )

        // ---- 3. 配对写入相册 ----
        let baseName = "SLATE-Live-\(Self.stamp())"
        _ = try await saveLivePhotoPair(stillData: stillData, videoURL: videoURL, baseName: baseName)

        // 保留静帧文件供分享
        let stillURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName).jpg")
        try? stillData.write(to: stillURL, options: .atomic)
        return stillURL
    }

    /// 计算实况图时间窗：居中截取，且不超出素材时长。
    static func livePhotoWindow(assetDuration: CMTime, target: Double = 3.0) -> CMTimeRange {
        let total = CMTimeGetSeconds(assetDuration)
        guard total.isFinite, total > 0 else {
            return CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        }
        let windowDuration = min(target, total)
        let start = max(0, (total - windowDuration) / 2.0)
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: windowDuration, preferredTimescale: 600)
        )
    }

    /// 把「静帧 + 视频」作为一对实况照片写入相册。
    ///
    /// - Returns: 新建资源的 localIdentifier。
    @discardableResult
    func saveLivePhotoPair(stillData: Data,
                           videoURL: URL,
                           baseName: String) async throws -> String {
        try await ensureAddOnlyAccess()

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ExportError.saveFailed("配对的视频文件不存在：\(videoURL.lastPathComponent)")
        }

        let box = Box<String?>(nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()

                // 静帧：.photo 资源，必须是 JPEG 或 HEIC
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.originalFilename = "\(baseName).JPG"
                request.addResource(with: .photo, data: stillData, options: photoOptions)

                // 视频：.pairedVideo 资源，文件名主干必须与静帧一致
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.originalFilename = "\(baseName).MOV"
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)

                box.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    let detail = error?.localizedDescription ?? "系统拒绝了实况照片配对写入"
                    continuation.resume(throwing: ExportError.saveFailed(detail))
                }
            }
        }
        return box.value ?? ""
    }

    // MARK: 内部

    /// CGImage → CVPixelBuffer（BGRA）。
    private func makePixelBuffer(from cgImage: CGImage,
                                 size: CGSize,
                                 pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA,
                                attributes as CFDictionary, &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pixelBuffer
    }

    private func savePhotoToLibrary(data: Data, fileName: String) async throws {
        try await ensureAddOnlyAccess()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileName
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }
    }

    /// 逐帧导出用不到，但保留给实况图：请求"仅添加"权限。
    func ensureAddOnlyAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
            if !granted { throw ExportError.photoLibraryDenied }
        default:
            throw ExportError.photoLibraryDenied
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}


/// 把导出进度从后台串行队列切回主线程回调。
final class ExportProgressRelay: @unchecked Sendable {
    private let callback: (Double) -> Void
    private var lastValue: Double = -1

    init(callback: @escaping (Double) -> Void) {
        self.callback = callback
    }

    func report(_ value: Double) {
        // 节流：进度变化小于 1% 不打扰主线程
        guard value - lastValue >= 0.01 || value >= 1.0 else { return }
        lastValue = value
        DispatchQueue.main.async { [callback] in
            callback(value)
        }
    }
}

// MARK: - 工具

/// 轻量可变引用盒（在 Photos 的回调里回传值）。
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
