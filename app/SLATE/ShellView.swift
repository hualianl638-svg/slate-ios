//
//  ShellView.swift
//  SLATE
//
//  原型的外壳：底部 tab（图库 / LUT / 我的）+ 从图库进入编辑器。
//

import SwiftUI

struct ShellView: View {

    @StateObject private var library = LibraryStore()
    @StateObject private var lutStore = LUTStore()

    @State private var tab: SLTab = .library
    @State private var editing: EditingPayload?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .library:
                        LibraryScreen(store: library) { payload in
                            editing = EditingPayload(payload: payload)
                        }
                    case .lut:
                        LUTLibraryScreen(store: lutStore)
                    case .me:
                        MeScreen()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                SLTabBar(selection: $tab)
            }
        }
        .fullScreenCover(item: $editing) { wrapper in
            EditorHost(payload: wrapper.payload) {
                editing = nil
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// `fullScreenCover(item:)` 需要 Identifiable。
private struct EditingPayload: Identifiable {
    let id = UUID()
    var payload: LibraryPayload
}

/// 一次编辑会话：为素材创建独立的 EditorModel，进入时装载。
private struct EditorHost: View {

    let payload: LibraryPayload
    var onClose: () -> Void

    @StateObject private var model = EditorModel(kind: .video)
    @StateObject private var lutStore = LUTStore()
    @State private var didLoad = false

    var body: some View {
        EditorScreen(
            model: model,
            lutStore: lutStore,
            title: payload.title,
            subtitle: payload.subtitle,
            onClose: onClose
        )
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            model.sourceVideoURL = payload.videoURL
            model.load(image: payload.image, isVideo: payload.isVideo, colorInfo: nil)
            // 图库导入路径没有做色彩探测，默认按 S-Log3 还原；
            // 用户可在预览区点「709 预览」胶囊切回不做还原。
            if payload.isVideo {
                model.isSLog3 = true
            }
        }
    }
}
