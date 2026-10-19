//
//  FullPreviewView.swift
//  SLATE
//
//  放大预览：整屏显示当前画面（照片为渲染结果，视频为播放器当前帧）。
//

import SwiftUI
import UIKit

struct FullPreviewView: View {

    let image: UIImage?
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
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
            }
        }
    }
}
