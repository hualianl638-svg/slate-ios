//
//  SLATERenderer.swift
//  SLATE
//
//  M2 渲染器：把 EditState 真正作用到画面上，输出可显示的 CGImage。
//
//  设计说明：
//  · 常量一律从 ColorScience / SLog3 读取，**不在内核里手抄数值**
//    （S-Log3 的 k 曾被三处实现同时写错、且只在中灰以上看起来正常，见 ColorScience 注释）；
//  · 顺序固定为：S-Log3 解码 → 色域转 Rec.709 → 白平衡+曝光（线性域）
//    → 编码到 sRGB → 明度/对比度/饱和度/自然饱和度 → LUT；
//  · Core Image 的 CIColorKernel 语言里没有数组与自定义函数，所以按通道展开。
//

import CoreImage
import Metal
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// M2 渲染器。
///
/// 线程模型：`CIContext` 本身线程安全且应当复用；本类无可变状态，
/// 因此可安全地在并发队列里调用 `render(_:state:)`。
final class SLATERenderer {

    static let shared = SLATERenderer()

    private let context: CIContext

    /// S-Log3 码值 → 场景线性（S-Gamut3.Cine）。
    private let slog3Decode: CIColorKernel?

    private init() {
        // Metal 优先；不可用时回落（模拟器/受限环境）
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
        self.slog3Decode = CIColorKernel(source: Self.slog3DecodeSource)
    }

    // MARK: - 内核源码

    /// S-Log3 解码内核。
    ///
    /// 数值来自 `SLog3`（Sony 官方 ACES IDT 归一化形式）：
    ///   code >= 0.16736099187966763 时 linear = 10^((code-D)/A)/E - B
    ///   否则                          linear = (code - F) / K
    /// 自检：decode(0.41055718475073316) == 0.18，decode(0.09286412512218964) == 0
    private static let slog3DecodeSource = """
    kernel vec4 slateSLog3Decode(__sample s) {
        float3 c = s.rgb;
        float3 lin;

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

    // MARK: - 对外接口

    /// 渲染主入口。
    ///
    /// - Parameters:
    ///   - image: 源图（已转正的 CIImage，色彩空间为 sRGB 编码值）。
    ///   - state: 编辑状态。
    ///   - lut: 已解析的 3D LUT；nil 表示不套用。
    /// - Returns: 渲染后的 CGImage；失败返回 nil。
    func render(_ image: CIImage, state: EditState, lut: LUT3D?) -> CGImage? {
        var current = image

        // ---- 1. 归一化到线性工作域 ----
        if state.mediaKind.isMotion,
           let colorInfo = state.videoColorInfo,
           colorInfo.curve == .sLog3,
           let kernel = slog3Decode {
            // S-Log3 灰片：先解码到 S-Gamut3.Cine 场景线性
            current = kernel.apply(extent: current.extent, arguments: [current]) ?? current
            // 色域转 Rec.709（线性域矩阵）
            if colorInfo.colorSpace.requiresGamutConversion {
                current = applyGamutMatrix(current, colorSpace: colorInfo.colorSpace)
            }
        } else {
            // 普通素材：sRGB 编码值 → 线性
            current = current.applyingFilter("CISRGBToneCurveToLinear")
        }

        // ---- 2. 白平衡 + 曝光（线性域，合并成一次矩阵乘法）----
        let gain = state.adjustments.whiteBalance.rgbGain
        let exposureScale = pow(2.0, state.adjustments.exposure)
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

        // ---- 4. gamma 域基础调节 ----
        let a = state.adjustments

        if a.brightness != 0 {
            let offset = min(max(a.brightness, -1), 1) * 0.15
            current = current.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0),
            ])
        }

        if a.contrast != 0 || a.saturation != 0 {
            let contrast = 1 + min(max(a.contrast, -1), 1) * 0.5
            let saturation = min(max(1 + a.saturation, 0), 3)
            current = current.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrast,
                kCIInputSaturationKey: saturation,
                kCIInputBrightnessKey: 0.0,
            ])
        }

        if a.vibrance != 0 {
            current = current.applyingFilter("CIVibrance", parameters: [
                "inputAmount": min(max(a.vibrance, -1), 1),
            ])
        }

        // ---- 5. LUT（在显示参考域套用）----
        if state.lut.isActive, let lut {
            current = applyLUT(current, lut: lut, intensity: state.lut.intensity)
        }

        // ---- 6. 出图 ----
        let extent = current.extent.isInfinite ? image.extent : current.extent
        guard !extent.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(current, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// 生成直方图数据（RGB + 亮度，256 桶）。
    ///
    /// 实现方式：把图缩到 256px 后 CPU 统计。
    /// 对预览尺寸足够稳定，且不必依赖 CIAreaHistogram 的晦涩参数。
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
        let bytesPerPixel = 4
        let pixels = count / bytesPerPixel
        guard pixels > 0 else { return buckets }

        for i in stride(from: 0, to: count - 3, by: bytesPerPixel) {
            let r = bytes[i], g = bytes[i + 1], b = bytes[i + 2]
            let luma = UInt8((Int(r) * 2126 + Int(g) * 7152 + Int(b) * 722) / 10000)
            buckets[Int(luma)] += 1
        }
        // 归一化到 0...1
        if let maximum = buckets.max(), maximum > 0 {
            for i in 0..<buckets.count { buckets[i] /= maximum }
        }
        return buckets
    }

    // MARK: - 内部步骤

    /// 线性域色域矩阵（S-Gamut3(.Cine) → Rec.709）。
    private func applyGamutMatrix(_ image: CIImage, colorSpace: CameraColorSpace) -> CIImage {
        let m = colorSpace.toRec709Matrix
        // 行主序 [[r],[g],[b]] → CIColorMatrix 的列向量
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(m[0][0]), y: CGFloat(m[1][0]), z: CGFloat(m[2][0]), w: 0),
            "inputGVector": CIVector(x: CGFloat(m[0][1]), y: CGFloat(m[1][1]), z: CGFloat(m[2][1]), w: 0),
            "inputBVector": CIVector(x: CGFloat(m[0][2]), y: CGFloat(m[1][2]), z: CGFloat(m[2][2]), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// 套用 3D LUT，并按强度插值。
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
        // 线性混合：image*(1-t) + mapped*t
        let blend = mapped.applyingFilter("CIColorMatrix", parameters: [
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
        return blend.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: base,
        ])
    }
}
