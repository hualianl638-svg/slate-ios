//
//  SLExportSheet.swift
//  SLATE
//
//  原型「导出照片 / 导出视频」两张 sheet 的实现：
//    类型分段 / 导出卡片 / 参数 chips / 码率与质量滑杆 / 预计大小 / 主按钮
//
//  与原型一致地保留那些「当前版本尚不支持」的选项，但置灰不可选，
//  避免看起来能选却导不出对应格式。
//

import AVFoundation
import SwiftUI

struct SLExportSheet: View {

    @ObservedObject var model: EditorModel
    @ObservedObject var lutStore: LUTStore
    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .video
    @State private var codec: Codec = .hevc
    @State private var quality: Double = 95
    @State private var bitrateMbps: Double = 20
    @State private var liveDuration: Double = 3.0
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var resultText: String?
    @State private var errorText: String?

    enum Kind {
        case photo
        case video
        case live
    }

    enum Codec: Hashable {
        case hevc, h264
        var title: String { self == .hevc ? "HEVC" : "H.264" }
    }

    var body: some View {
        VStack(spacing: 0) {
            handle
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(titleText)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)

                    if isVideoSource {
                        kindCards
                    }
                    body(for: kind)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            footer
        }
        .background(Theme.bg)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            kind = isVideoSource ? .video : .photo
        }
    }

    private var isVideoSource: Bool { model.sourceVideoURL != nil }

    private var titleText: String {
        if !isVideoSource { return "导出照片" }
        switch kind {
        case .video: return "导出视频"
        case .live: return "导出实况图"
        case .photo: return "导出照片"
        }
    }

    private var handle: some View {
        Capsule()
            .fill(Theme.line)
            .frame(width: 36, height: 4)
            .padding(.top, 8)
            .padding(.bottom, 10)
    }

    // MARK: 类型卡片

    private var kindCards: some View {
        HStack(spacing: 10) {
            card(.video, icon: "video.fill", title: "视频", subtitle: "\(codec.title) · 原分辨率")
            card(.live, icon: "livephoto", title: "实况图", subtitle: "Live Photo · \(String(format: "%.0f", liveDuration))s")
        }
    }

    private func card(_ target: Kind, icon: String, title: String, subtitle: String) -> some View {
        let isOn = kind == target
        return Button {
            kind = target
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isOn ? Theme.onAccent : Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isOn ? Theme.onAccent.opacity(0.7) : Theme.meta)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isOn ? Theme.accent : Theme.surface2,
                        in: RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous)
                    .strokeBorder(isOn ? .clear : Theme.line, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 参数

    @ViewBuilder
    private func body(for kind: Kind) -> some View {
        switch kind {
        case .photo:
            photoOptions
        case .video:
            videoOptions
        case .live:
            liveOptions
        }
    }

    private var photoOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            segment(title: "格式",
                    options: ["JPG", "HEIF", "TIFF 16"],
                    enabledIndexes: [0],
                    selection: 0)

            VStack(alignment: .leading, spacing: 6) {
                row(title: "质量", value: "\(Int(quality))")
                Slider(value: $quality, in: 60...100, step: 1).tint(Theme.accent)
            }

            chips(title: "尺寸", options: ["原始", "4096", "2048"], enabledIndexes: [0], selection: 0)
            chips(title: "色彩空间", options: ["sRGB", "Display P3"], enabledIndexes: [0], selection: 0)

            HStack {
                Text("保留 EXIF / 镜头信息")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.meta)
                Spacer()
                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(true)
            }

            estimateRow(text: "预计大小", value: "—")
        }
    }

    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            chips(title: "编码", options: ["HEVC", "H.264"], enabledIndexes: [0, 1], selection: codec == .hevc ? 0 : 1,
                  onSelect: { index in codec = index == 0 ? .hevc : .h264 })

            chips(title: "色彩", options: ["保留 S-Log3", "709", "HDR10"], enabledIndexes: [1], selection: 1)

            VStack(alignment: .leading, spacing: 6) {
                row(title: "码率", value: "\(Int(bitrateMbps)) Mbps")
                Slider(value: $bitrateMbps, in: 20...200, step: 5).tint(Theme.accent)
            }

            HStack {
                Text("导出时写入 LUT 元数据")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.meta)
                Spacer()
                Toggle("", isOn: .constant(false))
                    .labelsHidden()
                    .tint(Theme.accent)
                    .disabled(true)
            }

            estimateRow(text: "预计大小", value: "按码率 × 时长估算")
        }
    }

    private var liveOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                row(title: "时长", value: String(format: "%.1f 秒", liveDuration))
                Slider(value: $liveDuration, in: 2...5, step: 0.5).tint(Theme.accent)
            }


            Text("片段取自视频的「选段裁剪」：在选段内居中截取，静帧为片段中间帧。（配对视频为 H.264）")
                .font(.system(size: 10))
                .foregroundStyle(Theme.meta)
                .fixedSize(horizontal: false, vertical: true)

            estimateRow(text: "预计大小", value: "—")
        }
    }

    // MARK: 小组件

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monoDigits()
                .foregroundStyle(Theme.accent)
        }
    }

    private func estimateRow(text: String, value: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.meta)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.meta)
        }
    }

    private func segment(title: String, options: [String], enabledIndexes: [Int], selection: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.meta)
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let enabled = enabledIndexes.contains(index)
                    let isOn = index == selection
                    Text(options[index])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(!enabled ? Theme.meta.opacity(0.5) : (isOn ? Theme.onAccent : Theme.text))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(isOn && enabled ? Theme.accent : Theme.surface2,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func chips(title: String,
                       options: [String],
                       enabledIndexes: [Int],
                       selection: Int,
                       onSelect: ((Int) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.meta)
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let enabled = enabledIndexes.contains(index)
                    let isOn = index == selection
                    SLChip(title: options[index], isOn: isOn && enabled, compact: true) {
                        guard enabled else { return }
                        onSelect?(index)
                    }
                    .opacity(enabled ? 1 : 0.45)
                }
                Spacer()
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 10) {
            if isExporting {
                ProgressView(value: progress).tint(Theme.accent)
            }
            if let resultText {
                Label(resultText, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.log)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                SLTextButton(title: "关闭") { dismiss() }
                SLPrimaryButton(title: primaryTitle, enabled: !isExporting) {
                    Task { await runExport() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            Theme.bg.overlay(alignment: .top) {
                Rectangle().fill(Theme.line).frame(height: 0.5)
            }
        )
    }

    private var primaryTitle: String {
        switch kind {
        case .photo: return "导出 1 张照片"
        case .video: return "导出视频"
        case .live: return "导出实况图"
        }
    }

    // MARK: 执行

    @MainActor
    private func runExport() async {
        isExporting = true
        progress = 0
        resultText = nil
        errorText = nil

        let settings = ExportSettings(
            kind: codec == .hevc ? .videoHEVC : .videoH264,
            bitrate: Int(bitrateMbps * 1_000_000),
            jpegQuality: quality / 100.0
        )

        do {
            switch kind {
            case .photo:
                guard let image = model.sourceImage else { throw ExportError.renderFailed }
                try await SLATEExporter.shared.exportPhoto(
                    image: image, state: model.state, lut: model.currentLUT, settings: settings
                )
                resultText = "照片已保存到相册"

            case .video:
                guard let url = model.sourceVideoURL else { throw ExportError.noVideoTrack }
                // 选段裁剪：按 trim 区间导出
                var range: CMTimeRange?
                if model.trimStart > 0.001 || model.trimEnd < 0.999 {
                    if let duration = try? await AVURLAsset(url: url).load(.duration) {
                        let total = CMTimeGetSeconds(duration)
                        let startSeconds = total * model.trimStart
                        let lengthSeconds = total * (model.trimEnd - model.trimStart)
                        range = CMTimeRange(
                            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                            duration: CMTime(seconds: max(0.1, lengthSeconds), preferredTimescale: 600)
                        )
                    }
                }
                let output = try await SLATEExporter.shared.exportVideo(
                    sourceURL: url, state: model.state, lut: model.currentLUT,
                    settings: settings, timeRange: range
                ) { value in
                    progress = value
                }
                try await SLATEExporter.shared.saveVideoToLibrary(fileURL: output)
                resultText = "视频已保存到相册"

            case .live:
                guard let url = model.sourceVideoURL else { throw ExportError.noVideoTrack }
                try await SLATEExporter.shared.exportLivePhoto(
                    sourceURL: url, state: model.state, lut: model.currentLUT,
                    settings: settings,
                    targetDuration: liveDuration,
                    stillPosition: 0.5
                ) { value in
                    progress = value
                }
                resultText = "实况图已保存到相册"
            }
        } catch {
            errorText = error.localizedDescription
        }

        isExporting = false
    }
}
