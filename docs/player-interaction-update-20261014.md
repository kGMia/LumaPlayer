# 2026-10-14 Liquid Glass 与播放器交互更新

> 后续窗口实现已更新：侧栏改为整体分段切换器，迷你模式改为独立 NSPanel 并保留原窗口；以下窗口描述为较早迭代。最新行为见 [独立迷你窗口说明](player-floating-panel-20261014.md)。

本轮只做基础编译和开发签名校验。视觉效果、逐帧定位与实际播放由用户验收；没有新增 FPS 或模型画质测试结果。

## 窗口和控件

- 侧栏去掉带可见 Sidebar 标签的 Picker，替换为 SwiftUI `GlassEffectContainer` 中的原生 `.glass` 图标按钮（Queue / Enhance / Info）。胶囊形按钮使用系统 Liquid Glass，当前页面通过 accent tint 与辅助功能选中状态标识，鼠标悬停提供名称。
- 侧栏底层改为半透明材质，Form / List 不再自行绘制不透明滚动背景；主播放器工具栏背景隐藏，标题栏透明。使用 hiddenTitleBar / fullSizeContentView，并让视频延伸到安全区，避免迷你模式顶部露出窗口的白色背景。
- 迷你模式入口从顶栏移至悬浮播放面板，保留 ⌥⌘P。迷你窗口中央是快退 / 播放暂停 / 快进玻璃面板；关闭与恢复在顶部角落，标题与静音在底部。支持从视频区域拖动窗口，悬停控件时不自动隐藏；Esc 或双击恢复普通窗口。
- 普通窗口保留右侧栏；全屏沿用队列与设置各自的 popover，不重排视频区域。

上述实现使用公开 SwiftUI / AppKit API，没有复制 QuickTime Player 的私有实现。原生模型与 VideoView 的实例不因切换窗口模式而重建。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| Space | 播放 / 暂停 |
| ← / → | 按普通步长快退 / 快进，默认 5 秒 |
| ⇧← / ⇧→ | 按长步长快退 / 快进，默认 30 秒 |
| ⌘← / ⌘→ | 前一帧 / 后一帧，自动暂停 |
| , / . | 前一帧 / 后一帧的替代键 |
| ⌥⌘← / ⌥⌘→ | 上一个 / 下一个文件（从原 ⌘ 方向键迁移） |
| ↑ / ↓ | 音量增减，默认每次 5% |
| M | 静音 |
| ⌃⌘F | 切换全屏 |
| ⌥⌘P | 进入 / 恢复迷你模式 |
| ⇧⌘P | 队列 |
| ⌥⌘I | 增强侧栏 / 全屏增强气泡 |
| ⇧⌘E | 增强总开关 |
| ⌘I | 视频信息叠加层 |
| ⌥⌘S / ⇧⌘S | 截图 / 加载字幕 |
| ⌘0 | 恢复 1× 速度 |
| ⌘, | Settings |

逐帧使用 mpv 的 `frame-step` / `frame-back-step`，不是按 1/FPS 估算时间跳转。后退需要精确 seek 与重新解码；VFR、关键帧分布及改变时间戳的插帧滤镜会影响定位和响应，不承诺所有格式下帧精确。代码显式暂停以取消预热后的自动续播。

## 新设置

- **General**：自动隐藏控件的等待时间（1–15 秒）、双击行为（全屏 / 暂停 / 无操作）、迷你窗口置顶与跨桌面显示。迷你窗口双击始终恢复。
- **Controls**：普通跳转 1–120 秒、Shift 跳转 1–600 秒、音量步长 1–20%，完整快捷键说明。
- **Enhancement → Automatic Activation Limits**：超分启动倍率 1.05–2×，超分源高度上限，插帧源 FPS 上限 24–60，插帧源高度上限。高度可选不限 / 720 / 1080 / 1440 / 2160。
- 以上偏好持久化；阈值修改实时参与滤镜规划。超过阈值显示 Bypassed 原因，不把效果仍标成 Active。重置阈值只改变四项限制。
- 原生 SR 停止阈值低于启动阈值 0.10×，且始终要求实际放大，减少尺寸边缘反复切换。GLSL 自身要求 >1.3×，自定义值不会绕过该条件。
- 颜色、模型维度、Apple 支持能力及输出目标 FPS 限制仍然有效。阈值不是降低模型推理分辨率的开关。默认统一 SR 倍率为 1.3×、插帧源帧率上限 30 fps；两种源高度默认不限。

## 构建和参考

最终 Xcode build 成功，日志为 `BuildProject-Log-20261014-200712.txt`（基础记录见 `benchmarks/results/player-interaction-basic-20261014.json`）。只有既有 AppIntents 无依赖提示，不影响编译。工作区开发应用为 `build/PersonalTeam/IIVE Player.app`，仍依赖本工作区的动态库；这不是独立公证发行包。

参考了本地 IINA 的键位翻译与 PlayerCore 逐帧入口，以及 pinned mpv 的 `DOCS/man/input.rst` 逐帧命令契约。公共框架参考：[Apple Liquid Glass](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))、[工具栏背景](https://developer.apple.com/documentation/swiftui/view/toolbarbackgroundvisibility(_:for:))、[隐藏标题栏](https://developer.apple.com/documentation/swiftui/windowstyle/hiddentitlebar)。
