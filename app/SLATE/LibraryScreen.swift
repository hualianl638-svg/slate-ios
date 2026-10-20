//
//  LibraryScreen.swift
//  SLATE
//
//  原型「图库」屏：大标题 + 搜索/导入 + 筛选胶囊 + 日期分组网格 + 底部 tab。
//

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - 素材载荷

/// 从图库带进编辑器的素材。
struct LibraryPayload {
    var image: UIImage
    var isVideo: Bool
    var videoURL: URL?
    var title: String
    var subtitle: String
    /// 是否判定为对数灰片（S-Log3 等）。照片恒为 false。
    var isLogLikely: Bool = false
    /// 识别说明，用于界面提示（如「10bit ITU_R_709_2 · 灰片」）。
    var detectionNote: String?
}

/// 图库条目。
struct LibraryItem: Identifiable {
    let id = UUID()
    var payload: LibraryPayload
    var thumbnail: UIImage { payload.image }
    var isVideo: Bool { payload.isVideo }
    var createdAt: Date = Date()
}

// MARK: - 素材库

@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var items: [LibraryItem] = []
    @Published var errorText: String?

    /// 从系统相册选择结果导入一条素材。
    func importItem(_ picker: PhotosPickerItem) async {
        let isVideo = picker.supportedContentTypes.contains { type in
            type.conforms(to: .movie) || type.conforms(to: .video)
        }

        do {
            if isVideo {
                guard let movie = try await picker.loadTransferable(type: Movie.self) else {
                    throw LibraryError.unsupported
                }
                let poster = try await Self.poster(for: movie.url)
                let info = try? await VideoProbe.inspect(url: movie.url)

                var subtitleParts: [String] = []
                if let info {
                    subtitleParts.append("\(info.width)×\(info.height)")
                    subtitleParts.append("\(Int(info.fps.rounded()))p")
                    if let depth = info.bitDepth { subtitleParts.append("\(depth)bit") }
                    subtitleParts.append(info.codec)
                } else {
                    subtitleParts.append(Self.shortSize(of: movie.url))
                }

                let note: String? = nil

                let payload = LibraryPayload(
                    image: poster,
                    isVideo: true,
                    videoURL: movie.url,
                    title: movie.url.deletingPathExtension().lastPathComponent,
                    subtitle: subtitleParts.joined(separator: " · "),
                    isLogLikely: false,
                    detectionNote: note
                )
                items.insert(LibraryItem(payload: payload), at: 0)
            } else {
                guard let data = try await picker.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw LibraryError.unsupported
                }
                let payload = LibraryPayload(
                    image: image,
                    isVideo: false,
                    videoURL: nil,
                    title: "照片",
                    subtitle: "\(Int(image.size.width)) × \(Int(image.size.height))"
                )
                items.insert(LibraryItem(payload: payload), at: 0)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
    }

    /// 按天分组（最近的在前）。
    func grouped() -> [(title: String, items: [LibraryItem])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [LibraryItem]] = [:]
        for item in items {
            let key = Self.dayTitle(item.createdAt, calendar: calendar)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let day = formatter.string(from: date)
        if calendar.isDateInToday(date) { return "今天 · \(day)" }
        if calendar.isDateInYesterday(date) { return "昨天 · \(day)" }
        return day
    }

    private nonisolated static func poster(for url: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        let (cgImage, _) = try await generator.image(at: .zero)
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func shortSize(of url: URL) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let bytes = (attributes[.size] as? Int) ?? 0
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }
}

enum LibraryError: LocalizedError {
    case unsupported
    var errorDescription: String? { "这个素材格式暂不支持导入。" }
}

// MARK: - 图库屏

struct LibraryScreen: View {

    @ObservedObject var store: LibraryStore
    /// 选中条目回调（交给 Shell 打开编辑器）。
    var onOpen: (LibraryPayload) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var filter: Filter = .all
    @State private var showImporter = false

    enum Filter: Hashable {
        case all, photo, video
        var title: String {
            switch self {
            case .all: return "全部"
            case .photo: return "照片"
            case .video: return "视频"
            }
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            scroll
        }
        .photosPicker(isPresented: $showImporter, selection: $pickerItem, matching: .any(of: [.images, .videos]))
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await store.importItem(item)
                pickerItem = nil
                // 选完直接进编辑器
                if let newest = store.items.first {
                    onOpen(newest.payload)
                }
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("图库")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    SLIconButton(systemName: "magnifyingglass", tint: Theme.muted) {}
                    SLIconButton(systemName: "plus", tint: Theme.text) { showImporter = true }
                }
            }

            HStack(spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 11, weight: .semibold))
                        Text("从相册选择")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Text("系统相册，可按相簿/文件夹浏览")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.meta)
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach([Filter.all, .photo, .video], id: \.self) { option in
                    SLChip(title: option.title, isOn: filter == option) {
                        filter = option
                    }
                }
                Spacer()
            }

            HStack {
                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Theme.log).frame(width: 5, height: 5)
                    Text("本机素材")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.meta)
                }
            }
        }
        .padding(.horizontal, SL.pad)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var metaLine: String {
        let total = store.items.count
        let videos = store.items.filter(\.isVideo).count
        return "\(total) 项 · 视频 \(videos) · 照片 \(total - videos)"
    }

    // MARK: 网格

    private var scroll: some View {
        ScrollView {
            if store.items.isEmpty {
                SLEmptyState(
                    icon: "square.stack.3d.up.slash",
                    title: "还没有素材",
                    message: "从系统相册导入 S-Log3 视频或 RAW 照片开始调色。",
                    actionTitle: "导入素材"
                ) { showImporter = true }
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: []) {
                    ForEach(store.grouped(), id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 14)
                            .padding(.bottom, 2)

                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(group.items.filter(matches)) { item in
                                cell(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 24)
            }
        }
        .clipped()
    }

    private func matches(_ item: LibraryItem) -> Bool {
        switch filter {
        case .all: return true
        case .photo: return !item.isVideo
        case .video: return item.isVideo
        }
    }

    private func cell(_ item: LibraryItem) -> some View {
        Button {
            onOpen(item.payload)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(uiImage: item.thumbnail)
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text(item.isVideo ? "视频" : "照片")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(5)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.remove(item)
            } label: {
                Label("从图库移除", systemImage: "trash")
            }
        }
    }
}
