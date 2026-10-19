//
//  SLATEUI.swift
//  SLATE
//
//  原型（桌面 index.html）里的通用组件在本工程的 SwiftUI 实现。
//  设计规格照抄原型：8 pt 基线、44 pt 触控、圆角 12/18/26、
//  SF Pro + 等宽数字、深色专业工具风。
//

import SwiftUI

// MARK: - 尺寸常量

enum SL {
    /// 8 pt 基线。
    static let u: CGFloat = 8
    /// 触控最小边。
    static let touch: CGFloat = 44
    /// 圆角：小卡片 / 面板 / 大卡片。
    static let rSmall: CGFloat = 12
    static let rMedium: CGFloat = 18
    static let rLarge: CGFloat = 26
    /// 页面左右边距。
    static let pad: CGFloat = 16
}

// MARK: - 文字

extension View {
    /// 等宽数字（原型要求「数字等宽」，避免滑杆数值跳动时抖动）。
    func monoDigits() -> some View {
        monospacedDigit()
    }
}

/// 分组标题（如「色彩管理」）。
struct SLGroupTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.meta)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
    }
}

// MARK: - 胶囊 chip

/// 原型里的 `.chip`：可选中的胶囊标签。
struct SLChip: View {
    let title: String
    var isOn: Bool = false
    var compact: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
                .padding(.horizontal, compact ? 10 : 13)
                .frame(height: compact ? 28 : 32)
                .background(
                    isOn ? Theme.accent : Theme.surface2,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(isOn ? .clear : Theme.line, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 图标按钮

/// 原型里的 `.icon-btn`：44 pt 触控的方形图标按钮。
struct SLIconButton: View {
    let systemName: String
    var tint: Color = Theme.text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: SL.touch, height: SL.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 主按钮 / 文字按钮

/// 原型里的 `.primary-btn`。
struct SLPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: SL.rSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 原型里的 `.txt-btn`（次级、无底色）。
struct SLTextButton: View {
    let title: String
    var tint: Color = Theme.muted
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(minWidth: 56, minHeight: SL.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 列表行

/// 原型里的 `.list-row`：左标题、右值、右箭头。
struct SLListRow: View {
    let title: String
    let value: String
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.meta)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.meta.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

/// 列表分组容器。
struct SLListGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SLGroupTitle(text: title)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: SL.rMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SL.rMedium, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 0.5)
            )
        }
    }
}

/// 行内分隔线（列表里用）。
struct SLRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

// MARK: - 底部 tab 栏

enum SLTab: Hashable {
    case library
    case lut
    case me
}

/// 原型里的 `.tabbar`：图库 / LUT / 我的。
struct SLTabBar: View {
    @Binding var selection: SLTab

    private struct TabSpec: Identifiable {
        let tab: SLTab
        let icon: String
        let title: String
        var id: SLTab { tab }
    }

    private let items: [TabSpec] = [
        TabSpec(tab: .library, icon: "square.grid.2x2", title: "图库"),
        TabSpec(tab: .lut, icon: "chart.xyaxis.line", title: "LUT"),
        TabSpec(tab: .me, icon: "person.crop.circle", title: "我的"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { spec in
                let tab = spec.tab
                let icon = spec.icon
                let title = spec.title
                let isOn = selection == tab
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: isOn ? .semibold : .regular))
                        Text(title)
                            .font(.system(size: 10, weight: isOn ? .semibold : .medium))
                    }
                    .foregroundStyle(isOn ? Theme.accent : Theme.meta)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
        .background(
            Theme.bg.opacity(0.96)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
        )
    }
}

// MARK: - 页头

/// 原型里的 `.lib-head`：大标题 + 右侧操作 + 筛选胶囊 + 统计行。
struct SLPageHeader<Actions: View, Filters: View>: View {
    let title: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var filters: Filters
    var metaLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                HStack(spacing: 0) { actions }
            }
            filters
            if let metaLine {
                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.meta)
            }
        }
        .padding(.horizontal, SL.pad)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

// MARK: - 空状态

struct SLEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.meta)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.meta)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                SLPrimaryButton(title: actionTitle, action: action)
                    .frame(maxWidth: 200)
                    .padding(.top, 4)
            }
        }
        .padding(SL.pad * 2)
        .frame(maxWidth: .infinity)
    }
}
