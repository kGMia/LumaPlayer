# 2026-10-14 独立迷你窗口与控件更新

> 后续需求已调整：进入迷你模式现在隐藏主窗口，并加入淡入淡出；请以 [队列与窗口切换说明](player-queue-transitions-20261014.md) 为准。

本记录取代此前「缩小原窗口」的迷你模式设计。只进行 Xcode 编译、代码路径检查和开发签名校验；没有进行 GUI 播放、切换耗时或新模型性能测量。

## 使用与交互

- 播放条的迷你窗口按钮或 ⌥⌘P 打开独立浮动窗口。原窗口保留大小、位置、播放列表和设置，并显示视频正在迷你窗口播放的提示；不会同时渲染第二份视频。
- 迷你窗口中央为三个独立 Liquid Glass 圆形控件：快退 / 快进 48 pt，播放暂停 64 pt。角落按钮 40 pt；底部显示标题、静音与精简进度条。拖动进度条时本地预览位置，释放后发送一次 seek；只按住滑块而未改变值不会跳转到旧预览值。
- 关闭迷你窗口、恢复按钮、Esc、双击视频均返回主窗口，继续同一个播放会话。关闭主窗口则停止播放并清理迷你窗口。视频区域可拖动窗口，边缘可调整尺寸。
- Settings → General 的置顶和跨桌面选项应用于浮动窗口。全屏主窗口不必退出全屏就能创建迷你窗口；实际 Spaces / 多屏行为待用户验证。
- 顶栏使用公开 `ToolbarSpacer(.flexible)` 将打开/最近文件与增强/窗口/设置操作分开。右侧栏使用一个 SwiftUI `.segmented` Picker，外层为整体玻璃胶囊，不再是三个独立玻璃按钮。保留透明标题栏与半透明侧栏。

## 实现边界

窗口使用公开 AppKit `NSPanel`，内容和控件使用 SwiftUI `NSHostingView`。这是播放器自己的原生浮动窗口，**不是 AVKit Picture in Picture**，不接入私有 PIP.framework。公开 `AVPlayerView` 的画中画入口属于 AVPlayer 播放路径，当前 mpv / Metal 增强帧没有直接接入该路径。

同一个 `VideoView` 在两个 NSView 容器之间移动，复用 mpv 会话、音频时钟、GL 上下文和增强滤镜。切换时先暂停新 render 回调，异步等待已开始的绘制结束，然后切换 drawable、恢复绘制。主线程没有同步等待整个 render 队列，且不做主窗口缩放动画。关闭主窗口时先解除暂停并结束 renderer，再移回视图和释放面板。快速重复触发在切换期间合并为忽略；延迟回调有 generation 校验，避免关闭后的过期操作。

输出尺寸来自实际视频视图，因此进入小窗口后超分可能因不满足倍率阈值而正常绕过。滤镜规划在窗口切换后等待 350 ms 再恢复，避免中间尺寸触发重配；确需更改目标尺寸时仍可能重新准备增强资源。这是代码层面的减少阻塞措施，**尚不能据此声称进入小窗口已无卡顿**。

## 基础验证

- Xcode scheme `IIVE Player` / My Mac 编译成功，6.477 秒，工具返回 errors 为空。
- 日志：`BuildProject-Log-20261014-202922.txt`。
- 开发应用：`build/PersonalTeam/IIVE Player.app`，从 Xcode DerivedData 复制。
- Personal Team 开发签名严格校验通过：valid on disk / satisfies its Designated Requirement。
- 应用仍依赖本工作区和 Homebrew 动态库；不是独立发行包。
- 未验证：连续快速切换、暂停时恢复画面、全屏跨桌面、多屏 Retina 切换、拖动进度的实际音画同步和玻璃视觉效果。用户可在普通播放与 RIFE fast / 48 fps 下分别试用。

源文件：`PlayerSystem/PlayerWindowModes.swift`、`native/Player/Modern/PlayerView.swift`、`PlaybackChrome.swift`、`PlayerModel.swift`、`PlayerSettings.swift`、`native/Player/VideoView.{h,m}`。

公共 API 参考：[NSPanel](https://developer.apple.com/documentation/appkit/nspanel)、[AVPlayerView 画中画入口](https://developer.apple.com/documentation/avkit/avplayerview/allowspictureinpictureplayback)、[ToolbarSpacer](https://developer.apple.com/documentation/swiftui/toolbarspacer)、[分段 Picker](https://developer.apple.com/documentation/swiftui/pickerstyle/segmented)、[Liquid Glass](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))。没有复制其他播放器的私有窗口实现。
