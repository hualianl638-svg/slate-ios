//
//  LogProfile.swift
//  SLATE
//
//  灰片（对数）曲线的手动选择与还原 LUT 解析。
//
//  设计：
//  · 方案 A —— 内置常见厂商官方 LUT，选中即还原（S-Log3 / C-Log3）；
//  · 方案 B —— 任何导入的 .cube 都可以「设为还原 LUT」，
//    兜底 F-Log2 / N-Log / V-Log / 手机 log 等没有内置文件的格式。
//
//  为什么用官方 LUT 而不是自己算曲线：曲线只解决"对数转线性"，
//  还会牵扯厂商色域（Cinema Gamut / F-Gamut / N-Gamut）与厂商定义的显示映射。
//  自己拼数学必然偏色（S-Log3 第一版就是这么翻车的）。
//

import Foundation

enum LogProfile: Int, CaseIterable, Identifiable {
    case off = 0
    case sLog3
    case cLog3
    case fLog2
    case nLog
    case custom

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .sLog3: return "S-Log3"
        case .cLog3: return "C-Log3"
        case .fLog2: return "F-Log2"
        case .nLog: return "N-Log"
        case .custom: return "自定义"
        }
    }

    /// 随 App 打包的官方 LUT 文件名（不含扩展名）。
    var builtinLUTName: String? {
        switch self {
        case .sLog3: return "SLog3SGamut3.CineToLC-709"
        case .cLog3: return "CinemaGamut_CanonLog3-to-Canon709_33_Ver.1.0"
        default: return nil
        }
    }

    /// 是否已有可用 LUT（内置或用户指定）。
    var hasBuiltinLUT: Bool { builtinLUTName != nil }

    /// 选中但缺少内置 LUT 时的提示。
    var missingLUTHint: String? {
        guard !hasBuiltinLUT, self != .off, self != .custom else { return nil }
        return "还没有内置 \(title) 的官方 LUT。请先在 LUT 库导入对应 .cube，再把它设为还原 LUT。"
    }
}

/// 还原 LUT 的解析与缓存。
///
/// 说明：渲染器会在后台线程读取这里的数据，写入只发生在用户操作时，
/// 因此用一把锁保护，避免数据竞争。
final class RestoreLUTLibrary {

    static let shared = RestoreLUTLibrary()

    private let lock = NSLock()
    private var cache: [String: LUT3D] = [:]
    private var userLUT: LUT3D?
    private var userName: String?

    private init() {}

    /// 当前用户指定的还原 LUT（方案 B）。
    var customLUT: LUT3D? {
        lock.lock(); defer { lock.unlock() }
        return userLUT
    }

    var customLUTName: String? {
        lock.lock(); defer { lock.unlock() }
        return userName
    }

    func setCustomLUT(_ lut: LUT3D?, name: String?) {
        lock.lock()
        userLUT = lut
        userName = name
        lock.unlock()
    }

    /// 取某个曲线对应的还原 LUT；`nil` 表示没有可用 LUT。
    func restoreLUT(for profile: LogProfile) -> LUT3D? {
        switch profile {
        case .off:
            return nil
        case .custom:
            return customLUT
        default:
            guard let name = profile.builtinLUTName else { return nil }
            lock.lock()
            if let cached = cache[name] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            guard let url = Bundle.main.url(forResource: name, withExtension: "cube"),
                  let lut = try? LUTFile.parse(contentsOf: url) else { return nil }

            lock.lock()
            cache[name] = lut
            lock.unlock()
            return lut
        }
    }
}
