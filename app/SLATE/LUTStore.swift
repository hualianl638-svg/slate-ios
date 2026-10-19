//
//  LUTStore.swift
//  SLATE
//
//  M3：LUT 仓库。负责 .cube 文件的导入、持久化、缓存与解析。
//
//  设计取舍：
//  · 解析一律走 Engine 里已验证的 `LUTFile`，不另写解析器
//    （.cube 的红色分量最快的数据布局极易写错，且错了只会表现为"颜色怪"）；
//  · 文件落在 Documents/LUTs/，重启后仍在；内存里按路径缓存 LUT3D，
//    避免每次调强度都重新解析 33³/64³ 的点；
//  · 内置 3 个程序化 LUT（恒等/暖调/青橙），保证首次启动就有东西可试，
//    且不需要打包二进制资源。
//

import Foundation

// MARK: - LUT 条目

/// 一条 LUT 记录。
struct LUTItem: Identifiable, Hashable {
    enum Source: Hashable {
        case builtin
        case imported
    }

    /// 身份：内置用固定的稳定 id，导入用相对文件名。
    let id: String
    let name: String
    let dimension: Int
    let source: Source
    /// 导入的 LUT 才有磁盘路径；内置为 nil。
    let fileURL: URL?

    var isBuiltin: Bool { source == .builtin }
}

// MARK: - 仓库

/// LUT 仓库：导入 / 列出 / 解析 / 删除。
@MainActor
final class LUTStore: ObservableObject {

    @Published private(set) var items: [LUTItem] = []
    @Published var errorText: String?

    /// Documents/LUTs 目录。
    private let directory: URL
    /// 解析结果缓存，键为 LUT 的 id。
    private var cache: [String: LUT3D] = [:]
    /// 内置 LUT 的解析结果（init 时生成一次）。
    private var builtinLUTs: [String: LUT3D] = [:]

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = documents.appendingPathComponent("LUTs", isDirectory: true)
        createDirectoryIfNeeded()
        reload()
    }

    // MARK: 列表

    /// 重新扫描磁盘。内置 LUT 始终排在前面。
    func reload() {
        var result: [LUTItem] = []

        // 内置（顺序固定，便于用户形成肌肉记忆）
        for id in Self.builtinOrder {
            if let lut = builtinLUTs[id] {
                result.append(LUTItem(
                    id: "builtin:\(id)",
                    name: Self.builtinNames[id] ?? id,
                    dimension: lut.dimension,
                    source: .builtin,
                    fileURL: nil
                ))
            }
        }

        // 导入的（按文件名排序）
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in files where url.pathExtension.lowercased() == "cube" {
                let name = url.deletingPathExtension().lastPathComponent
                let relative = url.lastPathComponent
                // 尺寸从缓存或惰性解析（这里不解析，避免启动慢）
                let dimension = cache[relative]?.dimension ?? 0
                result.append(LUTItem(
                    id: relative,
                    name: name,
                    dimension: dimension,
                    source: .imported,
                    fileURL: url
                ))
            }
            result.sort {
                if $0.isBuiltin != $1.isBuiltin { return $0.isBuiltin }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        items = result
    }

    // MARK: 解析

    /// 取（并缓存）某条 LUT 的解析结果。
    func resolved(_ item: LUTItem) throws -> LUT3D {
        if let cached = cache[item.id] { return cached }

        let lut: LUT3D
        if item.isBuiltin {
            let key = String(item.id.dropFirst("builtin:".count))
            guard let built = builtinLUTs[key] else {
                throw LUTStoreError.builtinMissing(item.name)
            }
            lut = built
        } else {
            guard let url = item.fileURL else {
                throw MediaPipelineError.lutNotFound(item.id)
            }
            lut = try LUTFile.parse(contentsOf: url)
        }

        cache[item.id] = lut
        return lut
    }

    // MARK: 导入

    /// 从 .cube 文本导入。
    ///
    /// 先解析再落盘：解析失败的文件不留在仓库里，避免给用户一个"看着在、点开报错"的条目。
    @discardableResult
    func importCube(data: Data, preferredName: String) throws -> LUTItem {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw MediaPipelineError.unsupportedFormat("文件不是可读文本，可能不是 .cube")
        }

        // 1) 先解析验证
        var baseName = preferredName
        if baseName.lowercased().hasSuffix(".cube") {
            baseName = String(baseName.dropLast(5))
        }
        if baseName.isEmpty { baseName = "导入的 LUT" }
        let lut = try LUTFile.parse(contents: text, fallbackTitle: baseName)

        // 2) 落盘（重名时加序号，不覆盖用户已有文件）
        let fileName = uniqueFileName(for: baseName)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)

        // 3) 更新缓存与列表
        let item = LUTItem(
            id: fileName,
            name: fileName.replacingOccurrences(of: ".cube", with: ""),
            dimension: lut.dimension,
            source: .imported,
            fileURL: url
        )
        cache[fileName] = lut
        reload()
        return item
    }

    /// 删除一条导入的 LUT（内置不可删）。
    func delete(_ item: LUTItem) {
        guard !item.isBuiltin, let url = item.fileURL else { return }
        do {
            try FileManager.default.removeItem(at: url)
            cache.removeValue(forKey: item.id)
            reload()
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: 内部

    private func createDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 生成一个不冲突的文件名。
    private func uniqueFileName(for base: String) -> String {
        var candidate = "\(base).cube"
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(index).cube"
            index += 1
        }
        return candidate
    }

    // MARK: 内置 LUT

    private static let builtinOrder = ["identity", "warm", "tealorange"]
    private static let builtinNames: [String: String] = [
        "identity": "恒等（对照）",
        "warm": "暖调",
        "tealorange": "青橙",
    ]

    /// 程序化生成 3 个 17³ 内置 LUT。
    ///
    /// 用 17³ 而不是 33³：内置 LUT 只是给用户试手感，17³ 足够且内存占用小（约 59 KB/个）。
    private func makeBuiltins() {
        builtinLUTs["identity"] = Self.makeLUT { $0 }

        // 暖调：R 提、B 降，并轻微抬黑场（胶片感）
        builtinLUTs["warm"] = Self.makeLUT { c in
            let r = min(1.0, c.x * 1.06 + 0.012)
            let g = min(1.0, c.y * 1.01)
            let b = min(1.0, c.z * 0.93 + 0.006)
            return SIMD3<Float>(r, g, b)
        }

        // 青橙：按亮度分离——暗部推向青蓝、亮部推向橙
        builtinLUTs["tealorange"] = Self.makeLUT { c in
            let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let shadowWeight = max(0, 1 - luma / 0.45)
            let highlightWeight = max(0, (luma - 0.5) / 0.5)
            let teal = SIMD3<Float>(0.0, 0.42, 0.48)
            let orange = SIMD3<Float>(1.0, 0.55, 0.22)
            var out = c
            out += (teal - c) * (shadowWeight * 0.20)
            out += (orange - c) * (highlightWeight * 0.16)
            return SIMD3<Float>(
                min(max(out.x, 0), 1),
                min(max(out.y, 0), 1),
                min(max(out.z, 0), 1)
            )
        }
    }

    /// 用变换闭包生成一个 17³ 恒等网格 LUT。
    private static func makeLUT(dimension: Int = 17,
                                _ transform: (SIMD3<Float>) -> SIMD3<Float>) -> LUT3D? {
        let size = max(dimension, 2)
        let scale = Float(size - 1)
        var values = ContiguousArray<Float>()
        values.reserveCapacity(size * size * size * 3)
        // .cube 布局：红色变化最快
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let input = SIMD3<Float>(Float(red) / scale,
                                             Float(green) / scale,
                                             Float(blue) / scale)
                    let out = transform(input)
                    values.append(out.x)
                    values.append(out.y)
                    values.append(out.z)
                }
            }
        }
        return LUT3D(dimension: size, values: values, title: "SLATE Builtin")
    }
}

// MARK: - 错误

enum LUTStoreError: LocalizedError {
    case builtinMissing(String)

    var errorDescription: String? {
        switch self {
        case .builtinMissing(let name):
            return "内置 LUT「\(name)」缺失，这通常说明程序资源被破坏。"
        }
    }
}
