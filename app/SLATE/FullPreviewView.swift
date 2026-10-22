//
//  FullPreviewView.swift
//  SLATE
//
//  放大预览：全屏显示当前画面，支持双指缩放 / 拖动查看细节，
//  并允许在这里横屏观看（App 本身以竖屏为主，仅此页放开方向）。
//

import SwiftUI
import UIKit

struct FullPreviewView: View {

    @ObservedObject var playback: VideoPlayback
    let image: UIImage?
    var onClose: () -> Void

    /// 当前缩放倍率与拖拽偏移。
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    /// 视频优先用播放器当前帧；照片用传入的渲染结果。
    private var displayImage: UIImage? {
        playback.frame ?? image
    }

    private var isVideo: Bool { playback.duration > 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .simultaneousGesture(magnification)
                    .simultaneousGesture(drag)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { toggleZoom() })
                    .ignoresSafeArea()
            } else {
                Text("暂无可预览的画面")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.meta)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        // 先转回竖屏再关闭，否则会回到横屏的编辑器（布局会被压坏）
                        OrientationController.shared.allowLandscape = false
                        OrientationController.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onClose() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(Theme.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if isVideo {
                    HStack(spacing: 16) {
                        Button {
                            playback.togglePlay()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 56, height: 56)
                                .background(Theme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Text(playback.timeText)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .monoDigits()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    .padding(.bottom, 40)
                }
            }

            // 缩放时给一个"当前倍率"提示，方便确认手势生效
            if scale > 1.02 {
                VStack {
                    Text(String(format: "%.1f×", scale))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monoDigits()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.top, 56)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // 旋转后容器尺寸变了，缩放/偏移必须复位，否则画面可能整幅移出屏幕
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
        .onAppear {
            // 只有全屏预览允许横屏，编辑器/图库保持竖屏
            OrientationController.shared.allowLandscape = true
            OrientationController.refresh()
        }
        .onDisappear {
            OrientationController.shared.allowLandscape = false
            OrientationController.refresh()
        }
    }

    // MARK: 手势

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let next = lastScale * value
                scale = min(max(next, minScale), maxScale)
            }
            .onEnded { _ in
                lastScale = min(max(scale, minScale), maxScale)
                scale = lastScale
                if scale <= minScale {
                    withAnimation(.easeOut(duration: 0.18)) {
                        offset = .zero
                        lastOffset = .zero
                    }
                } else {
                    offset = clamp(offset)
                    lastOffset = offset
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = clamp(CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                ))
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    /// 粗略限制拖动范围：让图像至少保留在屏幕内，不至于整幅拖丢。
    private func clamp(_ size: CGSize) -> CGSize {
        let limit = CGSize(width: 420 * max(scale, 1), height: 420 * max(scale, 1))
        return CGSize(
            width: min(max(size.width, -limit.width), limit.width),
            height: min(max(size.height, -limit.height), limit.height)
        )
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            if scale > 1.01 {
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }
}
