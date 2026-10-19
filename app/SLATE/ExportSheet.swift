//
//  ExportSheet.swift
//  SLATE
//
//  导出面板：照片 JPG / 视频 HEVC / 视频 H.264。
//  导出走 SLATEExporter，完成后写入相册并给出可分享的文件。
//

import SwiftUI
import UIKit

struct ExportSheet: View {

    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var kind: Settings = .videoHEVC
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var resultText: String?
    @State private var errorText: String?
    @State private var shareURL: URL?

    enum Settings: String, CaseIterable {
        case photoJPG = "照片 JPG"
        case videoHEVC = "视频 HEVC"
        case videoH264 = "视频 H.264"
        case livePhoto = "实况图"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 18) {
                    // 导出类型
                    VStack(alignment: .leading, spacing: 8) {
                        Text("导出为")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                        HStack(spacing: 8) {
                            ForEach(Settings.allCases, id: \.self) { option in
                                Button {
                                    kind = option
                                } label: {
                                    Text(option.rawValue)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(kind == option ? Theme.onAccent : Theme.text)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .background(kind == option ? Theme.accent : Theme.surface2,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // 说明
                    Text(noteText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.meta)
                        .fixedSize(horizontal: false, vertical: true)

                    // 进度
                    if isExporting {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress)
                                .tint(Theme.accent)
                            Text(String(format: "导出中… %d%%", Int(progress * 100)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.muted)
                        }
                    }

                    if let resultText {
                        Label(resultText, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.log)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Text("分享导出文件")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    Button {
                        Task { await runExport() }
                    } label: {
                        Text(isExporting ? "导出中…" : "开始导出")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting || model.sourceImage == nil)
                    .opacity(isExporting || model.sourceImage == nil ? 0.5 : 1)
                }
                .padding(20)
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var noteText: String {
        switch kind {
        case .photoJPG:
            return "把当前画面按调色结果渲染成 JPG，写入相册。全质量渲染（不受预览分辨率限制）。"
        case .livePhoto:
            if model.sourceVideoURL == nil {
                return "实况图需要视频素材。请导入视频后再导出。"
            }
            return "截取视频居中的 3 秒：中点那一帧作为静帧、这段视频作为配对视频，成对写入相册（相册里会显示 LIVE 角标）。本期静帧与配对视频均不带音轨。"
        case .videoHEVC, .videoH264:
            if model.sourceVideoURL == nil {
                return "当前素材来自照片，没有视频轨道。请导入视频后再导出。"
            }
            return "逐帧重新调色后用 \(kind.rawValue.contains("HEVC") ? "HEVC" : "H.264") 编码，写入相册。本期暂不透传音轨。"
        }
    }

    @MainActor
    private func runExport() async {
        isExporting = true
        progress = 0
        errorText = nil
        resultText = nil
        shareURL = nil

        let settings = ExportSettings(
            kind: {
                switch kind {
                case .photoJPG: return .photoJPEG
                case .videoHEVC, .livePhoto: return .videoHEVC
                case .videoH264: return .videoH264
                }
            }(),
            bitrate: 20_000_000,
            jpegQuality: 0.95
        )

        let lut = model.currentLUT

        do {
            switch kind {
            case .photoJPG:
                guard let image = model.sourceImage else {
                    throw ExportError.renderFailed
                }
                let url = try await SLATEExporter.shared.exportPhoto(
                    image: image, state: model.state, lut: lut, settings: settings
                )
                shareURL = url
                resultText = "照片已导出并保存到相册"

            case .videoHEVC, .videoH264:
                guard let videoURL = model.sourceVideoURL else {
                    throw ExportError.noVideoTrack
                }
                let url = try await SLATEExporter.shared.exportVideo(
                    sourceURL: videoURL,
                    state: model.state,
                    lut: lut,
                    settings: settings
                ) { value in
                    progress = value
                }
                try await SLATEExporter.shared.saveVideoToLibrary(fileURL: url)
                shareURL = url
                resultText = "视频已导出并保存到相册"

            case .livePhoto:
                guard let videoURL = model.sourceVideoURL else {
                    throw ExportError.noVideoTrack
                }
                let stillURL = try await SLATEExporter.shared.exportLivePhoto(
                    sourceURL: videoURL,
                    state: model.state,
                    lut: lut,
                    settings: settings
                ) { value in
                    progress = value
                }
                shareURL = stillURL
                resultText = "实况图已导出并保存到相册（相册里应显示 LIVE 角标）"
            }
        } catch {
            errorText = error.localizedDescription
        }

        isExporting = false
    }
}
