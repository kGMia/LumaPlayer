# 2026-10-14 播放器窗口、队列与签名更新

> 后续侧栏按钮、迷你控件和快捷键已调整，当前行为见 [交互更新](player-interaction-update-20261014.md)。

## 本轮交付

- 以 SwiftUI 实现队列、增强、信息三个侧边栏页面；顶部使用原生 segmented Picker，large 控件尺寸与 Capsule 外轮廓。增强参数由同一组件提供，侧栏与快捷设置保持一致。
- **最终全屏方案不使用右侧栏**：播放条的队列按钮打开 360×420 的 SwiftUI popover；设置按钮打开快捷增强设置，完整偏好仍在 Settings（⌘,）。⇧⌘P 同样打开队列气泡，⌥⌘I 打开增强设置。两个气泡互斥，打开时播放条不会自动隐藏。进入全屏前收起侧栏，退出后恢复先前状态，避免全屏中调整视频布局。
- 置顶迷你播放器：⌥⌘P 或工具栏 Mini Player。精简 SwiftUI 播放/静音/恢复控件，Esc 恢复普通窗口。复用同一 VideoView 和 mpv session；窗口层级、跨桌面行为与大小恢复由公开 AppKit API 管理。全屏进入迷你模式时先退出系统全屏。超分仍按实际输出尺寸决定是否必要。
- Settings → General → Add Media from the Same Folder，默认关闭。打开单文件时异步扫描同层普通音视频文件，自然排序；跳过隐藏文件、子目录、符号链接和非媒体扩展名。追加与 playlist-move 不重新加载当前视频。显式多选保留选择的队列；打开新文件、追加、手工切换/删除、停止和关闭时取消旧扫描。自动追加不再取消增强预热后的续播。
- Settings → Playback 增加软件解码 / 实验性 VideoToolbox 选择，应用于下次手动打开的文件。Information 显示实际 `hwdec-current`，不会把选中的偏好当作已启用状态。
- **按用户最新要求不加入 AirPlay**。

## 解码与增强管线判断

当前 FFmpeg 已具备 H.264、HEVC、AV1（包含 dav1d）、VP9、ProRes 等解码能力。增加第二套解码器通常不能直接改善同一压缩流的重建画质，反而增加维护与色彩一致性风险。暂不新增依赖；兼容性问题应由具体失败文件、编码 profile、位深和容器证据驱动。

当前本地 mpv 的 `vd_lavc.c` 存在 `videotoolbox-copy` 路径，可在没有原生 VideoToolbox 显示互操作的构建中输出软件可见帧。新增选项采用该路径；原生增强滤镜目前明确拒绝硬件 mp_image，因此不能直接切换到零拷贝硬件帧。解码效率和总体功耗是否改善仍需实测，默认保留软件解码。

继续优化优先级：

1. **解码到推理**：保留 VideoToolbox 解码的 CVPixelBuffer / IOSurface，增加 mpv 硬件帧导入与引用生命周期支持，避免 download 后再复制到新 IOSurface。必须同时处理 NV12/P010、色度位置、范围、旋转与 HDR 旁路。
2. **推理到显示**：原生 RIFE → FSRCNNX 已共享 NV12 surface；剩余 OpenGL 上传值得分析。Metal 呈现迁移须保留字幕、色彩/HDR、尺寸与 mpv 音频时钟，不能只替换显示一个纹理。
3. **调度与模型**：保持先插帧、后超分；小窗口跳过无意义 SR。先用 Instruments 定位计算、带宽和等待占比，再评估 balanced 的推理分辨率与图融合。本轮不宣称新的 FPS、加速倍数或 Neural Accelerator/ANE 占用率。

研究参考：

- IINA `AutoFileMatcher.swift`，commit `2afb9f20f6b4a049f9db066e55b4b7a457fa4e81`：同层扫描、自然排序、过期任务丢弃。独立实现了简化队列逻辑，没有复制其私有 PIP.framework 接口。[源码](https://github.com/iina/iina/blob/2afb9f20f6b4a049f9db066e55b4b7a457fa4e81/iina/AutoFileMatcher.swift)
- 本地 mpv commit `88eb9f2e73945d8bc9c133a2f67babaa9af34680`，`video/decode/vd_lavc.c`、`DOCS/man/input.rst` 的 `hwdec-current` 与 `playlist-move`。特别处理了向前移动时目标索引的语义。[源码](https://github.com/mpv-player/mpv/blob/88eb9f2e73945d8bc9c133a2f67babaa9af34680/video/decode/vd_lavc.c)
- [Apple：配置开发团队](https://help.apple.com/xcode/mac/current/en.lproj/dev23aab79b4.html)。已有 GPL 项目与本项目许可兼容；没有引入新的第三方代码或二进制依赖。

## 签名与构建

Xcode 已选中用户 Personal Team，并移除了旧的 ad-hoc identity 覆盖，改用 Apple Development。实际构建日志包含 Apple Development 签名，`codesign --verify --strict` 在系统信任链可访问时返回 `valid on disk` / `satisfies its Designated Requirement`。沙箱内验证曾报告信任链不可用，沙箱外验证通过；没有更改证书信任设置。

这是本机开发签名，不是 Developer ID 公证发行包。应用仍依赖工作区和 Homebrew 动态库。不要移动到其他 Mac 后将其当作独立发布包。

本轮已签名开发应用：`build/PersonalTeam/IIVE Player.app`。基础验证记录：`benchmarks/results/player-window-basic-20261014.json`。

打开 `IIVEPlayer.xcodeproj` → **IIVE Player / My Mac** → Run。`scripts/build-player-modern.sh` 仍可从命令行构建。项目生成器现在拒绝覆盖已有项目，以保护 Personal Team 和用户 Xcode 设置。

新增窗口/队列模块位于 `PlayerSystem/`（已加入 Xcode target）；现有播放器主代码在 `native/Player/Modern/`。

## 最小验证与未验证项

- Personal Team 构建成功；签名验证成功。
- 实际执行 FolderMedia：Episode 1 / 2 / 10 排序，以及隐藏文件、非媒体、目录、符号链接排除均通过。
- 早期方案的基础 UI 检查确认迷你窗口宽 440、恢复入口和全屏侧栏可打开；**该全屏侧栏方案已被最终 popover 方案替换**。
- 最终 popover / 胶囊切换器只做编译检查，按用户要求把观感、交互流畅度及实际播放验收交给用户。
- VideoToolbox 选项与显示字段已编译；本轮未完成硬件解码、组合模型实时性、音画同步及长片回归验收。没有新增性能数据。
