//
//  SLog3LookLUT.swift
//  SLATE
//
//  Sony 官方 LookProfile LUT：SLog3SGamut3.CineToLC_709（full in / full out，33³）。
//
//  为什么改用官方 LUT：
//  之前是拿 Sony ACES IDT 的常数自己反推 S-Log3 曲线、再乘一个手算的
//  S-Gamut3.Cine → Rec.709 矩阵。数学上"能出画面"，但那是"把对数信号线性化"
//  而不是 Sony 定义的"看起来对的 709"，所以肤色和中间调偏色。
//  官方 LUT 直接吃 log 编码的 R'G'B'，输出显示参考的 LC-709 值，颜色才是对的。
//

import Foundation

enum SLog3LookLUT {

    /// 资源文件名（不带扩展名）。
    static let resourceName = "SLog3SGamut3.CineToLC-709"

    /// 从 app bundle 载入并解析。缺失时返回 nil，调用方回退到旧链路。
    static func load() -> LUT3D? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            return nil
        }
        return try? LUTFile.parse(contentsOf: url)
    }
}
