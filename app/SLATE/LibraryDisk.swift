//
//  LibraryDisk.swift
//  SLATE
//
//  图库条目的磁盘持久化。
//
//  为什么需要：之前 LibraryStore 只存在内存里，App 被系统回收后图库清空，
//  即使每张素材的调整已写入 UserDefaults，也没有入口重新打开它恢复。
//
//  存储布局（Documents/Library/）：
//    index.json          条目索引
//    media/<uuid>.mov    视频源文件（导入时拷贝，避免临时文件被清）
//    media/<uuid>.jpg    照片源图（长边 ≤ 2048）
//    thumbs/<uuid>.jpg   网格缩略图（长边 ≤ 320）
//

import Foundation
import UIKit

struct LibraryRecord: Codable {
    var id: UUID
    var title: String
    var subtitle: String
    var isVideo: Bool
    var editKey: String
    var createdAt: Date
    var mediaFile: String
    var thumbFile: String
}

enum LibraryDisk {

    /// 最多保留多少条（超出按最旧淘汰）。
    static let maxEntries = 60

    /// 串行队列：save 必须串行，否则旧快照的 prune 会删掉新快照刚写的文件。
    private static let diskQueue = DispatchQueue(label: "slate.library.disk", qos: .utility)

    static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Library", isDirectory: true)
    }

    private static var mediaDirectory: URL { root.appendingPathComponent("media", isDirectory: true) }
    private static var thumbDirectory: URL { root.appendingPathComponent("thumbs", isDirectory: true) }
    private static var indexURL: URL { root.appendingPathComponent("index.json") }

    // MARK: 保存

    /// 把当前图库写入磁盘（媒体与缩略图按需生成，已存在的不重写）。
    static func save(_ items: [LibraryItem]) {
        let snapshot = items
        diskQueue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            try? manager.createDirectory(at: thumbDirectory, withIntermediateDirectories: true)

            var records: [LibraryRecord] = []
            for item in snapshot.prefix(maxEntries) {
                let identifier = item.id.uuidString
                let mediaFile = "\(identifier).\(item.isVideo ? "mov" : "jpg")"
                let thumbFile = "\(identifier).jpg"
                let mediaURL = mediaDirectory.appendingPathComponent(mediaFile)
                let thumbURL = thumbDirectory.appendingPathComponent(thumbFile)

                if !manager.fileExists(atPath: mediaURL.path) {
                    if item.isVideo {
                        if let source = item.payload.videoURL {
                            try? manager.copyItem(at: source, to: mediaURL)
                        }
                    } else if let data = scaled(item.payload.image, maxEdge: 2048)
                        .jpegData(compressionQuality: 0.9) {
                        try? data.write(to: mediaURL, options: .atomic)
                    }
                }

                if !manager.fileExists(atPath: thumbURL.path),
                   let data = scaled(item.payload.image, maxEdge: 320)
                    .jpegData(compressionQuality: 0.8) {
                    try? data.write(to: thumbURL, options: .atomic)
                }

                // 媒体写不出来（例如视频临时文件已被清）就不入库，避免留下死条目
                guard manager.fileExists(atPath: mediaURL.path) else { continue }

                records.append(LibraryRecord(
                    id: item.id,
                    title: item.payload.title,
                    subtitle: item.payload.subtitle,
                    isVideo: item.isVideo,
                    editKey: item.payload.editKey,
                    createdAt: item.createdAt,
                    mediaFile: mediaFile,
                    thumbFile: thumbFile
                ))
            }

            if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: indexURL, options: .atomic)
            }
            prune(keeping: records)
        }
    }

    // MARK: 读取

    static func load() -> [LibraryItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([LibraryRecord].self, from: data) else {
            return []
        }
        var items: [LibraryItem] = []
        for record in records {
            let mediaURL = mediaDirectory.appendingPathComponent(record.mediaFile)
            let thumbURL = thumbDirectory.appendingPathComponent(record.thumbFile)
            guard FileManager.default.fileExists(atPath: mediaURL.path) else { continue }

            let thumbnail = UIImage(contentsOfFile: thumbURL.path)
            let sourceImage: UIImage?
            if record.isVideo {
                // 视频只用于网格缩略图，编辑器走 videoURL
                sourceImage = thumbnail
            } else {
                sourceImage = UIImage(contentsOfFile: mediaURL.path)
            }
            guard let image = sourceImage ?? thumbnail else { continue }

            let payload = LibraryPayload(
                image: image,
                isVideo: record.isVideo,
                videoURL: record.isVideo ? mediaURL : nil,
                title: record.title,
                subtitle: record.subtitle,
                isLogLikely: false,
                detectionNote: nil,
                editKey: record.editKey
            )
            items.append(LibraryItem(
                payload: payload,
                createdAt: record.createdAt,
                thumbnailImage: thumbnail,
                id: record.id
            ))
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: 清理

    private static func prune(keeping records: [LibraryRecord]) {
        let manager = FileManager.default
        let keepMedia = Set(records.map(\.mediaFile))
        let keepThumbs = Set(records.map(\.thumbFile))
        if let files = try? manager.contentsOfDirectory(atPath: mediaDirectory.path) {
            for file in files where !keepMedia.contains(file) {
                try? manager.removeItem(at: mediaDirectory.appendingPathComponent(file))
            }
        }
        if let files = try? manager.contentsOfDirectory(atPath: thumbDirectory.path) {
            for file in files where !keepThumbs.contains(file) {
                try? manager.removeItem(at: thumbDirectory.appendingPathComponent(file))
            }
        }
    }

    // MARK: 工具

    /// 等比缩放到长边不超过 maxEdge。
    private static func scaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
