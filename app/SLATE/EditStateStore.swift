//
//  EditStateStore.swift
//  SLATE
//
//  按素材保存/恢复上次的调整（重开同一素材能接着改）。
//
//  说明：EditState 的 CodingKeys 未包含后加的字段（cropMask / logProfile /
//  restore* / trim*），直接编码会丢这些值；因此额外存一份副本，
//  解码后覆盖回去。
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
}

final class EditStateStore {

    static let shared = EditStateStore()

    private let defaults = UserDefaults.standard
    private let prefix = "slate.edit."

    private init() {}

    // MARK: 存取

    func save(_ state: EditState, for assetKey: String) {
        guard !assetKey.isEmpty else { return }
        guard let stateData = try? JSONEncoder().encode(state) else { return }
        let saved = SavedEdit(
            stateJSON: stateData,
            cropMask: state.cropMask,
            logProfileIndex: state.logProfileIndex,
            restoreEnabled: state.restoreEnabled,
            restoreLUTName: state.restoreLUTName,
            trimStart: state.trimStart,
            trimEnd: state.trimEnd
        )
        guard let blob = try? JSONEncoder().encode(saved) else { return }
        defaults.set(blob, forKey: prefix + assetKey)
    }

    func restore(for assetKey: String) -> EditState? {
        guard !assetKey.isEmpty,
              let blob = defaults.data(forKey: prefix + assetKey),
              let saved = try? JSONDecoder().decode(SavedEdit.self, from: blob),
              var state = try? JSONDecoder().decode(EditState.self, from: saved.stateJSON)
        else { return nil }

        // 补回不在 CodingKeys 里的字段
        state.cropMask = saved.cropMask
        state.logProfileIndex = saved.logProfileIndex
        state.restoreEnabled = saved.restoreEnabled
        state.restoreLUTName = saved.restoreLUTName
        state.trimStart = saved.trimStart
        state.trimEnd = saved.trimEnd
        return state
    }

    func clear(for assetKey: String) {
        guard !assetKey.isEmpty else { return }
        defaults.removeObject(forKey: prefix + assetKey)
    }
}
