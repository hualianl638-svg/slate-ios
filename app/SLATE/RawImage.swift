//
//  RawImage.swift
//  SLATE
//
//  RAW 图片支持：佳能 CR2/CR3、索尼 ARW、尼康 NEF、富士 RAF、大疆 DNG 等。
//
//  解码底层用 ImageIO/CoreImage（iOS 系统 RAW 能力）。
//  相册里的 RAW 默认只会给 JPEG 预览，必须用 PhotoKit 取回原始资源。
//

import Foundation
import Photos
import UIKit
import CoreImage

enum RawImage {

    /// 支持的扩展名（用于识别与临时文件命名，ImageIO 依赖扩展名判断格式）。
    static let extensions: [String] = [
        "cr2", "cr3", "crw",            // Canon
        "arw", "srf", "sr2",            // Sony
        "nef", "nrw",                   // Nikon
        "raf",                          // Fujifilm
        "dng",                          // DJI / Adobe / 通用
        "rw2", "raw", "orf", "pef", "x3f", "3fr", "fff", "iiq", "mrw",
    ]

    /// RAW 原片存放目录（Documents/RawOriginals）。
    static var originalsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("RawOriginals", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 整个图库目录已占用字节数（用于 0.7GB 容量上限）。
    static func libraryBytes() -> Int64 {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let roots = ["Library", "RawOriginals"].map { documents.appendingPathComponent($0, isDirectory: true) }
        var total: Int64 = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: []
            ) else { continue }
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    static let capacityLimit: Int64 = 700 * 1024 * 1024   // 0.7 GB

    /// 从文件头判断是不是 RAW（相册临时文件可能没有后缀）。
    static func looksLikeRaw(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        let head = [UInt8](data.prefix(16))
        let isTIFF = (head[0] == 0x49 && head[1] == 0x49 && head[2] == 0x2A && head[3] == 0x00)
            || (head[0] == 0x4D && head[1] == 0x4D && head[2] == 0x00 && head[3] == 0x2A)
        if isTIFF { return true }   // DNG / NEF / ARW / CR2 / ORF / PEF / RW2
        if head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 {   // "ftyp"
            let brand = String(bytes: head[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("crx") { return true }   // Canon CR3
        }
        if data.count > 16, data.prefix(8) == Data("FUJIFILM".utf8) { return true }   // Fujifilm RAF
        return false
    }

    /// 猜测扩展名（ImageIO 靠它选 RAW 解码器）。
    static func guessedExtension(_ data: Data) -> String {
        guard data.count > 12 else { return "dng" }
        let head = [UInt8](data.prefix(16))
        if data.prefix(8) == Data("FUJIFILM".utf8) { return "raf" }
        if head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 { return "cr3" }
        // TIFF 系：靠偏移 8 处的厂商标记区分
        if data.count > 12 {
            let marker = String(bytes: [UInt8](data.prefix(12)).dropFirst(8), encoding: .ascii) ?? ""
            if marker.hasPrefix("CR") { return "cr2" }
            if marker.hasPrefix("IIRO") || marker.hasPrefix("IIRS") { return "orf" }
            if marker.hasPrefix("IIU") { return "rw2" }
        }
        return "dng"
    }

    /// 从相册资源取 RAW 原始数据。
    static func loadRawData(identifier: String) async -> Data? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)

        let brandPrefixes = ["com.canon", "com.sony", "com.nikon", "com.fuji", "com.dji",
                             "com.adobe", "com.panasonic", "com.olympus", "com.pentax", "com.sigma"]
        let candidates = resources.filter { resource in
            let uti = resource.uniformTypeIdentifier.lowercased()
            if brandPrefixes.contains(where: { uti.hasPrefix($0) }) { return true }
            return extensions.contains { uti.hasSuffix($0) || uti.hasSuffix(".\($0)") }
        }
        guard let raw = candidates.first(where: { $0.type == .alternatePhoto }) ?? candidates.first else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(for: raw, options: options) { data, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// 解码 RAW 数据。失败返回 nil（调用方必须报错，不降级）。
    static func decode(_ data: Data, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let ext = guessedExtension(data)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: temporary)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard var output = CIImage(contentsOf: temporary, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        if let maxPixelSize {
            let longest = max(output.extent.width, output.extent.height)
            if longest > maxPixelSize {
                let scale = maxPixelSize / longest
                output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let context = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 把 RAW 原片保存到 Documents/RawOriginals，返回文件名。
    /// 超过容量上限时抛错（由调用方提示用户清理）。
    @discardableResult
    static func saveOriginal(_ data: Data, key: String) throws -> String {
        let used = libraryBytes()
        guard used + Int64(data.count) <= capacityLimit else {
            throw RawError.capacityExceeded(limitMB: Int(capacityLimit / 1024 / 1024))
        }
        let ext = guessedExtension(data)
        let safeKey = key.replacingOccurrences(of: "/", with: "-")
        let name = "\(safeKey).\(ext)"
        let url = originalsDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return name
    }

    /// 读取已保存的 RAW 原片。
    static func originalData(name: String) -> Data? {
        try? Data(contentsOf: originalsDirectory.appendingPathComponent(name))
    }

    enum RawError: LocalizedError {
        case capacityExceeded(limitMB: Int)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .capacityExceeded(let limitMB):
                return "RAW 存储已满（上限 \(limitMB)MB），请到图库删除部分 RAW 素材后再导入"
            case .unsupported:
                return "此 RAW 格式系统无法解码（支持 CR2/CR3/ARW/NEF/RAF/DNG 等），请改用 JPEG/HEIC"
            }
        }
    }
}
