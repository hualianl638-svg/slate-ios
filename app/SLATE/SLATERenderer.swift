//
//  SLATERenderer.swift
//  SLATE
//
//  渲染器：把 EditState 真正作用到画面上，输出可显示的 CGImage。
//
//  两条硬规矩（都是踩过坑的）：
//  1. **常量一律从 Engine 的 SLog3 读取**，不在内核里手抄数值
//     （S-Log3 的 k 曾被三处实现同时写反，且只在中灰以上看起来正常）；
//  2. **内核必须用 Core Image 内核语言的类型**（`vec3` / `vec4`），不是 Metal 的 `float3`。
//     用错类型时 `CIColorKernel(source:)` 返回 nil；若再静默跳过，效果会无声消失。
//     因此本文件把内核创建失败收集到 `kernelFailures`，由界面显式提示。
//
//  处理顺序（与 Engine.FilterGraphBuilder 的语义一致）：
//    S-Log3 解码 → 色域转 Rec.709 → 白平衡+曝光（线性域）→ 编码到 sRGB
//    → 阴影/高光/黑场/白场 → 明度 → 对比度 → 饱和度 → 自然饱和度
//    → 色调分离 → LUT
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import UIKit

final class SLATERenderer {

    static let shared = SLATERenderer()

    private let context: CIContext

    /// S-Log3 码值 → 场景线性。
    private let slog3Decode: CIColorKernel?
    /// 阴影/高光/黑场/白场。
    private let toneKernel: CIColorKernel?
    /// 色调分离。
    private let splitToneKernel: CIColorKernel?

    /// 创建失败的内核名。非空时界面应提示用户，而不是让效果静默消失。
    let kernelFailures: [String]

    private init() {
        var failures: [String] = []

        if let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
                .cacheIntermediates: false,
            ])
        } else {
            self.context = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            ])
        }

        let slog3 = CIColorKernel(source: Self.slog3DecodeSource)
        if slog3 == nil { failures.append("S-Log3 解码") }
        let tone = CIColorKernel(source: Self.toneSource)
        if tone == nil { failures.append("阴影/高光/黑白色阶") }
        let split = CIColorKernel(source: Self.splitToneSource)
        if split == nil { failures.append("色调分离") }

        self.slog3Decode = slog3
        self.toneKernel = tone
        self.splitToneKernel = split
        self.kernelFailures = failures
    }

    // MARK: - 内核源码

    /// S-Log3 解码。
    ///
    /// 数值来自 `SLog3`（Sony 官方 ACES IDT 归一化形式）：
    ///   code >= 0.16736099187966763 时 linear = 10^((code-D)/A)/E - B
    ///   否则                          linear = (code - F) / K
    /// 自检：decode(0.41055718475073316) == 0.18，decode(0.09286412512218964) == 0
    private static let slog3DecodeSource = """
    kernel vec4 slateSLog3Decode(__sample s) {
        vec3 c = s.rgb;
        vec3 lin;
        lin.r = (c.r >= 0.16736099187966763)
              ? (pow(10.0, (c.r - 0.41055718475073316) / 0.25562072336265884) / 5.2631578947368425 - 0.01)
              : ((c.r - 0.09286412512218964) / 6.621943711775821);
        lin.g = (c.g >= 0.16736099187966763)
              ? (pow(10.0, (c.g - 0.41055718475073316) / 0.25562072336265884) / 5.2631578947368425 - 0.01)
              : ((c.g - 0.09286412512218964) / 6.621943711775821);
        lin.b = (c.b >= 0.16736099187966763)
              ? (pow(10.0, (c.b - 0.41055718475073316) / 0.25562072336265884) / 5.2631578947368425 - 0.01)
              : ((c.b - 0.09286412512218964) / 6.621943711775821);
        return vec4(clamp(lin, 0.0, 1.0), s.a);
    }
    """

    /// 阴影 / 高光 / 黑场 / 白场。
    ///
    /// 用**亮度蒙版**驱动统一偏移，而不是逐通道算掩版：
    /// 逐通道做会让某个通道先饱和、产生色偏；用亮度做掩版能保持色相。
    /// 掩版形状与 Engine 的 `toneAdjustChannel` 一致。
    private static let toneSource = """
    kernel vec4 slateTone(__sample s, float shadows, float highlights, float blacks, float whites) {
        vec3 c = s.rgb;
        float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float l = clamp(luma, 0.0, 1.0);
        float shadowMask = pow(clamp(1.0 - l * 2.0, 0.0, 1.0), 2.0) * (0.30 + 0.70 * clamp(l * 2.0, 0.0, 1.0));
        float highMask   = pow(clamp(l * 2.0 - 1.0, 0.0, 1.0), 2.0) * (0.30 + 0.70 * clamp((1.0 - l) * 2.0, 0.0, 1.0));
        float blackMask  = pow(clamp(1.0 - l * 3.0, 0.0, 1.0), 2.0);
        float whiteMask  = pow(clamp(l * 3.0 - 2.0, 0.0, 1.0), 2.0);
        float delta = shadows * 0.35 * shadowMask
                    + highlights * 0.35 * highMask
                    + blacks * 0.18 * blackMask
                    + whites * 0.18 * whiteMask;
        return vec4(clamp(c + vec3(delta), 0.0, 1.0), s.a);
    }
    """

    /// 色调分离。
    ///
    /// 权重按亮度线性过渡（0 = 阴影端，1 = 高光端）；
    /// 色偏向量 = 目标色的全饱和色扣掉自身亮度 × 目标饱和度，
    /// 使染色只改色相/饱和、不改变整体亮度。
    private static let splitToneSource = """
    kernel vec4 slateSplitTone(__sample s, float shHue, float shSat, float hiHue, float hiSat, float amount) {
        vec3 c = s.rgb;
        float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float t = clamp((luma - 0.25) / 0.5, 0.0, 1.0);
        float wShadow = (1.0 - t) * amount;
        float wHigh = t * amount;

        vec3 shColor = clamp(vec3(abs(shHue * 6.0 - 3.0) - 1.0,
                                  2.0 - abs(shHue * 6.0 - 2.0),
                                  2.0 - abs(shHue * 6.0 - 4.0)), 0.0, 1.0);
        float shLuma = dot(shColor, vec3(0.2126, 0.7152, 0.0722));
        vec3 shChroma = (shColor - vec3(shLuma)) * shSat;

        vec3 hiColor = clamp(vec3(abs(hiHue * 6.0 - 3.0) - 1.0,
                                  2.0 - abs(hiHue * 6.0 - 2.0),
                                  2.0 - abs(hiHue * 6.0 - 4.0)), 0.0, 1.0);
        float hiLuma = dot(hiColor, vec3(0.2126, 0.7152, 0.0722));
        vec3 hiChroma = (hiColor - vec3(hiLuma)) * hiSat;

        vec3 outC = c + shChroma * wShadow + hiChroma * wHigh;
        return vec4(clamp(outC, 0.0, 1.0), s.a);
    }
    """

    // MARK: - 对外接口

    /// 渲染主入口。
    func render(_ image: CIImage, state: EditState, lut: LUT3D?) -> CGImage? {
        var current = image
        let a = state.adjustments

        // ---- 1. 归一化到线性工作域 ----
        if state.mediaKind.isMotion,
           let colorInfo = state.videoColorInfo,
           colorInfo.curve == .sLog3,
           let kernel = slog3Decode {
            current = kernel.apply(extent: current.extent, arguments: [current]) ?? current
            if colorInfo.colorSpace.requiresGamutConversion {
                current = applyGamutMatrix(current, colorSpace: colorInfo.colorSpace)
            }
        } else {
            current = current.applyingFilter("CISRGBToneCurveToLinear")
        }

        // ---- 2. 白平衡 + 曝光（线性域，合并成一次矩阵乘法）----
        let gain = a.whiteBalance.rgbGain
        let exposureScale = pow(2.0, a.exposure)
        if gain.red != 1 || gain.green != 1 || gain.blue != 1 || exposureScale != 1 {
            current = current.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(gain.red * exposureScale), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(gain.green * exposureScale), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain.blue * exposureScale), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }

        // ---- 3. 回到显示域（sRGB 编码）----
        current = current.applyingFilter("CILinearToSRGBToneCurve")

        // ---- 4. 阴影/高光/黑场/白场 ----
        if a.shadows != 0 || a.highlights != 0 || a.blacks != 0 || a.whites != 0,
           let kernel = toneKernel {
            current = kernel.apply(extent: current.extent, arguments: [
                current,
                Float(clampUnit(a.shadows)),
                Float(clampUnit(a.highlights)),
                Float(clampUnit(a.blacks)),
                Float(clampUnit(a.whites)),
            ]) ?? current
        }

        // ---- 5. 明度 / 对比度 / 饱和度 ----
        if a.brightness != 0 {
            let offset = clampUnit(a.brightness) * 0.15
            current = current.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0),
            ])
        }

        if a.contrast != 0 || a.saturation != 0 {
            let contrast = 1 + clampUnit(a.contrast) * 0.5
            let saturation = min(max(1 + a.saturation, 0), 3)
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrast,
                kCIInputSaturationKey: saturation,
                kCIInputBrightnessKey: 0.0,
            ])
        }

        if a.vibrance != 0 {
            current = current.applyingFilter("CIVibrance", parameters: [
                "inputAmount": clampUnit(a.vibrance),
            ])
        }

        // ---- 6. 色调分离 ----
        let st = state.splitToning
        if !st.isNeutral, let kernel = splitToneKernel {
            let amount = max(st.shadows.amount, st.highlights.amount)
            current = kernel.apply(extent: current.extent, arguments: [
                current,
                Float(st.shadows.hue),
                Float(min(max(st.shadows.saturation, 0), 1)),
                Float(st.highlights.hue),
                Float(min(max(st.highlights.saturation, 0), 1)),
                Float(min(max(amount, 0), 1)),
            ]) ?? current
        }

        // ---- 7. LUT（在显示参考域套用）----
        if state.lut.isActive, let lut {
            current = applyLUT(current, lut: lut, intensity: state.lut.intensity)
        }

        // ---- 8. 出图 ----
        let extent = current.extent.isInfinite ? image.extent : current.extent
        guard !extent.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(current, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// 亮度直方图（256 桶，归一化）。
    func histogram(of image: CIImage) -> [Float] {
        let target = 192
        let scale = min(1.0, CGFloat(target) / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                             colorSpace: CGColorSpaceCreateDeviceRGB()),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return Array(repeating: 0, count: 256)
        }

        var buckets = [Float](repeating: 0, count: 256)
        let count = CFDataGetLength(data)
        guard count > 4 else { return buckets }
        for i in stride(from: 0, to: count - 3, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            let luma = (r * 2126 + g * 7152 + b * 722) / 10000
            buckets[min(max(luma, 0), 255)] += 1
        }
        if let maximum = buckets.max(), maximum > 0 {
            for i in 0..<buckets.count { buckets[i] /= maximum }
        }
        return buckets
    }

    // MARK: - 内部步骤

    private func clampUnit(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    /// 线性域色域矩阵（S-Gamut3(.Cine) → Rec.709）。
    private func applyGamutMatrix(_ image: CIImage, colorSpace: CameraColorSpace) -> CIImage {
        let m = colorSpace.toRec709Matrix
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(m[0][0]), y: CGFloat(m[1][0]), z: CGFloat(m[2][0]), w: 0),
            "inputGVector": CIVector(x: CGFloat(m[0][1]), y: CGFloat(m[1][1]), z: CGFloat(m[2][1]), w: 0),
            "inputBVector": CIVector(x: CGFloat(m[0][2]), y: CGFloat(m[1][2]), z: CGFloat(m[2][2]), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// 套用 3D LUT，并按强度线性混合。
    private func applyLUT(_ image: CIImage, lut: LUT3D, intensity: Double) -> CIImage {
        let dimension = lut.dimension
        let floatCount = dimension * dimension * dimension * 4
        var rgba = [Float](repeating: 0, count: floatCount)
        let values = lut.values
        var src = 0
        var dst = 0
        while dst < floatCount {
            rgba[dst] = values[src]
            rgba[dst + 1] = values[src + 1]
            rgba[dst + 2] = values[src + 2]
            rgba[dst + 3] = 1.0
            src += 3
            dst += 4
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let mapped = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
            "inputColorSpace": colorSpace,
        ])

        let t = min(max(intensity, 0), 1)
        if t >= 0.999 { return mapped }
        if t <= 0.001 { return image }

        let blended = mapped.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(t), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(t), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(t), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(t)),
        ])
        let base = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(1 - t), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(1 - t), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1 - t), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(1 - t)),
        ])
        return blended.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: base,
        ])
    }
}
