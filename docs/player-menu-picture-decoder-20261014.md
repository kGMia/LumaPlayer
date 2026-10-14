# 播放菜单、画面设置和解码器 · 2026-10-14

## 菜单与空队列

播放条的播放选项/速度菜单、播放列表的排序/显示菜单改用公开 AppKit `NSPopUpButton` + `NSMenu`，通过 SwiftUI `NSViewRepresentable` 嵌入。仅在展开前构建菜单树，展开期间不随 250 ms 播放快照更新替换内容，也不自动隐藏播放条。二级菜单由 AppKit 跟踪，菜单关闭后再提交操作，避免开文件或窗口切换打断菜单跟踪。

菜单加入适用的 SF Symbols 图标与当前项勾选状态。其余页面继续使用 SwiftUI。

空播放列表的标题、选项和添加按钮固定在顶部；空状态提示占用下方剩余空间，不再把整个 VStack 垂直居中。

## 画面设置

Settings → Playback 新增 Picture & Color，播放条的 Playback options 也提供快捷项：

- 旋转：0 / 90 / 180 / 270 度，叠加在文件方向元数据上；某些原生增强滤镜会绕过不支持的旋转输入。
- 画面效果：Neutral / Vivid / Soft / Monochrome；映射到 mpv 的显示调整属性，不修改媒体文件，不宣称增加画面细节。
- 亮度、对比度、饱和度、Gamma、色相：-100…100，持久化并实时提交。
- 输出色彩描述档：Automatic（遵循源信息、不覆盖输出 ICC）、Current Display ICC、sRGB ICC、Display P3 ICC、载入自定义 RGB ICC。自定义描述档使用 NSColorSpace 校验，最大 16 MB；保存经过验证的数据副本。

ICC 数据通过 `MPV_RENDER_PARAM_ICC_PROFILE` 提交到现有 render context，并启用 `icc-profile-auto`，不是仅依赖 libmpv 无法自行获取的系统显示配置。状态区区分加载、渲染接口拒绝和 Configured。Configured 表示描述档已经提交，不能作为色准测量证明。当前显示器模式在视频窗口换屏或迁移后更新。

描述档描述输出设备，不用于猜测源色彩。手选 sRGB/P3 必须匹配实际显示目标，不等于 HDR 升级；原有增强的 HDR/色彩限制保留。

## 解码器

三个选项同时存在于设置页、播放条快捷设置和 Playback options → Decoder：

| 选项 | 实际请求 |
| --- | --- |
| Software | `hwdec=no` |
| Auto · Hardware Enabled | `hwdec=auto`；选用需普通像素帧的原生增强时为 `auto-copy` |
| Hardware · Copy | `hwdec=videotoolbox-copy` |

选择持久化并应用到当前会话；切换可能短暂重启解码。自动/复制硬解不支持具体格式时由 mpv 回退软解。界面同时显示 Requested 和实际 `hwdec-current`，不把偏好当作生效证据。

为补齐后端构建能力：

- 启用 LittleCMS 2.19（MIT），许可证随应用打包；依赖来自已安装的 Homebrew 包，没有下载可执行文件。
- 启用 mpv 已有 VideoToolbox/OpenGL mapper。固定版本的 Meson 原本把该 mapper 限制为 mpv 自己的 Cocoa 窗口前端；`prepare-mpv.py` 的小范围补丁允许 macOS plain-GL embedding 使用同一 mapper。播放器已提供当前 CGL 上下文，不引入另一个 mpv 窗口前端。
- 实际构建宏为 `HAVE_LCMS2=1`、`HAVE_VIDEOTOOLBOX_GL=1`。未启用 Vulkan 路线，也未启用不安全硬解候选。

## 播放信息

HUD 和 Information 增加当前播放器进程 CPU、物理内存 footprint；详细信息另列 resident memory、实际解码器、旋转和 ICC 状态。

CPU 用 `getrusage` 的进程 CPU 时间差/墙钟时间差计算，每秒采样一次，100% 表示一个逻辑核心，允许超过 100%。内存来自公开 `proc_pid_rusage`，单位由 ByteCountFormatter 展示。这些值不是全系统占用。

GPU 利用率显示 **N/A**：当前公开集成没有可靠的进程 GPU 利用率来源。没有使用私有 IOReport、推理耗时或 CPU 数值冒充 GPU 百分比。

## 基础检查与边界

最终构建成功：`BuildProject-Log-20261014-213918.txt`，6.15 秒；仅既有 AppIntents 无依赖提示。Personal Team 严格签名校验通过。

`mpv --no-config --hwdec=help` 列出 VideoToolbox 和 copy 路线，包括 H.264、HEVC、ProRes、VP9、AV1 等解码器候选。这只证明构建注册了候选，不代表当前 M5 对所有 codec/profile/bit depth 都能硬解。

在用户提出禁止 Computer Use 之前，进行过一次队列二级菜单的键盘展开检查；之后不再进行 Computer Use。最终空队列布局、悬停交互、色彩效果、硬解实际兼容性与播放表现均由用户验收。没有进行完整播放回归或新增性能基准。

开发应用：`build/PersonalTeam/IIVE Player.app`，仍依赖工作区与 Homebrew 动态库，不能视为可独立分发安装包。

实现依据是固定 mpv 源码中的 `DOCS/man/options.rst`、`include/mpv/render.h`、`video/out/gpu/libmpv_gpu.c` 和 `hwdec_mac_gl.c`，以及当前 Xcode SDK 的 NSColorSpace、NSMenu、sys/resource.h 公共接口。
