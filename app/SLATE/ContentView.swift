import SwiftUI
import PhotosUI
import Foundation
import UIKit

struct ContentView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var info: VideoInfo?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                preview
                    .padding(.top, 18)

                if let info {
                    metaList(info)
                        .padding(.top, 18)
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 14)
                }

                Spacer(minLength: 16)

                pickerButton
                footnote
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SLATE")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(Theme.text)

            Spacer()

            Text("M1 · 导入与探测")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.log)
        }
        .padding(.top, 6)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.meta)
                    Text(busy ? "正在读取素材…" : "还没有导入素材")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.meta)
                }
            }

            if busy {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private func metaList(_ info: VideoInfo) -> some View {
        VStack(spacing: 0) {
            metaRow("分辨率", "\(info.width) × \(info.height)")
            metaRow("帧率", String(format: "%.2f fps", info.fps))
            metaRow("时长", timecode(info.seconds))
            metaRow("编码", info.codec)
            metaRow("位深", info.bitDepth.map { "\($0)-bit" } ?? "未知")
            metaRow("传输函数", transferName(info.transfer), accent: info.isHDR)
        }
    }

    private func metaRow(_ key: String, _ value: String, accent: Bool = false) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(accent ? Theme.danger : Theme.text)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var pickerButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
            Text(busy ? "读取中…" : "从相册导入视频")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    private var footnote: some View {
        Text("M1 只验证工具链：能导入、能读元数据。调色与导出在 M2 / M3。")
            .font(.system(size: 11))
            .foregroundStyle(Theme.meta)
            .padding(.top, 10)
    }

    // MARK: - 逻辑

    @MainActor
    private func load(_ item: PhotosPickerItem) async {
        busy = true
        errorText = nil
        do {
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                throw ProbeError.noVideoTrack
            }
            async let probe = VideoProbe.inspect(url: movie.url)
            async let shot = VideoProbe.thumbnail(url: movie.url)
            let videoInfo = try await probe
            let thumb = try await shot

            self.info = videoInfo
            self.image = thumb
            self.busy = false
        } catch {
            self.errorText = "读取失败：\(error.localizedDescription)"
            self.busy = false
        }
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func transferName(_ raw: String?) -> String {
        guard let raw else { return "未标注" }
        switch raw {
        case "ITU_R_709_2": return "Rec.709"
        case "ITU_R_2100_HLG": return "HLG（HDR，本期不支持）"
        case "SMPTE_ST_2084_PQ": return "PQ（HDR，本期不支持）"
        case "SMPTE_240M_1995": return "SMPTE 240M"
        default: return raw
        }
    }
}

enum Theme {
    static let bg = Color(red: 0.031, green: 0.031, blue: 0.039)
    static let surface = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let surface2 = Color(red: 0.090, green: 0.090, blue: 0.102)
    static let line = Color(red: 0.149, green: 0.149, blue: 0.165)
    static let text = Color(red: 0.949, green: 0.953, blue: 0.961)
    static let muted = Color(red: 0.604, green: 0.608, blue: 0.631)
    static let meta = Color(red: 0.502, green: 0.506, blue: 0.525)
    static let accent = Color(red: 1.000, green: 0.478, blue: 0.271)
    static let onAccent = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let log = Color(red: 0.482, green: 0.773, blue: 0.847)
    static let danger = Color(red: 0.894, green: 0.376, blue: 0.310)
}
