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

        // 实况图必需：still-image-time 元数据轨
        //
        // 系统靠这条 timed metadata 判断"哪一帧是静帧"。缺失时
        // PHAssetCreationRequest.addResource(.pairedVideo) 会以
        // PHPhotosErrorDomain 3302（资源无效）拒收——即使 MOV 本身完全可播。
        var metadataInput: AVAssetWriterInput?
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

        // 静帧时间点写入元数据（重定基后的时间轴）
        if let stillImageTime, let metadataInput, let metadataFormat {
            let stillPTS = CMTime(seconds: max(stillImageTime, 0), preferredTimescale: 600)
            if let sample = Self.makeStillImageTimeSampleBuffer(
                formatDescription: metadataFormat, time: stillPTS
            ) {
                while !metadataInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                metadataInput.append(sample)
            }
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
        // 静帧在窗口内的相对位置（重定基后从 0 起算）
        let stillTimeInClip = CMTimeGetSeconds(window.duration) * 0.5
        let videoURL = try await exportVideo(
            sourceURL: sourceURL,
            state: state,
            lut: lut,
            settings: liveSettings,
            timeRange: window,
            stillImageTime: stillTimeInClip,
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

    /// 构造 still-image-time 的元数据格式描述。
    ///
    /// 对应 QuickTime 的 `com.apple.quicktime.still-image-time`，
    /// 数据类型是 8 位有符号整数（Apple 的实况图示例即此约定）。
    private static func makeStillImageTimeFormatDescription() -> CMMetadataFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String,
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

    /// 构造一条 still-image-time 元数据样本（1 字节，值为 0）。
    private static func makeStillImageTimeSampleBuffer(
        formatDescription: CMMetadataFormatDescription,
        time: CMTime
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: 1,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 1,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        var value: Int8 = 0
        let copyStatus = withUnsafeBytes(of: &value) { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: 1
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 1
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return createStatus == noErr ? sampleBuffer : nil
    }

    /// 把时间戳整体平移，使输出片段从 0 开始。
    ///
    /// 音频样本用 `CMSampleBufferCreateCopyWithNewTiming` 改时间轴；
    /// 失败就返回 nil（丢掉该样本），不让整段导出失败。
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

    /// 校验一个视频文件能被当作实况图的配对视频：可播放、有视频轨、时长合理。
    private static func validateVideo(url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            return false
        }
        guard let duration = try? await asset.load(.duration) else { return false }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0.3, seconds < 30 else { return false }
        let playable = (try? await asset.load(.isPlayable)) ?? false
        return playable
    }

    /// 把「静帧 + 视频」作为一对实况照片写入相册。
    ///
    /// - Returns: 新建资源的 localIdentifier。
    @discardableResult
    func saveLivePhotoPair(stillData: Data,
                           videoURL: URL,
                           baseName: String) async throws -> String {
        try await ensureAddOnlyAccess()

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
            .appendingPathComponent("\(baseName).JPG")
        try stillData.write(to: stillURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stillURL) }

        let box = Box<String?>(nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()

                // 静帧：.photo 资源，必须是 JPEG 或 HEIC
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.originalFilename = "\(baseName).JPG"
                photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: stillURL, options: photoOptions)

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
