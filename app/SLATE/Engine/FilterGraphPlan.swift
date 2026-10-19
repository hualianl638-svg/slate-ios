//
//  FilterGraphPlan.swift
//  ColorStudio
//
//  L2 · 业务逻辑层：FilterGraphBuilder 的输出格式
//  架构文档 L2「FilterGraphBuilder：把 EditState 编译成有序的 Core Image / Metal 滤镜链，
//  参数变更时增量重建」
//
//  为什么要这个"计划"结构，而不是直接建 CIFilter：
//  1. 它不依赖 Core Image / Metal，可以在任意平台单元测试滤镜链的**顺序与内容**；
//  2. 照片管线（CIFilter）与视频管线（Metal）各自把同一个 plan 翻译成自己的实现，
//     从结构上保证"照片和视频调节手感一致"（架构文档 L3 双管线共用调节内核）；
//  3. 渲染层可以对比新旧 plan 做增量重建（架构文档 L2「参数变更时增量重建」）。
//

import Foundation

// MARK: - LUT 步骤

/// 滤镜链里的 LUT 步骤。
///
/// 把解析好的 LUT 数据直接放进计划里，渲染层不需要再访问文件系统，
/// 也就不必关心 App 沙盒路径变化。
public struct LUTStep: Equatable, Sendable {

    /// 已解析的 3D LUT。
    public var lut: LUT3D
    /// 套用强度 0...1。
    public var intensity: Double
    /// 立方体边长，冗余存储便于快速校验（应与 `lut.dimension` 一致）。
    public var dimension: Int
    /// 来源展示名（日志/UI 用）。
    public var displayName: String

    public init(lut: LUT3D, intensity: Double, displayName: String = "") {
        self.lut = lut
        self.intensity = min(max(intensity, 0), 1)
        self.dimension = lut.dimension
        self.displayName = displayName
    }
}

// MARK: - 滤镜步骤

/// 滤镜链中的一个环节。
///
/// 每个 case 自带它需要的参数，`FilterGraphBuilder` 只负责"排序 + 按需包含"。
public enum FilterStep: Equatable, Sendable {

    // ---- 输入阶段（照片管线） ----

    /// RAW 解码参数（`CIRAWFilter`）。
    case rawDecode(RAWDecodeOptions)
    /// 线性化：S-Log3 -> 场景线性（视频管线），或对已在线性域的输入做恒等处理。
    case linearize(SLog3Options)
    /// 相机色域 -> 工作色彩空间（Rec.709 线性）。
    case gamutConvert(CameraColorSpace)

    // ---- 基础校正 ----

    /// 白平衡（线性域 RGB 增益）。
    case whiteBalance(WhiteBalanceParams)
    /// 曝光（线性域增益 2^EV）。
    case exposure(Double)
    /// 明度（gamma 域中间调偏移）。
    case brightness(Double)
    /// 对比度（中灰为轴心的 S 曲线）。
    case contrast(Double)
    /// 阴影 / 高光 / 黑场 / 白场（四段影调）。
    case toneCurve(ToneCurveParams)
    /// 去朦胧（压黑场 + 提对比）。
    case dehaze(Double)
    /// 自然饱和度。
    case vibrance(Double)
    /// 饱和度。
    case saturation(Double)

    // ---- 色彩 ----

    /// HSL 八通道。
    case hsl(HSLBands)
    /// 色调分离（阴影/高光染色）。
    case splitToning(SplitToning)
    /// 黑白混合。
    case grayscale(GrayscaleMix)

    // ---- 局部与质感 ----

    /// 清晰度（局部对比）。
    case clarity(Double)
    /// 暗角。
    case vignette(Double)
    /// 颗粒。
    case grain(Double)
    /// 降噪（高成本，`RenderQuality.allowsExpensiveFilters == false` 时跳过）。
    case noiseReduction(Double)
    /// 锐化（高成本）。
    case sharpness(Double)

    // ---- LUT 与输出 ----

    /// 3D LUT 套用。
    case lut(LUTStep)
    /// 输出编码（线性 -> Rec.709/sRGB 编码值）。
    case outputEncode(OutputEncoding)

    /// 人类可读的名称，用于调试面板与日志。
    public var displayName: String {
        switch self {
        case .rawDecode: return "RAW 解码"
        case .linearize: return "S-Log3 线性化"
        case .gamutConvert: return "色域转换"
        case .whiteBalance: return "白平衡"
        case .exposure: return "曝光"
        case .brightness: return "明度"
        case .contrast: return "对比度"
        case .toneCurve: return "影调曲线"
        case .dehaze: return "去朦胧"
        case .vibrance: return "自然饱和度"
        case .saturation: return "饱和度"
        case .hsl: return "HSL"
        case .splitToning: return "色调分离"
        case .grayscale: return "黑白混合"
        case .clarity: return "清晰度"
        case .vignette: return "暗角"
        case .grain: return "颗粒"
        case .noiseReduction: return "降噪"
        case .sharpness: return "锐化"
        case .lut: return "LUT"
        case .outputEncode: return "输出编码"
        }
    }

    /// 是否为高成本步骤（预览时可降级或跳过）。
    public var isExpensive: Bool {
        switch self {
        case .noiseReduction, .sharpness, .clarity: return true
        default: return false
        }
    }
}

// MARK: - 步骤参数

/// RAW 解码参数（对应 `CIRAWFilter` 的可调项）。
public struct RAWDecodeOptions: Equatable, Codable, Sendable {

    /// 解码时使用的色温（开尔文）；`nil` 表示跟随拍摄白平衡。
    public var neutralTemperature: Double?
    /// 解码时使用的色调；`nil` 表示跟随拍摄白平衡。
    public var neutralTint: Double?
    /// 曝光补偿 EV（在 RAW 域应用，避免高光溢出）。
    public var exposureEV: Double
    /// 高光恢复强度 0...1。
    public var highlightRecovery: Double
    /// 阴影提升 0...1。
    public var shadowBoost: Double
    /// 降噪等级（RAW 域降噪，0...1）。
    public var noiseReduction: Double
    /// 锐化等级 0...1。
    public var sharpness: Double
    /// 对比度 0...1（RAW 域对比）。
    public var contrast: Double
    /// 是否启用镜头校正（暗角/畸变）。
    public var enableLensCorrection: Bool
    /// 目标色彩空间（RAW 解码输出到哪个空间）。
    public var outputColorSpace: CameraColorSpace

    public init(
        neutralTemperature: Double? = nil,
        neutralTint: Double? = nil,
        exposureEV: Double = 0,
        highlightRecovery: Double = 0,
        shadowBoost: Double = 0,
        noiseReduction: Double = 0,
        sharpness: Double = 0,
        contrast: Double = 0,
        enableLensCorrection: Bool = true,
        outputColorSpace: CameraColorSpace = .rec709
    ) {
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
        self.exposureEV = exposureEV
        self.highlightRecovery = highlightRecovery
        self.shadowBoost = shadowBoost
        self.noiseReduction = noiseReduction
        self.sharpness = sharpness
        self.contrast = contrast
        self.enableLensCorrection = enableLensCorrection
        self.outputColorSpace = outputColorSpace
    }
}

/// S-Log3 线性化参数。
public struct SLog3Options: Equatable, Codable, Sendable {

    /// 记录曲线。
    public var curve: VideoColorInfo.TransferCurve
    /// 记录色域。
    public var colorSpace: CameraColorSpace
    /// 线性化后是否把 18% 中灰归一到 0.18（归一化），
    /// 还是把 S-Log3 的白点 1.0（约 38.4 线性）压到 1.0。
    ///
    /// 默认 `true`：把灰片"翻正"成 0...1 的场景线性，此时 18% 中灰 ≈ 0.18，
    /// 与普通照片一致，用户可以用同一套滑杆手感调 S-Log3。
    public var normalizeMidGray: Bool

    public init(
        curve: VideoColorInfo.TransferCurve = .sLog3,
        colorSpace: CameraColorSpace = .sGamut3Cine,
        normalizeMidGray: Bool = true
    ) {
        self.curve = curve
        self.colorSpace = colorSpace
        self.normalizeMidGray = normalizeMidGray
    }
}

/// 白平衡参数（已换算成线性域增益，渲染层直接用）。
public struct WhiteBalanceParams: Equatable, Codable, Sendable {

    /// 线性域 RGB 增益。
    public var redGain: Double
    public var greenGain: Double
    public var blueGain: Double
    /// 解码器侧使用的绝对色温（仅 RAW 管线使用）。
    public var absoluteTemperature: Double?
    /// 解码器侧使用的色调（仅 RAW 管线使用）。
    public var absoluteTint: Double?

    public init(
        redGain: Double = 1,
        greenGain: Double = 1,
        blueGain: Double = 1,
        absoluteTemperature: Double? = nil,
        absoluteTint: Double? = nil
    ) {
        self.redGain = redGain
        self.greenGain = greenGain
        self.blueGain = blueGain
        self.absoluteTemperature = absoluteTemperature
        self.absoluteTint = absoluteTint
    }

    /// 是否恒等（三个增益都为 1）。
    public var isIdentity: Bool {
        abs(redGain - 1) < 1e-9 && abs(greenGain - 1) < 1e-9 && abs(blueGain - 1) < 1e-9
    }
}

/// 四段影调参数：阴影 / 高光 / 黑场 / 白场。
public struct ToneCurveParams: Equatable, Codable, Sendable {
    public var shadows: Double
    public var highlights: Double
    public var blacks: Double
    public var whites: Double

    public init(shadows: Double = 0, highlights: Double = 0, blacks: Double = 0, whites: Double = 0) {
        self.shadows = shadows
        self.highlights = highlights
        self.blacks = blacks
        self.whites = whites
    }

    public var isNeutral: Bool {
        shadows == 0 && highlights == 0 && blacks == 0 && whites == 0
    }
}

/// 输出编码参数。
public struct OutputEncoding: Equatable, Codable, Sendable {

    /// 输出传递函数。
    public enum Transfer: String, Codable, Sendable {
        case sRGB
        case rec709
        /// 保持线性（用于写 16bit TIFF/EXR 或交给下游）。
        case linear
        /// 保持 S-Log3（输出灰片）。
        case sLog3
    }

    public var transfer: Transfer
    /// 输出色彩空间。
    public var colorSpace: CameraColorSpace
    /// 位深。
    public var bitDepth: Int

    public init(transfer: Transfer = .sRGB, colorSpace: CameraColorSpace = .rec709, bitDepth: Int = 8) {
        self.transfer = transfer
        self.colorSpace = colorSpace
        self.bitDepth = bitDepth
    }

    /// 8bit sRGB JPG 导出（第一部分默认）。
    public static let sRGB8Bit = OutputEncoding(transfer: .sRGB, colorSpace: .rec709, bitDepth: 8)

    /// 10bit Rec.709 视频导出（第二部分默认）。
    public static let rec709_10Bit = OutputEncoding(transfer: .rec709, colorSpace: .rec709, bitDepth: 10)
}

// MARK: - 计划

/// 编译完成的滤镜链计划。
public struct FilterGraphPlan: Equatable, Sendable {

    /// 有序步骤。渲染层按顺序执行。
    public var steps: [FilterStep]
    /// 入口：输入是否是 RAW（决定渲染层要不要建 CIRAWFilter）。
    public var isRAWInput: Bool
    /// 入口：输入是否是视频帧。
    public var isVideoInput: Bool
    /// 工作色彩空间（线性域运算在此空间进行）。
    public var workingColorSpace: CameraColorSpace
    /// 是否可以直接短路（中性编辑，渲染层跳过整条链）。
    public var isBypassed: Bool
    /// 编译时的诊断信息（哪些步骤因质量档位被跳过）。
    public var skippedSteps: [String]

    public init(
        steps: [FilterStep],
        isRAWInput: Bool = false,
        isVideoInput: Bool = false,
        workingColorSpace: CameraColorSpace = .rec709,
        isBypassed: Bool = false,
        skippedSteps: [String] = []
    ) {
        self.steps = steps
        self.isRAWInput = isRAWInput
        self.isVideoInput = isVideoInput
        self.workingColorSpace = workingColorSpace
        self.isBypassed = isBypassed
        self.skippedSteps = skippedSteps
    }

    /// 是否包含 LUT 步骤。
    public var containsLUT: Bool {
        steps.contains { if case .lut = $0 { return true } else { return false } }
    }

    /// 是否包含需要线性域的前置步骤（RAW 解码 / S-Log3 线性化）。
    public var requiresLinearInput: Bool {
        steps.contains {
            switch $0 {
            case .rawDecode, .linearize: return true
            default: return false
            }
        }
    }

    /// 便于日志与调试面板展示。
    public var summary: String {
        if isBypassed { return "旁路（无编辑）" }
        return steps.map(\.displayName).joined(separator: " → ")
    }
}

// MARK: - 编译

/// 把 `EditState` 编译成 `FilterGraphPlan`。
///
/// 这是纯函数式编译：不访问文件系统、不调用 GPU，因此可以完整单元测试。
/// LUT 数据由调用方（`LUTLibrary`）提前解析好传进来。
public enum FilterGraphBuilder {

    /// 编译滤镜链。
    ///
    /// - Parameters:
    ///   - state: 编辑状态。
    ///   - lut: 已解析的 LUT；`state.lut.isActive == true` 但此处为 `nil` 时会记录到 `skippedSteps`。
    ///   - quality: 渲染质量档位，决定是否包含高成本步骤。
    ///   - workingColorSpace: 工作色彩空间。
    /// - Returns: 可直接执行的计划。
    public static func build(
        state: EditState,
        lut: LUT3D? = nil,
        quality: RenderQuality = .preview,
        workingColorSpace: CameraColorSpace = .rec709
    ) -> FilterGraphPlan {
        var steps: [FilterStep] = []
        var skipped: [String] = []

        let isRAW = state.mediaKind == .raw
        let isVideo = state.mediaKind.isMotion
        let a = state.adjustments

        // ---- 0. 入口：把输入带到"线性、工作色域" ----

        if isRAW {
            let decode = RAWDecodeOptions(
                neutralTemperature: a.whiteBalance.temperature,
                neutralTint: a.whiteBalance.tint,
                // RAW 域只承担一部分曝光/降噪/锐化，其余留给统一内核，
                // 这样"照片与视频手感一致"这条约束才成立。
                exposureEV: 0,
                highlightRecovery: max(a.highlights, 0),
                shadowBoost: max(a.shadows, 0),
                noiseReduction: quality.allowsExpensiveFilters ? a.noiseReduction : 0,
                sharpness: 0,
                contrast: 0,
                enableLensCorrection: true,
                outputColorSpace: workingColorSpace
            )
            steps.append(.rawDecode(decode))
        } else if isVideo, let colorInfo = state.videoColorInfo, colorInfo.requiresNormalization {
            steps.append(.linearize(SLog3Options(
                curve: colorInfo.curve,
                colorSpace: colorInfo.colorSpace,
                normalizeMidGray: true
            )))
            if colorInfo.colorSpace.requiresGamutConversion {
                steps.append(.gamutConvert(colorInfo.colorSpace))
            }
        } else {
            // JPG / 普通视频：输入已是编码值，先线性化（sRGB 或 Rec.709 传递函数）。
            steps.append(.linearize(SLog3Options(
                curve: .rec709,
                colorSpace: .rec709,
                normalizeMidGray: false
            )))
        }

        // ---- 1. 白平衡（线性域） ----

        let gain = a.whiteBalance.rgbGain
        let wbParams = WhiteBalanceParams(
            redGain: gain.red,
            greenGain: gain.green,
            blueGain: gain.blue,
            absoluteTemperature: a.whiteBalance.temperature,
            absoluteTint: a.whiteBalance.tint
        )
        if !wbParams.isIdentity {
            steps.append(.whiteBalance(wbParams))
        }

        // ---- 2. 曝光（线性域） ----

        if a.exposure != 0 {
            steps.append(.exposure(a.exposure))
        }

        // ---- 3. 转入 gamma 域后的基础影调与色彩 ----

        if a.brightness != 0 { steps.append(.brightness(a.brightness)) }
        if a.contrast != 0 { steps.append(.contrast(a.contrast)) }

        let tone = ToneCurveParams(
            shadows: a.shadows,
            highlights: a.highlights,
            blacks: a.blacks,
            whites: a.whites
        )
        if !tone.isNeutral { steps.append(.toneCurve(tone)) }

        if a.dehaze > 0 { steps.append(.dehaze(a.dehaze)) }
        if a.vibrance != 0 { steps.append(.vibrance(a.vibrance)) }
        if a.saturation != 0 { steps.append(.saturation(a.saturation)) }

        // ---- 4. 色彩 ----

        if !state.hsl.isNeutral { steps.append(.hsl(state.hsl)) }
        if !state.splitToning.isNeutral { steps.append(.splitToning(state.splitToning)) }
        if state.grayscale.isEnabled { steps.append(.grayscale(state.grayscale)) }

        // ---- 5. 局部与质感 ----

        if a.clarity != 0 {
            if quality.allowsExpensiveFilters || !quality.isInteractive {
                steps.append(.clarity(a.clarity))
            } else {
                skipped.append("清晰度（预览降级）")
            }
        }
        if a.vignette != 0 { steps.append(.vignette(a.vignette)) }
        if a.grain > 0 { steps.append(.grain(a.grain)) }

        if a.noiseReduction > 0 {
            if quality.allowsExpensiveFilters {
                steps.append(.noiseReduction(a.noiseReduction))
            } else {
                skipped.append("降噪（仅全质量导出启用）")
            }
        }
        if a.sharpness > 0 {
            if quality.allowsExpensiveFilters {
                steps.append(.sharpness(a.sharpness))
            } else {
                skipped.append("锐化（仅全质量导出启用）")
            }
        }

        // ---- 6. LUT（在输出编码之前，Rec.709 显示参考域中套用） ----

        if state.lut.isActive {
            if let lut {
                steps.append(.lut(LUTStep(
                    lut: lut,
                    intensity: state.lut.intensity,
                    displayName: state.lut.reference?.displayName ?? ""
                )))
            } else {
                skipped.append("LUT 尚未加载完成")
            }
        }

        // ---- 7. 输出编码 ----

        steps.append(.outputEncode(outputEncoding(for: state, quality: quality)))

        return FilterGraphPlan(
            steps: steps,
            isRAWInput: isRAW,
            isVideoInput: isVideo,
            workingColorSpace: workingColorSpace,
            isBypassed: false,
            skippedSteps: skipped
        )
    }

    /// 由编辑状态推导输出编码。
    public static func outputEncoding(for state: EditState, quality: RenderQuality) -> OutputEncoding {
        let options = state.renderOptions
        let bitDepth = quality == .full ? (options.videoCodec.isTenBit ? 10 : 8) : 8

        if state.mediaKind.isMotion {
            switch options.outputColorSpace {
            case .rec709:
                return OutputEncoding(transfer: .rec709, colorSpace: .rec709, bitDepth: bitDepth)
            case .sLog3:
                return OutputEncoding(transfer: .sLog3, colorSpace: .sGamut3Cine, bitDepth: bitDepth)
            case .hlg:
                return OutputEncoding(transfer: .rec709, colorSpace: .rec709, bitDepth: bitDepth)
            }
        }
        return OutputEncoding(transfer: .sRGB, colorSpace: .rec709, bitDepth: bitDepth)
    }
}
