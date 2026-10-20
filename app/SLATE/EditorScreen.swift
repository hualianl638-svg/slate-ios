//
//  EditorScreen.swift
//  SLATE
//
//  原型「照片编辑 / 视频编辑」屏的完整实现：
//    顶部导航（返回 + 文件名 + 元信息 + 更多）
//    预览区（画面 + 直方图叠加 + 角标 + 对比按钮 + 709 预览开关）
//    视频时间轴（播放 / 时间码 / 胶片条 / 播放头）
//    单行工具条（基础 / 影调 / HSL / 色调分离 / LUT）
//    当前工具的单个面板
//    底部（重置 + 导出）
//

import SwiftUI
import UIKit

// MARK: - 编辑器

struct EditorScreen: View {

    @ObservedObject var model: EditorModel
    @ObservedObject var lutStore: LUTStore
    var title: String
    var subtitle: String
    /// 视频文件地址（照片素材为 nil）。显式传入而不是从模型里读，
    /// 因为子视图 onAppear 早于父视图 onAppear，那时模型还没装载。
    var videoURL: URL?
    /// 该素材的存档键（用于恢复上次调整）。
    var editKey: String = ""
    var onClose: () -> Void

    @State private var tool: Tool = .basic
    @State private var showExport = false
    @State private var showFullPreview = false
    @State private var showRestorePicker = false
    @State private var didRestoreStyleLUT = false
    @State private var didRestoreEdit = false
    /// 打开全屏预览时不该销毁播放器（它会触发本视图 onDisappear）
    @State private var suppressTeardown = false
    @StateObject private var playback = VideoPlayback()
    @State private var didConfigurePlayback = false
    @State private var comparing = false

    enum Tool: String, CaseIterable, Identifiable {
        case basic = "基础"
        case tone = "影调"
        case hsl = "HSL"
        case split = "色调分离"
        case lut = "LUT"
        case crop = "裁剪"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .basic: return "slider.horizontal.3"
            case .tone: return "circle.lefthalf.filled"
            case .hsl: return "eyedropper.halffull"
            case .split: return "circle.hexagongrid.fill"
            case .lut: return "cube.transparent"
            case .crop: return "crop"
            }
        }
    }

    var body: some View {
        // 用 GeometryReader 拿真实安全区：
        // fullScreenCover 下若上层没有传递安全区，导航栏会直接贴到状态栏上。
        // 这里按实际 inset 补顶部留白，横竖屏都成立。
        GeometryReader { proxy in

            VStack(spacing: 0) {
                nav
                    // 系统已给安全区时 proxy 有值（不再补）；
                    // fullScreenCover 下 inset 常为 0，此时用窗口真实值（灵动岛机型约 59pt）
                    .padding(.top, max(0, deviceTopInset - proxy.safeAreaInsets.top))
                preview
                if videoURL != nil {
                    timeline
                }
                toolstrip
                restoreBar
                panelWrap
                bottomBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showExport) {
            SLExportSheet(model: model, lutStore: lutStore)
        }
        .sheet(isPresented: $showRestorePicker) {
            RestoreLUTPicker(model: model) {
                model.requestRender()
                playback.refresh()
            }
        }
        .fullScreenCover(isPresented: $showFullPreview) {
            FullPreviewView(playback: playback, image: previewImage) {
                showFullPreview = false
            }
        }
        .onAppear {
            // 顺序很重要：先把上次调整恢复到模型，再配置播放器/同步选区，
            // 否则播放器与预览会用旧状态渲染。
            restoreSavedEditIfNeeded()
            configurePlaybackIfNeeded()
            syncTrim()
            playback.refresh()
            restoreStyleLUTIfNeeded()
        }
        .onChange(of: videoURL) { _, _ in configurePlaybackIfNeeded() }
        .onChange(of: tool) { _, newValue in
            // 编辑裁剪时绕过裁剪，画面完整显示，手柄坐标才能正确映射
            var settings = model.cropMask
            let shouldBypass = (newValue == .crop)
            if settings.bypassCrop != shouldBypass {
                settings.bypassCrop = shouldBypass
                model.cropMask = settings
                playback.refresh()
            }
        }
        .onDisappear {
            // 手指滑出按钮区域时 onEnded 可能不触发，离开页面时强制复位
            comparing = false
            playback.bypassGrading = false
            // 弹全屏预览/面板也会走到这里，此时不能销毁播放器
            if suppressTeardown {
                suppressTeardown = false
            } else {
                playback.teardown()
            }
            didConfigurePlayback = false
        }
    }

    /// 只配置一次；配置后播放器自行维护播放状态。
    private func configurePlaybackIfNeeded() {
        guard !didConfigurePlayback, let videoURL else { return }
        didConfigurePlayback = true
        playback.configure(url: videoURL) {
            (model.state, model.currentLUT)
        }
    }

    // MARK: 顶部导航

    private var nav: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: SL.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.meta)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: 预览

    private var preview: some View {
        ZStack {
            Color.black

            if let image = previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(Theme.muted)
            }


            // 裁剪：画面内拖手柄。
            // 降低 z 序，避免盖住右下角的「放大 / 对比」按钮导致点不动。
            if tool == .crop {
                GeometryReader { _ in
                    CropOverlay(
                        settings: cropMaskBinding,
                        sourceAspect: effectiveSourceAspect
                    ) {
                        playback.refresh()
                    }
                }
            }

            // 叠加控件分两排：上排左角标/胶囊、右直方图；下排右放大/对比。
            // 之前三件都堆在底部同一行，竖屏（画面窄）时会互相压住。
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 视频只留可点击的胶囊（信息重复的静态角标已移除）；
                        // 图片没有胶囊，角标用于显示「照片 / 曲线名」。
                        if videoURL != nil {
                            pillToggle
                        } else {
                            badge
                        }
                    }
                    Spacer(minLength: 4)
                    if !model.histogram.isEmpty {
                        HistogramOverlay(buckets: model.histogram)
                            .frame(width: 84, height: 48)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    zoomButton
                    compareButton
                }
                // 抬高控件层，保证裁剪手柄层不会盖住这两个按钮
            }
            .padding(10)

            if model.isRendering {
                ProgressView()
                    .tint(Theme.accent)
                    .scaleEffect(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
        // 弹性高度：吃掉导航/时间轴/工具条/面板/底栏之外的剩余空间。
        // 不再用 aspectRatio 撑高，否则竖屏素材会把整个 VStack 顶出屏幕。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// 预览要显示的图：视频用播放器当前帧，照片用模型渲染结果。
    private var previewImage: UIImage? {
        if videoURL != nil, let videoFrame = playback.frame {
            return videoFrame
        }
        return comparing ? model.originalUIImage : model.displayImage
    }

    private var previewAspect: CGFloat {
        guard let image = model.originalUIImage, image.size.height > 0 else { return 4.0 / 3.0 }
        return image.size.width / image.size.height
    }

    private var badge: some View {
        Text(badgeText)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
    }

    /// 灰片还原开关：点一下在「S-Log3 还原」与「709 直通」之间切换。
    private var pillToggle: some View {
        Button {
            // 只开关还原，不改用户选的曲线
            model.restoreEnabled.toggle()
            playback.refresh()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(!showsRestoreCurve ? Theme.meta : Theme.accent)
                    .frame(width: 5, height: 5)
                Text(showsRestoreCurve ? model.logProfile.title : "709 预览")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var zoomButton: some View {
        Button {
            suppressTeardown = true
            showFullPreview = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// 按住看原片。用 DragGesture(minimumDistance: 0) 而不是 onLongPressGesture：
    /// 后者在手势竞争下容易不触发，这正是之前"按了没反应"的原因。
    private var compareButton: some View {
        Text("对比")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(comparing ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(comparing ? Theme.accent : .black.opacity(0.55), in: Capsule())
            .overlay(
                Capsule().strokeBorder(comparing ? .clear : Theme.line, lineWidth: 0.5)
            )
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in setComparing(true) }
                    .onEnded { _ in setComparing(false) }
            )
    }

    private func setComparing(_ on: Bool) {
        guard comparing != on else { return }
        comparing = on
        playback.bypassGrading = on
        playback.refresh()
    }

    // MARK: 时间轴

    private var timeline: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)

                Text(playback.timeText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monoDigits()
                    .foregroundStyle(Theme.text)

                Spacer()

                Button {
                    playback.toggleMute()
                } label: {
                    Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(playback.isMuted ? Theme.meta : Theme.text)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(trimSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.meta)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let startX = width * CGFloat(model.trimStart)
                let endX = width * CGFloat(model.trimEnd)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surface2)

                    HStack(spacing: 2) {
                        ForEach(0..<10, id: \.self) { _ in
                            Rectangle().fill(Theme.line.opacity(0.5))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    // 选区外压暗
                    Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, startX))
                    Rectangle().fill(.black.opacity(0.45))
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)

                    // 已播放进度（仅选段内）
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent.opacity(0.28))
                        .frame(width: max(0, min(width * CGFloat(playback.progress), endX) - startX))
                        .offset(x: startX)

                    // 选段边框
                    Rectangle().fill(Theme.accent.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: max(0, startX))
                    Rectangle().fill(Theme.accent.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: min(width - 2, endX - 2))

                    // 播放头
                    Rectangle()
                        .fill(Theme.text)
                        .frame(width: 1.5)
                        .offset(x: max(0, min(width - 1.5, width * CGFloat(playback.progress))))

                    // 左右裁剪手柄
                    trimHandle(isStart: true, at: startX, width: width)
                    trimHandle(isStart: false, at: endX - 14, width: width)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                // 手柄手势与进度条手势共用同一坐标系，否则 handle 的局部坐标恒为 0…14
                .coordinateSpace(name: "timeline")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { drag in
                            guard playback.duration > 0 else { return }
                            let ratio = Double(min(1, max(0, drag.location.x / width)))
                            // seek 也限制在选段内
                            let clamped = min(max(ratio, model.trimStart), model.trimEnd)
                            playback.seek(to: clamped * playback.duration)
                        }
                )
            }
            .frame(height: 44)
        }
        .padding(.horizontal, SL.pad)
        .padding(.vertical, 8)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
        .onChange(of: model.trimStart) { _, _ in syncTrim() }
        .onChange(of: model.trimEnd) { _, _ in syncTrim() }
    }

    private func trimHandle(isStart: Bool, at x: CGFloat, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 14, height: 44)
            .overlay {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
            }
            .offset(x: max(0, min(width - 14, x)))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        // 手柄宽 14pt：按手指位置换算时扣掉抓握偏移，
                        // 否则按下瞬间边界会跳 7~14pt（短片约 2% 片长）
                        let raw = Double(min(max(0, value.location.x), width) / width)
                        let grip = 7.0 / Double(max(width, 1))
                        // start 手柄画在 startX（中心在边界右侧 7pt）→ 减；
                        // end 手柄画在 endX-14（中心在边界左侧 7pt）→ 加。
                        let fraction = isStart ? max(0, raw - grip) : min(1, raw + grip)
                        if isStart {
                            model.setTrim(start: fraction, end: model.trimEnd)
                        } else {
                            model.setTrim(start: model.trimStart, end: fraction)
                        }
                        syncTrim()
                    }
                    .onEnded { _ in
                        // 松手后把播放头拉回选区内，避免停留在被裁掉的区域
                        clampPlayheadToTrim()
                    }
            )
    }

    private func syncTrim() {
        playback.applyTrim(start: model.trimStart, end: model.trimEnd)
    }

    /// 把该素材上次保存的调整恢复到模型。
    ///
    /// 放在 onAppear 而不是父视图 init：init 时 @StateObject 还没挂载，
    /// requestRender 触发的 @Published 更新可能被丢弃，导致照片恢复后不重渲染。
    private func restoreSavedEditIfNeeded() {
        guard !didRestoreEdit else { return }
        didRestoreEdit = true
        guard !editKey.isEmpty,
              let saved = EditStateStore.shared.restore(for: editKey) else { return }
        model.restore(saved)
    }

    /// 恢复的编辑状态里若带风格 LUT，重新从 LUT 库解析并套用。
    ///
    /// EditState 只存 LUT 的引用（名称/路径），渲染器需要真实的 LUT3D，
    /// 所以进入编辑器要把引用重新解析一次，否则「上次套的 LUT」会消失。
    private func restoreStyleLUTIfNeeded() {
        guard !didRestoreStyleLUT, model.activeLUTName == nil,
              let reference = model.state.lut.reference else { return }
        guard let item = lutStore.items.first(where: { $0.name == reference.displayName }),
              let lut = try? lutStore.resolved(item) else { return }

        model.applyLUT(lut, name: item.name)
        playback.refresh()
        didRestoreStyleLUT = true
    }

    /// 把播放头限制在选段内。
    private func clampPlayheadToTrim() {
        guard playback.duration > 0 else { return }
        let fraction = min(max(playback.progress, model.trimStart), model.trimEnd)
        if abs(fraction - playback.progress) > 0.001 {
            playback.seek(to: fraction * playback.duration)
        }
    }

    /// 选段摘要：起止时间 + 时长。
    private var trimSummary: String {
        guard playback.duration > 0 else { return "" }
        let total = playback.duration
        let startSeconds = total * model.trimStart
        let lengthSeconds = total * (model.trimEnd - model.trimStart)
        return String(format: "%@ → %@ · %@",
                      timeString(startSeconds),
                      timeString(startSeconds + lengthSeconds),
                      timeString(lengthSeconds))
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var durationText: String {
        let total = max(0, Int(playback.duration.rounded()))
        return String(format: "%02d:%02d · %@", total / 60, total % 60,
                      videoURL?.lastPathComponent ?? "")
    }

    // MARK: 工具条

    private var toolstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Tool.allCases) { item in
                    let isOn = tool == item
                    Button {
                        tool = item
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.icon)
                                .font(.system(size: 12, weight: .medium))
                            Text(item.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(isOn ? Theme.accent : Theme.surface2, in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SL.pad)
        }
        .frame(height: 46)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: 还原 LUT 工具条

    /// 左侧入口选择曲线，右侧开关控制是否启用。
    /// 视频与图片都显示 —— 相机的 S-Log3 照片同样需要还原。
    private var restoreBar: some View {
        HStack(spacing: 10) {
            Button {
                showRestorePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.restoreEnabled ? Theme.accent : Theme.meta)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("还原 LUT")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(restoreTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.meta)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.meta)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { model.restoreEnabled },
                set: { newValue in
                    if newValue, model.logProfile == .off {
                        model.logProfile = .sLog3
                    }
                    model.restoreEnabled = newValue
                    model.requestRender()
                    playback.refresh()
                }
            ))
            .labelsHidden()
            .tint(Theme.accent)
        }
        .padding(.horizontal, SL.pad)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    /// 还原曲线是否真正生效（开关打开且选了曲线）。
    private var showsRestoreCurve: Bool {
        model.restoreEnabled && model.logProfile != .off
    }

    /// 左上角标：只有**开关打开**时才显示曲线名，否则显示默认态。
    private var badgeText: String {
        if model.restoreEnabled, model.logProfile != .off {
            return model.logProfile.title
        }
        return videoURL != nil ? "709" : "照片"
    }

    private var restoreTitle: String {
        guard model.restoreEnabled else { return "已关闭" }
        switch model.logProfile {
        case .off:
            return "未选择曲线"
        case .custom:
            guard !model.restoreLUTName.isEmpty else { return "未选择 LUT" }
            // 只查目录列表，不在这里解析 LUT 文件。
            // 之前调用 userLUT(named:) 会在 body 求值时同步解析近 1MB 文本，造成卡顿。
            let exists = RestoreLUTLibrary.shared.userLUTs.contains { $0.name == model.restoreLUTName }
            return exists
                ? model.restoreLUTName
                : "\(model.restoreLUTName)（LUT 缺失，请重新导入）"
        default:
            return model.logProfile.title
        }
    }

    // MARK: 面板

    private var panelWrap: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                panel
            }
            .padding(.horizontal, SL.pad)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .frame(height: 240)
        .background(Theme.bg)
    }

    @ViewBuilder
    private var panel: some View {
        switch tool {
        case .basic: basicPanel
        case .tone: tonePanel
        case .hsl: hslPanel
        case .split: splitPanel
        case .lut: lutPanel
        case .crop: cropPanel
        }
    }

    private var basicPanel: some View {
        VStack(spacing: 12) {
            sliderRow("曝光", Binding(get: { model.exposure }, set: { model.exposure = $0 }),
                      -2...2, { String(format: "%+.2f EV", $0) })
            sliderRow("明度", Binding(get: { model.brightness }, set: { model.brightness = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("对比度", Binding(get: { model.contrast }, set: { model.contrast = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("高光", Binding(get: { model.highlights }, set: { model.highlights = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("阴影", Binding(get: { model.shadows }, set: { model.shadows = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("色温", Binding(get: { model.temperature }, set: { model.temperature = $0 }),
                      -1...1, temperatureLabel)
            sliderRow("色调", Binding(get: { model.tint }, set: { model.tint = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("饱和度", Binding(get: { model.saturation }, set: { model.saturation = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("自然饱和度", Binding(get: { model.vibrance }, set: { model.vibrance = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
        }
    }

    private var tonePanel: some View {
        VStack(spacing: 12) {
            sliderRow("阴影", Binding(get: { model.shadows }, set: { model.shadows = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("高光", Binding(get: { model.highlights }, set: { model.highlights = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("黑色色阶", Binding(get: { model.blacks }, set: { model.blacks = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("白色色阶", Binding(get: { model.whites }, set: { model.whites = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
        }
    }

    private var hslPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(HSLBandID.allCases, id: \.self) { band in
                        let isOn = model.hslSelectedBand == band
                        Button {
                            model.hslSelectedBand = band
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(swatch(band))
                                    .frame(width: 7, height: 7)
                                Text(band.displayName)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(isOn ? Theme.accent : Theme.surface2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            sliderRow("色相", Binding(get: { model.hslHue }, set: { model.hslHue = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("饱和度", Binding(get: { model.hslSaturation }, set: { model.hslSaturation = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
            sliderRow("明度", Binding(get: { model.hslLuminance }, set: { model.hslLuminance = $0 }),
                      -1...1, { String(format: "%+.2f", $0) })
        }
    }

    private var splitPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("启用色调分离")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.isSplitToneOn },
                    set: { newValue in
                        model.isSplitToneOn = newValue
                        playback.refresh()
                    }
                ))
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            sliderRow("分离强度", Binding(get: { model.splitToneAmount }, set: { model.splitToneAmount = $0 }),
                      0...1, { String(format: "%.2f", $0) })
            sliderRow("阴影色相", Binding(get: { model.shadowHue }, set: { model.shadowHue = $0 }),
                      0...1, hueLabel)
            sliderRow("阴影饱和", Binding(get: { model.shadowSaturation }, set: { model.shadowSaturation = $0 }),
                      0...1, { String(format: "%.2f", $0) })
            sliderRow("高光色相", Binding(get: { model.highlightHue }, set: { model.highlightHue = $0 }),
                      0...1, hueLabel)
            sliderRow("高光饱和", Binding(get: { model.highlightSaturation }, set: { model.highlightSaturation = $0 }),
                      0...1, { String(format: "%.2f", $0) })
        }
    }

    private var lutPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.activeLUTName ?? "未套用 LUT")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.activeLUTName == nil ? Theme.meta : Theme.accent)

            // 存档里记着某个风格 LUT，但文件已不在 LUT 库 -> 明确提示，
            // 避免"名字对但画面没变化"这种静默失败。
            if let reference = model.state.lut.reference, model.activeLUTName == nil {
                Text("上次套用的 LUT「\(reference.displayName)」未找到，请重新导入或选择其他 LUT")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        model.applyLUT(nil, name: nil)
                        playback.refresh()
                    } label: {
                        Text("无")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.activeLUTName == nil ? Theme.onAccent : Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(model.activeLUTName == nil ? Theme.accent : Theme.surface2, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    ForEach(lutStore.items) { item in
                        let isOn = model.activeLUTName == item.name
                        Button {
                            if let lut = try? lutStore.resolved(item) {
                                model.applyLUT(lut, name: item.name)
                                playback.refresh()
                            }
                        } label: {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(isOn ? Theme.accent : Theme.surface2, in: Capsule())
                                .overlay(Capsule().strokeBorder(isOn ? .clear : Theme.line, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            sliderRow("LUT 强度", Binding(get: { model.lutIntensity }, set: { model.lutIntensity = $0 }),
                      0...1, { String(format: "%.2f", $0) })
        }
    }

    // MARK: 裁剪 / 蒙版面板

    /// 设备顶部的**真实**安全区高度。
    ///
    /// `fullScreenCover` 呈现时 SwiftUI 偶尔不向下传递安全区（GeometryReader 里读到 0），
    /// 内容就会从 y=0 开始排、和状态栏叠在一起。这里直接向窗口要真实 inset，
    /// 与 SwiftUI 已给出的 inset 做差，两种情形都不会重复留白。
    private var deviceTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }

    /// 源图的有效宽高比（旋转 90°/270° 时取倒数）。
    ///
    /// 裁剪框是归一化坐标，换算成像素宽高比必须乘上源图宽高比，
    /// 否则 1:1 在 16:9 素材上会变成 16:9 —— 上一版比例对不上就是这个原因。
    private var effectiveSourceAspect: CGFloat {
        let base = previewAspect
        return model.cropMask.turns % 2 == 0 ? base : 1 / max(base, 0.0001)
    }

    private var cropMaskBinding: Binding<CropMaskSettings> {
        Binding(
            get: { model.cropMask },
            set: { model.cropMask = $0 }
        )
    }

    private func setCrop<T>(_ keyPath: WritableKeyPath<CropMaskSettings, T>, _ value: T) {
        var settings = model.cropMask
        settings[keyPath: keyPath] = value
        model.cropMask = settings
        // 视频预览走播放器帧，必须显式刷新
        playback.refresh()
    }

    private func cropDouble(_ keyPath: WritableKeyPath<CropMaskSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.cropMask[keyPath: keyPath] },
            set: { setCrop(keyPath, $0) }
        )
    }

    private var cropPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(["自由", "1:1", "4:3", "16:9", "9:16"].enumerated()), id: \.offset) { index, title in
                    SLChip(title: title, isOn: model.cropMask.aspectLock == index, compact: true) {
                        applyAspectLock(index)
                    }
                }
                Spacer(minLength: 0)
            }

            SLPrimaryButton(title: "确定裁剪") {
                // 退出裁剪工具会触发 bypassCrop = false，裁剪正式生效
                tool = .basic
                playback.refresh()
            }

            HStack(spacing: 10) {
                SLTextButton(title: "水平镜像") {
                    setCrop(\.flipHorizontal, !model.cropMask.flipHorizontal)
                }
                SLTextButton(title: "垂直镜像") {
                    setCrop(\.flipVertical, !model.cropMask.flipVertical)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                SLTextButton(title: "旋转 90°") {
                    setCrop(\.turns, (model.cropMask.turns + 1) % 4)
                    // 旋转后源图宽高比变倒数，按当前锁定比例重新拟合
                    applyAspectLock(model.cropMask.aspectLock)
                }
                SLTextButton(title: "复位") {
                    var settings = model.cropMask
                    settings.cropX = 0
                    settings.cropY = 0
                    settings.cropWidth = 1
                    settings.cropHeight = 1
                    settings.aspectLock = 0
                    settings.turns = 0
                    model.cropMask = settings
                    playback.refresh()
                }
                Spacer()
            }

            Text("拖动画面内方框移动，拖四角改大小；选比例后会锁定形状")
                .font(.system(size: 11))
                .foregroundStyle(Theme.meta)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 应用比例锁定。
    ///
    /// 关键换算：像素宽高比 `A = (w·W) / (h·H)`，其中 w/h 是归一化宽高。
    /// 因此归一化关系是 `w / h = A / S`（S = W/H 源图宽高比）。
    /// 上一版直接令 w = h，在非方形源图上必然不等于目标比例。
    private func applyAspectLock(_ lockIndex: Int) {
        var settings = model.cropMask
        settings.aspectLock = lockIndex

        guard let ratio = settings.aspectRatio else {
            model.cropMask = settings
            playback.refresh()
            return
        }

        let sourceAspect = effectiveSourceAspect
        var width = 1.0
        var height = 1.0
        if ratio >= sourceAspect {
            // 目标更宽：宽度占满，高度按比例缩
            width = 1.0
            height = Double(sourceAspect / ratio)
        } else {
            // 目标更高：高度占满，宽度按比例缩
            height = 1.0
            width = Double(ratio / sourceAspect)
        }

        // 留一点边距（90%），围绕画面中心
        width *= 0.9
        height *= 0.9

        settings.cropWidth = width
        settings.cropHeight = height
        settings.cropX = (1 - width) / 2
        settings.cropY = (1 - height) / 2

        model.cropMask = settings
        playback.refresh()
    }

    private var maskPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(["关闭", "线性", "径向"].enumerated()), id: \.offset) { index, title in
                    SLChip(title: title, isOn: model.cropMask.maskKind == index, compact: true) {
                        var settings = model.cropMask
                        settings.maskKind = index
                        model.cropMask = settings
                        playback.refresh()
                    }
                }
                Spacer(minLength: 0)
            }

            if model.cropMask.maskKind == 0 {
                Text("选择线性或径向后，拖动画面上的橙色手柄调整位置与范围。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                sliderRow("羽化", cropDouble(\.feather), 0...1) { String(format: "%.2f", $0) }
                sliderRow("强度", cropDouble(\.strength), 0...1) { String(format: "%.2f", $0) }

                HStack {
                    Text("反向蒙版")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.cropMask.invert },
                        set: { setCrop(\.invert, $0) }
                    ))
                    .labelsHidden()
                    .tint(Theme.accent)
                }

                Text(model.cropMask.maskKind == 1
                     ? "拖动橙点移动分隔线中心，拖线段端点改角度"
                     : "拖动中心橙点移动，拖右侧橙点改半径")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 底部

    private var bottomBar: some View {
        HStack(spacing: 12) {
            SLTextButton(title: "重置") {
                // 重置后退出裁剪工具：否则 bypassCrop 与 tool 状态不一致，
                // 再拖手柄会按整幅坐标映射到已裁剪的画面上
                tool = .basic
                model.reset()
                playback.refresh()
            }
            SLPrimaryButton(title: videoURL != nil ? "导出" : "导出 JPG") {
                // 旁路只用于编辑预览，导出必须带上真实裁剪
                var settings = model.cropMask
                settings.bypassCrop = false
                model.cropMask = settings
                // 先退出裁剪工具：否则 tool 仍为 .crop 而 bypass 被置 false，
                // 预览已是裁剪后画面、叠加层却按整幅映射（永久错位）
                tool = .basic
                // 4) 点导出即保存：避免导出后 App 被杀导致调整丢失
                EditStateStore.shared.save(model.state, for: editKey)
                showExport = true
            }
        }
        .padding(.horizontal, SL.pad)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: 组件

    private func sliderRow(_ title: String,
                           _ value: Binding<Double>,
                           _ range: ClosedRange<Double>,
                           _ format: @escaping (Double) -> String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monoDigits()
                    .foregroundStyle(abs(value.wrappedValue) < 0.001 ? Theme.meta : Theme.accent)
            }
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { newValue in
                        value.wrappedValue = newValue
                        // 视频暂停时，改动参数要立刻重渲当前帧
                        playback.refresh()
                    }
                ),
                in: range
            )
            .tint(Theme.accent)
            .frame(height: 26)
        }
    }

    private func swatch(_ band: HSLBandID) -> Color {
        let rgb = band.swatchRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func temperatureLabel(_ value: Double) -> String {
        let kelvin = Int(5500 + value * 2500)
        return "\(kelvin)K"
    }

    private func hueLabel(_ value: Double) -> String {
        let names = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红"]
        let index = Int((value * Double(names.count)).rounded()) % names.count
        return names[max(0, min(names.count - 1, index))]
    }
}

// MARK: - 直方图叠加

/// 用 Path 画亮度直方图（原型里是 R/G/B/L 四条曲线，这里渲染的是亮度通道）。
struct HistogramOverlay: View {
    let buckets: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = max(1, buckets.count)
            let maxValue = max(0.0001, buckets.max() ?? 1)

            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height))
                for index in 0..<count {
                    let x = geo.size.width * CGFloat(index) / CGFloat(count - 1)
                    let normalized = CGFloat(buckets[index] / maxValue)
                    let y = geo.size.height * (1 - min(1, normalized))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [Theme.log.opacity(0.55), Theme.log.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    for index in 0..<count {
                        let x = geo.size.width * CGFloat(index) / CGFloat(count - 1)
                        let normalized = CGFloat(buckets[index] / maxValue)
                        let y = geo.size.height * (1 - min(1, normalized))
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(Theme.log.opacity(0.85), lineWidth: 0.7)
            }
        }
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
