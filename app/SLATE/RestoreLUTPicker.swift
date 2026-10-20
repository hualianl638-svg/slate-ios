//
//  RestoreLUTPicker.swift
//  SLATE
//
//  还原 LUT 选择面板：内置厂商曲线 + 我的还原 LUT + 导入 .cube。
//  与风格化 LUT（LUT 库）完全分开，互不混用。
//

import SwiftUI
import UniformTypeIdentifiers

struct RestoreLUTPicker: View {

    @ObservedObject var model: EditorModel
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var errorText: String?
    @State private var userLUTs: [RestoreLUTLibrary.UserLUT] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        builtinSection
                        userSection
                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(SL.pad)
                }
            }
            .navigationTitle("还原 LUT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(Theme.accent)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                handleImport(result)
            }
        }
        .onAppear { reload() }
    }

    // MARK: 内置曲线

    private var builtinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SLGroupTitle(text: "内置厂商曲线")

            row(title: "关闭",
                subtitle: "不做灰片还原",
                selected: model.logProfile == .off,
                badge: nil) {
                model.logProfile = .off
                onChange()
                dismiss()
            }

            ForEach(LogProfile.allCases.filter { $0 != .off && $0 != .custom }) { profile in
                row(title: profile.title,
                    subtitle: profile.hasBuiltinLUT ? "官方 LUT 已内置" : "需导入官方 .cube 后使用",
                    selected: model.logProfile == profile,
                    badge: profile.hasBuiltinLUT ? nil : "缺 LUT") {
                    guard profile.hasBuiltinLUT else {
                        errorText = profile.missingLUTHint
                        return
                    }
                    model.logProfile = profile
                    onChange()
                    dismiss()
                }
            }
        }
    }

    // MARK: 我的还原 LUT

    private var userSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SLGroupTitle(text: "我的还原 LUT")

            if userLUTs.isEmpty {
                Text("还没有导入。可导入任何厂商或自己制作的 .cube，作为灰片还原。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(userLUTs) { lut in
                    row(title: lut.name,
                        subtitle: "我的还原 LUT",
                        selected: model.logProfile == .custom && model.restoreLUTName == lut.name,
                        badge: nil) {
                        model.restoreLUTName = lut.name
                        model.logProfile = .custom
                        onChange()
                        dismiss()
                    }
                }
            }

            Button {
                showImporter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("导入还原 LUT（.cube）")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 行

    private func row(title: String,
                     subtitle: String,
                     selected: Bool,
                     badge: String?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.meta)
                }
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.danger.opacity(0.15), in: Capsule())
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.line, lineWidth: selected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 逻辑

    private func reload() {
        RestoreLUTLibrary.shared.reloadUserLUTs()
        userLUTs = RestoreLUTLibrary.shared.userLUTs
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let lut = try RestoreLUTLibrary.shared.importUserLUT(
                data: data,
                preferredName: url.deletingPathExtension().lastPathComponent
            )
            reload()
            model.restoreLUTName = lut.name
            model.logProfile = .custom
            model.restoreEnabled = true
            onChange()
            errorText = nil
            dismiss()
        } catch {
            errorText = "导入失败：\(error.localizedDescription)"
        }
    }
}
