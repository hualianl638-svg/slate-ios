//
//  TabsScreens.swift
//  SLATE
//
//  原型「LUT 库」与「我的」两屏。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - LUT 库

struct LUTLibraryScreen: View {

    @ObservedObject var store: LUTStore
    @State private var filter: Filter = .all
    @State private var showImporter = false

    enum Filter: Hashable {
        case all, builtin, mine
        var title: String {
            switch self {
            case .all: return "全部"
            case .builtin: return "内置"
            case .mine: return "我的"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            handleImport(result)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("LUT 库")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                SLIconButton(systemName: "plus", tint: Theme.text) { showImporter = true }
            }

            HStack(spacing: 8) {
                ForEach([Filter.all, .builtin, .mine], id: \.self) { option in
                    SLChip(title: option.title, isOn: filter == option) {
                        filter = option
                    }
                }
                Spacer()
            }

            Text("\(store.items.count) 个 LUT")
                .font(.system(size: 11))
                .foregroundStyle(Theme.meta)

            if let error = store.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, SL.pad)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollView {
            if filtered.isEmpty {
                SLEmptyState(
                    icon: "chart.xyaxis.line",
                    title: "还没有 LUT",
                    message: "点右上角「＋」导入 .cube 文件（1D / 3D 均可）。",
                    actionTitle: "导入 .cube"
                ) { showImporter = true }
                .padding(.top, 60)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, SL.pad)
                .padding(.bottom, 24)
            }
        }
    }

    private var filtered: [LUTItem] {
        switch filter {
        case .all: return store.items
        case .builtin: return store.items.filter(\.isBuiltin)
        case .mine: return store.items.filter { !$0.isBuiltin }
        }
    }

    private func row(_ item: LUTItem) -> some View {
        HStack(spacing: 12) {
            // 缩略示意：用渐变方块代表 LUT 的调性
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: item.isBuiltin
                            ? [Theme.accent.opacity(0.85), Theme.accentSoft()]
                            : [Theme.log, Theme.log.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.onAccent)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(item.isBuiltin ? "内置 · 3D LUT" : "我的 · 3D LUT")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
            }

            Spacer(minLength: 8)

            if !item.isBuiltin {
                Button {
                    store.delete(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.meta)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: SL.rMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SL.rMedium, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 0.5)
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            _ = try store.importCube(data: data, preferredName: url.deletingPathExtension().lastPathComponent)
        } catch {
            store.errorText = error.localizedDescription
        }
    }
}

// MARK: - 我的

struct MeScreen: View {

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    profile
                    stats
                    SLListGroup(title: "色彩管理") {
                        SLListRow(title: "工作色彩空间", value: "sRGB")
                        SLRowDivider()
                        SLListRow(title: "S-Log3 还原", value: "官方 709")
                        SLRowDivider()
                        SLListRow(title: "LUT 套用域", value: "显示参考")
                    }
                    SLListGroup(title: "导出") {
                        SLListRow(title: "照片默认格式", value: "JPG · 质量 95")
                        SLRowDivider()
                        SLListRow(title: "视频默认编码", value: "HEVC")
                        SLRowDivider()
                        SLListRow(title: "实况图时长", value: "3 秒")
                    }
                    SLListGroup(title: "存储") {
                        SLListRow(title: "缓存", value: "—")
                        SLRowDivider()
                        SLListRow(title: "关于 SLATE", value: "v1.0")
                    }
                    Text("Sony S-Log3 / S-Gamut3.Cine 官方转换参数 · Core Image 实时渲染")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, SL.pad)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("我的")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, SL.pad)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var profile: some View {
        HStack(spacing: 12) {
            Text("S")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 54, height: 54)
                .background(Theme.accent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("SLATE 用户")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("本地调色 · 不上传云端")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
            }
            Spacer()
        }
    }

    private var stats: some View {
        HStack(spacing: 0) {
            statBlock("8", "调节项")
            divider
            statBlock("3", "内置 LUT")
            divider
            statBlock("2", "导出格式")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: SL.rMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SL.rMedium, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 0.5)
        )
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 0.5, height: 26)
    }

    private func statBlock(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .monoDigits()
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.meta)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 颜色补充

extension Theme {
    /// 原型的辅助暖色 `#FFB08C`。
    static func accentSoft() -> Color {
        Color(red: 1.000, green: 0.690, blue: 0.549)
    }
}
