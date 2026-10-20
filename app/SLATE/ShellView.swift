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

    @StateObject private var model: EditorModel
    @StateObject private var lutStore = LUTStore()

    init(payload: LibraryPayload, onClose: @escaping () -> Void) {
        self.payload = payload
        self.onClose = onClose
        // 必须在 init 里装载：子视图的 onAppear 会早于父视图的 onAppear，
        // 若等到 onAppear 再设置 sourceVideoURL，编辑器的播放器就永远拿不到地址。
        let model = EditorModel(kind: .video)
        model.sourceVideoURL = payload.videoURL
        model.load(image: payload.image, isVideo: payload.isVideo, colorInfo: nil)
        if payload.isVideo {
            // 自动识别已关闭：灰片还原一律默认关，由用户手动打开还原开关。
            model.isSLog3 = false
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        EditorScreen(
            model: model,
            lutStore: lutStore,
            title: payload.title,
            subtitle: payload.subtitle,
            videoURL: payload.videoURL,
            onClose: onClose
        )
    }
}
