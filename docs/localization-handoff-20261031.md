# Luma Player 收尾记录 · 2026-10-31

按用户要求完成繁体中文（`zh-Hant-TW`）全量本地化与校对，未执行 GUI 验证。

- 播放列表泛光改为按条目身份淡入淡出；保留跨行反射范围与辅助功能设置。
- 列表行使用主线程隔离的 Equatable 输入，避免无关播放器状态触发整行重算；“接下来播放”邻项只扫描一次。
- 本地文件加入 SwiftUI ShareLink；文件对话框按打开、文件夹和导出分别记忆配置。
- Xcode 原生 String Catalog 已接入，Swift 字符串提取已开启。菜单、OSD、文件对话框、网络错误、语音字幕状态等补入本地化入口。

## 本地化状态

- `Localizable.xcstrings`（`zh-Hant-TW`）：全部 **616 条** 已完成翻译并标记为 `translated`（含原有 131 条审校转正与新增 485 条补齐，未翻译 0 条）。
- `InfoPlist.xcstrings`（`zh-Hant-TW`）：全部 **3 条** 已完成审校并标记为 `translated`。
- 合计 **619 条** 全部完成（100%），严格遵循 Apple macOS 繁体中文原生术语规范（如「檔案夾」、「拷貝」、「輸出」、「共享」、「原況文字」、「即時字幕」、「在Finder中顯示」、「移到垃圾桶」、「接著播放」等），所有多参数格式化占位符（`%1$@`、`%2$@`、`%1$lld`、`%2$lld`、`%3$lld`、`%1$d`）与单参数占位符均已校验一致。
- 部分底层诊断及动态增强状态仍保留英文；文件名、模型名和协议名称保留原文；持久化选项值与内部状态字符串保持不变。

## 验证与交付

在 Xcode 中打开 `IIVEPlayer.xcodeproj`，选择 `Luma Player` scheme 重新构建或运行 `scripts/build-player-modern.sh`，即可将最新完整翻译编译进 `build/Luma Player.app`。可通过 Xcode scheme 的 Application Language 或系统的应用语言设置检查繁体中文布局。
