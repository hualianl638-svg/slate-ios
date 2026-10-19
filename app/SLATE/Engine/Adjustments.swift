//
//  Adjustments.swift
//  ColorStudio
//
//  L2 · 业务逻辑层：非破坏性编辑参数值类型
//  对应架构文档 L2「EditState（非破坏性编辑参数）」
//
//  设计约定（全工程共用，改动需同步 L2/L3/L1）：
//  · 所有参数都是"归中值 + 归一化范围"，0 表示不改变画面。
//  · 曝光与白平衡之外的参数统一使用 -1...1 或 0...1，便于滑杆与 Metal uniform 直接映射。
//  · 本文件不依赖 Core Image / Metal / UIKit，可在任意平台单元测试。
//

import Foundation

// MARK: - 基础调节（L3 照片/视频共用的"调色内核"输入）

/// 基础调节参数。
///
/// 参数与 Lightroom 的对应关系：
/// `exposure` 曝光 · `brightness` 明度 · `contrast` 对比度 · `shadows`/`highlights` 阴影/高光
/// `vibrance` 自然饱和度 · `saturation` 饱和度 · `whiteBalance` 白平衡
public struct Adjustments: Equatable, Codable, Hashable, Sendable {

    // MARK: 影调

    /// 曝光，单位 EV。范围 -5...5，0 为不改变。
    /// 线性域增益：`gain = 2^exposure`。
    public var exposure: Double

    /// 明度。范围 -1...1，0 为不改变。
    /// 作用于 gamma 域，主要抬升/压暗中间调，对纯黑纯白影响小于曝光。
    public var brightness: Double

    /// 对比度。范围 -1...1，0 为不改变。
    /// 以中灰为轴心的 S 曲线强度；-1 为完全平坦，+1 为强对比。
    public var contrast: Double

    /// 阴影。范围 -1...1，0 为不改变。
    /// 只抬升/压暗暗部，不影响高光（蒙版基于亮度权重）。
    public var shadows: Double

    /// 高光。范围 -1...1，0 为不改变。
    /// 只压暗/抬升高光，用于找回天空细节。
    public var highlights: Double

    /// 黑色色阶。范围 -1...1，0 为不改变。收缩/扩张最暗端。
    public var blacks: Double

    /// 白色色阶。范围 -1...1，0 为不改变。收缩/扩张最亮端。
    public var whites: Double

    // MARK: 色彩

    /// 自然饱和度。范围 -1...1，0 为不改变。
    /// 低饱和区域加权更强，避免肤色与已饱和区域溢出。
    public var vibrance: Double

    /// 饱和度。范围 -1...1，0 为不改变。-1 为完全去色，+1 约 2 倍饱和。
    public var saturation: Double

    // MARK: 白平衡

    /// 白平衡（色温 + 色调）。
    public var whiteBalance: WhiteBalance

    /// 清晰度（局部对比）。范围 -1...1，0 为不改变。用于补充 LR 观感的"通透度"。
    public var clarity: Double

    /// 去朦胧。范围 0...1，0 为不改变。压黑场 + 提对比，用于灰片初步归一化。
    public var dehaze: Double

    /// 锐化强度。范围 0...1，0 为不锐化。导出与预览共用。
    public var sharpness: Double

    /// 降噪强度。范围 0...1，0 为不降噪。高 ISO ARW 常用。
    public var noiseReduction: Double

    /// 暗角。范围 -1...1，0 为不改变。负值压暗四角，正值提亮四角。
    public var vignette: Double

    /// 颗粒。范围 0...1，0 为不添加。
    public var grain: Double

    public init(
        exposure: Double = 0,
        brightness: Double = 0,
        contrast: Double = 0,
        shadows: Double = 0,
        highlights: Double = 0,
        blacks: Double = 0,
        whites: Double = 0,
        vibrance: Double = 0,
        saturation: Double = 0,
        whiteBalance: WhiteBalance = .neutral,
        clarity: Double = 0,
        dehaze: Double = 0,
        sharpness: Double = 0,
        noiseReduction: Double = 0,
        vignette: Double = 0,
        grain: Double = 0
    ) {
        self.exposure = exposure
        self.brightness = brightness
        self.contrast = contrast
        self.shadows = shadows
        self.highlights = highlights
        self.blacks = blacks
        self.whites = whites
        self.vibrance = vibrance
        self.saturation = saturation
        self.whiteBalance = whiteBalance
        self.clarity = clarity
        self.dehaze = dehaze
        self.sharpness = sharpness
        self.noiseReduction = noiseReduction
        self.vignette = vignette
        self.grain = grain
    }

    /// 全部归中：不改变画面。
    public static let neutral = Adjustments()

    /// 是否所有参数都位于不改变画面的位置。
    public var isNeutral: Bool {
        self == .neutral
    }

    // MARK: 数值约束

    /// 取值范围表。UI 滑杆与参数校验共用同一份定义，避免两处硬编码不一致。
    public enum Range {
        public static let exposure: ClosedRange<Double> = -5...5
        public static let brightness: ClosedRange<Double> = -1...1
        public static let contrast: ClosedRange<Double> = -1...1
        public static let shadows: ClosedRange<Double> = -1...1
        public static let highlights: ClosedRange<Double> = -1...1
        public static let blacks: ClosedRange<Double> = -1...1
        public static let whites: ClosedRange<Double> = -1...1
        public static let vibrance: ClosedRange<Double> = -1...1
        public static let saturation: ClosedRange<Double> = -1...1
        public static let clarity: ClosedRange<Double> = -1...1
        public static let dehaze: ClosedRange<Double> = 0...1
        public static let sharpness: ClosedRange<Double> = 0...1
        public static let noiseReduction: ClosedRange<Double> = 0...1
        public static let vignette: ClosedRange<Double> = -1...1
        public static let grain: ClosedRange<Double> = 0...1
    }

    /// 把越界参数夹回合法区间。导入外部预设/工程文件后必须调用。
    public mutating func clamp() {
        exposure = Self.clamp(exposure, to: Range.exposure)
        brightness = Self.clamp(brightness, to: Range.brightness)
        contrast = Self.clamp(contrast, to: Range.contrast)
        shadows = Self.clamp(shadows, to: Range.shadows)
        highlights = Self.clamp(highlights, to: Range.highlights)
        blacks = Self.clamp(blacks, to: Range.blacks)
        whites = Self.clamp(whites, to: Range.whites)
        vibrance = Self.clamp(vibrance, to: Range.vibrance)
        saturation = Self.clamp(saturation, to: Range.saturation)
        clarity = Self.clamp(clarity, to: Range.clarity)
        dehaze = Self.clamp(dehaze, to: Range.dehaze)
        sharpness = Self.clamp(sharpness, to: Range.sharpness)
        noiseReduction = Self.clamp(noiseReduction, to: Range.noiseReduction)
        vignette = Self.clamp(vignette, to: Range.vignette)
        grain = Self.clamp(grain, to: Range.grain)
        whiteBalance.clamp()
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    // MARK: 兼容性解码

    /// 手写解码：新增字段缺失时回落到中性值，保证旧工程文件仍可打开。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) -> Double {
            (try? container.decodeIfPresent(Double.self, forKey: key)) .flatMap { $0 } ?? 0
        }
        exposure = value(.exposure)
        brightness = value(.brightness)
        contrast = value(.contrast)
        shadows = value(.shadows)
        highlights = value(.highlights)
        blacks = value(.blacks)
        whites = value(.whites)
        vibrance = value(.vibrance)
        saturation = value(.saturation)
        whiteBalance = (try? container.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance)) .flatMap { $0 } ?? .neutral
        clarity = value(.clarity)
        dehaze = value(.dehaze)
        sharpness = value(.sharpness)
        noiseReduction = value(.noiseReduction)
        vignette = value(.vignette)
        grain = value(.grain)
        clamp()
    }
}

// MARK: - 白平衡

/// 白平衡。色温/色调同时保存"绝对开尔文"与"相对偏移"，两者用途不同：
/// · 绝对色温用于 RAW 解码器（CIRAWFilter.neutralTemperature）与元数据回读；
/// · 相对偏移用于已解码图像（JPG / S-Log3 视频帧）上的色彩增益，与解码器无关。
public struct WhiteBalance: Equatable, Codable, Hashable, Sendable {

    /// 绝对色温（开尔文）。`nil` 表示"原照拍摄白平衡"，不改变画面。
    public var temperature: Double?

    /// 色调偏移 -1...1。`nil` 或 0 表示不改变。
    public var tint: Double?

    /// 相对色温偏移 -1...1映射到 UI 的 -100...100。
    /// 正值（UI 正值）向暖色偏移，负值向冷色偏移。
    public var relativeTemperatureOffset: Double

    /// 相对色调偏移 -1...1。
    /// 正值向品红偏移，负值向绿色偏移。
    public var relativeTintOffset: Double

    public init(
        temperature: Double? = nil,
        tint: Double? = nil,
        relativeTemperatureOffset: Double = 0,
        relativeTintOffset: Double = 0
    ) {
        self.temperature = temperature
        self.tint = tint
        self.relativeTemperatureOffset = relativeTemperatureOffset
        self.relativeTintOffset = relativeTintOffset
    }

    /// 不改变画面。
    public static let neutral = WhiteBalance()

    /// 色温合法范围（与 CIRAWFilter 的 2000...50000 取交集后收紧到常用区间）。
    public static let temperatureRange: ClosedRange<Double> = 2000...12000

    /// 标准日光白平衡，作为"sRGB 图像上的中性起点"。
    public static let daylight: WhiteBalance = WhiteBalance(temperature: 6500, tint: 0)

    public var isNeutral: Bool {
        relativeTemperatureOffset == 0 && relativeTintOffset == 0
            && (temperature == nil || tint == nil)
    }

    public mutating func clamp() {
        if let temperature {
            self.temperature = Self.temperatureRange.contains(temperature)
                ? temperature
                : (temperature.isFinite ? Swift.min(Swift.max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound) : nil)
        }
        if let tint {
            self.tint = tint.isFinite ? Swift.min(Swift.max(tint, -1), 1) : nil
        }
        relativeTemperatureOffset = Adjustments.clamp(relativeTemperatureOffset, to: -1...1)
        relativeTintOffset = Adjustments.clamp(relativeTintOffset, to: -1...1)
    }

    /// 相对偏移换算成 RGB 增益（线性域乘数）。
    ///
    /// 用简化 Tanner Helland 近似只取方向：暖 = R↑ B↓，品红 = R↑B↑G↓。
    /// 返回 0...2 左右的正增益，`ColorScience` 与 Metal uniform 共用。
    public var rgbGain: (red: Double, green: Double, blue: Double) {
        let warm = relativeTemperatureOffset
        let magenta = relativeTintOffset
        // 每 1.0 的相对偏移约对应 ±25% 通道增益。
        let red = 1.0 + 0.25 * warm + 0.10 * magenta
        let green = 1.0 - 0.10 * magenta
        let blue = 1.0 - 0.25 * warm + 0.10 * magenta
        return (max(red, 0.01), max(green, 0.01), max(blue, 0.01))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try? container.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try? container.decodeIfPresent(Double.self, forKey: .tint)
        relativeTemperatureOffset = (try? container.decodeIfPresent(Double.self, forKey: .relativeTemperatureOffset)) .flatMap { $0 } ?? 0
        relativeTintOffset = (try? container.decodeIfPresent(Double.self, forKey: .relativeTintOffset)) .flatMap { $0 } ?? 0
        clamp()
    }
}

// MARK: - HSL 八通道

/// HSL 八通道的通道标识。顺序即 UI 色环顺序，也是 Metal uniform 数组下标。
public enum HSLBandID: Int, CaseIterable, Codable, Hashable, Sendable {
    case red = 0
    case orange
    case yellow
    case green
    case aqua
    case blue
    case purple
    case magenta

    /// 通道中心色相（0...1 的色相环角度）。
    public var centerHue: Double {
        switch self {
        case .red: return 0.0
        case .orange: return 30.0 / 360.0
        case .yellow: return 60.0 / 360.0
        case .green: return 120.0 / 360.0
        case .aqua: return 180.0 / 360.0
        case .blue: return 240.0 / 360.0
        case .purple: return 280.0 / 360.0
        case .magenta: return 320.0 / 360.0
        }
    }

    /// 中文显示名（UI 用）。
    public var displayName: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .aqua: return "浅绿"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .magenta: return "洋红"
        }
    }

    /// 通道代表色，用于 UI 色块（sRGB 0...1）。
    public var swatchRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: return (0.90, 0.16, 0.16)
        case .orange: return (0.95, 0.55, 0.12)
        case .yellow: return (0.94, 0.85, 0.15)
        case .green: return (0.30, 0.72, 0.24)
        case .aqua: return (0.18, 0.76, 0.70)
        case .blue: return (0.16, 0.44, 0.90)
        case .purple: return (0.52, 0.30, 0.88)
        case .magenta: return (0.88, 0.20, 0.62)
        }
    }
}

/// 单个 HSL 通道的调整量。三个分量都是 -1...1，0 为不改变。
public struct HSLBand: Equatable, Codable, Hashable, Sendable {
    /// 色相偏移。
    public var hue: Double
    /// 饱和度缩放。
    public var saturation: Double
    /// 明度缩放。
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public static let neutral = HSLBand()

    public var isNeutral: Bool { self == .neutral }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = (try? container.decodeIfPresent(Double.self, forKey: .hue)) .flatMap { $0 } ?? 0
        saturation = (try? container.decodeIfPresent(Double.self, forKey: .saturation)) .flatMap { $0 } ?? 0
        luminance = (try? container.decodeIfPresent(Double.self, forKey: .luminance)) .flatMap { $0 } ?? 0
    }
}

/// HSL 八通道集合。下标访问：`bands[.orange]`。
public struct HSLBands: Equatable, Codable, Hashable, Sendable {

    private var storage: [HSLBand]

    /// 按 `HSLBandID.allCases` 顺序返回，长度恒为 8。
    public var ordered: [HSLBand] { storage }

    public init() {
        storage = Array(repeating: .neutral, count: HSLBandID.allCases.count)
    }

    public init(_ bands: [HSLBand]) {
        var normalized = Array(bands.prefix(HSLBandID.allCases.count))
        while normalized.count < HSLBandID.allCases.count {
            normalized.append(.neutral)
        }
        storage = normalized
    }

    public subscript(id: HSLBandID) -> HSLBand {
        get { storage[id.rawValue] }
        set { storage[id.rawValue] = newValue }
    }

    /// 是否所有通道都未调整（用于跳过 HSL 内核，省一次全图运算）。
    public var isNeutral: Bool { storage.allSatisfy(\.isNeutral) }

    public mutating func reset() { storage = Array(repeating: .neutral, count: HSLBandID.allCases.count) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = (try? container.decode([HSLBand].self)) ?? []
        self.init(decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}

// MARK: - 色调分离

/// 色调分离的单一目标区域参数。
public struct SplitToneTarget: Equatable, Codable, Hashable, Sendable {
    /// 目标色相 0...1。
    public var hue: Double
    /// 目标饱和度 0...1。
    public var saturation: Double
    /// 混合强度 0...1，0 为不改变。
    public var amount: Double
    /// 平衡偏移 -1...1，正值把权重推向更亮的像素。
    public var balance: Double

    public init(hue: Double = 0, saturation: Double = 0, amount: Double = 0, balance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.amount = amount
        self.balance = balance
    }

    public static let neutral = SplitToneTarget()

    public var isNeutral: Bool { amount == 0 || saturation == 0 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = (try? container.decodeIfPresent(Double.self, forKey: .hue)) .flatMap { $0 } ?? 0
        saturation = (try? container.decodeIfPresent(Double.self, forKey: .saturation)) .flatMap { $0 } ?? 0
        amount = (try? container.decodeIfPresent(Double.self, forKey: .amount)) .flatMap { $0 } ?? 0
        balance = (try? container.decodeIfPresent(Double.self, forKey: .balance)) .flatMap { $0 } ?? 0
    }
}

/// 色调分离：分别给阴影与高光染色（架构文档 L3「色调分离(阴影/高光 HSB)」）。
public struct SplitToning: Equatable, Codable, Hashable, Sendable {
    public var shadows: SplitToneTarget
    public var highlights: SplitToneTarget
    /// 全局平衡 -1...1，在阴影/高光之间平移分界点。
    public var balance: Double

    public init(
        shadows: SplitToneTarget = .neutral,
        highlights: SplitToneTarget = .neutral,
        balance: Double = 0
    ) {
        self.shadows = shadows
        self.highlights = highlights
        self.balance = balance
    }

    public static let neutral = SplitToning()

    public var isNeutral: Bool { shadows.isNeutral && highlights.isNeutral }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shadows = (try? container.decodeIfPresent(SplitToneTarget.self, forKey: .shadows)) .flatMap { $0 } ?? .neutral
        highlights = (try? container.decodeIfPresent(SplitToneTarget.self, forKey: .highlights)) .flatMap { $0 } ?? .neutral
        balance = (try? container.decodeIfPresent(Double.self, forKey: .balance)) .flatMap { $0 } ?? 0
    }
}

// MARK: - 黑白混合

/// 黑白混合。8 个通道决定各色相转灰后的明度权重。
public struct GrayscaleMix: Equatable, Codable, Hashable, Sendable {
    /// 是否启用黑白。
    public var isEnabled: Bool
    public var bands: HSLBands

    public init(isEnabled: Bool = false, bands: HSLBands = HSLBands()) {
        self.isEnabled = isEnabled
        self.bands = bands
    }

    public static let disabled = GrayscaleMix()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) .flatMap { $0 } ?? false
        bands = (try? container.decodeIfPresent(HSLBands.self, forKey: .bands)) .flatMap { $0 } ?? HSLBands()
    }
}
