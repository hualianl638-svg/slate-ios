//
//  EditStateStore.swift
//  SLATE
//
//  按素材保存/恢复上次的调整。
//
//  设计要点：
//  · EditState 的 CodingKeys 未包含后加字段，故额外存一份副本并在解码后覆盖；
//  · 存档前把编辑期临时标志（bypassCrop）清掉，避免恢复后裁剪不生效；
//  · 只保留最近 N 条，防止 UserDefaults 无限增长；
//  · 恢复时校验取值区间，损坏存档不会把界面搞乱。
//

import Foundation

/// 落盘用的编辑快照。
struct SavedEdit: Codable {
    var stateJSON: Data
    var cropMask: CropMaskSettings
    var logProfileIndex: Int
    var restoreEnabled: Bool
    var restoreLUTName: String
    var trimStart: Double
    var trimEnd: Double
    /// 风格 LUT 强度（applyLUT 会重置为 1，恢复时需要还原）
    var lutIntensity: Double
    var savedAt: Date
    /// 存档格式版本，便于将来升级。
    var version: Int

    /// 手工解码：所有后加字段都给默认值。
    ///
    /// 这是必须的——`lutIntensity` / `savedAt` / `version` 是后来新增的非可选字段，
    /// 合成解码器遇到旧存档缺字段会直接抛错，导致 restore 返回 nil，
    /// 用户此前保存的所有调整会全部丢失。
    init(stateJSON: Data,
         cropMask: CropMaskSettings,
         logProfileIndex: Int,
         restoreEnabled: Bool,
         restoreLUTName: String,
         trimStart: Double,
         trimEnd: Double,
         lutIntensity: Double,
         savedAt: Date,
         version: Int = 1) {
        self.stateJSON = stateJSON
        self.cropMask = cropMask
        self.logProfileIndex = logProfileIndex
        self.restoreEnabled = restoreEnabled
        self.restoreLUTName = restoreLUTName
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.lutIntensity = lutIntensity
        self.savedAt = savedAt
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateJSON = try container.decode(Data.self, forKey: .stateJSON)
        cropMask = (try? container.decodeIfPresent(CropMaskSettings.self, forKey: .cropMask)) ?? CropMaskSettings()
        logProfileIndex = (try? container.decodeIfPresent(Int.self, forKey: .logProfileIndex)) ?? 0
        restoreEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .restoreEnabled)) ?? false
        restoreLUTName = (try? container.decodeIfPresent(String.self, forKey: .restoreLUTName)) ?? ""
        trimStart = (try? container.decodeIfPresent(Double.self, forKey: .trimStart)) ?? 0
        trimEnd = (try? container.decodeIfPresent(Double.self, forKey: .trimEnd)) ?? 1
        lutIntensity = (try? container.decodeIfPresent(Double.self, forKey: .lutIntensity)) ?? 1
        savedAt = (try? container.decodeIfPresent(Date.self, forKey: .savedAt)) ?? Date()
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 0
    }
}

final class EditStateStore {

    static let shared = EditStateStore()

    /// 最多保留多少条素材存档。
    private let maxEntries = 60

    private let defaults = UserDefaults.standard
    private let prefix = "slate.edit."
    private let indexKey = "slate.edit.index"

    private init() {}

    // MARK: 保存

    func save(_ state: EditState, for assetKey: String) {
        guard !assetKey.isEmpty else { return }

        // 编辑期的临时旁路不能进存档
        var snapshot = state
        snapshot.cropMask.bypassCrop = false
        snapshot.trimStart = min(max(snapshot.trimStart, 0), 0.98)
        snapshot.trimEnd = min(max(snapshot.trimEnd, snapshot.trimStart + 0.02), 1)

        guard let stateData = try? JSONEncoder().encode(snapshot) else { return }
        let saved = SavedEdit(
            stateJSON: stateData,
            cropMask: snapshot.cropMask,
            logProfileIndex: snapshot.logProfileIndex,
            restoreEnabled: snapshot.restoreEnabled,
            restoreLUTName: snapshot.restoreLUTName,
            trimStart: snapshot.trimStart,
            trimEnd: snapshot.trimEnd,
            lutIntensity: snapshot.lut.intensity,
            savedAt: Date()
        )
        guard let blob = try? JSONEncoder().encode(saved) else { return }
        defaults.set(blob, forKey: prefix + assetKey)
        touchIndex(assetKey)
        pruneIfNeeded()
    }

    // MARK: 恢复

    func restore(for assetKey: String) -> EditState? {
        guard !assetKey.isEmpty,
              let blob = defaults.data(forKey: prefix + assetKey),
              let saved = try? JSONDecoder().decode(SavedEdit.self, from: blob),
              var state = try? JSONDecoder().decode(EditState.self, from: saved.stateJSON)
        else { return nil }

        // EditState 没有自定义 CodingKeys，合成编码器其实已包含全部字段，
        // 因此 stateJSON 解码出来的值优先；只有它是默认值时（旧存档缺字段）
        // 才用 SavedEdit 的副本兜底——否则会用旧副本的默认值覆盖掉真实数据。
        if state.cropMask == CropMaskSettings(), saved.cropMask != CropMaskSettings() {
            state.cropMask = saved.cropMask
        }
        state.cropMask.bypassCrop = false
        if state.logProfileIndex == 0 { state.logProfileIndex = saved.logProfileIndex }
        if !state.restoreEnabled { state.restoreEnabled = saved.restoreEnabled }
        if state.restoreLUTName.isEmpty { state.restoreLUTName = saved.restoreLUTName }
        if state.trimStart == 0 && state.trimEnd == 1 {
            state.trimStart = min(max(saved.trimStart, 0), 0.98)
            state.trimEnd = min(max(saved.trimEnd, state.trimStart + 0.02), 1)
        }
        state.trimStart = min(max(state.trimStart, 0), 0.98)
        state.trimEnd = min(max(state.trimEnd, state.trimStart + 0.02), 1)
        return state
    }

    /// 存档里的风格 LUT 强度。
    func savedLUTIntensity(for assetKey: String) -> Double? {
        guard let blob = defaults.data(forKey: prefix + assetKey),
              let saved = try? JSONDecoder().decode(SavedEdit.self, from: blob) else { return nil }
        return min(max(saved.lutIntensity, 0), 1)
    }

    func clear(for assetKey: String) {
        guard !assetKey.isEmpty else { return }
        defaults.removeObject(forKey: prefix + assetKey)
        var index = storedIndex().filter { $0 != assetKey }
        defaults.set(index, forKey: indexKey)
        _ = index
    }

    // MARK: 索引与容量控制

    private func storedIndex() -> [String] {
        (defaults.array(forKey: indexKey) as? [String]) ?? []
    }

    private func touchIndex(_ assetKey: String) {
        var index = storedIndex().filter { $0 != assetKey }
        index.append(assetKey)
        defaults.set(index, forKey: indexKey)
    }

    /// 超出上限时删掉最旧的存档（索引按写入顺序排列）。
    private func pruneIfNeeded() {
        var index = storedIndex()
        while index.count > maxEntries {
            let oldest = index.removeFirst()
            defaults.removeObject(forKey: prefix + oldest)
        }
        defaults.set(index, forKey: indexKey)
    }
}
