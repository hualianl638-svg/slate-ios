//
//  LUTPanel.swift
//  SLATE
//
//  M3：LUT 面板。导入 .cube、选择、调强度、删除。
//
//  为什么用 fileImporter 而不是自建 UIDocumentPicker：
//  .cube 没有系统标准 UTI，fileImporter 配合 UTType.data + 扩展名校验
//  是最少代码、最少平台差异的做法；自己包 UIViewController 只会多写 80 行。
//

import SwiftUI
import UniformTypeIdentifiers

struct LUTPanel: View {

    @ObservedObject var store: LUTStore
    @ObservedObject var model: EditorModel

    @State private var showImporter = false
    @State private var isImporting = false
    @State private var pendingDelete: LUTItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            errorLine
            itemList
            if model.activeLUTName != nil {
                strengthRow
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "删除这个 LUT？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete {
                    model.applyLUT(nil, name: nil)
                    store.delete(item)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
    }

    // MARK: 标题

    private var header: some View {
        HStack {
            Text("LUT")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            if let name = model.activeLUTName {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.log)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showImporter = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isImporting ? "hourglass" : "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("导入 .cube")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surface2, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = store.errorText {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 列表

    private var itemList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 「无」= 不套 LUT
                chip(
                    title: "无",
                    isOn: model.activeLUTName == nil
                ) {
                    model.applyLUT(nil, name: nil)
                }

                ForEach(store.items) { item in
                    chip(
                        title: item.name,
                        isOn: model.activeLUTName == item.name,
                        onLongPress: item.isBuiltin ? nil : { pendingDelete = item }
                    ) {
                        select(item)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(
        title: String,
        isOn: Bool,
        onLongPress: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isOn ? Theme.accent : Theme.surface2,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.clear : Theme.line, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                onLongPress?()
            }
        )
    }

    // MARK: 强度

    private var strengthRow: some View {
        VStack(spacing: 6) {
            HStack {
                Text("强度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text(String(format: "%d%%", Int(model.lutIntensity * 100)))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Slider(
                value: Binding(
                    get: { model.lutIntensity },
                    set: { model.lutIntensity = $0 }
                ),
                in: 0...1
            ) { editing in
                if !editing { model.requestRender() }
            }
            .tint(Theme.accent)
        }
    }

    // MARK: 行为

    private func select(_ item: LUTItem) {
        do {
            let lut = try store.resolved(item)
            model.applyLUT(lut, name: item.name)
            store.errorText = nil
        } catch {
            store.errorText = "无法套用「\(item.name)」：\(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            store.errorText = "导入失败：\(error.localizedDescription)"

        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            defer { isImporting = false }

            // 从「文件」App 选来的 URL 需要显式开启安全作用域
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let item = try store.importCube(
                    data: data,
                    preferredName: url.deletingPathExtension().lastPathComponent
                )
                // 导入后立即套用，用户能看到效果
                let lut = try store.resolved(item)
                model.applyLUT(lut, name: item.name)
                store.errorText = nil
            } catch {
                store.errorText = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
