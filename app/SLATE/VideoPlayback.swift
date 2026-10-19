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
            self.currentTime = CMTimeGetSeconds(time)
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
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
        renderCurrentFrame(force: true)
    }

    /// 调色参数变化时刷新当前帧（暂停状态下的实时预览）。
    func refresh() {
        guard !isPlaying else { return }
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
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            image = image.transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }
        let longest = max(image.extent.width, image.extent.height)
        if longest > previewMaxEdge {
            let scale = previewMaxEdge / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let rendered = renderer.processedImage(image, state: state, lut: lut)
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
