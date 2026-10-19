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
    /// - Parameter progress: 0...1 进度回调（主线程）。
    /// - Returns: 输出的 .mov 临时文件。
    func exportVideo(sourceURL: URL,
                     state: EditState,
                     lut: LUT3D?,
                     settings: ExportSettings,
                     progress: @escaping (Double) -> Void) async throws -> URL {

        let asset = AVURLAsset(url: sourceURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let frameRate = nominalFPS > 0 ? Double(nominalFPS) : 30.0

        // 旋转后的实际显示尺寸，并取偶数
        let rotatedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displayWidth = abs(rotatedRect.width)
        let displayHeight = abs(rotatedRect.height)
        var outWidth = Int(displayWidth.rounded())
        var outHeight = Int(displayHeight.rounded())
        if outWidth % 2 != 0 { outWidth -= 1 }
        if outHeight % 2 != 0 { outHeight -= 1 }
        guard outWidth > 1, outHeight > 1 else {
            throw ExportError.writerFailed("素材尺寸异常（\(outWidth)×\(outHeight)）")
        }

        // 输出文件
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLATE-\(Self.stamp()).mov")
        try? FileManager.default.removeItem(at: outURL)

        // Reader
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw ExportError.readerFailed("无法添加读取输出")
        }
        reader.add(readerOutput)

        // Writer
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let codec: AVVideoCodecType = settings.kind == .videoH264 ? .h264 : .hevc
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
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
            throw ExportError.writerFailed("无法添加写入输入")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1.0, CMTimeGetSeconds(duration) * frameRate)
        var frameIndex = 0
        let outputSize = CGSize(width: outWidth, height: outHeight)

        // 逐帧处理
        while let sample = readerOutput.copyNextSampleBuffer() {
            // 背压：等 writer 就绪
            while !writerInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 3_000_000)
                if writer.status == .failed { break }
            }
            if writer.status == .failed {
                break
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                frameIndex += 1
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            // 朝向：先按 transform 旋转，再平移到原点
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            if !transform.isIdentity {
                image = image.transformed(by: transform)
                image = image.transformed(by: CGAffineTransform(
                    translationX: -image.extent.origin.x,
                    y: -image.extent.origin.y
                ))
            }

            guard let cg = renderer.render(image, state: state, lut: lut) else {
                frameIndex += 1
                continue
            }
            guard let outBuffer = makePixelBuffer(from: cg,
                                                  size: outputSize,
                                                  pool: adaptor.pixelBufferPool) else {
                throw ExportError.pixelBufferFailed
            }
            adaptor.append(outBuffer, withPresentationTime: pts)

            frameIndex += 1
            if frameIndex % 6 == 0 {
                let p = min(1.0, Double(frameIndex) / totalFrames)
                await MainActor.run { progress(p) }
            }
        }

        reader.cancelReading()
        writerInput.markAsFinished()

        await writer.finishWriting()
        await MainActor.run { progress(1.0) }

        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "未知原因")
        }
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

// MARK: - 工具

/// 轻量可变引用盒（在 Photos 的回调里回传值）。
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
