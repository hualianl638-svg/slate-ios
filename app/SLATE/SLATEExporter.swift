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
import ImageIO
import CoreMedia
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
                     stillImageTime: Double? = nil,
                     assetIdentifier: String? = nil,
                     includeAudio: Bool = true,
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

        // 画布必须按**裁剪后**的尺寸算。
        // 之前用源尺寸当画布，而逐帧渲染出来的是裁剪后的图，
        // render(into:) 会把裁剪结果用 sx≠sy 非等比拉伸回满画布 —— 成片画面变形。
        let exportCrop = state.cropMask
        if !exportCrop.bypassCrop, exportCrop.isCropActive {
            outWidth = max(2, Int(Double(outWidth) * exportCrop.cropWidth))
            outHeight = max(2, Int(Double(outHeight) * exportCrop.cropHeight))
        }
        if outWidth % 2 != 0 { outWidth -= 1 }
        if outHeight % 2 != 0 { outHeight -= 1 }

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
        //
        // 实况图刻意**不带音轨**：截取 3 秒时音频需要重定基，
        // 而重定基后的音频时间轴可能被 Photos 判定为非法（3302）。
        // 普通视频导出照常带声音，已实测可用。
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if includeAudio, let audioTrack = audioTracks.first {
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

        // 实况图必需之一：**内容标识符**。
        // Photos 靠 `com.apple.quicktime.content.identifier` 与静帧 JPEG 的
        // MakerApple[17] 是否一致来判定配对；缺失或不一致即 3302（资源无效）。
        if let assetIdentifier {
            writer.metadata = [Self.contentIdentifierMetadata(assetIdentifier)]
        }

        // 实况图必需：still-image-time 元数据轨
        //
        // 系统靠这条 timed metadata 判断"哪一帧是静帧"。缺失时
        // PHAssetCreationRequest.addResource(.pairedVideo) 会以
        // PHPhotosErrorDomain 3302（资源无效）拒收——即使 MOV 本身完全可播。
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        var metadataFormat: CMMetadataFormatDescription?
        if let stillImageTime {
            if let format = Self.makeStillImageTimeFormatDescription() {
                metadataFormat = format
                let input = AVAssetWriterInput(
                    mediaType: .metadata,
                    outputSettings: nil,
                    sourceFormatHint: format
                )
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    metadataInput = input
                    metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
                }
            }
        }

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
        // PTS 重定基：导出的文件必须从 0 开始。
        //
        // 之前写成 startSession(atSourceTime: timeRange.start)，结果实况图的 3 秒片段
        // 第一帧时间戳是 1.5s，MOV 前面留了 1.5s 空白、总时长变 4.5s，
        // Photos 校验配对视频时判定资源无效 -> PHPhotosErrorDomain 3302。
        // 正确做法：会话从 0 开始，每帧 PTS 减去源片段起点。
        let ptsOrigin = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: .zero)

        // 静帧时间点写入 still-image-time 元数据。
        //
        // 关键：必须用 `AVAssetWriterInputMetadataAdaptor` + `AVTimedMetadataGroup`，
        // 之前手工拼 CMSampleBuffer 的做法生成的轨不被 Photos 认，实况图仍报 3302。
        if let stillImageTime, let metadataInput, let metadataAdaptor, metadataFormat != nil {
            let stillPTS = CMTime(seconds: max(stillImageTime, 0), preferredTimescale: 600)
            let item = AVMutableMetadataItem()
            item.key = "com.apple.quicktime.still-image-time" as NSString
            item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            item.dataType = "com.apple.metadata.datatype.int8"
            item.value = 0 as NSNumber

            let group = AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: stillPTS, duration: CMTime(value: 1, timescale: 600))
            )
            var waited = 0
            while !metadataInput.isReadyForMoreMediaData && waited < 500 {
                Thread.sleep(forTimeInterval: 0.002)
                waited += 1
            }
            metadataAdaptor.append(group)
            metadataInput.markAsFinished()
        }

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
                        // 读取失败（源损坏、iCloud 未下载、timeRange 越界）不能当成"正常读完"
                        if reader.status == .failed {
                            finishWithError(ExportError.readerFailed(
                                reader.error?.localizedDescription ?? "读取中断"
                            ))
                            return
                        }
                        // 一帧都没写进去时也不能当成功
                        guard frameIndex > 0 else {
                            finishWithError(ExportError.writerFailed("没有读到任何视频帧"))
                            return
                        }
                        // 视频读完：排空音频后收尾
                        writerInput.markAsFinished()
                        if let audioOut = audioReaderOutput, let audioIn = audioWriterInput {
                            while let audioSample = pendingAudio ?? audioOut.copyNextSampleBuffer() {
                                pendingAudio = nil
                                guard audioIn.isReadyForMoreMediaData else { break }
                                if let retimed = Self.retimed(audioSample, subtracting: ptsOrigin) {
                                    audioIn.append(retimed)
                                }
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
                            if let retimed = Self.retimed(audioSample, subtracting: ptsOrigin) {
                                audioIn.append(retimed)
                            }
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

                    let outputPTS = CMTimeSubtract(pts, ptsOrigin)
                    if CMTimeCompare(outputPTS, .zero) < 0 {
                        continue
                    }
                    if !adaptor.append(outBuffer, withPresentationTime: outputPTS) {
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

    /// 把导出的视频写入相册。
    @discardableResult
    func saveVideoToLibrary(fileURL: URL) async throws -> String {
        try await ensureAddOnlyAccess()
        let box = Box<String?>(nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: fileURL, options: options)
                box.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportError.saveFailed(error?.localizedDescription ?? "未知错误"))
                }
            }
        }
        return box.value ?? ""
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
                         stillPosition: Double = 0.5,
                         progress: @escaping (Double) -> Void) async throws -> URL {

        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let duration = try await asset.load(.duration)
        // 片段范围来自视频的「选段裁剪」：实况图不再单独设起点，
        // 直接取选段内居中、时长 2~5 秒的一段。
        let total = CMTimeGetSeconds(duration)
        let rangeStartFraction = min(max(state.trimStart, 0), 0.98)
        let rangeEndFraction = min(max(state.trimEnd, rangeStartFraction + 0.02), 1)
        let rangeStart = total * rangeStartFraction
        let rangeLength = max(0.1, total * (rangeEndFraction - rangeStartFraction))

        // 选段太短时明确拒绝，而不是产出一个系统会拒收的过短配对视频
        guard rangeLength >= 2.0 else {
            throw ExportError.saveFailed(
                String(format: "选段太短：实况图至少需要 2 秒（当前选段 %.1f 秒）", rangeLength)
            )
        }
        let wanted = min(max(targetDuration, 2.0), 5.0)
        let windowDuration = min(wanted, rangeLength)
        let windowStart = rangeStart + max(0, (rangeLength - windowDuration) / 2)
        let window = CMTimeRange(
            start: CMTime(seconds: windowStart, preferredTimescale: 600),
            duration: CMTime(seconds: windowDuration, preferredTimescale: 600)
        )
        // 静帧位置：0 = 窗口开头，1 = 窗口结尾（默认 0.5 即中点）
        let clampedPosition = min(max(stillPosition, 0), 1)
        let stillOffset = CMTimeMultiplyByFloat64(window.duration, multiplier: clampedPosition)
        let midpoint = CMTimeAdd(window.start, stillOffset)

        // ---- 1. 静帧：取窗口中点那一帧，按当前调色渲染 ----
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 4096, height: 4096)

        // 配对标识符：视频与静帧都要带上同一个值
        let assetIdentifier = UUID().uuidString

        let stillCGImage: CGImage
        do {
            let (image, _) = try await generator.image(at: midpoint)
            stillCGImage = image
        } catch {
            throw ExportError.renderFailed
        }
        guard let renderedStill = renderer.render(CIImage(cgImage: stillCGImage), state: state, lut: lut),
              let stillData = Self.jpegDataWithAssetIdentifier(
                  UIImage(cgImage: renderedStill),
                  identifier: assetIdentifier,
                  quality: settings.jpegQuality
              ) else {
            throw ExportError.renderFailed
        }

        // ---- 2. 3 秒视频（复用视频导出，只截窗口）----
        // 实况图的视频部分要小一些：3 秒 4K 用 20Mbps 会偏大，这里按 12Mbps。
        // 实况图的配对视频强制 H.264：
        // Apple 的实况图配对视频长期以 H.264 为主，部分系统版本对 .pairedVideo
        // 只接受 H.264（HEVC 虽 iOS 11+ 支持，但配对场景仍有拒收报告）。
        var liveSettings = settings
        liveSettings.kind = .videoH264
        liveSettings.bitrate = min(settings.bitrate, 12_000_000)
        // 实况图视频：不带音轨、不带元数据轨。
        //
        // 这两项是实况图路径相对普通视频导出的差异项，也是最可能触发
        // Photos 3302（资源无效）的地方——普通视频导出已实测完全正常，
        // 所以先把变量减到最少：只做一个「从 0 开始的 3 秒无声 H.264 片段」。
        // 静帧在片段内的相对时间（重定基后从 0 起算），必须与写入的
        // still-image-time 元数据一致，否则系统找不到静帧对应位置。
        let stillTimeInClip = CMTimeGetSeconds(window.duration) * clampedPosition
        let videoURL = try await exportVideo(
            sourceURL: sourceURL,
            state: state,
            lut: lut,
            settings: liveSettings,
            timeRange: window,
            stillImageTime: stillTimeInClip,
            assetIdentifier: assetIdentifier,
            includeAudio: false,
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

    /// 内容标识符元数据（`com.apple.quicktime.content.identifier`）。
    private static func contentIdentifierMetadata(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.content.identifier" as NSString
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = identifier as NSString
        item.dataType = "com.apple.metadata.datatype.UTF-8"
        return item
    }

    /// 把配对标识符写进 JPEG 的 MakerApple 字典（key "17"）。
    static func jpegDataWithAssetIdentifier(_ image: UIImage,
                                            identifier: String,
                                            quality: Double) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImagePropertyMakerAppleDictionary as String: ["17": identifier],
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 构造 still-image-time 的元数据格式描述。
    private static func makeStillImageTimeFormatDescription() -> CMMetadataFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8",
        ]
        var format: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    /// 把时间戳整体平移，使输出片段从 0 开始。
    private static func retimed(_ sample: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sample }
        var timing = CMSampleTimingInfo()
        let status = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        guard status == noErr else { return nil }
        timing.presentationTimeStamp = CMTimeSubtract(timing.presentationTimeStamp, offset)
        if CMTimeCompare(timing.presentationTimeStamp, .zero) < 0 { return nil }
        timing.decodeTimeStamp = .invalid
        var newBuffer: CMSampleBuffer?
        let created = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )
        guard created == noErr else { return nil }
        return newBuffer
    }

    /// 校验视频可播放、有视频轨、时长合理。
    private static func validateVideo(url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            return false
        }
        guard let duration = try? await asset.load(.duration) else { return false }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0.3, seconds < 30 else { return false }
        return (try? await asset.load(.isPlayable)) ?? false
    }

    /// 把「静帧 + 视频」作为一对实况照片写入相册。
    ///
    /// - Returns: 新建资源的 localIdentifier。
    @discardableResult
    func saveLivePhotoPair(stillData: Data,
                           videoURL: URL,
                           baseName: String) async throws -> String {
        try await ensureFullLibraryAccess()

        // 保存前先校验：宁可给出精确原因，也不要把不合格的资源丢给 Photos
        // （Photos 只会回一个笼统的 PHPhotosErrorDomain 3302）。
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw ExportError.saveFailed("配对的视频文件不存在：\(videoURL.lastPathComponent)")
        }
        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
        guard (videoSize ?? 0) > 1024 else {
            throw ExportError.saveFailed("配对视频过小（\(videoSize ?? 0) 字节），可能导出中断")
        }
        guard let videoTrackOK = try? await Self.validateVideo(url: videoURL), videoTrackOK else {
            throw ExportError.saveFailed("配对视频不可播放或没有视频轨道，无法作为实况图视频")
        }
        // 静帧必须是 JPEG（FF D8 开头）
        guard stillData.count > 1024, stillData.first == 0xFF, stillData.dropFirst().first == 0xD8 else {
            throw ExportError.saveFailed("静帧不是有效的 JPEG 数据")
        }

        // 静帧写成临时文件，用 fileURL 添加（比 data: 更贴近系统示例的用法）
        let stillURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName).jpg")
        try stillData.write(to: stillURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stillURL) }

        // 三种组合都试，任一成功即止：
        //   (静帧 fileURL, 先照片)  -> (静帧 data, 先照片)  -> (静帧 data, 先视频)
        // 系统对实况图配对较严，且不同版本对资源添加顺序敏感。
        struct PairVariant {
            let useFileURL: Bool
            let photoFirst: Bool
        }
        let variants = [
            PairVariant(useFileURL: true, photoFirst: false),
            PairVariant(useFileURL: false, photoFirst: false),
            PairVariant(useFileURL: true, photoFirst: true),
        ]

        var lastError: Error?
        for variant in variants {
            let useFileURL = variant.useFileURL
            let box = Box<String?>(nil)
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()

                        let photoOptions = PHAssetResourceCreationOptions()
                        photoOptions.originalFilename = "\(baseName).jpg"
                        photoOptions.shouldMoveFile = false

                        let videoOptions = PHAssetResourceCreationOptions()
                        videoOptions.originalFilename = "\(baseName).mov"
                        videoOptions.shouldMoveFile = false

                        let addPhoto = {
                            if variant.useFileURL {
                                request.addResource(with: .photo, fileURL: stillURL, options: photoOptions)
                            } else {
                                request.addResource(with: .photo, data: stillData, options: photoOptions)
                            }
                        }
                        let addVideo = {
                            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
                        }

                        if variant.photoFirst {
                            addPhoto()
                            addVideo()
                        } else {
                            addVideo()
                            addPhoto()
                        }

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
            } catch {
                // 把资源规格带进错误信息，便于定位（尺寸/时长是最常见的拒收原因）
                let seconds = (try? await AVURLAsset(url: videoURL).load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
                let videoKB = videoSize / 1024
                // 输出实际像素尺寸：静帧与视频尺寸必须严格一致，否则 Photos 拒收
                let stillPixels = UIImage(data: stillData).map {
                    "\(Int($0.size.width))×\(Int($0.size.height))"
                } ?? "未知"
                var videoPixels = "未知"
                if let vTrack = try? await AVURLAsset(url: videoURL).loadTracks(withMediaType: .video).first,
                   let size = try? await vTrack.load(.naturalSize) {
                    videoPixels = "\(Int(abs(size.width)))×\(Int(abs(size.height)))"
                }
                lastError = ExportError.saveFailed(
                    "\(error.localizedDescription)［诊断：静帧 \(stillData.count / 1024)KB/\(stillPixels)，"
                    + "视频 \(videoKB)KB/\(String(format: "%.2f", seconds))s/\(videoPixels)，"
                    + "形式=\(variant.useFileURL ? "fileURL" : "data")，"
                    + "顺序=\(variant.photoFirst ? "照→视" : "视→照")］"
                )
                continue
            }
        }
        throw lastError ?? ExportError.saveFailed("实况图配对失败（两种静帧形式均被系统拒绝）")
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

    /// 请求**读写**权限。
    ///
    /// 普通照片/视频用"仅添加"即可；实况图配对涉及系统对两个资源的校验，
    /// 部分系统版本要求读写权限，否则以 3302（资源无效）拒绝。
    /// 授权类型无法在运行时升级，因此这里直接用 `.readWrite` 请求。
    func ensureReadWriteAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
            if !granted { throw ExportError.photoLibraryDenied }
        default:
            throw ExportError.photoLibraryDenied
        }
    }

    /// 实况图必须要求**完全访问**（`.authorized`）。
    ///
    /// 只拿到 `.limited`（有限的照片访问）时，系统允许普通照片/视频入库，
    /// 但会以 PHPhotosErrorDomain 3302（资源无效）拒绝实况图配对——
    /// 因为配对需要读取并校验容器内的资源，受限访问做不到。
    /// 这里给用户明确的修复指引，而不是让他看到笼统的 3302。
    func ensureFullLibraryAccess() async throws {
        func status() -> PHAuthorizationStatus {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        var current = status()
        if current == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                    continuation.resume(returning: true)
                }
            }
            current = status()
        }
        switch current {
        case .authorized:
            return
        case .limited:
            throw ExportError.saveFailed(
                "相册权限是「有限的照片访问」。实况图需要完全访问才能配对写入——"
                + "请到 设置 > SLATE > 照片，改为「完全访问」后重试。"
            )
        case .notDetermined:
            throw ExportError.photoLibraryDenied
        default:
            throw ExportError.photoLibraryDenied
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
