//
//  VideoPlayback.swift
//  SLATE
//
//  视频预览播放器：AVPlayer 输出帧 → Core Image 调色 → 显示。
//
//  设计取舍（为什么不是"直接播放 AVPlayerLayer"）：
//  AVPlayerLayer 播放的是原始画面，套不上调色。要"边播边看到调色结果"，
//  必须自己取帧、逐帧渲染。逐帧渲染 4K 来不及，因此预览帧缩到 900 px 以内，
//  播放时按 ~12 fps 丢帧渲染，暂停时再按当前帧全质量重渲一次。
//

import AVFoundation
import Combine
import ImageIO
import CoreImage
import SwiftUI
import UIKit

@MainActor
final class VideoPlayback: ObservableObject {

    @Published private(set) var frame: UIImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isMuted = false
    /// 跳过调色（长按「对比」时显示原片）。
    var bypassGrading = false
    /// 选段裁剪区间（0...1），播放到终点自动回到起点。
    private var trimStartFraction: Double = 0
    private var trimEndFraction: Double = 1

    func applyTrim(start: Double, end: Double) {
        trimStartFraction = min(max(start, 0), 1)
        trimEndFraction = min(max(end, trimStartFraction + 0.02), 1)
    }

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var transform: CGAffineTransform = .identity
    private var timer: Timer?
    private var timeObserver: Any?
    private var isRendering = false
    private var pendingRefresh = false
    private var stateProvider: (() -> (EditState, LUT3D?))?

    private let renderer = SLATERenderer.shared
    private let context = CIContext()

    /// 预览渲染的最大边长（越大越清晰、越慢）。
    private let previewMaxEdge: CGFloat = 900

    // MARK: 配置

    func configure(url: URL, stateProvider: @escaping () -> (EditState, LUT3D?)) {
        self.stateProvider = stateProvider
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        self.item = item
        self.output = output
        self.player = player
        self.duration = CMTimeGetSeconds(asset.duration)

        // 朝向与尺寸（异步加载）
        Task { [weak self] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let loadedTransform = try? await track.load(.preferredTransform) else { return }
            self?.transform = loadedTransform
            self?.renderCurrentFrame(force: true)
        }

        // 时间观察：更新进度条
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            self.currentTime = seconds

            // 播放到选段终点 -> 回到起点继续（循环预览）
            if self.isPlaying, self.duration > 0 {
                let endTime = self.duration * self.trimEndFraction
                if seconds >= endTime - 0.03 {
                    let startTime = self.duration * self.trimStartFraction
                    self.player?.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
                    self.currentTime = startTime
                }
            }
        }

        renderCurrentFrame(force: true)
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    // MARK: 播放控制

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// 静音开关（只影响播放声音，不影响导出）。
    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func play() {
        guard let player else { return }
        // 播放范围限制在选段内；落点在选段外则从起点开始
        if duration > 0 {
            let startTime = duration * trimStartFraction
            let endTime = duration * trimEndFraction
            if currentTime < startTime - 0.05 || currentTime >= endTime - 0.05 {
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
                currentTime = startTime
            }
        }
        // 播到末尾再按播放，从头开始
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero)
            currentTime = 0
        }
        player.play()
        isPlaying = true
        timer?.invalidate()
        // 约 12 fps 取帧渲染（丢帧优先保证不卡 UI）
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderCurrentFrame() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
        renderCurrentFrame(force: true)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTime = clamped
        // seek 是异步的：必须在完成回调里再取帧，
        // 否则立即渲染读到的还是 seek 前的 itemTime（画面停在旧帧）。
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.renderCurrentFrame(force: true)
            }
        }
    }

    /// 调色参数变化时刷新当前帧（暂停状态下的实时预览）。
    func refresh() {
        // 不再限制"仅暂停时刷新"：对比切换、曲线切换在播放中也要立刻看到
        renderCurrentFrame(force: true)
    }

    // MARK: 取帧渲染

    func renderCurrentFrame(force: Bool = false) {
        guard let output, let player, let stateProvider else { return }

        if isRendering {
            pendingRefresh = true
            return
        }

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        let hasNew = output.hasNewPixelBuffer(forItemTime: itemTime)
        if !hasNew && !force {
            return
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }

        isRendering = true
        let (state, lut) = stateProvider()

        // 朝向 + 缩放到预览尺寸
        //
        // 用 `CIImage.oriented(_:)` 而不是手工乘 preferredTransform：
        // 手工矩阵在竖屏素材上容易把平移符号算错，表现为"画面转了 180°"。
        // oriented() 的语义由 EXIF 方向定义，平移由 Core Image 负责，不会翻错。
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(Self.orientation(from: transform))
        let longest = max(image.extent.width, image.extent.height)
        if longest > previewMaxEdge {
            let scale = previewMaxEdge / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        // 长按对比时直接显示未调色帧
        let rendered = bypassGrading ? image : renderer.processedImage(image, state: state, lut: lut)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cgImage = context.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: colorSpace)

        if let cgImage {
            frame = UIImage(cgImage: cgImage)
        }
        isRendering = false

        if pendingRefresh {
            pendingRefresh = false
            renderCurrentFrame(force: true)
        }

        _ = player
    }

    /// 把 video track 的 preferredTransform 映射成 EXIF 方向。
    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = t.a, b = t.b, c = t.c, d = t.d
        // 先看旋转分量（忽略平移）
        if abs(a - 1) < 0.001, abs(b) < 0.001, abs(c) < 0.001, abs(d - 1) < 0.001 {
            return .up
        }
        if abs(a) < 0.001, abs(b - 1) < 0.001, abs(c + 1) < 0.001, abs(d) < 0.001 {
            return .right
        }
        if abs(a) < 0.001, abs(b + 1) < 0.001, abs(c - 1) < 0.001, abs(d) < 0.001 {
            return .left
        }
        if abs(a + 1) < 0.001, abs(b) < 0.001, abs(c) < 0.001, abs(d + 1) < 0.001 {
            return .down
        }
        if abs(a + 1) < 0.001, abs(b) < 0.001, abs(c) < 0.001, abs(d - 1) < 0.001 {
            return .upMirrored
        }
        if abs(a - 1) < 0.001, abs(b) < 0.001, abs(c) < 0.001, abs(d + 1) < 0.001 {
            return .downMirrored
        }
        return .up
    }

    // MARK: 时间文本

    var timeText: String {
        let total = max(0, Int(currentTime.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}
