//
//  LUT.swift
//  ColorStudio
//
//  L2 · 业务逻辑层 + L3 · LUT 引擎的数据模型
//  对应架构文档 L3「LUT 引擎：.cube 解析 → 3D 纹理缓存 · 尺寸校验(17/33/64) · 双线性插值」
//
//  本文件只做「解析 + CPU 端采样」，不依赖 Metal / Core Image：
//  · 解析结果 `LUT3D` 是 Metal 纹理与 CIColorCube 的唯一输入；
//  · CPU 端 `sample` 用于单元测试、LUT 缩略图生成与颜色数值校验；
//  · GPU 端三线性插值由 ColorKernels.metal 实现，两者必须数值一致（见 Tests/LUTInterpolationTests）。
//

import Foundation

// MARK: - 3D LUT 数据

/// 一个解析完成的 3D LUT。
///
/// 数据布局遵循 .cube 文件规范：红色分量变化最快，
/// 即下标 `index = ((blue * size + green) * size + red) * 3`。
public struct LUT3D: Equatable, Sendable {

    /// 立方体边长。.cube 常见取值 17 / 33 / 64。
    public let dimension: Int

    /// 扁平存储的 RGB 浮点，长度恒为 `dimension³ * 3`。
    public let values: ContiguousArray<Float>

    /// 文件表头 TITLE（若存在）。
    public let title: String?

    /// 定义域下界，默认 (0,0,0)。
    public let domainMin: SIMD3<Float>

    /// 定义域上界，默认 (1,1,1)。
    public let domainMax: SIMD3<Float>

    /// 采样点总数。
    public var pointCount: Int { dimension * dimension * dimension }

    public init?(
        dimension: Int,
        values: ContiguousArray<Float>,
        title: String? = nil,
        domainMin: SIMD3<Float> = SIMD3(0, 0, 0),
        domainMax: SIMD3<Float> = SIMD3(1, 1, 1)
    ) {
        guard dimension >= 2, dimension <= 256 else { return nil }
        guard values.count == dimension * dimension * dimension * 3 else { return nil }
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        self.dimension = dimension
        self.values = values
        self.title = title
        self.domainMin = domainMin
        self.domainMax = domainMax
    }

    // MARK: 采样

    /// 直接按立方体坐标取栅格点（下标越界会夹取）。
    public func latticeValue(red: Int, green: Int, blue: Int) -> SIMD3<Float> {
        let r = min(max(red, 0), dimension - 1)
        let g = min(max(green, 0), dimension - 1)
        let b = min(max(blue, 0), dimension - 1)
        let index = ((b * dimension + g) * dimension + r) * 3
        return SIMD3(values[index], values[index + 1], values[index + 2])
    }

    /// 三线性插值采样。输入与输出均为定义域内的归一化 RGB。
    ///
    /// 与 Metal 端的做法一致：先把输入映射到 `0...(dimension-1)` 的连续坐标，
    /// 取相邻两个栅格点按小数部分插值，边界夹取。
    public func sample(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let normalized = normalizeToDomain(color)
        let scale = Float(dimension - 1)
        let position = SIMD3(
            min(max(normalized.x, 0), 1) * scale,
            min(max(normalized.y, 0), 1) * scale,
            min(max(normalized.z, 0), 1) * scale
        )

        let base = SIMD3(
            min(Int(position.x.rounded(.down)), dimension - 2),
            min(Int(position.y.rounded(.down)), dimension - 2),
            min(Int(position.z.rounded(.down)), dimension - 2)
        )
        let fraction = position - SIMD3(Float(base.x), Float(base.y), Float(base.z))

        let c000 = latticeValue(red: base.x, green: base.y, blue: base.z)
        let c100 = latticeValue(red: base.x + 1, green: base.y, blue: base.z)
        let c010 = latticeValue(red: base.x, green: base.y + 1, blue: base.z)
        let c110 = latticeValue(red: base.x + 1, green: base.y + 1, blue: base.z)
        let c001 = latticeValue(red: base.x, green: base.y, blue: base.z + 1)
        let c101 = latticeValue(red: base.x + 1, green: base.y, blue: base.z + 1)
        let c011 = latticeValue(red: base.x, green: base.y + 1, blue: base.z + 1)
        let c111 = latticeValue(red: base.x + 1, green: base.y + 1, blue: base.z + 1)

        let x00 = c000 + (c100 - c000) * fraction.x
        let x10 = c010 + (c110 - c010) * fraction.x
        let x01 = c001 + (c101 - c001) * fraction.x
        let x11 = c011 + (c111 - c011) * fraction.x

        let y0 = x00 + (x10 - x00) * fraction.y
        let y1 = x01 + (x11 - x01) * fraction.y

        return y0 + (y1 - y0) * fraction.z
    }

    /// 按强度混合原色与 LUT 结果。`intensity` 会被夹取到 0...1。
    public func apply(to color: SIMD3<Float>, intensity: Double) -> SIMD3<Float> {
        let t = Float(min(max(intensity, 0), 1))
        guard t > 0 else { return color }
        let mapped = sample(color)
        return color + (mapped - color) * t
    }

    /// 把输入从定义域映射到 0...1。
    public func normalizeToDomain(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let span = domainMax - domainMin
        let safeSpan = SIMD3(
            span.x == 0 ? 1 : span.x,
            span.y == 0 ? 1 : span.y,
            span.z == 0 ? 1 : span.z
        )
        return (color - domainMin) / safeSpan
    }

    // MARK: 导出给渲染层

    /// 打包成 Metal 3D 纹理 / CIColorCube 需要的 32 位浮点数据。
    ///
    /// 返回值已经按定义域归一化，因此渲染层可以忽略 `domainMin/domainMax`。
    public func normalizedFloatData() -> Data {
        var output = ContiguousArray<Float>()
        output.reserveCapacity(values.count)
        let span = domainMax - domainMin
        let safeSpan = SIMD3(
            span.x == 0 ? 1 : span.x,
            span.y == 0 ? 1 : span.y,
            span.z == 0 ? 1 : span.z
        )
        for index in stride(from: 0, to: values.count, by: 3) {
            let value = SIMD3(values[index], values[index + 1], values[index + 2])
            let normalized = (value - domainMin) / safeSpan
            output.append(normalized.x)
            output.append(normalized.y)
            output.append(normalized.z)
        }
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 恒等 LUT，用于生成缩略图底图与测试对照。
    ///
    /// `LUT3D` 是 `Sendable` 值类型，静态常量无需额外标注即可跨并发域安全共享。
    public static func identity(dimension: Int = 17) -> LUT3D {
        let size = max(dimension, 2)
        var values = ContiguousArray<Float>()
        values.reserveCapacity(size * size * size * 3)
        let scale = Float(size - 1)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    values.append(Float(red) / scale)
                    values.append(Float(green) / scale)
                    values.append(Float(blue) / scale)
                }
            }
        }
        // 构造必然成功：dimension 合法且长度匹配。
        return LUT3D(dimension: size, values: values, title: "Identity")!
    }
}

// MARK: - .cube 解析

/// .cube 文件解析错误。
public enum LUTParseError: LocalizedError, Equatable {
    case emptyFile
    case missingSize
    case unsupported1DLUT(size: Int)
    case invalidSize(String)
    case sizeOutOfRange(Int)
    case invalidDomain(String)
    case malformedEntry(line: Int, content: String)
    case entryCountMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "LUT 文件为空。"
        case .missingSize:
            return "缺少 LUT_3D_SIZE 声明，无法确定立方体尺寸。"
        case .unsupported1DLUT(let size):
            return "暂不支持 1D LUT（LUT_1D_SIZE \(size)）。请在调色软件中导出为 3D .cube。"
        case .invalidSize(let raw):
            return "LUT_3D_SIZE 取值非法：\(raw)"
        case .sizeOutOfRange(let size):
            return "LUT 尺寸 \(size) 超出支持范围（2...256）。"
        case .invalidDomain(let raw):
            return "定义域声明非法：\(raw)"
        case .malformedEntry(let line, let content):
            return "第 \(line) 行无法解析为 RGB 三元组：\(content)"
        case .entryCountMismatch(let expected, let actual):
            return "LUT 数据点数量不匹配：期望 \(expected)，实际 \(actual)。"
        }
    }
}

/// .cube（Adobe Cube LUT）解析器。
///
/// 支持：`TITLE` / `LUT_3D_SIZE` / `DOMAIN_MIN` / `DOMAIN_MAX` / `#` 注释 / 空行 /
/// 科学计数法 / 逗号或空格分隔 / CRLF 与 LF 换行。
/// 不支持：`LUT_1D_SIZE`（会返回 `.unsupported1DLUT`，UI 需给出可读提示）。
public enum LUTFile {

    /// 解析 .cube 文本内容。
    public static func parse(contents: String, fallbackTitle: String? = nil) throws -> LUT3D {
        var title = fallbackTitle
        var dimension: Int?
        var oneDimensionalSize: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var values = ContiguousArray<Float>()
        var sawAnyContent = false

        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            sawAnyContent = true

            // 去掉行尾注释
            let withoutComment: String
            if let commentIndex = trimmed.firstIndex(of: "#") {
                withoutComment = String(trimmed[trimmed.startIndex..<commentIndex]).trimmingCharacters(in: .whitespaces)
            } else {
                withoutComment = trimmed
            }
            guard !withoutComment.isEmpty else { continue }

            let upper = withoutComment.uppercased()

            if upper.hasPrefix("TITLE") {
                title = extractQuotedValue(from: withoutComment) ?? title
                continue
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let raw = valuePart(of: withoutComment)
                guard let size = Int(raw) else { throw LUTParseError.invalidSize(raw) }
                guard (2...256).contains(size) else { throw LUTParseError.sizeOutOfRange(size) }
                dimension = size
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                oneDimensionalSize = Int(valuePart(of: withoutComment)) ?? 0
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                domainMin = try parseVector(valuePart(of: withoutComment), line: lineNumber)
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                domainMax = try parseVector(valuePart(of: withoutComment), line: lineNumber)
                continue
            }

            // 数据行：三个浮点
            let components = splitComponents(withoutComment)
            guard components.count == 3 else {
                throw LUTParseError.malformedEntry(line: lineNumber, content: withoutComment)
            }
            var triple = [Float]()
            triple.reserveCapacity(3)
            for component in components {
                guard let value = Float(component) else {
                    throw LUTParseError.malformedEntry(line: lineNumber, content: withoutComment)
                }
                triple.append(value)
            }
            values.append(contentsOf: triple)
        }

        guard sawAnyContent || dimension != nil else { throw LUTParseError.emptyFile }
        if let oneDimensionalSize, dimension == nil {
            throw LUTParseError.unsupported1DLUT(size: oneDimensionalSize)
        }
        guard let dimension else { throw LUTParseError.missingSize }

        let expected = dimension * dimension * dimension * 3
        guard values.count == expected else {
            throw LUTParseError.entryCountMismatch(expected: expected / 3, actual: values.count / 3)
        }
        guard let lut = LUT3D(
            dimension: dimension,
            values: values,
            title: title,
            domainMin: domainMin,
            domainMax: domainMax
        ) else {
            throw LUTParseError.sizeOutOfRange(dimension)
        }
        return lut
    }

    /// 从文件 URL 解析。
    public static func parse(contentsOf url: URL) throws -> LUT3D {
        let data = try Data(contentsOf: url)
        // 先按 UTF-8 解码，失败则按 Latin-1 回落（.cube 规范允许 ASCII 之外的 TITLE）。
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw LUTParseError.emptyFile
        }
        return try parse(contents: text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: 词法辅助

    private static func valuePart(of line: String) -> String {
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return "" }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func extractQuotedValue(from line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: first)...]
        guard let second = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<second])
    }

    private static func parseVector(_ raw: String, line: Int) throws -> SIMD3<Float> {
        let components = splitComponents(raw)
        guard components.count == 3, let x = Float(components[0]), let y = Float(components[1]), let z = Float(components[2]) else {
            throw LUTParseError.invalidDomain(raw)
        }
        return SIMD3(x, y, z)
    }

    private static func splitComponents(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            .map(String.init)
    }
}
