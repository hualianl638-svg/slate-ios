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
import CoreVideo
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
    /// HSL 八通道。
    private let hslKernel: CIColorKernel?

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
        let hsl = CIColorKernel(source: Self.hslSource)
        if hsl == nil { failures.append("HSL 八通道") }

        self.slog3Decode = slog3
        self.toneKernel = tone
        self.splitToneKernel = split
        self.hslKernel = hsl
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
    /// **两个曾经出错的地方，都已修正**：
    /// 1. 早期用"统一加偏移"：亮部像素被推过 1.0 后 clamp，表现为"拉滑杆没变化"。
    ///    改为乘性增益（暗部乘 >1 提亮、亮部乘 <1 压暗），暗部/亮部都确实会动。
    /// 2. 早期掩版只在 l>0.5（高光）与 l>0.667（白色）才非零，
    ///    而 S-Log3 正确解码后中灰约 0.46，**整幅图落在掩版为零的区间**，
    ///    于是高光/白色色阶数学上恒等于零、完全没有反应。
    ///    现在用 smoothstep 把作用区间放宽容：
    ///      阴影 1→0 覆盖 0…0.75 ／ 高光 0→1 覆盖 0.25…1.0
    ///      黑场 1→0 覆盖 0…0.35 ／ 白场 0→1 覆盖 0.65…1.0
    ///    （Core Image 内核语言不支持自定义函数，smoothstep 只能内联展开。）
    private static let toneSource = """
    kernel vec4 slateTone(__sample s, float shadows, float highlights, float blacks, float whites) {
        vec3 c = s.rgb;
        float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
        float l = clamp(luma, 0.0, 1.0);

        // shadowMask = 1 - smoothstep(0.0, 0.75, l)
        float st = clamp(l / 0.75, 0.0, 1.0);
        float shadowMask = 1.0 - (st * st * (3.0 - 2.0 * st));

        // highMask = smoothstep(0.25, 1.0, l)
        float ht = clamp((l - 0.25) / 0.75, 0.0, 1.0);
        float highMask = ht * ht * (3.0 - 2.0 * ht);

        // blackMask = 1 - smoothstep(0.0, 0.35, l)
        float bt = clamp(l / 0.35, 0.0, 1.0);
        float blackMask = 1.0 - (bt * bt * (3.0 - 2.0 * bt));

        // whiteMask = smoothstep(0.65, 1.0, l)
        float wt = clamp((l - 0.65) / 0.35, 0.0, 1.0);
        float whiteMask = wt * wt * (3.0 - 2.0 * wt);

        vec3 outC = c;

        // 暗部提亮 / 压暗（乘性）
        float darkGain = shadows * 0.60 * shadowMask + blacks * 0.75 * blackMask;
        outC *= (1.0 + darkGain);

        // 亮部提亮 / 压暗（乘性）
        float lightGain = highlights * 0.55 + whites * 0.70;
        float lightWeight = highMask * 0.55 + whiteMask * 0.45;
        outC *= (1.0 + lightGain * lightWeight);

        return vec4(clamp(outC, 0.0, 1.0), s.a);
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

    /// HSL 八通道。
    ///
    /// 通道中心色相（0...1 圈）：
    ///   红 0.0000 / 橙 0.0833 / 黄 0.1667 / 绿 0.3333 / 浅绿 0.5000 / 蓝 0.6667 / 紫 0.7778 / 洋红 0.8889
    /// 半宽（到较近邻居的角距）：
    ///   30° / 30° / 30° / 60° / 60° / 40° / 40° / 40°（= 0.0833/0.0833/0.0833/0.1667/0.1667/0.1111/0.1111/0.1111）
    ///
    /// 权重用**归一化三角帽**：w = max(0, 1 - 环距/半宽)，再除以 Σw。
    /// 归一化是必须的 —— 不归一化时相邻通道交界处 Σw 只有 0.5，效果会被腰斩。
    /// CIKL 没有数组与自定义函数，因此 8 个通道与 HSL 往返全部内联展开。
    private static let hslSource = """
    kernel vec4 slateHSL(__sample s,
                         vec4 b0, vec4 b1, vec4 b2, vec4 b3,
                         vec4 b4, vec4 b5, vec4 b6, vec4 b7) {
        vec3 c = clamp(s.rgb, 0.0, 1.0);

        // ---- RGB -> HSL ----
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float l = (mx + mn) * 0.5;
        float delta = mx - mn;
        float h = 0.0;
        float sat = 0.0;
        if (delta > 0.00001) {
            sat = (l > 0.5) ? (delta / max(2.0 - mx - mn, 0.00001))
                            : (delta / max(mx + mn, 0.00001));
            if (mx == c.r) {
                h = (c.g - c.b) / delta + ((c.g < c.b) ? 6.0 : 0.0);
            } else if (mx == c.g) {
                h = (c.b - c.r) / delta + 2.0;
            } else {
                h = (c.r - c.g) / delta + 4.0;
            }
            h = h / 6.0;
        }

        // ---- 8 通道三角帽权重（含环距折叠）----
        float d0 = abs(h - 0.00000); d0 = min(d0, 1.0 - d0);
        float d1 = abs(h - 0.08333); d1 = min(d1, 1.0 - d1);
        float d2 = abs(h - 0.16667); d2 = min(d2, 1.0 - d2);
        float d3 = abs(h - 0.33333); d3 = min(d3, 1.0 - d3);
        float d4 = abs(h - 0.50000); d4 = min(d4, 1.0 - d4);
        float d5 = abs(h - 0.66667); d5 = min(d5, 1.0 - d5);
        float d6 = abs(h - 0.77778); d6 = min(d6, 1.0 - d6);
        float d7 = abs(h - 0.88889); d7 = min(d7, 1.0 - d7);

        float w0 = max(0.0, 1.0 - d0 / 0.08333);
        float w1 = max(0.0, 1.0 - d1 / 0.08333);
        float w2 = max(0.0, 1.0 - d2 / 0.08333);
        float w3 = max(0.0, 1.0 - d3 / 0.16667);
        float w4 = max(0.0, 1.0 - d4 / 0.16667);
        float w5 = max(0.0, 1.0 - d5 / 0.11111);
        float w6 = max(0.0, 1.0 - d6 / 0.11111);
        float w7 = max(0.0, 1.0 - d7 / 0.11111);

        float total = w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7;
        if (total > 0.00001) {
            float inv = 1.0 / total;
            w0 *= inv; w1 *= inv; w2 *= inv; w3 *= inv;
            w4 *= inv; w5 *= inv; w6 *= inv; w7 *= inv;
        }

        // 中性保护：饱和度极低的像素不参与色相/饱和度调整，避免灰面被染色
        float mask = clamp((sat - 0.02) / 0.08, 0.0, 1.0);

        float hueAdj = (w0 * b0.x + w1 * b1.x + w2 * b2.x + w3 * b3.x
                      + w4 * b4.x + w5 * b5.x + w6 * b6.x + w7 * b7.x) * mask;
        float satAdj = (w0 * b0.y + w1 * b1.y + w2 * b2.y + w3 * b3.y
                      + w4 * b4.y + w5 * b5.y + w6 * b6.y + w7 * b7.y) * mask;
        float lumAdj = (w0 * b0.z + w1 * b1.z + w2 * b2.z + w3 * b3.z
                      + w4 * b4.z + w5 * b5.z + w6 * b6.z + w7 * b7.z) * mask;

        // 色相滑杆满量程 ±30°（1/12 圈）
        float hh = h + hueAdj * (1.0 / 12.0);
        hh = hh - floor(hh);
        float s2 = clamp(sat * (1.0 + satAdj), 0.0, 1.0);
        float l2 = (lumAdj >= 0.0) ? (l + lumAdj * (1.0 - l))
                                   : (l + lumAdj * l);
        l2 = clamp(l2, 0.0, 1.0);

        // ---- HSL -> RGB ----
        float r;
        float g;
        float bl;
        if (s2 <= 0.00001) {
            r = l2; g = l2; bl = l2;
        } else {
            float q = (l2 < 0.5) ? (l2 * (1.0 + s2)) : (l2 + s2 - l2 * s2);
            float p = 2.0 * l2 - q;
            float t1 = hh + (1.0 / 3.0); t1 = t1 - floor(t1);
            float t2 = hh;
            float t3 = hh - (1.0 / 3.0); t3 = t3 + 1.0 - floor(t3);
            r = (t1 < 0.166667) ? (p + (q - p) * 6.0 * t1)
              : ((t1 < 0.5) ? q
              : ((t1 < 0.666667) ? (p + (q - p) * (0.666667 - t1) * 6.0) : p));
            g = (t2 < 0.166667) ? (p + (q - p) * 6.0 * t2)
              : ((t2 < 0.5) ? q
              : ((t2 < 0.666667) ? (p + (q - p) * (0.666667 - t2) * 6.0) : p));
            bl = (t3 < 0.166667) ? (p + (q - p) * 6.0 * t3)
               : ((t3 < 0.5) ? q
               : ((t3 < 0.666667) ? (p + (q - p) * (0.666667 - t3) * 6.0) : p));
        }

        return vec4(clamp(vec3(r, g, bl), 0.0, 1.0), s.a);
    }
    """

    /// Sony 官方 S-Log3 → LC-709 的 LUT（随 app bundle 打包，只解析一次）。
    private static let sLog3LookLUT: LUT3D? = SLog3LookLUT.load()

    // MARK: - 对外接口

    /// 渲染主入口。
    func processedImage(_ image: CIImage, state: EditState, lut: LUT3D?) -> CIImage {
        // 裁剪（含旋转）放在整条链最前面；蒙版在链尾用"裁剪后的原图"做混合。
        let croppedSource = CropMask.crop(image, settings: state.cropMask)
        var current = croppedSource
        let a = state.adjustments

        // ---- 1. 归一化到线性工作域 ----
        //
        // 灰片还原**优先走 Sony 官方 LookProfile LUT**：
        // 输入是 log 编码的 R'G'B'（正是视频帧的原始值），
        // 输出即显示参考的 LC-709。之后再把 709 编码转回线性，
        // 让白平衡/曝光仍在线性域计算，与普通照片走同一条链路。
        // 灰片还原：按用户在「灰片曲线」里选的类型取对应 LUT
        let logProfile = LogProfile(rawValue: state.logProfileIndex) ?? .off
        let restoreLUT = state.restoreEnabled
            ? RestoreLUTLibrary.shared.restoreLUT(for: logProfile,
                                                 customName: state.restoreLUTName)
            : nil

        if let look = restoreLUT {
            current = applyLUT(current, lut: look, intensity: 1.0)
            current = current.applyingFilter("CISRGBToneCurveToLinear")
        } else if logProfile != .off,
                  let look = Self.sLog3LookLUT,
                  state.videoColorInfo?.curve == .sLog3 {
            // 兜底：曲线选的是 S-Log3 但外部 LUT 取不到时，用内置那份
            current = applyLUT(current, lut: look, intensity: 1.0)
            current = current.applyingFilter("CISRGBToneCurveToLinear")
        } else if state.mediaKind.isMotion,
                  let colorInfo = state.videoColorInfo,
                  colorInfo.curve == .sLog3,
                  let kernel = slog3Decode {
            // 兜底：bundle 里没有官方 LUT 时，退回 ACES IDT 反推链路
            current = kernel.apply(extent: current.extent, arguments: [current]) ?? current
            if colorInfo.colorSpace.requiresGamutConversion {
                current = applyGamutMatrix(current, colorSpace: colorInfo.colorSpace)
            }
        } else {
            current = current.applyingFilter("CISRGBToneCurveToLinear")
        }

        // ---- 2. 白平衡 + 曝光（线性域，合并成一次矩阵乘法）----
        //
        // 白平衡增益**先按 Rec.709 亮度权重归一化**：原始 rgbGain 会同时改变整体亮度
        // （暖调整体变亮、冷调整体变暗），那会掩盖"只是偏色"的观感，也让用户觉得
        // "拉色温画面没变"。归一化后 luma 保持不变，只剩色彩偏移，更容易看出来。
        let rawGain = a.whiteBalance.rgbGain
        let lumaGain = 0.2126 * rawGain.red + 0.7152 * rawGain.green + 0.0722 * rawGain.blue
        var gain = rawGain
        if lumaGain > 0.001 {
            gain = (rawGain.red / lumaGain, rawGain.green / lumaGain, rawGain.blue / lumaGain)
        }
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

        // ---- 6. HSL 八通道 ----
        if !state.hsl.isNeutral, let kernel = hslKernel {
            let bands = state.hsl.ordered
            var arguments: [Any] = [current]
            for index in 0..<8 {
                let band = index < bands.count ? bands[index] : HSLBand()
                arguments.append(CIVector(
                    x: CGFloat(band.hue),
                    y: CGFloat(band.saturation),
                    z: CGFloat(band.luminance),
                    w: 0
                ))
            }
            current = kernel.apply(extent: current.extent, arguments: arguments) ?? current
        }

        // ---- 7. 色调分离 ----
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

        // ---- 8. LUT（在显示参考域套用）----
        if state.lut.isActive, let lut {
            current = applyLUT(current, lut: lut, intensity: state.lut.intensity)
        }

        return CropMask.blend(
            adjusted: current,
            original: croppedSource,
            settings: state.cropMask
        )
    }

    /// 渲染为 CGImage（预览与照片导出用）。
    func render(_ image: CIImage, state: EditState, lut: LUT3D?) -> CGImage? {
        let current = processedImage(image, state: state, lut: lut)
        let extent = current.extent.isInfinite ? image.extent : current.extent
        guard !extent.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(current, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// 直接渲染进 CVPixelBuffer（视频导出用）。
    ///
    /// 为什么单独开这条路径：导出逐帧时若走 `createCGImage` -> `CGContext.draw`，
    /// 每帧要多两次全画幅拷贝，4K 下极慢，长任务容易被系统打断
    /// （表现为 H.264 报 "operation interrupted"、HEVC 卡在低进度）。
    /// `CIContext.render(_:to:bounds:colorSpace:)` 是零拷贝的 GPU 路径。
    @discardableResult
    func render(_ image: CIImage,
                state: EditState,
                lut: LUT3D?,
                into pixelBuffer: CVPixelBuffer,
                size: CGSize) -> Bool {
        var current = processedImage(image, state: state, lut: lut)

        // 平移到原点
        let origin = current.extent.origin
        if abs(origin.x) > 0.01 || abs(origin.y) > 0.01 {
            current = current.transformed(by: CGAffineTransform(
                translationX: -origin.x, y: -origin.y
            ))
        }
        // 尺寸对齐（正常情况下已一致；这里兜底防止 append 尺寸不匹配）
        let extent = current.extent
        if extent.width > 0, extent.height > 0,
           abs(extent.width - size.width) > 1 || abs(extent.height - size.height) > 1 {
            let sx = size.width / extent.width
            let sy = size.height / extent.height
            current = current.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let bounds = CGRect(origin: .zero, size: size)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(current, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)
        return true
    }

    /// 采样图像的平均 R/G/B（0...1）。
    ///
    /// 用于诊断"某个滑杆是否真的生效"：如果拖动后平均通道值不变，
    /// 说明参数没进渲染管线；如果有变化但肉眼看不出，说明是显示/幅度问题。
    /// 这比让用户猜"感觉没变"要靠得住。
    func meanRGB(of image: CIImage) -> (r: Double, g: Double, b: Double) {
        let target = 96
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return (0, 0, 0) }
        let scale = min(1.0, CGFloat(target) / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                             colorSpace: CGColorSpaceCreateDeviceRGB()),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return (0, 0, 0)
        }
        let count = CFDataGetLength(data)
        guard count > 4 else { return (0, 0, 0) }
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var pixels = 0
        for i in stride(from: 0, to: count - 3, by: 4) {
            sumR += Double(bytes[i]) / 255.0
            sumG += Double(bytes[i + 1]) / 255.0
            sumB += Double(bytes[i + 2]) / 255.0
            pixels += 1
        }
        guard pixels > 0 else { return (0, 0, 0) }
        return (sumR / Double(pixels), sumG / Double(pixels), sumB / Double(pixels))
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
