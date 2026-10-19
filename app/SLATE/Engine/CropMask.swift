//
//  CropMask.swift
//  SLATE
//
//  裁剪与蒙版：作为 EditState 的一部分，保证照片/视频/导出走同一套管线。
//

import CoreImage
import Foundation

/// 裁剪与蒙版设置。
public struct CropMaskSettings: Equatable, Codable, Sendable {

    /// 裁剪比例：0 原始 / 1 1:1 / 2 4:3 / 3 16:9 / 4 9:16。
    public var aspect: Int = 0
    /// 缩放 1...3（在选定比例内进一步裁切）。
    public var zoom: Double = 1
    /// 画面中心偏移 -1...1。
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    /// 旋转 90° 的次数 0...3。
    public var turns: Int = 0

    /// 蒙版类型：0 关 / 1 线性 / 2 径向。
    public var maskKind: Int = 0
    public var centerX: Double = 0.5
    public var centerY: Double = 0.5
    /// 线性蒙版角度（度）。
    public var angle: Double = 90
    /// 径向蒙版半径 0.05...1（相对短边）。
    public var radius: Double = 0.55
    /// 羽化 0...1。
    public var feather: Double = 0.35
    /// 强度 0...1。
    public var strength: Double = 1
    public var invert: Bool = false

    public init() {}

    public var isCropActive: Bool {
        aspect != 0 || zoom > 1.001 || abs(offsetX) > 0.001 || abs(offsetY) > 0.001 || turns % 4 != 0
    }

    public var isMaskActive: Bool {
        maskKind != 0 && strength > 0.001
    }
}

enum CropMask {

    /// 按设置裁剪（先旋转、再按比例裁、最后把原点搬回 0）。
    static func crop(_ image: CIImage, settings: CropMaskSettings) -> CIImage {
        var source = image
        let turns = ((settings.turns % 4) + 4) % 4
        if turns != 0 {
            let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            source = source.oriented(orientations[turns])
        }
        guard settings.isCropActive else { return source }

        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return source }

        var targetAspect: CGFloat
        switch settings.aspect {
        case 1: targetAspect = 1
        case 2: targetAspect = 4.0 / 3.0
        case 3: targetAspect = 16.0 / 9.0
        case 4: targetAspect = 9.0 / 16.0
        default: targetAspect = extent.width / extent.height
        }

        var width = extent.width
        var height = extent.height
        if width / height > targetAspect {
            width = height * targetAspect
        } else {
            height = width / targetAspect
        }
        let zoom = min(max(settings.zoom, 1), 3)
        width /= CGFloat(zoom)
        height /= CGFloat(zoom)

        let maxShiftX = (extent.width - width) / 2
        let maxShiftY = (extent.height - height) / 2
        let centerX = extent.midX + CGFloat(min(max(settings.offsetX, -1), 1)) * maxShiftX
        let centerY = extent.midY + CGFloat(min(max(settings.offsetY, -1), 1)) * maxShiftY

        var rect = CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        ).integral
        rect = rect.intersection(extent)
        guard rect.width > 1, rect.height > 1 else { return source }

        return source
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
    }

    /// 用蒙版把"调节后"和"调节前（已裁剪）"混合起来。
    static func blend(adjusted: CIImage, original: CIImage, settings: CropMaskSettings) -> CIImage {
        guard settings.isMaskActive else { return adjusted }
        let extent = original.extent
        guard extent.width > 1, extent.height > 1 else { return adjusted }

        let center = CGPoint(
            x: extent.minX + extent.width * CGFloat(min(max(settings.centerX, 0), 1)),
            y: extent.minY + extent.height * CGFloat(min(max(settings.centerY, 0), 1))
        )

        var mask: CIImage
        if settings.maskKind == 1 {
            // 线性：沿角度方向的明暗渐变
            let angle = CGFloat(settings.angle) * .pi / 180
            let span = max(extent.width, extent.height) * 0.75
            let dx = cos(angle) * span
            let dy = sin(angle) * span
            let filter = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x + dx, y: center.y + dy),
                "inputPoint1": CIVector(x: center.x - dx, y: center.y - dy),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            mask = filter?.outputImage ?? CIImage(color: .white)
        } else {
            // 径向：中心亮、边缘暗
            let base = min(extent.width, extent.height) * 0.5 * CGFloat(min(max(settings.radius, 0.05), 1))
            let feather = CGFloat(min(max(settings.feather, 0), 1))
            let filter = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": base * max(0.01, 1 - feather),
                "inputRadius1": base,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            mask = filter?.outputImage ?? CIImage(color: .white)
        }

        mask = mask.cropped(to: extent)

        // 羽化（线性也要能柔化边缘）
        if settings.feather > 0.001 {
            mask = mask.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: settings.feather * CGFloat(min(extent.width, extent.height)) * 0.12,
                ])
                .cropped(to: extent)
        }

        if settings.invert {
            mask = mask.applyingFilter("CIColorInvert")
        }

        // 强度：压低蒙版亮度 = 向原图方向回退
        let strength = CGFloat(min(max(settings.strength, 0), 1))
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        return adjusted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: original,
            kCIInputMaskImageKey: mask,
        ])
    }
}
