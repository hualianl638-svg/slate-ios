//
//  RestoreLUTLibrary.swift
//  SLATE
//
//  还原 LUT 的独立管理（与风格化 LUT 完全分离）。
//
//  · 内置：随 App 打包的厂商官方 LUT（S-Log3 / C-Log3）
//  · 我的还原 LUT：用户导入的 .cube，存在 Documents/RestoreLUTs/
//  · 风格化 LUT 仍由 LUTStore 管理（Documents/LUTs/），两者互不影响
//

import Foundation

enum RestoreLUTError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "这个 .cube 不是可识别的文本 LUT 文件。"
    }
}

final class RestoreLUTLibrary {

    static let shared = RestoreLUTLibrary()

    struct UserLUT: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    private let lock = NSLock()
    private var builtinCache: [String: LUT3D] = [:]
    private var userCache: [String: LUT3D] = [:]
    private var userNameList: [String] = []
    private let directory: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("RestoreLUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reloadUserLUTs()
    }

    // MARK: 我的还原 LUT

    var directoryURL: URL { directory }

    var userLUTs: [UserLUT] {
        lock.lock(); defer { lock.unlock() }
        return userNameList.map { UserLUT(name: $0) }
    }

    func reloadUserLUTs() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.lowercased().hasSuffix(".cube") }
            .map { String($0.dropLast(5)) }
            .sorted() ?? []
        lock.lock()
        userNameList = names
        userCache = [:]
        lock.unlock()
    }

    @discardableResult
    func importUserLUT(data: Data, preferredName: String) throws -> UserLUT {
        // LUTFile 只有「文本 / URL」两个入口，这里先把字节解成文本
        guard let text = String(data: data, encoding: .utf8) else {
            throw RestoreLUTError.unreadable
        }
        let lut = try LUTFile.parse(contents: text, fallbackTitle: nil)
        let base = preferredName.isEmpty ? "还原LUT" : preferredName
        var name = base
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).cube").path) {
            name = "\(base)-\(index)"
            index += 1
        }
        try data.write(to: directory.appendingPathComponent("\(name).cube"), options: .atomic)
        lock.lock()
        userCache[name] = lut
        userNameList.append(name)
        userNameList.sort()
        lock.unlock()
        return UserLUT(name: name)
    }

    func deleteUserLUT(named name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).cube"))
        lock.lock()
        userCache[name] = nil
        userNameList.removeAll { $0 == name }
        lock.unlock()
    }

    // MARK: 解析

    /// 取某条曲线对应的还原 LUT。
    func restoreLUT(for profile: LogProfile, customName: String) -> LUT3D? {
        switch profile {
        case .off:
            return nil
        case .custom:
            return userLUT(named: customName)
        default:
            guard let builtin = profile.builtinLUTName else { return nil }
            return builtinLUT(named: builtin)
        }
    }

    func userLUT(named name: String) -> LUT3D? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        if let cached = userCache[name] { lock.unlock(); return cached }
        lock.unlock()

        let url = directory.appendingPathComponent("\(name).cube")
        guard let lut = try? LUTFile.parse(contentsOf: url) else { return nil }
        lock.lock(); userCache[name] = lut; lock.unlock()
        return lut
    }

    private func builtinLUT(named name: String) -> LUT3D? {
        lock.lock()
        if let cached = builtinCache[name] { lock.unlock(); return cached }
        lock.unlock()

        guard let url = Bundle.main.url(forResource: name, withExtension: "cube"),
              let lut = try? LUTFile.parse(contentsOf: url) else { return nil }
        lock.lock(); builtinCache[name] = lut; lock.unlock()
        return lut
    }
}
