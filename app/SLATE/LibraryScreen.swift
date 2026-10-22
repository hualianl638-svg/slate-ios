//
//  LibraryScreen.swift
//  SLATE
//
//  原型「图库」屏：大标题 + 搜索/导入 + 筛选胶囊 + 日期分组网格 + 底部 tab。
//

import AVFoundation
import CryptoKit
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
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
    /// 用于按素材保存/恢复调整的稳定键。
    var editKey: String = ""
}

/// 图库条目。
struct LibraryItem: Identifiable {
    var id = UUID()
    var payload: LibraryPayload
    /// 网格缩略图（从磁盘恢复时与源图分开保存；没有则退回源图）
    var thumbnailImage: UIImage?
    var isVideo: Bool { payload.isVideo }
    var createdAt: Date = Date()

    var thumbnail: UIImage { thumbnailImage ?? payload.image }

    init(payload: LibraryPayload,
         createdAt: Date = Date(),
         thumbnailImage: UIImage? = nil,
         id: UUID = UUID()) {
        self.payload = payload
        self.createdAt = createdAt
        self.thumbnailImage = thumbnailImage
        self.id = id
    }
}

// MARK: - 素材库

@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var items: [LibraryItem] = []
    @Published var errorText: String?

    init() {
        // 从磁盘恢复图库（上次运行导入的素材）
        items = LibraryDisk.load()
    }

    /// 插入一条素材并落盘（外部无法直接改 private(set) 的 items）。
    func insert(_ item: LibraryItem) {
        items.insert(item, at: 0)
        LibraryDisk.save(items)
    }

    /// 从系统相册选择结果导入一条素材。
    func importItem(_ picker: PhotosPickerItem) async {
        let isVideo = picker.supportedContentTypes.contains { type in
            type.conforms(to: .movie) || type.conforms(to: .video)
        }

        // 只有"可能是 RAW"时才需要相册原始资源；普通照片走 PhotosPicker 数据即可。
        let rawLikely = picker.supportedContentTypes.contains { $0.conforms(to: .rawImage) }

        do {
            // 权限检查必须在 do 内，throw 才能被下面的 catch 接住并显示给用户。
            if rawLikely {
                switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
                case .notDetermined:
                    let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    guard granted == .authorized else { throw RawImage.RawError.permissionDenied }
                case .authorized:
                    break
                default:
                    // .limited / .denied / .restricted：拿不到 RAW 原片 -> 直接报错，不降级
                    throw RawImage.RawError.permissionDenied
                }
            }
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
                    detectionNote: note,
                    editKey: "video-\(picker.itemIdentifier ?? movie.url.lastPathComponent)"
                )
                items.insert(LibraryItem(payload: payload), at: 0)
                LibraryDisk.save(items)
            } else {

                // RAW 优先：相册里选 RAW 时 PhotosPicker 只给 JPEG 预览，
                // 必须用 PhotoKit 取回原始数据再解码；解不出来直接报错（按需求：不降级）。
                var image: UIImage?
                var isRaw = false
                var rawKey: String?
                if let identifier = picker.itemIdentifier,
                   let rawAsset = await RawImage.loadRawAsset(identifier: identifier) {
                    // hint 传入资源的真实 UTI：ImageIO 靠它选对 RAW 解码器
                    guard let decoded = RawImage.decode(rawAsset.data, hint: rawAsset.uti) else {
                        throw RawImage.RawError.unsupported
                    }
                    image = decoded
                    isRaw = true
                    rawKey = try RawImage.saveOriginal(rawAsset.data, key: "photo-" + identifier)
                }
                // 明确是 RAW 却取不到原始资源 -> 报错，不允许静默降级成 JPEG 预览
                if rawLikely, image == nil {
                    throw RawImage.RawError.unsupported
                }
                if image == nil {
                    guard let data = try await picker.loadTransferable(type: Data.self) else {
                        throw LibraryError.unsupported
                    }
                    if RawImage.looksLikeRaw(data) {
                        guard let decoded = RawImage.decode(data) else {
                            throw RawImage.RawError.unsupported
                        }
                        image = decoded
                        isRaw = true
                        rawKey = try RawImage.saveOriginal(data, key: picker.itemIdentifier.map { "photo-" + $0 } ?? Self.photoKey(for: data))
                    } else {
                        guard let decoded = UIImage(data: data) else { throw LibraryError.unsupported }
                        image = decoded
                    }
                }
                guard let image else { throw LibraryError.unsupported }
                let payload = LibraryPayload(
                    image: image,
                    isVideo: false,
                    videoURL: nil,
                    title: isRaw ? "RAW 照片" : "照片",
                    subtitle: "\(Int(image.size.width)) × \(Int(image.size.height))"
                        + (isRaw ? " · RAW" : ""),
                    // rawKey 是 saveOriginal 返回的**文件名**（key + 扩展名），
                    // 必须剥掉扩展名才与 hasOriginal/deleteOriginal 的 key 一致；
                    // 最后兜底用 UUID，避免所有无 identifier 的照片共用同一个存档键。
                    editKey: picker.itemIdentifier.map { "photo-" + $0 }
                        ?? rawKey.map { ($0 as NSString).deletingPathExtension }
                        ?? UUID().uuidString
                )
                items.insert(LibraryItem(payload: payload), at: 0)
                LibraryDisk.save(items)

            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        LibraryDisk.save(items)
        EditStateStore.shared.clear(for: item.payload.editKey)
        // RAW 原片必须一起删：否则空间不释放，2GB 上限会把导入永久锁死
        RawImage.deleteOriginal(key: item.payload.editKey)
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

    /// 照片的稳定标识键。
    ///
    /// 之前用「尺寸 + 字节数」，同尺寸同体积的不同照片会撞键、互相串用调整；
    /// 改成文件内容 SHA256 前 16 位，几乎不可能碰撞。
    private nonisolated static func photoKey(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "photo-" + hex.prefix(16)
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
    @State private var showRawImporter = false
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

        /// 从「文件」App 导入 RAW 原片（支持多选）。
    private func importRawFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                do {
                    let data = try Data(contentsOf: url)
                    let hint = UTType(filenameExtension: url.pathExtension)?.identifier
                    guard RawImage.looksLikeRaw(data), let image = RawImage.decode(data, hint: hint) else {
                        throw RawImage.RawError.unsupported
                    }
                    let key = "raw-" + url.lastPathComponent + "-" + String(data.count)
                    _ = try RawImage.saveOriginal(data, key: key)
                    let payload = LibraryPayload(
                        image: image,
                        isVideo: false,
                        videoURL: nil,
                        title: url.deletingPathExtension().lastPathComponent,
                        subtitle: "\(Int(image.size.width)) × \(Int(image.size.height)) · RAW",
                        editKey: key
                    )
                    store.insert(LibraryItem(payload: payload))
                    store.errorText = nil
                } catch {
                    store.errorText = error.localizedDescription
                }
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

var body: some View {
        VStack(spacing: 0) {
            header
            scroll
        }
        .fileImporter(
            isPresented: $showRawImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { importRawFiles(urls) }
        }
        .alert("导入失败", isPresented: Binding(
            get: { store.errorText != nil },
            set: { if !$0 { store.errorText = nil } }
        )) {
            Button("好", role: .cancel) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
        .photosPicker(isPresented: $showImporter, selection: $pickerItem, matching: .any(of: [.images, .videos]))
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                let countBefore = store.items.count
                await store.importItem(item)
                pickerItem = nil
                // 导入失败时不要 fall through 去打开上一条素材
                guard store.errorText == nil,
                      store.items.count > countBefore,
                      let newest = store.items.first else { return }
                onOpen(newest.payload)
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
                // 主入口：系统相册（实心强调色胶囊）
                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 11, weight: .semibold))
                        Text("从相册选择")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                // 次入口：RAW 原片（描边胶囊，视觉层级低于主按钮）
                Button {
                    showRawImporter = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("RAW 文件")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
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
