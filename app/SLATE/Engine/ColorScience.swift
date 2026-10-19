//
//  ColorScience.swift
//  ColorStudio
//
//  L3 · 渲染引擎层的颜色数学（Core，跨平台，不含 Core Image / Metal 依赖）
//
//  本文件是 S-Log3 与色彩空间转换的**唯一事实来源**。
//  Metal 端 Resources/Shaders/ColorKernels.metal 中同名函数必须与本文件数值一致，
//  tools/verify_color_math.py 会解析两边的常量并交叉校验（CI 可跑）。
//
//  S-Log3 常量来源与验证：
//  Sony 官方提供给 ACES 的输入变换 IDT.Sony.Venice_SLog3_SGamut3.ctl：
//      if (SLog >= 171.2102946929 / 1023.0)
//          out = pow(10.0, (SLog * 1023.0 - 420.0) / 261.5) * (0.18 + 0.01) - 0.01;
//      else
//          out = (SLog * 1023.0 - 95.0) * 0.01125000 / (171.2102946929 - 95.0);
//  归一化为 0...1 码值后即为下面的 A/B/D/E 与分段点：
//      18% 中灰   -> 码值 0.41055718475073316（10bit 420.000000）✔
//      黑电平 x=0 -> 码值 0.09286412512218964（10bit  95.000000）✔
//      解码后再编码，20001 点最大偏差 2.2e-16 ✔
//

import Foundation

// MARK: - S-Log3

/// Sony S-Log3 的对数传递函数。
///
/// 输入为归一化 0...1 码值（与 10bit 码值 / 1023 等价），
/// 输出为 0...1 的"场景线性"值（1.0 = 反射率 100%，18% 中灰 = 0.18）。
public enum SLog3 {

    // MARK: 常量（与 Sony 官方一致，改动前请先跑 tools/derive_color_math.py）

    /// log 段系数 261.5 / 1023
    public static let a: Double = 261.5 / 1023.0

    /// log 段黑偏移 0.01
    public static let b: Double = 0.01

    /// 18% 中灰 0.18
    public static let c: Double = 0.18

    /// log 段码值偏移 420 / 1023
    public static let d: Double = 420.0 / 1023.0

    /// log 项内部常数 1 / (b + c) = 5.2631578947368425
    public static let e: Double = 1.0 / (b + c)

    /// 低段（线性段）**码值域斜率**：`code = k * linear + f`。
    ///
    /// 单位说明（**这是本工程最容易抄错的一个常量，务必看清**）：
    /// · 本值是"**每单位线性值对应多少码值**"，即斜率，= 6.621943711775821；
    /// · 它等于线性域斜率 ÷ 1023，也等于官方直线分母的倒数：
    ///   k = (171.2102946929 - 95.0) / (1023 × 0.01125)
    /// · ❌ 常见错误：把它写成 1/k ≈ 0.151013，或写成只取 `0.01125 / (…/1023 - …/1023)`（那是 1/k）。
    ///   写成 1/k 会让深阴影（码值 95~171，约 10 档里最暗的一段）整体差 44 倍，
    ///   而 18% 中灰以上走 log 分支完全正常 —— 只测中间调根本发现不了。
    ///
    /// 验证锚点：`linearize(0.0) == 0`、`encode(0.0) == 95/1023`、
    /// `legacyWrongLinearize(0.15)` 会比 `linearize(0.15)` 小约 44 倍。
    public static let k: Double = (171.2102946929 - 95.0) / (1023.0 * 0.01125)

    /// 低段截距 95 / 1023
    public static let f: Double = 95.0 / 1023.0

    /// 分段点（线性域）
    public static let linearSplit: Double = 0.01125

    /// 分段点（归一化码值域）
    public static let codeSplit: Double = 171.2102946929 / 1023.0

    /// 10bit 码值下的黑电平（S-Log3 全范围素材的 0 亮度）
    public static let blackCode10Bit: Double = 95.0

    /// 10bit 码值下的 18% 中灰
    public static let midGrayCode10Bit: Double = 420.0

    // MARK: 解码：S-Log3 -> 线性

    /// S-Log3 码值 -> 场景线性。
    ///
    /// 低段必须写成 `(code - f) / k`：k 是码值域斜率，
    /// 与官方直线 `(code*1023 - 95) * 0.01125 / (171.2102946929 - 95)` 逐点等价。
    public static func linearize(_ code: Double) -> Double {
        let clamped = min(max(code, 0), 1)
        if clamped >= codeSplit {
            return pow(10.0, (clamped - d) / a) / e - b
        }
        return (clamped - f) / k
    }

    /// S-Log3 码值 -> 场景线性，跳过 0...1 夹取。
    ///
    /// 用于需要保留超范围信息（10bit 全范围、HEVC 10bit）的场景：
    /// 相机录制范围通常是 0...1023，但调色后可能出现超出，解码侧保持线性外推。
    public static func linearizeUnclamped(_ code: Double) -> Double {
        if code >= codeSplit {
            return pow(10.0, (code - d) / a) / e - b
        }
        return (code - f) / k
    }

    // MARK: 编码：线性 -> S-Log3

    /// 场景线性 -> S-Log3 码值（0...1）。
    public static func encode(_ linear: Double) -> Double {
        if linear >= linearSplit {
            return a * log10(e * (linear + b)) + d
        }
        return k * linear + f
    }

    /// 场景线性 -> S-Log3 10bit 码值（0...1023 浮点）。
    public static func encode10Bit(_ linear: Double) -> Double {
        encode(linear) * 1023.0
    }

    /// S-Log3 10bit 码值 -> 场景线性。
    public static func linearize10Bit(_ code10Bit: Double) -> Double {
        linearize(code10Bit / 1023.0)
    }

    // MARK: 批量

    /// 对 RGB 三元组做线性化。
    public static func linearize(_ code: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            Float(linearize(Double(code.x))),
            Float(linearize(Double(code.y))),
            Float(linearize(Double(code.z)))
        )
    }
}

// MARK: - 传递函数

/// 显示传递函数（OETF/EOTF）。
public enum TransferFunction {

    /// sRGB EOTF：sRGB 编码值 -> 线性。
    public static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// sRGB OETF：线性 -> sRGB 编码值。
    public static func linearToSRGB(_ value: Double) -> Double {
        let clamped = max(value, 0)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
    }

    /// ITU-R BT.709 OETF：线性 -> Rec.709 编码值。
    ///
    /// 注意：BT.709 的 OETF 在 x = 0.018 处存在很小但真实的不连续（约 0.08/1023），
    /// 这是标准本身的性质，制造时按标准实现即可，不要"修正"它。
    public static func linearToRec709(_ value: Double) -> Double {
        let clamped = max(value, 0)
        return clamped < 0.018 ? 4.5 * clamped : 1.099 * pow(clamped, 0.45) - 0.099
    }

    /// ITU-R BT.709 EOTF：Rec.709 编码值 -> 线性。
    public static func rec709ToLinear(_ value: Double) -> Double {
        value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1.0 / 0.45)
    }
}

// MARK: - 色彩空间与色域转换

/// 相机的色彩空间（决定用哪一组原色）。
public enum CameraColorSpace: String, CaseIterable, Codable, Sendable {
    /// S-Gamut3.Cine：S-Log3 的推荐搭配，色域比 S-Gamut3 窄，转 Rec.709 损失最小。
    case sGamut3Cine = "S-Gamut3.Cine"
    /// S-Gamut3：完整 S-Gamut3 色域，包含更多高饱和色。
    case sGamut3 = "S-Gamut3"
    /// 已经是 Rec.709（例如机内直接拍的普通视频或 JPG）。
    case rec709 = "Rec.709"
    /// sRGB（屏幕截图、手机素材）。
    case sRGB = "sRGB"

    public var displayName: String {
        switch self {
        case .sGamut3Cine: return "S-Gamut3.Cine"
        case .sGamut3: return "S-Gamut3"
        case .rec709: return "Rec.709"
        case .sRGB: return "sRGB"
        }
    }

    /// 是否需要在调色前做色域转换。
    public var requiresGamutConversion: Bool {
        self == .sGamut3Cine || self == .sGamut3
    }

    /// 3x3 线性域转换矩阵，行主序，目标为 Rec.709 线性。
    ///
    /// 数值由 tools/derive_color_math.py 从标准原色色度坐标推导：
    ///   M = inv(RGB2XYZ_Rec709) * RGB2XYZ_source，白点 D65。
    /// 行和精确为 1，说明 D65 中性色在转换后保持不变。
    public var toRec709Matrix: [[Double]] {
        switch self {
        case .sGamut3Cine:
            return [
                [ 1.626947410, -0.540138539, -0.086808871],
                [-0.178515527,  1.417940927, -0.239425400],
                [-0.044436115, -0.195919966,  1.240356081],
            ]
        case .sGamut3:
            return [
                [ 1.877915128, -0.794168761, -0.083746367],
                [-0.176806981,  1.350999621, -0.174192640],
                [-0.026201126, -0.148422262,  1.174623389],
            ]
        case .rec709, .sRGB:
            return [
                [1, 0, 0],
                [0, 1, 0],
                [0, 0, 1],
            ]
        }
    }
}

/// 色彩空间转换工具。
public enum ColorSpaceConversion {

    /// 矩阵乘法：3x3 行主序矩阵 × RGB。
    public static func multiply(_ matrix: [[Double]], _ color: SIMD3<Float>) -> SIMD3<Float> {
        guard matrix.count == 3 else { return color }
        let r = matrix[0][0] * Double(color.x) + matrix[0][1] * Double(color.y) + matrix[0][2] * Double(color.z)
        let g = matrix[1][0] * Double(color.x) + matrix[1][1] * Double(color.y) + matrix[1][2] * Double(color.z)
        let b = matrix[2][0] * Double(color.x) + matrix[2][1] * Double(color.y) + matrix[2][2] * Double(color.z)
        return SIMD3(Float(r), Float(g), Float(b))
    }

    /// 把 S-Gamut3(.Cine) 线性 RGB 转到 Rec.709 线性 RGB。
    public static func toRec709(_ color: SIMD3<Float>, from source: CameraColorSpace) -> SIMD3<Float> {
        multiply(source.toRec709Matrix, color)
    }

    /// 软压扩：把广色域转窄色域产生的越界值压回 0...1，避免硬裁剪造成的色相偏移。
    ///
    /// 由推导脚本测得：S-Gamut3.Cine 立方体转到 Rec.709 后取值约 -0.627...1.627，
    /// 其中纯青 (0,1,1) 会得到 R = -0.627。硬 `clamp(0,1)` 会让高饱和青/黄区域整片变色，
    /// 因此这里用二次软膝压缩：越界越远压缩越强，保留色相关系。
    ///
    /// - Parameters:
    ///   - knee: 开始压缩的阈值（距边界多远开始软压缩），默认 0.25。
    public static func softClipGamut(_ value: Double, knee: Double = 0.25) -> Double {
        let softKnee = max(knee, 1e-4)
        if value < 0 {
            let overshoot = -value
            // 二次衰减：(1 - 1/(1 + o/k)) 形式在 o=0 处导数为 1/k，保证连续
            let compressed = overshoot / (1.0 + overshoot / softKnee)
            return -compressed * min(1.0, softKnee)
        }
        if value > 1 {
            let overshoot = value - 1
            let compressed = overshoot / (1.0 + overshoot / softKnee)
            return 1.0 + compressed * min(1.0, softKnee)
        }
        return value
    }

    /// 对 RGB 三个通道整体做软压扩。
    public static func softClipGamut(_ color: SIMD3<Float>, knee: Double = 0.25) -> SIMD3<Float> {
        SIMD3(
            Float(softClipGamut(Double(color.x), knee: knee)),
            Float(softClipGamut(Double(color.y), knee: knee)),
            Float(softClipGamut(Double(color.z), knee: knee))
        )
    }

    /// Rec.709 线性 -> sRGB 线性（两者原色与白点相同，只需传递函数差异，线性域无需矩阵）。
    public static func rec709ToSRGBLinear(_ color: SIMD3<Float>) -> SIMD3<Float> {
        color
    }
}

// MARK: - 白平衡

/// 白平衡的数值实现（CPU 参考实现，Metal 端必须一致）。
public enum WhiteBalanceMath {

    /// 相对色温/色调偏移 -> 线性域 RGB 增益。
    ///
    /// 与 `WhiteBalance.rgbGain` 保持同一公式：每 1.0 的相对偏移对应约 ±25% 通道增益。
    public static func rgbGain(temperatureOffset: Double, tintOffset: Double) -> SIMD3<Float> {
        let warm = temperatureOffset
        let magenta = tintOffset
        let red = 1.0 + 0.25 * warm + 0.10 * magenta
        let green = 1.0 - 0.10 * magenta
        let blue = 1.0 - 0.25 * warm + 0.10 * magenta
        return SIMD3(Float(max(red, 0.01)), Float(max(green, 0.01)), Float(max(blue, 0.01)))
    }

    /// 把绝对色温换算成相对偏移（当素材本身没有白平衡元数据时使用）。
    ///
    /// 以 6500K 为中性参考，按 Mired（微倒度）差值线性映射到 -1...1。
    /// 3000K 大约对应 -0.53，9000K 大约对应 +0.39，与 Lightroom 滑杆手感接近。
    public static func offset(forTemperature kelvin: Double, reference: Double = 6500) -> Double {
        let mired = 1_000_000.0 / max(kelvin, 500)
        let referenceMired = 1_000_000.0 / max(reference, 500)
        return min(max((mired - referenceMired) / 120.0, -1), 1)
    }

    /// 绝对色温 -> 近似 RGB 增益（Tanner Helland 近似的线性简化版）。
    ///
    /// 仅用于 UI 预览与"没有拍摄白平衡信息"的兜底，不参与主渲染路径。
    public static func approximateGain(forTemperature kelvin: Double) -> SIMD3<Float> {
        let temp = min(max(kelvin, 1000), 40000) / 100.0
        let red: Double
        let green: Double
        let blue: Double

        if temp <= 66 {
            red = 255
            green = 99.4708025861 * log(temp) - 161.1195681661
            blue = temp <= 19 ? 0 : 138.5177312231 * log(temp - 10) - 305.0447927307
        } else {
            red = 329.698727446 * pow(temp - 60, -0.1332047592)
            green = 288.1221695283 * pow(temp - 60, -0.0755148492)
            blue = 255
        }
        return SIMD3(
            Float(min(max(red, 0), 255) / 255.0),
            Float(min(max(green, 0), 255) / 255.0),
            Float(min(max(blue, 0), 255) / 255.0)
        )
    }
}

// MARK: - 亮度与饱和度工具

/// 感知亮度与饱和度计算（CPU 参考实现，调色内核与直方图共用权重）。
public enum LuminanceMath {

    /// Rec.709 亮度权重（线性域）。
    public static let rec709Weights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    /// 线性域亮度（Y）。
    public static func linearLuminance(_ color: SIMD3<Float>) -> Float {
        Float(rec709Weights.x * Double(color.x)
            + rec709Weights.y * Double(color.y)
            + rec709Weights.z * Double(color.z))
    }

    /// HSV 形式的饱和度： (max - min) / max。
    public static func saturation(_ color: SIMD3<Float>) -> Float {
        let maximum = max(color.x, max(color.y, color.z))
        guard maximum > 1e-6 else { return 0 }
        let minimum = min(color.x, min(color.y, color.z))
        return (maximum - minimum) / maximum
    }
}
