# SLATE · iOS 原生工程（M1）

Windows 上开发 iOS 的唯一可行路线：**源码在本地写，编译交给 GitHub 的 macOS 机器，产物侧载到手机**。
本目录已经配好整条链路，你只需要做三步（见下）。

---

## 为什么不能直接在这台电脑上编

iOS 应用必须用 Apple 的 `Xcode` 编译，而 Xcode 只有 macOS 版，没有任何 Windows 移植或交叉编译方案。
所以「在 Windows 写代码」可以，「在 Windows 生成 .app」不行。这里用云端 macOS 补上这一环。

---

## 三步走

### 1. 建一个 GitHub 仓库

- 打开 https://github.com/new
- 名字随便（例如 `slate-ios`），**建议选 Public** —— 公开仓库的 Actions 额度不限，私有仓库每月只有 2000 分钟，且 macOS 按 **10 倍**扣（约 40 次构建/月）
- 建好后页面会给一个地址，形如 `https://github.com/你的用户名/slate-ios.git`

### 2. 推代码

仓库已经准备好（单一提交 + remote + 分支 main），只差推送一次并登录 GitHub。

**最简单的方式** —— 关掉所有旧的终端窗口，**新开一个 PowerShell**，粘一行：

```powershell
cd "C:\Users\jooy\WorkBuddy\ios app 开发\ios"; git push -u origin main
```

会弹出浏览器让你登录 GitHub，授权一次即可（凭据存进 Git Credential Manager，以后不用再登）。

**或者双击 `init-repo.cmd`** —— 现在不需要输入任何内容，它自己会用正确的仓库地址；
窗口结束前会停在 `Press any key to continue`，不会再一闪而过。

推送成功后，打开仓库页面的 **Actions** 标签，构建会自动开始。第一次约 5–8 分钟。

> 如果 PowerShell 提示 `git` 不是内部或外部命令，说明它读的是旧 PATH。
> 关掉窗口重开；还不行就双击 `init-repo.cmd`，它会自己找到 git。

> 如果仓库在建的时候勾了「Add a README file」，第一次 push 会被拒绝。脚本会自动 `pull --rebase` 再推一次；仍然失败就手动执行 `git push -u origin main --force`（仓库是新建的，强推安全）。

### 3. 下载 ipa 并装到手机

1. 构建完成后，在 Actions → 该次运行 → 页面底部 **Artifacts** 下载 `SLATE-ipa.zip`，解压得到 `SLATE.ipa`
2. Windows 上安装 [Sideloadly](https://sideloadly.io/)（免费），以及 iTunes / iCloud 的 Apple 驱动（Sideloadly 会提示）
3. iPhone 用数据线连电脑，解锁并点「信任」
4. 把 `SLATE.ipa` 拖进 Sideloadly，Apple ID 填你的（免费账号即可），点 Start
5. 手机上：设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书
6. 回到桌面，图标出现

> **免费证书 7 天过期。** 到期后 App 打不开，重新跑一次 Sideloadly 即可（不用重新构建）。
> 想免掉这个麻烦，需要加入 Apple Developer Program（$99/年），证书有效期变成 1 年。

---

## M1 验证什么

- [x] 云端能编出可安装的包（工具链打通）
- [x] 能从相册导入视频（PhotosPicker）
- [x] 能读出真实元数据：分辨率 / 帧率 / 时长 / 编码 / 位深 / 传输函数
- [x] 能识别 HDR（HLG / PQ）并在界面上标红

**M1 不做调色**，只证明「这条路能走通」。UI 沿用 SLATE 的深色 + 暖橙。

---

## 目录

```
ios/
├─ .github/workflows/build.yml   云端构建：XcodeGen 生成工程 → xcodebuild → 打包 ipa
├─ app/
│  ├─ project.yml                工程定义（替代手写 pbxproj）
│  └─ SLATE/
│     ├─ App.swift               入口
│     ├─ ContentView.swift       界面（导入 / 预览 / 元数据）
│     ├─ Movie.swift             相册视频 → 沙盒文件
│     └─ VideoProbe.swift        AVFoundation 探测 + 取帧
├─ init-repo.cmd                 一键建仓并推送
└─ README.md
```

**为什么用 XcodeGen**：`project.pbxproj` 是 Xcode 的二进制风格工程文件，手写极易出错且无法 review。
`project.yml` 是纯文本声明，云端一条命令生成工程，改文件结构不用碰 Xcode。

---

## 常见问题

**构建失败怎么看**
Actions 里点进失败的那次运行，展开红色的 `Build (unsigned)` 步骤，最后 30 行通常是真正的原因。

**Sideloadly 报 "Provision" 错误**
多半是 Apple ID 没开双重认证，或者这台手机已经装过 3 个自签应用（免费账号上限 3 个）。

**装好后闪退**
先确认证书已信任（设置 → 通用 → VPN 与设备管理）。仍闪退就看 Xcode Organizer 拿不到日志，
改用手机上的「设置 → 隐私与安全性 → 分析与改进 → 分析数据」找对应崩溃日志。

---

## 下一步（M2）

按 `docs/specs/phase1-video-pipeline.md` §4 做色彩管线：

1. `ColorMath.swift`：S-Log3 解码 + S-Gamut3.Cine→709 矩阵 + OETF + 高光软肩
2. `CubeParser.swift`：.cube 解析（1D / 3D）
3. Core Image 自定义 kernel 串起来，先出「静帧调色对比」
4. 再接 `AVAssetReader/Writer` 做 HEVC 导出
