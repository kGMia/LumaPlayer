# Dolby Vision、画面工具与章节进度条（2026-10-15）

## 本次实现

### Dolby Vision：实验性的 GPU RPU → SDR 路径

当前窗口为 NSOpenGLView + libmpv render API。阅读固定 mpv 版本的 `video/out/gpu/video.c` 后发现，旧 GPU renderer 在初始化时明确恢复 Dolby Vision 的基础层色彩参数。单独改变 HDR 选项并不能修复 Profile 5 的专用编码。

本次在已有颜色转换阶段接入 **libplacebo 7.360.1 的 `pl_shader_decode_color`**。复用该库的 polynomial/MMR reshaping、非线性转换和矩阵实现，不重新实现 Dolby 数学。每个画面从当前 `mp_image` 读取 RPU；生成的 GLSL 与标量、向量、矩阵和数组参数通过 mpv shader cache 绑定。没有视频帧 CPU 回读，也没有增加一次完整画面的中转。元数据系数作为动态 uniform 更新，系数变化不改变 shader 源码；分段结构变化仍可能触发 shader 编译。释放 renderer 时释放 generator。

转换后继续现有 BT.2390 SDR 色调映射与显示色彩管理；每帧更新 HDR 色彩参数，避免 seek、RPU 中断或基础层回退沿用上一帧映射数据。RPU 接口或参数不支持时，保留基础层路径，并在视频信息中报告映射未确认。实际效果与成本尚未测量。

- Settings → Playback → Picture & Color：`Dolby Vision RPU Mapping · Experimental`，默认开启，可以关闭用于基础层对比。
- 视频信息显示容器 DV Profile、RPU 渲染 pass 状态或基础层回退。Profile 5 无可用 RPU 时提示颜色可能不正确，可尝试 Software 解码。
- 状态依据所选 track、帧色彩参数及 renderer pass 名称，不会仅凭 HEVC 或 PQ 就宣称 Dolby Vision。
- SDR-only 的 RIFE / Apple / FSRCNNX 增强明确旁路 Dolby Vision，包括容器已声明 DV、颜色信息尚不完整的情况。
- **输出仍是 SDR，不是原生 Dolby Vision/EDR 输出**。没有声称支持完整 FEL 重建、所有 DV profiles、Dolby trims 或认证参考显示。当前 libplacebo/FFmpeg 元数据支持决定能进入映射的内容；部分文件/硬解路径可能没有可用 RPU。Profile 7/8 回退时也不应一律称为 HDR10：兼容层类型依实际文件而异。
- 编译通过不等于 GPU shader 或影片色彩已验证；尚未播放 Profile 5 / 7 / 8 样片，也没有画质或性能数据。

源码：`native/mpv-filter/iive_dovi.h`，可重复的固定版本补丁在 `scripts/prepare-mpv.py`。只修改工作区专用 mpv，不修改 IINA.app。libplacebo 为 LGPL-2.1-or-later，mpv 源文件为 LGPL-2.1-or-later，本项目及适配代码 GPL-3.0-or-later；复用已有链接依赖，没有新增下载模型或可执行文件。

### 原生右键菜单与图片

在视频画面或黑边右键 / Control-click：

- **Save Image**：不弹确认框，保存唯一命名 PNG。默认目录 `~/Pictures/IIVE Screenshots`；Settings → General → Screenshots 可选择目录。不会自动覆盖已有快照。
- **Save Image As…**：系统保存面板。
- **Live Text**：立即打开面板显示捕获/识别进度，调用 VisionKit `ImageAnalyzer` 后直接展示识别全文，可以选择文字或 Copy All。原画面默认折叠，展开 Captured Frame 后仍可使用系统图中文字选择。无识别结果和失败均有说明。不会自动暂停或恢复播放。
- **Add Time Marker / Time Markers**：添加当前时间，跳转或删除已有标记；黄色刻线显示在时间轴上。每个视频最多 500 个，0.5 秒内不重复添加。按媒体路径摘要在本机持久化，重启后保留；移动/改名后不会自动迁移，不修改媒体文件。

截图使用 mpv `screenshot-to-file ... window`，包含当前缩放、色彩映射和 mpv 字幕，排除 SwiftUI 控件和实时语音字幕层。当前截图为显示的 SDR 图像，不能作为 HDR 原始图像导出。成功提示来自命令完成回调；截图任务入队后若换片会拒绝捕获。另存为在打开保存面板之前冻结当前帧，避免选完目录后保存成后续画面；最终图片在后台原子写入。Live Text 临时 PNG 读入内存后立即清理，关闭面板释放图像与识别视图。这是单次截图功能，不是实时视频管线的磁盘中转。

快捷键：⌥⌘S 直接保存，⇧⌥⌘S 另存，⌘B 添加时间标记。

### 章节条

按文件章节时间分段，各段圆角，段间留缝。鼠标悬停的分段加粗，拖动时同样突出当前分段。**流光已按反馈移除**；只保留遵循 Reduce Motion 的短暂厚度过渡。间隙在原时间坐标内部缩进，点击/拖动依然保持线性的时间映射。

没有章节时保留单段。排序、重复时间、零起点缺失、越界章节、极短视频均有边界处理。原有缩略图/章节文字预览保留，时间标记不影响原章节结构。

## 最基础检查

- Xcode 27 / macOS 27 arm64 Debug 最终构建通过（13.657 秒，0 errors）；保留既有的 AppIntents metadata skipped 提示。已复制 Personal Team 开发签名应用到 `build/PersonalTeam/IIVE Player.app`。
- `tests/dovi_shader_smoke.c`：仅 CPU 生成合成 polynomial / 混合 MMR 元数据的 GLSL150，检查绑定格式、紧密 host layout、数组维度与系数修改时源码稳定性。两种输入分别为 133 / 421 个 float 值，全部通过。**这不是 GPU 图像正确性测试，也不是视频性能数据。**
- `scripts/prepare-mpv.py` 语法检查与重复应用成功。
- 不进行 Computer Use、GUI 检查、真实媒体播放、完整测试或性能 benchmark。实际显示、截图、Live Text 选择、菜单、章节动效由用户验证。

结果：`benchmarks/results/dovi-shader-contract-20261015.txt`、`dolby-frame-tools-build-20261015.log`、`dolby-frame-tools-backends-20261015.log`。

## 下一步优先级

1. **Metal/EDR 输出路径**：先做独立、可切换的 renderer 原型，保留现有 mpv 解码、音频、PTS、字幕逻辑。评估 libplacebo GPU-next 的可嵌入接口与 Metal/Vulkan 依赖成本，再决定架构；不能将 `vo=gpu-next` 直接当成当前 OpenGL render API 的替代选项。正确管理浮点表面、屏幕 EDR headroom、ICC、窗口跨屏和 HDR 截图。
2. **播放关键路径调度**：统一 RIFE/SR/解码背压与 GPU in-flight 上限，减少主线程状态广播；分离解码、推理、GPU 排队、显示等待指标，依据实测尾延迟决定降级，避免只看模型吞吐。
3. **定位交互**：拖动期间合并 seek 请求，增加仅在释放时精确定位的快速预览策略；标记名称编辑、导入导出与章节键盘导航。继续保留当前预览帧直到下一张就绪。
4. **产品完善**：依赖打包与签名、播放错误恢复、断点/标记文件身份迁移、辅助功能覆盖。可选再加入 HDR 原图保存和更完整的色彩管理 UI。

参考：

- [mpv stable manual](https://mpv.io/manual/stable/)，本地固定源码 `88eb9f2e73945d8bc9c133a2f67babaa9af34680` 的 GPU conversion / screenshot / vf_format。
- [libplacebo color shader source](https://github.com/haasn/libplacebo/blob/master/src/shaders/colorspace.c)，实际编译接口以本机 7.360.1 headers 为准。
- [Apple Live Text for images](https://developer.apple.com/documentation/visionkit/enabling-live-text-interactions-with-images)、[ImageAnalysisOverlayView](https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview)，并核对 macOS 27 SDK Swift interface。

## 同日交互修复与后续优化

- 修复多章节偏移：`offset` 不参与 SwiftUI 容器尺寸计算，原 ZStack 被按最长单段宽度居中。章节容器现在明确占满轨道宽度并左对齐。
- GeometryReader 在同一次布局中向绘制、指针、预览定位和手势提供一致宽度。窗口缩放时不再使用滞后一拍的宽度状态定位；进度填充按同一绝对时间坐标裁切，首尾不额外留缝。
- 完全删除流光渐变、动画任务与状态，保留章节圆角和悬停加粗。
- Live Text 主界面直接显示识别全文，原画面可选展开。PNG 读取移到后台；重复调用正在识别的面板只将其前置。关闭面板或播放器会取消识别并丢弃迟到的截图结果，避免窗口再次弹出。
- 缩略图轮询命中同一张图时不重复发布状态；拖动释放以最终指针位置定位。
- 仅执行基础 Xcode 构建与签名检查；没有 GUI、实际 OCR/播放检查或完整测试。最终日志见 `benchmarks/results/chapter-text-fix-build-20261015.log`。
