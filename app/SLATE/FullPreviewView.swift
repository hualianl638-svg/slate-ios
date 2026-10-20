//
//  FullPreviewView.swift
//  SLATE
//
//  放大预览：整屏显示当前画面，视频可在此直接播放/暂停。
//

import SwiftUI
import UIKit

struct FullPreviewView: View {

    @ObservedObject var playback: VideoPlayback
    let image: UIImage?
    var onClose: () -> Void

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
                    .ignoresSafeArea()
            } else {
                Text("暂无可预览的画面")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.meta)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
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
        }
    }
}
