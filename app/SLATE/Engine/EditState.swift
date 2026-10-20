//
//  EditState.swift
//  ColorStudio
//
//  L2 · 业务逻辑层：非破坏性编辑状态
//  架构文档 L2「EditState（非破坏性编辑参数）：所有调节仅存参数（Codable JSON），
//  原片永不修改；支持撤销/重做、参数复制、预设」
//
//  第一部分（照片）与第二部分（视频）共用同一个 EditState，
//  保证"照片管线"和"视频管线"的调节手感完全一致（架构文档 L3 的双管线共用一套调节内核）。
//

import Foundation

// MARK: - LUT 引用与套用

/// 对 LUT 仓库中某个 LUT 的轻量引用。
///
/// 只存相对路径而不是绝对 URL：App 沙盒路径在重装/迁移后会变化，
/// 存绝对路径会导致所有历史编辑失效。
public struct LUTReference: Equatable, Codable, Hashable, Sendable {
    /// 相对 `Documents/LUTs/` 的路径，例如 `Imported/Film-01.cube`。
    public var relativePath: String
    /// 展示名。
    public var displayName: String
    /// 立方体边长（17/33/64），用于校验文件是否被替换过。
    public var dimension: Int?
    /// 文件内容指纹，用于检测文件被替换/损坏。
    public var contentHash: String?

    public init(relativePath: String, displayName: String, dimension: Int? = nil, contentHash: String? = nil) {
        self.relativePath = relativePath
        self.displayName = displayName
        self.dimension = dimension
        self.contentHash = contentHash
    }
}

/// LUT 套用状态。
public struct LUTApplication: Equatable, Codable, Hashable, Sendable {
    /// 当前套用的 LUT；`nil` 表示未套用。
    public var reference: LUTReference?
    /// 强度 0...1，0 等于不套用，1 为完整套用（架构文档 L3「强度插值」）。
    public var intensity: Double

    public init(reference: LUTReference? = nil, intensity: Double = 1.0) {
        self.reference = reference
        self.intensity = intensity
    }

    public static let none = LUTApplication(reference: nil, intensity: 1.0)

    public var isActive: Bool {
        reference != nil && intensity > 0
    }

    public mutating func clamp() {
        intensity = intensity.isFinite ? min(max(intensity, 0), 1) : 0
        if intensity <= 0 { reference = nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reference = try? container.decodeIfPresent(LUTReference.self, forKey: .reference)
        intensity = (try? container.decodeIfPresent(Double.self, forKey: .intensity)).flatMap { $0 } ?? 1.0
        clamp()
    }
}

// MARK: - 编辑状态

/// 完整的非破坏性编辑状态。
///
/// 约定：
/// · 原片字节永不修改，所有编辑只体现为这个结构的值；
/// · `isNeutral == true` 时渲染层可以直接跳过整条滤镜链；
/// · 新增字段时必须在 `init(from:)` 里给回落默认值，保证旧工程文件仍能打开。
public struct EditState: Identifiable, Equatable, Codable, Sendable {

    /// 裁剪与蒙版。
    ///
    /// 放在 EditState 里而不是单独持有，是为了让照片预览、视频逐帧预览、
    /// 导出三条管线自动共用同一份设置（否则三处会不一致）。
    public var cropMask: CropMaskSettings = CropMaskSettings()

    /// 灰片曲线（对数）类型，对应 `LogProfile.rawValue`。
    public var logProfileIndex: Int = 0

    /// 还原 LUT 是否启用（功能条右侧开关）。
    public var restoreEnabled: Bool = false
    /// 自定义还原 LUT 的名称（Documents/RestoreLUTs/ 下的文件名，不含扩展名）。
    public var restoreLUTName: String = ""

    /// 当前序列化版本。新增字段时递增，供迁移使用。
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    /// 该编辑属于照片还是视频，用于 UI 决定显示哪组控件。
    public var mediaKind: MediaKind

    // MARK: 调色参数

    /// 基础调节：曝光/明度/对比度/阴影/高光/自然饱和度/饱和度/白平衡等。
    public var adjustments: Adjustments
    /// HSL 八通道。
    public var hsl: HSLBands
    /// 色调分离。
    public var splitToning: SplitToning
    /// 黑白混合。
    public var grayscale: GrayscaleMix
    /// LUT 套用。
    public var lut: LUTApplication

    // MARK: 视频专用

    /// 视频色彩信息（S-Log3 识别结果）。照片为 `nil`。
    public var videoColorInfo: VideoColorInfo?

    // MARK: 渲染选项（照片）

    /// 输出色彩空间与位深选项。
    public var renderOptions: RenderOptions

    // MARK: 元数据

    /// 创建时间。
    public var createdAt: Date
    /// 最后修改时间。
    public var updatedAt: Date
    /// 预设来源名称（若由预设创建），仅用于 UI 展示。
    public var presetName: String?

    public init(
        id: UUID = UUID(),
        mediaKind: MediaKind = .image,
        adjustments: Adjustments = .neutral,
        hsl: HSLBands = HSLBands(),
        splitToning: SplitToning = .neutral,
        grayscale: GrayscaleMix = .disabled,
        lut: LUTApplication = .none,
        videoColorInfo: VideoColorInfo? = nil,
        renderOptions: RenderOptions = RenderOptions(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        presetName: String? = nil
    ) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.mediaKind = mediaKind
        self.adjustments = adjustments
        self.hsl = hsl
        self.splitToning = splitToning
        self.grayscale = grayscale
        self.lut = lut
        self.videoColorInfo = videoColorInfo
        self.renderOptions = renderOptions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.presetName = presetName
    }

    // MARK: 工厂

    /// 新建：完全中性，不改变画面。
    public static func neutral(for kind: MediaKind) -> EditState {
        EditState(mediaKind: kind)
    }

    /// 视频默认：Sony S-Log3 + S-Gamut3.Cine，并把"去朦胧"预置一点用于灰片初步归一化。
    ///
    /// 之所以给一点默认值：S-Log3 灰片直接看非常平，用户需要立刻看到"翻正"的观感，
    /// 但默认值刻意保守（0.15），用户不满意可以一键复位。
    public static func sonySLog3Default() -> EditState {
        var adjustments = Adjustments.neutral
        adjustments.dehaze = 0.15
        return EditState(
            mediaKind: .video,
            adjustments: adjustments,
            videoColorInfo: .sonySLog3Cine
        )
    }

    // MARK: 查询

    /// 是否完全没有编辑（渲染层据此跳过整条滤镜链）。
    ///
    /// **只统计"影响画面"的参数**：`renderOptions` 是导出选项（JPEG 质量、编码格式、
    /// 是否存相册…），它们不改变渲染结果，因此不参与本判断。
    /// 否则用户只把 JPEG 质量从 0.95 调到 0.9，画面就会被当成"已编辑"：
    /// 滤镜链不再短路、图库角标误显示"已编辑"、`activeAdjustmentCount` 也无故加一。
    public var isNeutral: Bool {
        adjustments.isNeutral
            && hsl.isNeutral
            && splitToning.isNeutral
            && !grayscale.isEnabled
            && !lut.isActive
    }

    /// 已生效的编辑项数量，用于图库角标与"是否已编辑"判断。
    public var activeAdjustmentCount: Int {
        var count = 0
        let a = adjustments
        if a.exposure != 0 { count += 1 }
        if a.brightness != 0 { count += 1 }
        if a.contrast != 0 { count += 1 }
        if a.shadows != 0 { count += 1 }
        if a.highlights != 0 { count += 1 }
        if a.blacks != 0 { count += 1 }
        if a.whites != 0 { count += 1 }
        if a.vibrance != 0 { count += 1 }
        if a.saturation != 0 { count += 1 }
        if !a.whiteBalance.isNeutral { count += 1 }
        if a.clarity != 0 { count += 1 }
        if a.dehaze != 0 { count += 1 }
        if a.sharpness != 0 { count += 1 }
        if a.noiseReduction != 0 { count += 1 }
        if a.vignette != 0 { count += 1 }
        if a.grain != 0 { count += 1 }
        count += hsl.ordered.filter { !$0.isNeutral }.count
        if !splitToning.isNeutral { count += 1 }
        if grayscale.isEnabled { count += 1 }
        if lut.isActive { count += 1 }
        return count
    }

    // MARK: 变更

    /// 复位全部调色参数，保留素材相关设置（媒体类型、视频色彩信息）。
    public mutating func resetAdjustments() {
        adjustments = .neutral
        hsl = HSLBands()
        splitToning = .neutral
        grayscale = .disabled
        lut = .none
        presetName = nil
        touch()
    }

    /// 标记为已修改。
    public mutating func touch(at date: Date = Date()) {
        updatedAt = date
    }

    /// 复制成"同一素材的另一份编辑"，用于快照/撤销点。
    public func snapshot() -> EditState {
        var copy = self
        copy.id = UUID()
        copy.createdAt = Date()
        copy.updatedAt = copy.createdAt
        return copy
    }

    /// 把参数应用到另一个素材（"复制编辑设置"/"粘贴设置"）。
    ///
    /// 保留目标素材自己的 `mediaKind`、`videoColorInfo` 与 `renderOptions`，
    /// 只搬运调色参数——照片的 SDR 选项套到 HDR 视频上是没有意义的。
    public func appliedTo(_ target: EditState) -> EditState {
        var result = target
        result.adjustments = adjustments
        result.hsl = hsl
        result.splitToning = splitToning
        result.grayscale = grayscale
        result.lut = lut
        result.presetName = presetName
        result.touch()
        return result
    }

    /// 参数校验：所有越界值夹回合法区间。
    public mutating func clampAll() {
        adjustments.clamp()
        lut.clamp()
        splitToning.balance = min(max(splitToning.balance, -1), 1)
        renderOptions.clamp()
    }

    // MARK: 兼容性解码

    /// 手写解码：任何字段缺失都回落到默认值，保证旧工程文件可打开、新字段可前向兼容。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)).flatMap { $0 } ?? 1
        mediaKind = (try? container.decodeIfPresent(MediaKind.self, forKey: .mediaKind)).flatMap { $0 } ?? .image
        adjustments = (try? container.decodeIfPresent(Adjustments.self, forKey: .adjustments)).flatMap { $0 } ?? .neutral
        hsl = (try? container.decodeIfPresent(HSLBands.self, forKey: .hsl)).flatMap { $0 } ?? HSLBands()
        splitToning = (try? container.decodeIfPresent(SplitToning.self, forKey: .splitToning)).flatMap { $0 } ?? .neutral
        grayscale = (try? container.decodeIfPresent(GrayscaleMix.self, forKey: .grayscale)).flatMap { $0 } ?? .disabled
        lut = (try? container.decodeIfPresent(LUTApplication.self, forKey: .lut)).flatMap { $0 } ?? .none
        videoColorInfo = try? container.decodeIfPresent(VideoColorInfo.self, forKey: .videoColorInfo)
        renderOptions = (try? container.decodeIfPresent(RenderOptions.self, forKey: .renderOptions)).flatMap { $0 } ?? RenderOptions()
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)).flatMap { $0 } ?? Date()
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)).flatMap { $0 } ?? createdAt
        presetName = try? container.decodeIfPresent(String.self, forKey: .presetName)
        clampAll()
    }
}

// MARK: - 渲染选项

/// 输出相关选项（照片导出与视频导出的公共部分）。
public struct RenderOptions: Equatable, Codable, Hashable, Sendable {

    /// JPEG 导出质量 0...1（架构文档 L1「导出界面：JPG 质量」）。
    public var jpegQuality: Double

    /// 导出分辨率档位。
    ///
    /// 命名说明：字段名沿用架构文档的「视频分辨率/码率」，
    /// 但它描述的是**输出尺寸档位**，照片导出同样使用（`.original` = 原尺寸）。
    /// 真正需要"任意像素"时用 `stillImageTargetSize`。
    public var videoResolution: ExportResolution

    /// 照片/静帧导出的**自定义目标尺寸**（像素）。`nil` 表示按 `videoResolution` 与原尺寸推导。
    ///
    /// 存在的理由：`ExportResolution` 只有几个预设档位，而照片导出常需要"
    /// 长边 3000px 用于社交平台"这类任意值。视频侧不使用本字段。
    public var stillImageTargetSize: CGSize?

    /// 视频编码格式。
    public var videoCodec: VideoCodec

    /// 视频输出色彩空间。
    public var outputColorSpace: OutputColorSpace

    /// 视频码率（Mbps）；`nil` 表示由 AVAssetWriter 按分辨率自动选择。
    public var videoBitrateMbps: Double?

    /// 是否在导出时保留 EXIF/拍摄元数据。
    public var preserveMetadata: Bool

    /// 是否同时保存到系统相册（否则只写入 Files App 目录）。
    public var saveToPhotoLibrary: Bool

    public init(
        jpegQuality: Double = 0.95,
        videoResolution: ExportResolution = .original,
        stillImageTargetSize: CGSize? = nil,
        videoCodec: VideoCodec = .hevc,
        outputColorSpace: OutputColorSpace = .rec709,
        videoBitrateMbps: Double? = nil,
        preserveMetadata: Bool = true,
        saveToPhotoLibrary: Bool = true
    ) {
        self.jpegQuality = jpegQuality
        self.videoResolution = videoResolution
        self.stillImageTargetSize = stillImageTargetSize
        self.videoCodec = videoCodec
        self.outputColorSpace = outputColorSpace
        self.videoBitrateMbps = videoBitrateMbps
        self.preserveMetadata = preserveMetadata
        self.saveToPhotoLibrary = saveToPhotoLibrary
    }

    /// 静帧导出的目标长边；`nil` 表示保持原始尺寸。
    ///
    /// 照片导出器应当用这个属性而不是直接读 `videoResolution`，
    /// 这样以后改档位定义时只需要改一处。
    public var stillImageTargetLongEdge: Int? {
        if stillImageTargetSize != nil { return nil }
        return videoResolution.targetLongEdge
    }

    /// 是否偏离默认值（参与 `EditState.isNeutral` 判断）。
    public var hasNonDefaultOptions: Bool {
        jpegQuality != 0.95
            || videoResolution != .original
            || stillImageTargetSize != nil
            || videoCodec != .hevc
            || outputColorSpace != .rec709
            || videoBitrateMbps != nil
            || preserveMetadata != true
            || saveToPhotoLibrary != true
    }

    public mutating func clamp() {
        jpegQuality = jpegQuality.isFinite ? min(max(jpegQuality, 0.1), 1.0) : 0.95
        if let bitrate = videoBitrateMbps, !bitrate.isFinite || bitrate <= 0 {
            videoBitrateMbps = nil
        }
        if let size = stillImageTargetSize, size.width < 1 || size.height < 1 || !size.width.isFinite || !size.height.isFinite {
            stillImageTargetSize = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jpegQuality = (try? container.decodeIfPresent(Double.self, forKey: .jpegQuality)).flatMap { $0 } ?? 0.95
        videoResolution = (try? container.decodeIfPresent(ExportResolution.self, forKey: .videoResolution)).flatMap { $0 } ?? .original
        stillImageTargetSize = try? container.decodeIfPresent(CGSize.self, forKey: .stillImageTargetSize)
        videoCodec = (try? container.decodeIfPresent(VideoCodec.self, forKey: .videoCodec)).flatMap { $0 } ?? .hevc
        outputColorSpace = (try? container.decodeIfPresent(OutputColorSpace.self, forKey: .outputColorSpace)).flatMap { $0 } ?? .rec709
        videoBitrateMbps = try? container.decodeIfPresent(Double.self, forKey: .videoBitrateMbps)
        preserveMetadata = (try? container.decodeIfPresent(Bool.self, forKey: .preserveMetadata)).flatMap { $0 } ?? true
        saveToPhotoLibrary = (try? container.decodeIfPresent(Bool.self, forKey: .saveToPhotoLibrary)).flatMap { $0 } ?? true
        clamp()
    }
}

// MARK: - 预设

/// 编辑预设。内置预设与用户预设共用同一结构（架构文档 L2「预设」）。
public struct EditPreset: Identifiable, Equatable, Codable, Hashable, Sendable {

    /// 预设分组，UI 用于分节展示。
    public enum Category: String, Codable, CaseIterable, Sendable {
        case basic = "基础"
        case film = "胶片"
        case portrait = "人像"
        case landscape = "风光"
        case video = "视频 / S-Log3"
        case user = "我的预设"

        public var displayName: String { rawValue }
    }

    public var id: UUID
    public var name: String
    public var category: Category
    /// 是否为 App 内置预设（内置预设不可删除）。
    public var isBuiltIn: Bool
    /// 预设包含的调色参数。
    public var adjustments: Adjustments
    public var hsl: HSLBands
    public var splitToning: SplitToning
    public var grayscale: GrayscaleMix
    /// 预设可以引用一个 LUT（架构文档 L1「LUT 管理界面：收藏/分组」）。
    public var lut: LUTApplication
    /// 适用的媒体类型；`nil` 表示照片与视频都适用。
    public var applicableMediaKinds: [MediaKind]?
    /// 预览缩略图文件名（存在 Documents/PresetThumbnails/）。
    public var thumbnailFileName: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        category: Category = .user,
        isBuiltIn: Bool = false,
        adjustments: Adjustments = .neutral,
        hsl: HSLBands = HSLBands(),
        splitToning: SplitToning = .neutral,
        grayscale: GrayscaleMix = .disabled,
        lut: LUTApplication = .none,
        applicableMediaKinds: [MediaKind]? = nil,
        thumbnailFileName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.adjustments = adjustments
        self.hsl = hsl
        self.splitToning = splitToning
        self.grayscale = grayscale
        self.lut = lut
        self.applicableMediaKinds = applicableMediaKinds
        self.thumbnailFileName = thumbnailFileName
        self.createdAt = createdAt
    }

    /// 从当前编辑状态创建用户预设。
    public init(name: String, from state: EditState, category: Category = .user) {
        self.init(
            name: name,
            category: category,
            isBuiltIn: false,
            adjustments: state.adjustments,
            hsl: state.hsl,
            splitToning: state.splitToning,
            grayscale: state.grayscale,
            lut: state.lut,
            applicableMediaKinds: [state.mediaKind]
        )
    }

    /// 把预设套到编辑状态上。
    ///
    /// 保留目标自己的 `mediaKind`、`videoColorInfo`、`renderOptions`，
    /// 与 `EditState.appliedTo(_:)` 行为一致。
    public func applied(to state: EditState) -> EditState {
        var result = state
        result.adjustments = adjustments
        result.hsl = hsl
        result.splitToning = splitToning
        result.grayscale = grayscale
        result.lut = lut
        result.presetName = name
        result.touch()
        return result
    }

    /// 是否适用于给定媒体类型。
    public func isApplicable(to kind: MediaKind) -> Bool {
        guard let applicableMediaKinds else { return true }
        return applicableMediaKinds.contains(kind)
    }
}
