//
//  CropMaskOverlays.swift
//  SLATE
//
//  预览上直接拖手柄改裁剪框 / 蒙版范围（原型交互）。
//

import SwiftUI

// MARK: - 裁剪手柄

struct CropOverlay: View {

    @Binding var settings: CropMaskSettings
    /// 源图宽高比（像素），比例锁定时必须用它把归一化尺寸换算成真实比例。
    var sourceAspect: CGFloat
    var onChange: () -> Void

    @State private var startRect: CGRect?

    private let handle: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = viewRect(in: size)

            ZStack(alignment: .topLeading) {
                // 框外压暗
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // 三分线
                Path { path in
                    for i in 1...2 {
                        let x = rect.minX + rect.width * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                        let y = rect.minY + rect.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: rect.minX, y: y))
                        path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)

                // 边框
                Rectangle()
                    .strokeBorder(.white.opacity(0.95), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                // 内部拖动 = 移动框
                Rectangle()
                    .fill(.white.opacity(0.001))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(size: size))

                // 四角手柄 = 缩放框
                corner(.topLeft, at: CGPoint(x: rect.minX, y: rect.minY), size: size)
                corner(.topRight, at: CGPoint(x: rect.maxX, y: rect.minY), size: size)
                corner(.bottomLeft, at: CGPoint(x: rect.minX, y: rect.maxY), size: size)
                corner(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY), size: size)
            }
        }
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func corner(_ corner: Corner, at point: CGPoint, size: CGSize) -> some View {
        Circle()
            .fill(.white)
            .frame(width: handle * 0.7, height: handle * 0.7)
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .frame(width: handle, height: handle)
            .contentShape(Rectangle())
            .position(point)
            .gesture(resizeGesture(corner: corner, size: size))
    }

    // MARK: 几何

    private func viewRect(in size: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(settings.cropX) * size.width,
            y: CGFloat(settings.cropY) * size.height,
            width: CGFloat(settings.cropWidth) * size.width,
            height: CGFloat(settings.cropHeight) * size.height
        )
    }

    // MARK: 手势

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = startRect ?? currentRect()
                if startRect == nil { startRect = start }
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)
                var rect = start
                rect.origin.x = min(max(start.minX + dx, 0), 1 - start.width)
                rect.origin.y = min(max(start.minY + dy, 0), 1 - start.height)
                apply(rect)
            }
            .onEnded { _ in
                startRect = nil
                onChange()
            }
    }

    private func resizeGesture(corner: Corner, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = startRect ?? currentRect()
                if startRect == nil { startRect = start }
                let dx = value.translation.width / max(size.width, 1)
                let dy = value.translation.height / max(size.height, 1)

                var minX = start.minX
                var minY = start.minY
                var maxX = start.maxX
                var maxY = start.maxY

                switch corner {
                case .topLeft:     minX += dx; minY += dy
                case .topRight:    maxX += dx; minY += dy
                case .bottomLeft:  minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }

                // 最小尺寸，避免翻转
                let minSize = 0.08
                if maxX - minX < minSize { maxX = minX + minSize }
                if maxY - minY < minSize { maxY = minY + minSize }
                minX = min(max(minX, 0), 1 - minSize)
                minY = min(max(minY, 0), 1 - minSize)
                maxX = min(max(maxX, minSize), 1)
                maxY = min(max(maxY, minSize), 1)

                var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if let ratio = settings.aspectRatio {
                    // 比例锁定：归一化高 = 归一化宽 × 源图宽高比 / 目标比例
                    // （像素比例 A = w·W / (h·H)  =>  h = w · (W/H) / A）
                    let targetHeight = rect.width * sourceAspect / max(ratio, 0.0001)
                    if corner == .topLeft || corner == .topRight {
                        rect.origin.y = max(0, rect.maxY - targetHeight)
                        rect.size.height = min(targetHeight, rect.maxY)
                    } else {
                        rect.size.height = min(targetHeight, 1 - rect.minY)
                    }
                }
                apply(rect)
            }
            .onEnded { _ in
                startRect = nil
                onChange()
            }
    }

    private func currentRect() -> CGRect {
        CGRect(
            x: CGFloat(settings.cropX),
            y: CGFloat(settings.cropY),
            width: CGFloat(settings.cropWidth),
            height: CGFloat(settings.cropHeight)
        )
    }

    private func apply(_ rect: CGRect) {
        var next = settings
        next.cropX = Double(rect.minX)
        next.cropY = Double(rect.minY)
        next.cropWidth = Double(rect.width)
        next.cropHeight = Double(rect.height)
        settings = next
    }
}

// MARK: - 蒙版手柄

struct MaskOverlay: View {

    @Binding var settings: CropMaskSettings
    var onChange: () -> Void

    @State private var dragStartCenter: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(
                x: CGFloat(settings.centerX) * size.width,
                y: CGFloat(settings.centerY) * size.height
            )

            ZStack(alignment: .topLeading) {
                if settings.maskKind == 2 {
                    let radius = CGFloat(settings.radius) * min(size.width, size.height) * 0.5
                    // 内圈（强度满）与外圈（羽化边界）
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 1)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                        .allowsHitTesting(false)
                    Circle()
                        .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: radius * 2 * max(0.01, 1 - CGFloat(settings.feather)),
                               height: radius * 2 * max(0.01, 1 - CGFloat(settings.feather)))
                        .position(center)
                        .allowsHitTesting(false)

                    // 半径手柄
                    handleDot
                        .position(x: center.x + radius, y: center.y)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let dx = value.location.x - center.x
                                    let dy = value.location.y - center.y
                                    let distance = sqrt(dx * dx + dy * dy)
                                    let normalized = Double(distance / max(min(size.width, size.height) * 0.5, 1))
                                    var next = settings
                                    next.radius = min(max(normalized, 0.02), 1)
                                    settings = next
                                }
                                .onEnded { _ in onChange() }
                        )
                } else {
                    // 线性：过中心的线，端点可拖动改角度
                    let angle = CGFloat(settings.angle) * .pi / 180
                    let span = max(size.width, size.height)
                    let p0 = CGPoint(x: center.x - cos(angle) * span, y: center.y - sin(angle) * span)
                    let p1 = CGPoint(x: center.x + cos(angle) * span, y: center.y + sin(angle) * span)

                    Path { path in
                        path.move(to: p0)
                        path.addLine(to: p1)
                    }
                    .stroke(.white.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)

                    handleDot
                        .position(p1)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let dx = value.location.x - center.x
                                    let dy = value.location.y - center.y
                                    let degrees = atan2(dy, dx) * 180 / .pi
                                    var next = settings
                                    next.angle = Double(degrees < 0 ? degrees + 360 : degrees)
                                    settings = next
                                }
                                .onEnded { _ in onChange() }
                        )
                }

                // 中心手柄：拖动移动蒙版中心
                handleDot
                    .position(center)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                var next = settings
                                next.centerX = Double(min(max(value.location.x / max(size.width, 1), 0), 1))
                                next.centerY = Double(min(max(value.location.y / max(size.height, 1), 0), 1))
                                settings = next
                            }
                            .onEnded { _ in onChange() }
                    )
            }
        }
        // 蒙版区域外的点击交给下层，不影响预览
        .allowsHitTesting(true)
    }

    private var handleDot: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: 34, height: 34)
            .contentShape(Circle())
    }
}
