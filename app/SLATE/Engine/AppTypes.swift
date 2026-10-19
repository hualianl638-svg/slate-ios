//
//  AppTypes.swift
//  ColorStudio
//
//  L2 · 业务逻辑层 / L4 · 数据层共用的基础类型
//  架构文档 L2「MediaRouter：按输入类型分流」与 L4「素材访问」的公共词汇表。
//
//  本文件定义"素材是什么、从哪里来"，不含任何加载实现；
//  加载实现见 Services/MediaIO/MediaResolver.swift。
//

import Foundation

// MARK: - 素材类型

/// 素材类型。决定走哪条解码/渲染管线。
public enum MediaKind: String, Codable, CaseIterable, Sendable {
    /// 相机 RAW（Sony .arw，以及其它可被 CIRAWFilter 识别的 RAW）。
    case raw
    /// 普通位图（.jpg/.jpeg/.png/.heic/.tiff）。
    case image
    /// 视频（.mov/.mp4/.m4v）。S-Log3 灰片也走这里，靠 `VideoColorInfo` 区分。
    case video
    /// Apple 实况照片（成对的 HEIC/JPG + MOV）。
    case livePhoto

    public var displayName: String {
        switch self {
        case .raw: return "RAW"
        case .image: return "照片"
        case .video: return "视频"
        case .livePhoto: return "实况照片"
        }
    }

    /// 是否属于"第一部分：照片"（导出 JPG）。
    public var isStillImage: Bool {
        self == .raw || self == .image
    }

    /// 是否属于"第二部分：视频"（导出视频 / Live Photo）。
    public var isMotion: Bool {
        self == .video || self == .livePhoto
    }
}

/// 素材来源位置。
public enum MediaLocation: Equatable, Hashable, Sendable {
    /// 系统相册，通过 PhotoKit 访问。
    case photoLibrary(localIdentifier: String?)
    /// 文件系统（Files App 导入、App 沙盒内文件）。
    case file(URL)
    /// 仅承载"名称/标识"，**不携带任何像素数据**。
    ///
    /// 用途限制：UI 占位、单元测试、以及"已知道名字但还没落盘"的中间态。
    /// 渲染器无法从它解码出画面，会抛 `MediaPipelineError.assetUnreadable`。
    /// 分享进入 / 粘贴板 / 内存图片等真实数据必须先落盘成临时文件，
    /// 再以 `.file(url)` 传入（落盘由 `MediaRouter` 负责）。
    case inMemory(name: String?)

    public var fileURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    public var photoLibraryIdentifier: String? {
        if case .photoLibrary(let identifier) = self { return identifier }
        return nil
    }

    /// 用于 UI 去重与缓存键的稳定标识。
    public var cacheKey: String {
        switch self {
        case .photoLibrary(let identifier):
            return "ph:\(identifier ?? "unknown")"
        case .file(let url):
            return "file:\(url.path)"
        case .inMemory(let name):
            return "mem:\(name ?? UUID().uuidString)"
        }
    }
}

/// 统一的素材描述。UI、渲染管线、导出都只认这个结构。
public struct MediaSource: Identifiable, Equatable, Hashable, Sendable {

    public let id: UUID
    /// 展示名（通常是文件名）。
    public var displayName: String
    /// 素材类型。
    public var kind: MediaKind
    /// 来源位置。
    public var location: MediaLocation
    /// 文件扩展名（小写，不含点）。内存素材可能为空。
    public var fileExtension: String
    /// 像素尺寸（若已知）。
    public var pixelSize: CGSize?
    /// 时长（视频/实况照片，若已知）。
    public var duration: Double?
    /// 实况照片配对的视频位置。
    public var pairedVideoLocation: MediaLocation?

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: MediaKind,
        location: MediaLocation,
        fileExtension: String = "",
        pixelSize: CGSize? = nil,
        duration: Double? = nil,
        pairedVideoLocation: MediaLocation? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.location = location
        self.fileExtension = fileExtension.lowercased()
        self.pixelSize = pixelSize
        self.duration = duration
        self.pairedVideoLocation = pairedVideoLocation
    }

    /// 是否是 Sony RAW。
    public var isSonyRaw: Bool {
        kind == .raw && ["arw", "srf", "sr2"].contains(fileExtension)
    }
}

// MARK: - 视频色彩信息（S-Log3 识别）

/// 视频的色彩信息。决定是否需要 S-Log3 归一化。
///
/// 识别来源优先级：① 用户在 UI 手动指定；② 视频元数据（AVAssetTrack 的
/// transfer function / color primaries 等格式描述扩展）；③ 文件名与目录启发式。
///
/// 实现见 `Sources/Pipelines/VideoColorInfoDetector.swift`：
/// `detect(for:userSpecified:includeCoverageStatistics:loadedAsset:)` 返回完整识别结果
/// （含证据、可靠性、覆盖率与"是否需要询问用户"），
/// `colorInfo(of:userSpecified:)` 是只读元数据的轻量版本。
public struct VideoColorInfo: Equatable, Codable, Hashable, Sendable {

    /// 记录曲线。
    public enum TransferCurve: String, Codable, CaseIterable, Sendable {
        /// S-Log3（Sony 灰片）。
        case sLog3
        /// S-Log2（少数机型）。
        case sLog2
        /// 标准 Rec.709 曲线。
        case rec709
        /// HLG（HDR）。
        case hlg
        /// PQ（HDR10）。
        case pq
        /// 未知，按 Rec.709 处理但 UI 需提示用户确认。
        case unknown

        public var displayName: String {
            switch self {
            case .sLog3: return "S-Log3"
            case .sLog2: return "S-Log2"
            case .rec709: return "Rec.709"
            case .hlg: return "HLG"
            case .pq: return "PQ (HDR10)"
            case .unknown: return "未知"
            }
        }

        /// 是否需要先归一化到线性再调色。
        public var requiresLinearization: Bool {
            self == .sLog3 || self == .sLog2
        }

        /// 当前渲染管线是否**完整支持**该曲线。
        ///
        /// 只有 S-Log3 有完整实现（官方 IDT 精确归一化）。其余取值：
        /// · `.sLog2`：枚举位保留，但管线按 Rec.709 EOTF 兜底，暗部会有偏差；
        /// · `.hlg` / `.pq`：HDR 曲线，管线**没有**对应 EOTF，画面会偏亮偏灰；
        /// · `.rec709` / `.unknown`：按 Rec.709 处理，正确。
        ///
        /// 界面层据此决定是否向用户发出警示（该曲线的素材需要手动确认或暂不支持），
        /// 而不是让用户选了一个管线处理不了的选项却看不出异常。
        public var isFullySupported: Bool {
            switch self {
            case .sLog3, .rec709, .unknown: return true
            case .sLog2, .hlg, .pq: return false
            }
        }

        /// 不支持时的可读说明，供 UI 直接展示。
        public var unsupportedReason: String? {
            switch self {
            case .sLog3, .rec709, .unknown:
                return nil
            case .sLog2:
                return "当前版本按 Rec.709 曲线近似处理 S-Log2，暗部层次会有偏差；建议按 S-Log3 处理或使用官方 LUT。"
            case .hlg:
                return "当前版本未实现 HLG (HDR) 的传递函数，画面会偏亮偏灰；请改用 S-Log3 流程或等待后续版本。"
            case .pq:
                return "当前版本未实现 PQ (HDR10) 的传递函数，画面会偏亮偏灰；请改用 S-Log3 流程或等待后续版本。"
            }
        }
    }

    /// 记录曲线。
    public var curve: TransferCurve
    /// 相机色域。
    public var colorSpace: CameraColorSpace
    /// 是否由用户手动指定（手动指定时不再做自动识别覆盖）。
    public var isUserSpecified: Bool

    public init(
        curve: TransferCurve = .unknown,
        colorSpace: CameraColorSpace = .rec709,
        isUserSpecified: Bool = false
    ) {
        self.curve = curve
        self.colorSpace = colorSpace
        self.isUserSpecified = isUserSpecified
    }

    /// Sony S-Log3 + S-Gamut3.Cine（最常见的灰片组合）。
    public static let sonySLog3Cine = VideoColorInfo(curve: .sLog3, colorSpace: .sGamut3Cine)

    /// 普通 Rec.709 素材。
    public static let rec709 = VideoColorInfo(curve: .rec709, colorSpace: .rec709)

    /// 未知素材（UI 需要询问用户）。
    public static let unknown = VideoColorInfo()

    /// 是否需要归一化 + 色域转换。
    public var requiresNormalization: Bool {
        curve.requiresLinearization || colorSpace.requiresGamutConversion
    }
}

// MARK: - 分辨率与导出规格

/// 导出分辨率。
public enum ExportResolution: String, Codable, CaseIterable, Sendable {
    case original
    case uhd4K
    case fullHD1080p
    case hd720p
    case custom

    public var displayName: String {
        switch self {
        case .original: return "原始分辨率"
        case .uhd4K: return "4K (3840×2160)"
        case .fullHD1080p: return "1080p (1920×1080)"
        case .hd720p: return "720p (1280×720)"
        case .custom: return "自定义"
        }
    }

    /// 目标长边像素；`nil` 表示保持原始。
    public var targetLongEdge: Int? {
        switch self {
        case .original, .custom: return nil
        case .uhd4K: return 3840
        case .fullHD1080p: return 1920
        case .hd720p: return 1280
        }
    }
}

/// 视频编码格式。
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    /// H.264，兼容性最好。
    case h264
    /// HEVC 8bit。
    case hevc
    /// HEVC 10bit，保留 S-Log3 调色后的过渡细节（架构文档技术要点 ④）。
    case hevc10Bit

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .hevc10Bit: return "HEVC 10bit"
        }
    }

    public var isTenBit: Bool { self == .hevc10Bit }
}

/// 视频调色后的输出色彩空间。
public enum OutputColorSpace: String, Codable, CaseIterable, Sendable {
    /// Rec.709 + sRGB 传递（SDR，最通用）。
    case rec709
    /// 保持 S-Log3 输出（给后续专业流程留余地）。
    case sLog3
    /// HLG（HDR 播放）。
    case hlg

    public var displayName: String {
        switch self {
        case .rec709: return "Rec.709 (SDR)"
        case .sLog3: return "S-Log3（保留灰片）"
        case .hlg: return "HLG (HDR)"
        }
    }
}
