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
    /// 预览用降采样源图（长边 ≤ 2048）。RAW/大图渲染预览时用它，
    /// 导出仍用 sourceImage 全分辨率，避免每帧产出上百 MB 的 CGImage。
    private(set) var previewSource: CIImage?
    /// 原图缩略（用于"对比"时直接显示，避免重渲）。
    private(set) var originalUIImage: UIImage?

    /// 源视频文件 URL（导出视频用；照片素材为 nil）。
    var sourceVideoURL: URL?

    /// 当前已解析的 LUT（导出时复用同一份）。
    var currentLUT: LUT3D? { resolvedLUT }
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
        // 预览源图：长边超过 2048 就降采样（RAW 常见 6000×4000）
        let longest = max(ci.extent.width, ci.extent.height)
        if longest > 2048 {
            let scale = 2048 / longest
            self.previewSource = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            self.previewSource = ci
        }
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

    // MARK: 影调四段

    /// 阴影。
    var shadows: Double {
        get { state.adjustments.shadows }
        set { state.adjustments.shadows = newValue; requestRender() }
    }
    /// 高光。
    var highlights: Double {
        get { state.adjustments.highlights }
        set { state.adjustments.highlights = newValue; requestRender() }
    }
    /// 黑色色阶。
    var blacks: Double {
        get { state.adjustments.blacks }
        set { state.adjustments.blacks = newValue; requestRender() }
    }
    /// 白色色阶。
    var whites: Double {
        get { state.adjustments.whites }
        set { state.adjustments.whites = newValue; requestRender() }
    }

    // MARK: 色调分离

    /// 阴影染色色相（0...1 色相环）。
    var shadowHue: Double {
        get { state.splitToning.shadows.hue }
        set { state.splitToning.shadows.hue = newValue; requestRender() }
    }
    /// 阴影染色饱和度。
    var shadowSaturation: Double {
        get { state.splitToning.shadows.saturation }
        set { state.splitToning.shadows.saturation = newValue; requestRender() }
    }
    /// 高光染色色相。
    var highlightHue: Double {
        get { state.splitToning.highlights.hue }
        set { state.splitToning.highlights.hue = newValue; requestRender() }
    }
    /// 高光染色饱和度。
    var highlightSaturation: Double {
        get { state.splitToning.highlights.saturation }
        set { state.splitToning.highlights.saturation = newValue; requestRender() }
    }
    /// 整体强度（同时作用于阴影与高光）。
    var splitToneAmount: Double {
        get { max(state.splitToning.shadows.amount, state.splitToning.highlights.amount) }
        set {
            state.splitToning.shadows.amount = newValue
            state.splitToning.highlights.amount = newValue
            requestRender()
        }
    }
    /// 色调分离是否已启用。
    var isSplitToneOn: Bool {
        get { !state.splitToning.isNeutral }
        set {
            if newValue {
                // 默认给一个可用的配方：阴影偏青、高光偏暖
                state.splitToning.shadows = SplitToneTarget(hue: 0.55, saturation: 0.5, amount: 0.45, balance: 0)
                state.splitToning.highlights = SplitToneTarget(hue: 0.08, saturation: 0.4, amount: 0.35, balance: 0)
            } else {
                state.splitToning = .neutral
            }
            requestRender()
        }
    }


    // MARK: HSL 八通道

    /// 当前选中的 HSL 通道（纯界面状态，不参与渲染）。
    // MARK: 裁剪 / 蒙版

    /// 裁剪与蒙版设置（写入即触发重渲）。
    var cropMask: CropMaskSettings {
        get { state.cropMask }
        set {
            state.cropMask = newValue
            requestRender()
        }
    }

    // MARK: 灰片曲线

    /// 当前选中的灰片曲线。
    var logProfile: LogProfile {
        get { LogProfile(rawValue: state.logProfileIndex) ?? .off }
        set {
            state.logProfileIndex = newValue.rawValue
            // 选中曲线即启用；选「关闭」即关闭 —— 避免"选了没反应"
            state.restoreEnabled = (newValue != .off)
            requestRender()
        }
    }

    /// 还原 LUT 开关。
    var restoreEnabled: Bool {
        get { state.restoreEnabled }
        set {
            state.restoreEnabled = newValue
            requestRender()
        }
    }

    /// 自定义还原 LUT 名称。
    var restoreLUTName: String {
        get { state.restoreLUTName }
        set {
            state.restoreLUTName = newValue
            requestRender()
        }
    }

    // MARK: 选段裁剪

    var trimStart: Double {
        get { state.trimStart }
        set { state.trimStart = min(newValue, state.trimEnd - 0.02) }
    }

    var trimEnd: Double {
        get { state.trimEnd }
        set { state.trimEnd = max(newValue, state.trimStart + 0.02) }
    }

    func setTrim(start: Double, end: Double) {
        let s = max(0, min(start, 0.98))
        let e = min(1, max(end, s + 0.02))
        state.trimStart = s
        state.trimEnd = e
    }

    /// 用上次保存的调整覆盖当前状态。
    func restore(_ saved: EditState) {
        state = saved
        requestRender()
    }

    @Published var hslSelectedBand: HSLBandID = .red

    /// 选中通道的色相偏移（-1...1，满量程 ±30°）。
    var hslHue: Double {
        get { state.hsl[hslSelectedBand].hue }
        set { state.hsl[hslSelectedBand].hue = newValue; requestRender() }
    }
    /// 选中通道的饱和度调整。
    var hslSaturation: Double {
        get { state.hsl[hslSelectedBand].saturation }
        set { state.hsl[hslSelectedBand].saturation = newValue; requestRender() }
    }
    /// 选中通道的明度调整。
    var hslLuminance: Double {
        get { state.hsl[hslSelectedBand].luminance }
        set { state.hsl[hslSelectedBand].luminance = newValue; requestRender() }
    }
    /// HSL 是否有任何通道被调整过。
    var isHSLActive: Bool { !state.hsl.isNeutral }

    /// 只重置当前选中通道。
    func resetSelectedHSLBand() {
        state.hsl[hslSelectedBand] = HSLBand()
        requestRender()
    }

    // MARK: LUT

    /// 当前生效的 LUT 展示名（nil 表示未套用）。
    @Published private(set) var activeLUTName: String?

    /// LUT 强度 0...1。
    var lutIntensity: Double {
        get { state.lut.intensity }
        set {
            state.lut.intensity = min(max(newValue, 0), 1)
            // 强度归零仍保留引用，便于再次拉回（EditState.clamp 只在持久化时清理）
            requestRender()
        }
    }

    /// 套用 / 取消 LUT。
    ///
    /// - Parameters:
    ///   - lut: 已解析的 LUT；nil 表示取消。
    ///   - name: 展示名（用于 UI 显示当前选中项）。
    func applyLUT(_ lut: LUT3D?, name: String?) {
        resolvedLUT = lut
        activeLUTName = lut == nil ? nil : name
        if lut == nil {
            state.lut = .none
        } else {
            state.lut.reference = LUTReference(
                relativePath: "LUTs/\(name ?? "lut").cube",
                displayName: name ?? "LUT",
                dimension: lut?.dimension
            )
            if state.lut.intensity <= 0 { state.lut.intensity = 1.0 }
        }
        requestRender()
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
        resolvedLUT = nil
        activeLUTName = nil
        requestRender()
    }

    // MARK: 渲染

    /// 请求一次渲染。
    ///
    /// 节流策略：同一轮 RunLoop 内多次修改只渲染最后一帧（丢过期结果），
    /// 拖动滑块时不会堆积任务。
    func requestRender() {
        // 预览渲染用降采样源；导出走 sourceImage（全分辨率）
        guard let source = previewSource ?? sourceImage else { return }
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
    @StateObject private var lutStore = LUTStore()
    @State private var pickerItem: PhotosPickerItem?

    /// 从图库带入的素材（为 nil 时与原来行为一致，走应用内导入）。
    var prefill: LibraryPayload?
    @State private var didApplyPrefill = false
    @State private var videoInfo: VideoInfo?
    @State private var busy = false
    @State private var pickerFilter: PickerFilter = .videos
    @State private var showExport = false

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
                    kernelWarning
                    preview
                        .padding(.top, 14)
                    if let videoInfo {
                        metaList(videoInfo)
                            .padding(.top, 14)
                    }
                    sliders
                        .padding(.top, 18)

                    Divider()
                        .overlay(Theme.line)
                        .padding(.vertical, 16)

                    hslSection

                    Divider()
                        .overlay(Theme.line)
                        .padding(.vertical, 16)

                    LUTPanel(store: lutStore, model: model)

                    Divider()
                        .overlay(Theme.line)
                        .padding(.vertical, 16)

                    splitToningSection

                    Spacer(minLength: 20)
                    importButton
                    exportButton
                    footnote
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            guard !didApplyPrefill, let prefill else { return }
            didApplyPrefill = true
            model.sourceVideoURL = prefill.videoURL
            model.load(image: prefill.image, isVideo: prefill.isVideo, colorInfo: nil)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
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

    // MARK: 内核告警

    /// 内核创建失败时显式提示。
    ///
    /// 为什么需要这块：Core Image 的 `CIColorKernel(source:)` 在语法错误时只返回 nil，
    /// 不抛异常。M2 里我把内核类型写成了 Metal 的 `float3`（内核语言应为 `vec3`），
    /// 结果 S-Log3 解码**静默失效**，界面上完全看不出来。
    /// 现在失败会在顶部明确显示是哪一项效果缺失。
    @ViewBuilder
    private var kernelWarning: some View {
        let failures = SLATERenderer.shared.kernelFailures
        if !failures.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                Text("以下效果在本机不可用：\(failures.joined(separator: "、"))。这是渲染内核编译失败，请联系开发者。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 10)
        }
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
            slider("阴影", value: Binding(get: { model.shadows }, set: { model.shadows = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("高光", value: Binding(get: { model.highlights }, set: { model.highlights = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("黑色色阶", value: Binding(get: { model.blacks }, set: { model.blacks = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("白色色阶", value: Binding(get: { model.whites }, set: { model.whites = $0 }),
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

    // MARK: 色调分离

    // MARK: HSL 八通道界面

    private var hslSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HSL 八通道")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("按色相分别调整，中性灰不受影响")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.meta)
                }
                Spacer()
                Button {
                    model.resetSelectedHSLBand()
                } label: {
                    Text("重置通道")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HSLBandID.allCases, id: \.self) { band in
                        Button {
                            model.hslSelectedBand = band
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(hslSwatch(band))
                                    .frame(width: 8, height: 8)
                                Text(band.displayName)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(model.hslSelectedBand == band ? Theme.onAccent : Theme.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                model.hslSelectedBand == band ? Theme.accent : Theme.surface2,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            slider("色相", value: Binding(get: { model.hslHue }, set: { model.hslHue = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("饱和度", value: Binding(get: { model.hslSaturation }, set: { model.hslSaturation = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
            slider("明度", value: Binding(get: { model.hslLuminance }, set: { model.hslLuminance = $0 }),
                   range: -1...1, reset: 0, format: { String(format: "%+.2f", $0) })
        }
    }

    /// 通道代表色（Engine 提供的 swatchRGB）。
    private func hslSwatch(_ band: HSLBandID) -> Color {
        let rgb = band.swatchRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private var splitToningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("色调分离")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("阴影与高光分别染色")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.meta)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.isSplitToneOn },
                    set: { model.isSplitToneOn = $0 }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }

            if model.isSplitToneOn {
                slider("阴影色相", value: Binding(get: { model.shadowHue }, set: { model.shadowHue = $0 }),
                       range: 0...1, reset: 0.55, format: { hueName($0) })
                slider("阴影饱和", value: Binding(get: { model.shadowSaturation }, set: { model.shadowSaturation = $0 }),
                       range: 0...1, reset: 0, format: { String(format: "%.2f", $0) })
                slider("高光色相", value: Binding(get: { model.highlightHue }, set: { model.highlightHue = $0 }),
                       range: 0...1, reset: 0.08, format: { hueName($0) })
                slider("高光饱和", value: Binding(get: { model.highlightSaturation }, set: { model.highlightSaturation = $0 }),
                       range: 0...1, reset: 0, format: { String(format: "%.2f", $0) })
                slider("分离强度", value: Binding(get: { model.splitToneAmount }, set: { model.splitToneAmount = $0 }),
                       range: 0...1, reset: 0, format: { String(format: "%.2f", $0) })
            }
        }
    }

    /// 把 0...1 色相换算成中文色名，比显示小数更容易理解。
    private func hueName(_ hue: Double) -> String {
        switch hue {
        case ..<0.042: return "红"
        case ..<0.125: return "橙"
        case ..<0.208: return "黄"
        case ..<0.375: return "绿"
        case ..<0.542: return "青"
        case ..<0.708: return "蓝"
        case ..<0.833: return "紫"
        case ..<0.958: return "洋红"
        default: return "红"
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

    /// 导出入口。没有素材时置灰。
    private var exportButton: some View {
        Button {
            showExport = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                Text("导出")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(model.sourceImage == nil ? Theme.meta : Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.sourceImage == nil)
        .padding(.top, 8)
    }

    private var footnote: some View {
        Text("M4：影调四段 + 色调分离 + LUT 已全部接通。视频与实况图导出为下一里程碑。")
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
                model.sourceVideoURL = movie.url
                // 传输函数里若标注了 HLG/PQ，本里程碑不支持，提示但不阻塞
                model.load(image: thumb, isVideo: true, colorInfo: .sonySLog3Cine)
            } else {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw ProbeError.noVideoTrack
                }
                self.videoInfo = nil
                model.sourceVideoURL = nil
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
