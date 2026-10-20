//
//  PhotosBrowser.swift
//  SLATE
//
//  直接浏览 iOS「照片」图库：按相册（文件夹）筛选，点击素材直接进编辑器。
//

import AVFoundation
import Photos
import SwiftUI
import UIKit

// MARK: - 浏览模型

@MainActor
final class PhotoLibraryBrowser: ObservableObject {

    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let collection: PHAssetCollection?
    }

    @Published private(set) var albums: [Album] = []
    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    @Published var selectedAlbumID: String = "all"

    private var thumbnails: [String: UIImage] = [:]
    private let imageManager = PHImageManager.default()

    func requestAccess() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var resolved = status
        if status == .notDetermined {
            resolved = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        }
        switch resolved {
        case .authorized, .limited:
            authorized = true
            loadAlbums()
            selectAlbum(id: "all")
        default:
            denied = true
        }
    }

    func loadAlbums() {
        var result: [Album] = [Album(id: "all", title: "全部", collection: nil)]

        // 智能相册（最近项目 / 视频 / 自拍…）
        let smartTypes: [PHAssetCollectionSubtype] = [
            .smartAlbumUserLibrary,
            .smartAlbumVideos,
            .smartAlbumFavorites,
            .smartAlbumRecentlyAdded,
        ]
        for type in smartTypes {
            let fetched = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: type, options: nil)
            fetched.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle else { return }
                if result.contains(where: { $0.title == title }) { return }
                result.append(Album(id: collection.localIdentifier, title: title, collection: collection))
            }
        }

        // 用户自建相册 / 文件夹（"按文件夹选择"）
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle else { return }
            result.append(Album(id: collection.localIdentifier, title: title, collection: collection))
        }

        albums = result
    }

    func selectAlbum(id: String) {
        selectedAlbumID = id
        guard let album = albums.first(where: { $0.id == id }) else { return }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                       PHAssetMediaType.image.rawValue,
                                       PHAssetMediaType.video.rawValue)

        let fetched: PHFetchResult<PHAsset>
        if let collection = album.collection {
            fetched = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            fetched = PHAsset.fetchAssets(with: options)
        }

        var list: [PHAsset] = []
        list.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
        thumbnails.removeAll()
    }

    func thumbnail(for asset: PHAsset) -> UIImage? {
        thumbnails[asset.localIdentifier]
    }

    /// 拉取缩略图（网格用）。
    func loadThumbnail(for asset: PHAsset, size: CGSize = CGSize(width: 220, height: 220)) {
        guard thumbnails[asset.localIdentifier] == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { [weak self] image, _ in
            guard let image else { return }
            Task { @MainActor in
                self?.thumbnails[asset.localIdentifier] = image
            }
        }
    }

    /// 把 PHAsset 转换为编辑器可用的素材。
    func payload(for asset: PHAsset) async -> LibraryPayload? {
        if asset.mediaType == .video {
            guard let avAsset = await requestAVAsset(for: asset),
                  let urlAsset = avAsset as? AVURLAsset else { return nil }
            let poster = await requestFullImage(for: asset, isVideo: true) ?? UIImage()
            let info = try? await VideoProbe.inspect(url: urlAsset.url)
            var parts: [String] = []
            if let info {
                parts.append("\(info.width)×\(info.height)")
                parts.append("\(Int(info.fps.rounded()))p")
                if let depth = info.bitDepth { parts.append("\(depth)bit") }
                parts.append(info.codec)
            }
            return LibraryPayload(
                image: poster,
                isVideo: true,
                videoURL: urlAsset.url,
                title: asset.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "视频",
                subtitle: parts.isEmpty ? "视频" : parts.joined(separator: " · "),
                isLogLikely: false,
                detectionNote: nil
            )
        } else {
            guard let image = await requestFullImage(for: asset, isVideo: false) else { return nil }
            return LibraryPayload(
                image: image,
                isVideo: false,
                videoURL: nil,
                title: asset.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "照片",
                subtitle: "\(Int(image.size.width)) × \(Int(image.size.height))",
                isLogLikely: false,
                detectionNote: nil
            )
        }
    }

    private func requestFullImage(for asset: PHAsset, isVideo: Bool) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact
            // 视频取一帧做封面，尺寸不必最大
            let target = isVideo ? CGSize(width: 1600, height: 1600) : PHImageManagerMaximumSize
            imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func requestAVAsset(for asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVAsset?, Never>) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

// MARK: - 浏览界面

struct PhotosBrowserView: View {

    @ObservedObject var browser: PhotoLibraryBrowser
    var onOpen: (LibraryPayload) -> Void

    @State private var loadingID: String?

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    var body: some View {
        Group {
            if browser.denied {
                SLEmptyState(
                    icon: "lock.slash",
                    title: "没有照片访问权限",
                    message: "请到 设置 > SLATE > 照片，允许访问后重试。"
                )
            } else if !browser.authorized {
                SLEmptyState(
                    icon: "photo.on.rectangle",
                    title: "读取照片图库",
                    message: "允许后可直接浏览相册，按文件夹选择素材。",
                    actionTitle: "允许访问"
                ) {
                    Task { await browser.requestAccess() }
                }
            } else {
                content
            }
        }
        .task {
            await browser.requestAccess()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // 相册（文件夹）选择
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(browser.albums) { album in
                        SLChip(title: album.title,
                               isOn: browser.selectedAlbumID == album.id,
                               compact: true) {
                            browser.selectAlbum(id: album.id)
                        }
                    }
                }
                .padding(.horizontal, SL.pad)
                .padding(.vertical, 8)
            }

            ScrollView {
                if browser.assets.isEmpty {
                    SLEmptyState(
                        icon: "photo.stack",
                        title: "这个相册是空的",
                        message: "换一个相册试试。"
                    )
                    .padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(browser.assets, id: \.localIdentifier) { asset in
                            cell(asset)
                                .onAppear { browser.loadThumbnail(for: asset) }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func cell(_ asset: PHAsset) -> some View {
        Button {
            guard loadingID == nil else { return }
            loadingID = asset.localIdentifier
            Task {
                defer { loadingID = nil }
                if let payload = await browser.payload(for: asset) {
                    onOpen(payload)
                }
            }
        } label: {
            ZStack {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .background(Theme.surface2)

                if let image = browser.thumbnail(for: asset) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView().tint(Theme.meta).scaleEffect(0.7)
                }

                if loadingID == asset.localIdentifier {
                    Color.black.opacity(0.5)
                    ProgressView().tint(Theme.accent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if asset.mediaType == .video {
                    Text(durationText(asset.duration))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
