//
//  ContentView.swift
//  SLATE
//
//  M2 主界面：导入 → S-Log3 识别 → 实时调色 → 对比。
//
//  与原型的对应关系（桌面 index.html）：
//    顶部导航     → header
//    预览 + 直方图 → preview
//    调节面板     → sliders
//    底部主按钮   → importButton
//  原型里图库/视频时间轴/LUT 库属于 M3/M4，本里程碑只做"单素材调色闭环"。
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - 编辑模型

/// 编辑会话状态。
///
/// 用 `ObservableObject` 而不是 iOS 17 的 `@Observable`：
/// 工程 `project.yml` 里 `SWIFT_VERSION = 5.0`，ObservableObject 的兼容面更宽，
/// 首次云端编译时少一类宏展开风险。后续可在稳定后切换。
@MainActor
final class EditorModel: ObservableObject {

    @Published private(set) var state: EditState
    @Published private(set) var displayImage: UIImage?
    @Published private(set) var histogram: [Float] = []
    @Published private(set) var isRendering = false
    @Published var errorText: String?
    @Published var showOriginal = false

    /// 原图（已转正的 CIImage），用于重复渲染。
    private(set) var sourceImage: CIImage?
    /// 原图缩略（用于"对比"时直接显示，避免重渲）。
    private(set) var originalUIImage: UIImage?
    /// 已解析的 LUT（M2 暂未接入 LUT 导入，占位）。
    private var resolvedLUT: LUT3D?
    /// 渲染序号：用于丢弃过期渲染结果。
    private var renderGeneration = 0

    init(kind: MediaKind = .video) {
        self.state = EditState(mediaKind: kind)
    }

    // MARK: 载入

    func load(image: UIImage, isVideo: Bool, colorInfo: VideoColorInfo?) {
        let ci = CIImage(image: image)
        self.sourceImage = ci
        self.originalUIImage = image
        self.state.mediaKind = isVideo ? .video : .image
        self.state.videoColorInfo = colorInfo
        self.displayImage = image
        requestRender()
    }

    // MARK: 参数

    /// 曝光（EV）。
    var exposure: Double {
        get { state.adjustments.exposure }
        set { state.adjustments.exposure = newValue; requestRender() }
    }
    /// 明度。
    var brightness: Double {
        get { state.adjustments.brightness }
        set { state.adjustments.brightness = newValue; requestRender() }
    }
    /// 对比度。
    var contrast: Double {
        get { state.adjustments.contrast }
        set { state.adjustments.contrast = newValue; requestRender() }
    }
    /// 饱和度。
    var saturation: Double {
        get { state.adjustments.saturation }
        set { state.adjustments.saturation = newValue; requestRender() }
    }
    /// 自然饱和度。
    var vibrance: Double {
        get { state.adjustments.vibrance }
        set { state.adjustments.vibrance = newValue; requestRender() }
    }
    /// 色温相对偏移。
    var temperature: Double {
        get { state.adjustments.whiteBalance.relativeTemperatureOffset }
        set { state.adjustments.whiteBalance.relativeTemperatureOffset = newValue; requestRender() }
    }
    /// 色调相对偏移。
    var tint: Double {
        get { state.adjustments.whiteBalance.relativeTintOffset }
        set { state.adjustments.whiteBalance.relativeTintOffset = newValue; requestRender() }
    }

    /// 是否按 S-Log3 处理（原型里的「709 预览」开关的反面）。
    var isSLog3: Bool {
        get { state.videoColorInfo?.curve == .sLog3 }
        set {
            state.videoColorInfo = newValue
                ? .sonySLog3Cine
                : VideoColorInfo(curve: .rec709, colorSpace: .rec709)
            requestRender()
        }
    }

    func reset() {
        let kind = state.mediaKind
        let info = state.videoColorInfo
        state = EditState(mediaKind: kind)
        state.videoColorInfo = info
        requestRender()
    }

    // MARK: 渲染

    /// 请求一次渲染。
    ///
    /// 节流策略：同一轮 RunLoop 内多次修改只渲染最后一帧（丢过期结果），
    /// 拖动滑块时不会堆积任务。
    func requestRender() {
        guard let source = sourceImage else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let snapshot = state
        let lut = resolvedLUT
        isRendering = true

        Task.detached(priority: .userInitiated) { [renderer = SLATERenderer.shared] in
            let cg = renderer.render(source, state: snapshot, lut: lut)
            let hist = renderer.histogram(of: source)

            await MainActor.run { [weak self] in
                guard let self, self.renderGeneration == generation else { return }
                if let cg {
                    self.displayImage = UIImage(cgImage: cg)
                }
                self.histogram = hist
                self.isRendering = false
            }
        }
    }
}

// MARK: - 主界面

struct ContentView: View {

    @StateObject private var model = EditorModel(kind: .video)
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoInfo: VideoInfo?
    @State private var busy = false
    @State private var pickerFilter: PickerFilter = .videos

    enum PickerFilter: String, CaseIterable {
        case videos = "视频"
        case images = "照片"
        var matching: PHPickerFilter {
            switch self {
            case .videos: return .videos
            case .images: return .images
            }
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    preview
                        .padding(.top, 14)
                    if let videoInfo {
                        metaList(videoInfo)
                            .padding(.top, 14)
                    }
                    sliders
                        .padding(.top, 18)
                    Spacer(minLength: 20)
                    importButton
                    footnote
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SLATE")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .tracking(2.2)
                .foregroundStyle(Theme.text)
            Spacer()
            Text("M2 · S-Log3 调色")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Theme.log)
        }
        .padding(.top, 6)
    }

    // MARK: 预览

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)

            if let image = model.showOriginal ? model.originalUIImage : model.displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.meta)
                    Text(busy ? "正在读取素材…" : "还没有导入素材")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.meta)
                }
            }

            // 徽标：S-LOG3 / 709
            if model.sourceImage != nil {
                VStack {
                    HStack {
                        badge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
            }

            if model.isRendering {
                ProgressView().tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if model.sourceImage != nil {
                compareButton
                    .padding(10)
            }
        }
    }

    private var badge: some View {
        Text(model.isSLog3 ? "S-LOG3" : "709")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(Theme.bg)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(model.isSLog3 ? Theme.log : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// 长按查看原片（原型「对比」）。
    private var compareButton: some View {
        Text(model.showOriginal ? "原片" : "对比")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface2.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
            .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 30) {
                // 长按结束才会回调，这里用 pressing 状态更准，但闭包式更简单稳妥
            } onPressingChanged: { pressing in
                model.showOriginal = pressing
            }
    }

    // MARK: 元数据

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
            Text(key).font(.system(size: 13)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(accent ? Theme.danger : Theme.text)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    // MARK: 调节面板

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("调节")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    model.reset()
                } label: {
                    Text("重置")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }

            toggleRow

            slider("曝光", value: Binding(get: { model.exposure }, set: { model.exposure = $0 }),
                   range: -2.0...2.0, reset: 0, format: { String(format: "%+.2f EV", $0) })
            slider("明度", value: Binding(get: { model.brightness }, set: { model.brightness = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("对比度", value: Binding(get: { model.contrast }, set: { model.contrast = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("饱和度", value: Binding(get: { model.saturation }, set: { model.saturation = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("自然饱和度", value: Binding(get: { model.vibrance }, set: { model.vibrance = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("色温", value: Binding(get: { model.temperature }, set: { model.temperature = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("色调", value: Binding(get: { model.tint }, set: { model.tint = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
        }
    }

    private var toggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("按 S-Log3 灰片处理")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("Sony S-Gamut3.Cine · 官方曲线归一化")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isSLog3 }, set: { model.isSLog3 = $0 }))
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.vertical, 4)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        reset: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(abs(value.wrappedValue - reset) < 1e-9 ? Theme.muted : Theme.text)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(abs(value.wrappedValue - reset) < 1e-9 ? Theme.meta : Theme.accent)
            }
            Slider(value: value, in: range) { editing in
                // 松手时重渲一次全质量（拖动中已是节流渲染）
                if !editing { model.requestRender() }
            }
            .tint(Theme.accent)
        }
    }

    // MARK: 导入

    private var importButton: some View {
        VStack(spacing: 10) {
            Picker("", selection: $pickerFilter) {
                ForEach(PickerFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)

            PhotosPicker(
                selection: $pickerItem,
                matching: pickerFilter.matching,
                photoLibrary: .shared()
            ) {
                Text(busy ? "读取中…" : "从相册导入\(pickerFilter.rawValue)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
        }
    }

    private var footnote: some View {
        Text("M2：S-Log3 解码 + 基础调节已在 GPU 上实时生效。LUT 导入与视频/实况图导出在 M3。")
            .font(.system(size: 11))
            .foregroundStyle(Theme.meta)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 逻辑

    @MainActor
    private func load(_ item: PhotosPickerItem) async {
        busy = true
        model.errorText = nil
        defer { busy = false }

        do {
            if pickerFilter == .videos {
                guard let movie = try await item.loadTransferable(type: Movie.self) else {
                    throw ProbeError.noVideoTrack
                }
                async let probe = VideoProbe.inspect(url: movie.url)
                async let shot = VideoProbe.thumbnail(url: movie.url)
                let info = try await probe
                let thumb = try await shot
                self.videoInfo = info
                // 传输函数里若标注了 HLG/PQ，本里程碑不支持，提示但不阻塞
                model.load(image: thumb, isVideo: true, colorInfo: .sonySLog3Cine)
            } else {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw ProbeError.noVideoTrack
                }
                self.videoInfo = nil
                model.load(image: image, isVideo: false, colorInfo: nil)
            }
        } catch {
            model.errorText = "读取失败：\(error.localizedDescription)"
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

// MARK: - 主题（沿用 M1，与原型色板一致）

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
