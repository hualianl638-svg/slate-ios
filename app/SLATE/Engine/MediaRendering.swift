//
//  MediaRendering.swift
//  ColorStudio
//
//  L2 · 业务逻辑层与 L3 · 渲染引擎层之间的**唯一接口契约**
//
//  这张契约的作用：让「照片管线」「视频管线」「界面层」可以分别开发而互不阻塞。
//  · 照片管线（PhotoKit/Core Image）实现 `MediaRendering`（still image 部分）
//  · 视频管线（AVFoundation/Metal）实现 `MediaRendering`（frame/motion 部分）
//  · 界面层只依赖本协议，不 import 任何具体实现
//
//  刻意不把 CIImage / CVPixelBuffer 放进协议签名：
//  渲染器内部用什么类型是它的自由，跨模块只传 `ImageFrame` 这种轻量描述。
//

import CoreGraphics
import CoreMedia
import Foundation

// MARK: - 帧描述

/// 渲染结果的轻量描述。
///
/// 只回答"渲染出了多大、什么时候的一帧"，不承载像素数据，
/// 像素数据留在渲染器内部（CIImage 或 CVPixelBuffer）。
public struct ImageFrame: Equatable, Sendable {

    /// 像素宽高。
    public let pixelSize: CGSize
    /// 帧在时间轴上的位置（视频帧才有）。
    public let time: CMTime?
    /// 该帧对应的色彩信息（视频才有）。
    public let colorInfo: VideoColorInfo?
    /// 渲染后的峰值亮度指示（0...1，用于 HDR/SDR 提示，可选）。
    public let normalizedPeak: Float?

    public init(
        pixelSize: CGSize,
        time: CMTime? = nil,
        colorInfo: VideoColorInfo? = nil,
        normalizedPeak: Float? = nil
    ) {
        self.pixelSize = pixelSize
        self.time = time
        self.colorInfo = colorInfo
        self.normalizedPeak = normalizedPeak
    }
}

// MARK: - 渲染质量

/// 渲染质量档位。决定降采样策略与是否启用高成本滤镜（如降噪、大半径锐化）。
public enum RenderQuality: String, Codable, CaseIterable, Sendable {

    /// 网格缩略图（长边 ~256）。
    case thumbnail
    /// 编辑预览（跟随屏幕尺寸，60fps 目标）。
    case preview
    /// 全质量导出。
    case full
    /// 视频逐帧渲染（介于 preview 与 full 之间，受码率限制）。
    case videoFrame

    /// 预览长边上限；`nil` 表示不限制。
    public var longEdgeLimit: Int? {
        switch self {
        case .thumbnail: return 256
        case .preview: return 2048
        case .full, .videoFrame: return nil
        }
    }

    /// 是否启用高成本滤镜（降噪/清晰度）。
    public var allowsExpensiveFilters: Bool {
        self == .full
    }

    /// 预览侧是否允许跳过高成本项以获得实时帧率。
    public var isInteractive: Bool {
        self == .preview || self == .thumbnail
    }
}

// MARK: - 渲染上下文

/// 一次渲染的上下文参数。
public struct RenderContext: Equatable, Sendable {

    /// 渲染质量。
    public var quality: RenderQuality
    /// 目标输出尺寸；`nil` 表示按素材原始尺寸。
    public var targetSize: CGSize?
    /// 是否把渲染结果裁剪到 targetSize 的宽高比（预览用）。
    public var aspectFill: Bool
    /// 工作色彩空间。
    public var workingColorSpace: CameraColorSpace
    /// 是否输出 16bit/浮点精度（导出用；预览恒为 8bit 以省带宽）。
    public var prefersHighPrecision: Bool
    /// 定向模糊等"编辑中临时降质"开关（拖动滑杆时打开，松手后关闭）。
    public var isInteractionInProgress: Bool

    public init(
        quality: RenderQuality = .preview,
        targetSize: CGSize? = nil,
        aspectFill: Bool = false,
        workingColorSpace: CameraColorSpace = .rec709,
        prefersHighPrecision: Bool = false,
        isInteractionInProgress: Bool = false
    ) {
        self.quality = quality
        self.targetSize = targetSize
        self.aspectFill = aspectFill
        self.workingColorSpace = workingColorSpace
        self.prefersHighPrecision = prefersHighPrecision
        self.isInteractionInProgress = isInteractionInProgress
    }

    /// 缩略图预览上下文。
    public static let thumbnail = RenderContext(quality: .thumbnail, targetSize: CGSize(width: 256, height: 256), aspectFill: true)

    /// 全质量导出上下文。
    public static let fullExport = RenderContext(quality: .full, prefersHighPrecision: true)

    /// 视频逐帧上下文。
    public static func videoFrame(targetSize: CGSize?) -> RenderContext {
        RenderContext(quality: .videoFrame, targetSize: targetSize, prefersHighPrecision: true)
    }
}

// MARK: - 渲染与导出协议

/// 渲染器：把「素材 + 编辑状态」渲染成画面。
///
/// 照片管线与视频管线各有一个实现，界面层通过 `MediaRouter` 拿到具体实例。
public protocol MediaRendering: AnyObject, Sendable {

    /// 渲染单帧静态图（照片编辑、视频帧预览、实况照片封面都走这里）。
    ///
    /// - Parameters:
    ///   - source: 素材。
    ///   - state: 当前编辑状态。
    ///   - lut: 已解析的 LUT；`nil` 表示未套用或尚未加载完成。
    ///   - context: 渲染上下文（质量、尺寸）。
    func renderFrame(
        source: MediaSource,
        state: EditState,
        lut: LUT3D?,
        context: RenderContext
    ) async throws -> ImageFrame

    /// 取任意时间点的一帧（视频的时间轴预览/帧级预览）。
    func frame(
        of source: MediaSource,
        at time: CMTime,
        state: EditState,
        lut: LUT3D?,
        context: RenderContext
    ) async throws -> ImageFrame

    /// 素材的原始像素尺寸（用于 UI 布局与导出尺寸计算）。
    func pixelSize(of source: MediaSource) async throws -> CGSize

    /// 生成 RGB + 亮度直方图（架构文档 L3「直方图分析器」）。
    ///
    /// 返回 4 个通道（R/G/B/亮度），每个通道 256 个桶，已归一化到 0...1。
    func histogram(
        source: MediaSource,
        state: EditState,
        lut: LUT3D?,
        at time: CMTime?
    ) async throws -> HistogramData

    /// 取消进行中的**交互期**渲染（用户快速拖动滑杆/切换素材时）。
    ///
    /// 语义边界（与两个渲染实现的约定一致）：
    /// · 只取消预览类工作（预览位图 / `renderFrame` / 直方图）；
    /// · **不得打断正在进行的全质量导出** —— 导出只跟随调用方 `Task` 的取消。
    ///   否则"边导出边拖滑杆"会丢掉导出，而拖滑杆时会高频调用本方法。
    func cancelPendingWork()
}

/// 预览位图能力。
///
/// 为什么单独拆一个协议，而不是把"返回位图"塞进 `MediaRendering`：
/// · `ImageFrame` 是"多大、第几帧"的**元数据**，刻意不承载像素，这样渲染器
///   内部用 CIImage 还是 CVPixelBuffer 对外都不可见；
/// · 但界面层终究需要一张能显示的位图。把这一步做成**可选能力**，
///   渲染器按需采纳，界面层用 `as? any PreviewImageRendering` 探测即可，
///   既不用给协议加"必须实现但可能用不到"的方法，也不会让 UI 依赖具体类型。
///
/// 采纳者：`PhotoRenderer`（照片/RAW）与 `VideoRenderer`（视频帧）。
/// 二者都已各自提供等价的内部方法，采纳本协议只是把返回类型统一成 `CGImage`。
///
/// 约定：
/// · 返回 `CGImage` 而不是 `UIImage`，因为 `CGImage` 本身线程安全，
///   而 `UIImage` 的跨 actor 传递在 Swift 6 下需要额外标注；
///   UI 侧用 `UIImage(cgImage:)` 或 `Image(decorative:scale:orientation:)` 包装即可。
/// · 渲染器必须复用同一个 `CIContext` / 命令队列，不要按帧新建。
public protocol PreviewImageRendering: AnyObject, Sendable {

    /// 渲染一张可直接显示的位图。
    ///
    /// - Parameters:
    ///   - source: 素材。
    ///   - state: 当前编辑状态。
    ///   - lut: 已解析的 LUT；`nil` 表示未套用或尚未加载。
    ///   - time: 视频取帧时间；静态图传 `nil`。
    ///   - context: 渲染上下文（质量/目标尺寸）。拖动中应传 `.preview`
    ///     并置 `isInteractionInProgress = true`，松手后再用全质量重渲一次。
    func makeDisplayImage(
        source: MediaSource,
        state: EditState,
        lut: LUT3D?,
        at time: CMTime?,
        context: RenderContext
    ) async throws -> CGImage

    /// 取消在途的预览渲染（快速拖动滑杆、切换素材时调用）。
    ///
    /// 与 `MediaRendering.cancelPendingWork()` 的区别：这个只影响预览位图，
    /// 同样**不应打断正在进行的导出**。两者都只作用于交互期工作。
    func cancelImageWork()
}

/// 默认实现：渲染器未采纳本协议的具体实现时，给出可读错误而不是崩溃。
public extension PreviewImageRendering {
    func cancelImageWork() {}
}

/// 直方图数据。
public struct HistogramData: Equatable, Sendable {

    /// 每个通道的桶数量。
    public static let bucketCount = 256

    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]
    public var luminance: [Float]
    /// 参与统计的像素数。
    public var sampleCount: Int

    public init(red: [Float], green: [Float], blue: [Float], luminance: [Float], sampleCount: Int) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        self.sampleCount = sampleCount
    }

    /// 空直方图。
    public static let empty = HistogramData(
        red: Array(repeating: 0, count: bucketCount),
        green: Array(repeating: 0, count: bucketCount),
        blue: Array(repeating: 0, count: bucketCount),
        luminance: Array(repeating: 0, count: bucketCount),
        sampleCount: 0
    )

    public var isEmpty: Bool { sampleCount == 0 }
}

/// 导出结果。
public struct MediaExportResult: Equatable, Sendable {

    /// 产物类型。
    public enum Kind: Equatable, Sendable {
        case jpeg
        case video
        case livePhoto
    }

    public var kind: Kind
    /// 写入的文件位置（临时目录或 Documents）。
    public var fileURL: URL
    /// 是否已保存到系统相册。
    public var savedToPhotoLibrary: Bool
    /// 相册资源标识（已保存时）。
    public var photoLibraryIdentifier: String?
    /// 是否为实况照片配对（实况照片导出时，视频部分的位置）。
    public var pairedVideoURL: URL?

    public init(
        kind: Kind,
        fileURL: URL,
        savedToPhotoLibrary: Bool = false,
        photoLibraryIdentifier: String? = nil,
        pairedVideoURL: URL? = nil
    ) {
        self.kind = kind
        self.fileURL = fileURL
        self.savedToPhotoLibrary = savedToPhotoLibrary
        self.photoLibraryIdentifier = photoLibraryIdentifier
        self.pairedVideoURL = pairedVideoURL
    }
}

/// 导出器：把渲染结果编码成文件并（可选）写入相册。
public protocol MediaExporting: AnyObject, Sendable {

    /// 导出 JPG（第一部分）。
    func exportImage(
        source: MediaSource,
        state: EditState,
        lut: LUT3D?,
        options: RenderOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MediaExportResult

    /// 导出视频（第二部分）。
    func exportVideo(
        source: MediaSource,
        state: EditState,
        lut: LUT3D?,
        options: RenderOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MediaExportResult

    /// 导出实况照片：渲染后的 JPG + 调色后的 MOV 配对写入相册。
    func exportLivePhoto(
        imageSource: MediaSource,
        videoSource: MediaSource,
        state: EditState,
        lut: LUT3D?,
        options: RenderOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MediaExportResult
}

/// 素材解析：识别类型、读取色彩信息、解析成可渲染的素材。
public protocol MediaResolving: AnyObject, Sendable {

    /// 从文件 URL 解析素材（Files App 导入）。
    func resolveFile(at url: URL) async throws -> MediaSource

    /// 从相册资源标识解析素材。
    func resolvePhotoLibraryAsset(localIdentifier: String) async throws -> MediaSource

    /// 猜测素材类型（仅按扩展名，不做 IO，UI 快速分流用）。
    func kind(forFileExtension fileExtension: String) -> MediaKind

    /// 读取视频色彩信息（S-Log3 识别）。
    func colorInfo(of source: MediaSource) async throws -> VideoColorInfo
}

// MARK: - 错误

/// 管线错误。
public enum MediaPipelineError: LocalizedError, Equatable {

    case unsupportedFormat(String)
    case rawDecodeFailed(String)
    case lutNotFound(String)
    case lutDimensionMismatch(expected: Int, actual: Int)
    case renderFailed(String)
    case exportFailed(String)
    case cancelled
    case photoLibraryAccessDenied
    case photoLibrarySaveFailed(String)
    case livePhotoPairingFailed(String)
    case assetUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail):
            return "不支持的文件格式：\(detail)"
        case .rawDecodeFailed(let detail):
            return "RAW 解码失败：\(detail)"
        case .lutNotFound(let path):
            return "找不到 LUT 文件：\(path)"
        case .lutDimensionMismatch(let expected, let actual):
            return "LUT 尺寸不匹配：期望 \(expected)，实际 \(actual)"
        case .renderFailed(let detail):
            return "渲染失败：\(detail)"
        case .exportFailed(let detail):
            return "导出失败：\(detail)"
        case .cancelled:
            return "操作已取消。"
        case .photoLibraryAccessDenied:
            return "没有相册访问权限，请在系统设置中允许访问。"
        case .photoLibrarySaveFailed(let detail):
            return "保存到相册失败：\(detail)"
        case .livePhotoPairingFailed(let detail):
            return "实况照片配对失败：\(detail)"
        case .assetUnreadable(let detail):
            return "无法读取素材：\(detail)"
        }
    }
}

// MARK: - 辅助

extension CGSize {
    /// 按长边等比缩放（不放大）。
    public func scaledToLongEdge(_ longEdge: Int) -> CGSize {
        let longest = max(width, height)
        guard longest > 0, longest > CGFloat(longEdge) else { return self }
        let scale = CGFloat(longEdge) / longest
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    /// 像素总数。
    public var pixelCount: Double { Double(width) * Double(height) }
}
