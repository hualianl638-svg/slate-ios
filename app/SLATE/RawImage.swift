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
import ImageIO
import CoreImage
import UniformTypeIdentifiers

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

    static let capacityLimit: Int64 = 2000 * 1024 * 1024  // 2 GB（超过提示清理）

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

    /// 决定临时文件的扩展名——ImageIO 靠它选 RAW 解码器，猜错就会解码失败。
    /// 优先用调用方给的 UTI（相册资源的 uniformTypeIdentifier 最准确），
    /// 否则扫描厂商标记（ARW/NEF/RAF 都是 TIFF 头，偏移 8 处认不出来）。
    static func preferredExtension(_ data: Data, hint: String?) -> String {
        if let hint, let type = UTType(hint), let ext = type.preferredFilenameExtension {
            return ext
        }
        // 必须按字节扫描：RAW 是二进制，String(encoding: .ascii) 会整体返回 nil
        let window = Data(data.prefix(min(data.count, 65536)))
        func contains(_ marker: String) -> Bool {
            window.range(of: Data(marker.utf8)) != nil
        }
        if contains("SONY") { return "arw" }
        if contains("NIKON") || contains("Nikon") { return "nef" }
        if contains("FUJIFILM") { return "raf" }
        if contains("Canon") { return "cr2" }
        if contains("Panasonic") { return "rw2" }
        if contains("OLYMPUS") { return "orf" }
        if contains("PENTAX") { return "pef" }
        // 兜底：CR3(ftyp)/ORF/RW2 的偏移-8 魔数识别
        return legacyGuessedExtension(data)
    }

    /// 兼容旧调用（不带 hint 时按厂商字符串识别）。
    static func guessedExtension(_ data: Data) -> String {
        preferredExtension(data, hint: nil)
    }

    static func legacyGuessedExtension(_ data: Data) -> String {
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
    static func loadRawAsset(identifier: String) async -> (data: Data, uti: String?)? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)

        let brandPrefixes = ["com.canon", "com.sony", "com.nikon", "com.fuji", "com.dji",
                             "com.adobe", "com.panasonic", "com.olympus", "com.pentax", "com.sigma",
                             "com.apple.camera-raw-image"]   // iPhone ProRAW
        let candidates = resources.filter { resource in
            let uti = resource.uniformTypeIdentifier.lowercased()
            if brandPrefixes.contains(where: { uti.hasPrefix($0) }) { return true }
            return extensions.contains { uti.hasSuffix($0) || uti.hasSuffix(".\($0)") }
        }
        guard let raw = candidates.first(where: { $0.type == .alternatePhoto }) ?? candidates.first else {
            return nil
        }

        // 注意：requestData 的尾随闭包会绑定到 completionHandler（只收 1 个参数），
        // 且数据是分块多次回调的，不能在那里直接 resume。改用 writeData 落临时文件。
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-src-\(UUID().uuidString).dat")
        defer { try? FileManager.default.removeItem(at: temporary) }

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let uti = raw.uniformTypeIdentifier
            PHAssetResourceManager.default().writeData(for: raw, toFile: temporary, options: options) { error in
                guard error == nil, let data = try? Data(contentsOf: temporary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data: data, uti: uti))
            }
        }
    }

    /// 多策略解码 RAW：
    /// iOS 的 RAW 解码依赖"扩展名/UTI → 解码器"的匹配，猜错就返回 nil。
    /// 这里把常见扩展名 × UTI hint × ImageIO/CoreImage 两条通道全部试一遍，
    /// 仍失败才报错（并带上诊断信息，便于用户/开发者定位是哪张图不兼容）。
    static func decode(_ data: Data, maxPixelSize: CGFloat? = nil, hint: String? = nil) -> UIImage? {
        let hintExtension = hint.flatMap { UTType($0)?.preferredFilenameExtension }
        var extensions: [String] = []
        for candidate in [hintExtension, preferredExtension(data, hint: hint), "arw", "dng", "tif"] {
            if let candidate, !extensions.contains(candidate) { extensions.append(candidate) }
        }
        let utiHints: [String?] = [hint, "public.camera-raw-image", "com.sony.arw-raw-image", nil]

        for ext in extensions {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("raw-\(UUID().uuidString).\(ext)")
            guard (try? data.write(to: temporary)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: temporary) }

            // 通道 A：ImageIO + UTI hint（系统 RAW 解码器注册在 UTI 上）
            for uti in utiHints {
                var options: [CFString: Any] = [:]
                if let uti { options[kCGImageSourceTypeIdentifierHint] = uti as CFString }
                guard let source = CGImageSourceCreateWithURL(
                    temporary as CFURL, options as CFDictionary
                ) else { continue }
                let decodeOptions: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailFromImageAlways: false
                ]
                if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions as CFDictionary) {
                    return finish(cgImage, maxPixelSize: maxPixelSize)
                }
            }

            // 通道 B：Core Image（部分 RAW 只有 CI 通道能读）
            if let output = CIImage(contentsOf: temporary) {
                let context = CIContext(options: [.workingColorSpace: CGColorSpace.extendedLinearSRGB])
                if let cgImage = context.createCGImage(
                    output,
                    from: output.extent,
                    format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                ) {
                    return finish(cgImage, maxPixelSize: maxPixelSize)
                }
            }
        }
        return nil
    }

    /// 把解码出的 CGImage 转成 UIImage，并按需缩放。
    private static func finish(_ cgImage: CGImage, maxPixelSize: CGFloat?) -> UIImage {
        let image = UIImage(cgImage: cgImage)
        guard let maxPixelSize else { return image }
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixelSize else { return image }
        let scale = maxPixelSize / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 解码失败时报出可定位的错误（含文件名与大小）。
    static func decodeFailure(name: String, data: Data) -> RawError {
        RawError.decodeFailed(name: name, megabytes: Double(data.count) / 1_048_576)
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

    /// 该素材是否存过 RAW 原片（按 editKey 前缀匹配，不依赖 subtitle 文本）。
    static func hasOriginal(key: String) -> Bool {
        originalName(for: key) != nil
    }

    /// 删除该素材的 RAW 原片（返回是否真的删了文件）。
    @discardableResult
    static func deleteOriginal(key: String) -> Bool {
        guard let name = originalName(for: key) else { return false }
        try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent(name))
        return true
    }

    private static func originalName(for key: String) -> String? {
        let safeKey = key.replacingOccurrences(of: "/", with: "-")
        guard let files = try? FileManager.default.contentsOfDirectory(
            atPath: originalsDirectory.path
        ) else { return nil }
        return files.first { $0.hasPrefix(safeKey + ".") }
    }

    /// 读取已保存的 RAW 原片。
    static func originalData(name: String) -> Data? {
        try? Data(contentsOf: originalsDirectory.appendingPathComponent(name))
    }

    enum RawError: LocalizedError {
        case capacityExceeded(limitMB: Int)
        case unsupported
        case permissionDenied
        case decodeFailed(name: String, megabytes: Double)
        case rawUnavailable

        var errorDescription: String? {
            switch self {
            case .capacityExceeded(let limitMB):
                return "RAW 存储已满（上限 \(limitMB)MB），请到图库删除部分 RAW 素材后再导入"
            case .unsupported:
                return "此 RAW 格式系统无法解码（支持 CR2/CR3/ARW/NEF/RAF/DNG 等），请改用 JPEG/HEIC"
            case .rawUnavailable:
                return "取不到这张 RAW 的原始文件（可能在 iCloud 尚未下载，或相册权限不是「完全访问」）。请先到设置里确认权限，或点「RAW 文件」从文件 App 导入原片。"
            case .decodeFailed(let name, let megabytes):
                return "无法解码 \(name)（\(String(format: "%.1f", megabytes)) MB）。iOS 可能暂不支持该机型的 RAW 压缩格式，可尝试在相机/电脑上转成 DNG 或 JPEG 后再导入。"
            case .permissionDenied:
                return "取回 RAW 原片需要相册「完全访问」权限。请到 设置 › 隐私与安全性 › 照片 › SLATE 改为完全访问后重试；也可以点「RAW 文件」从文件 App 选择原片。"
            }
        }
    }
}
