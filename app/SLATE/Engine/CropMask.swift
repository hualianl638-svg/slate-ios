//
//  CropMask.swift
//  SLATE
//
//  裁剪与蒙版：作为 EditState 的一部分，让照片/视频/导出共用同一套设置。
//
//  裁剪框用**归一化矩形**（0...1，相对旋转后的源图）表示，
//  这样预览上拖手柄时可以直接把位移换算成比例，不需要知道像素尺寸。
//

import CoreImage
import Foundation

public struct CropMaskSettings: Equatable, Codable, Sendable {

    // MARK: 裁剪（归一化矩形）
    public var cropX: Double = 0
    public var cropY: Double = 0
    public var cropWidth: Double = 1
    public var cropHeight: Double = 1
    /// 比例锁定：0 自由 / 1 → 1:1 / 2 → 4:3 / 3 → 16:9 / 4 → 9:16。
    public var aspectLock: Int = 0
    /// 旋转 90° 次数 0...3。
    public var turns: Int = 0
    /// 编辑裁剪时临时绕过裁剪，让预览显示完整画面（导出前会复位）。
    public var bypassCrop: Bool = false

    // MARK: 蒙版
    /// 0 关 / 1 线性 / 2 径向。
    public var maskKind: Int = 0
    public var centerX: Double = 0.5
    public var centerY: Double = 0.5
    /// 线性角度（度）。
    public var angle: Double = 90
    /// 径向半径（相对短边，0...1）。
    public var radius: Double = 0.55
    public var feather: Double = 0.35
    public var strength: Double = 1
    public var invert: Bool = false

    public init() {}

    public var isCropActive: Bool {
        cropWidth < 0.999 || cropHeight < 0.999
            || cropX > 0.001 || cropY > 0.001
            || turns % 4 != 0
    }

    public var isMaskActive: Bool { maskKind != 0 && strength > 0.001 }

    /// 比例锁定的目标宽高比（nil = 自由）。
    public var aspectRatio: CGFloat? {
        switch aspectLock {
        case 1: return 1
        case 2: return 4.0 / 3.0
        case 3: return 16.0 / 9.0
        case 4: return 9.0 / 16.0
        default: return nil
        }
    }
}

enum CropMask {

    static func crop(_ image: CIImage, settings: CropMaskSettings) -> CIImage {
        var source = image
        let turns = ((settings.turns % 4) + 4) % 4
        if turns != 0 {
            let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            source = source.oriented(orientations[turns])
        }
        guard !settings.bypassCrop else { return source }
        guard settings.isCropActive else { return source }

        let extent = source.extent
        guard extent.width > 1, extent.height > 1 else { return source }

        let rect = CGRect(
            x: extent.minX + extent.width * CGFloat(min(max(settings.cropX, 0), 1)),
            y: extent.minY + extent.height * CGFloat(min(max(settings.cropY, 0), 1)),
            width: extent.width * CGFloat(min(max(settings.cropWidth, 0.02), 1)),
            height: extent.height * CGFloat(min(max(settings.cropHeight, 0.02), 1))
        )
        // 注意：不要再用 .integral 做像素扩边。
        // 扩边会让实际裁剪宽高比与用户看到/设定的框产生 1~2px 偏差，
        // 在 1:1 等锁定比例下表现为看起来不是正方形。
        .intersection(extent)

        guard rect.width > 1, rect.height > 1 else { return source }

        return source
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
    }

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
            let angle = CGFloat(settings.angle) * .pi / 180
            let span = max(extent.width, extent.height) * 0.75
            let dx = cos(angle) * span
            let dy = sin(angle) * span
            mask = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x + dx, y: center.y + dy),
                "inputPoint1": CIVector(x: center.x - dx, y: center.y - dy),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])?.outputImage ?? CIImage(color: .white)
        } else {
            let base = min(extent.width, extent.height) * 0.5
                * CGFloat(min(max(settings.radius, 0.02), 1))
            let feather = CGFloat(min(max(settings.feather, 0), 1))
            mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": base * max(0.01, 1 - feather),
                "inputRadius1": base,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])?.outputImage ?? CIImage(color: .white)
        }

        mask = mask.cropped(to: extent)
        if settings.feather > 0.001 {
            mask = mask.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: settings.feather * CGFloat(min(extent.width, extent.height)) * 0.1,
                ])
                .cropped(to: extent)
        }
        if settings.invert {
            mask = mask.applyingFilter("CIColorInvert")
        }

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
