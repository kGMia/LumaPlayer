# 管线优化与原生动画 · 2026-10-15

本轮落实上一轮检查中的颜色转换、播放预热状态、重复解码和阶段计时建议，并增加 SwiftUI 原生动画。仅编译检查，未运行播放器或 Computer Use，未测量实际画质、吞吐和功耗。

## Metal NV12 输入规范化

新增 `native/AppleBackend/NV12Normalizer.m`、`NV12Normalize.metal`，由 Xcode 既有 `Build native engines` 阶段经 `build-apple.sh` 编译。编译后的 metallib 嵌入 `libIIVEApple`，不依赖运行时 Shader 路径，不需要修改 Xcode 工程结构。

每个原生滤镜 worker 持有一个转换器并在退出时释放。输入选择顺序：

1. 已满足规范的 IOSurface 直接共享。
2. 支持的 VideoToolbox NV12 帧通过 Metal 写入现有输出池。
3. 不支持的格式或 GPU 转换失败继续走 swscale。

GPU 路径范围：BT.709 primaries / BT.1886 / BT.709 matrix；偶数尺寸；8-bit NV12；有限或全范围；center 或 left chroma；逐行帧。仅处理范围与色度位置，不做色域或传递函数转换。left → center 在 UV 水平方向偏移 1/4 色度纹素，并进行线性采样和边界钳制。全范围转换至视频范围。源缓冲区像素和附件保持不变，成功后才设置目标附件。

这是一条真实 GPU 转换路径，**不是零拷贝**：写入新的池化 IOSurface，并在 worker 等待完成后交给模型。仍保留同步 GPU 边界。原生 SR / Apple FI 的颜色支持范围没有扩大，HDR 仍旁路。

信息面板显示实际路径 `shared-iosurface` / `metal-normalized` / `swscale-copy`，及 GPU 规范化输入计数。使用软件解码时不会触发新增的硬解 NV12 路径。

## 预热状态与用户播放意图

`MPVSession` 从一个恢复布尔值改为三种显式状态：idle、warming-play、warming-paused。

- 模型预热产生的临时引擎暂停，与用户希望播放/暂停的意图区分。
- 预热期间按播放/暂停切换用户意图；逐帧操作显式保持暂停。
- 切换/删除当前文件或收到文件生命周期事件时，取消旧预热；恢复仅由预热造成的临时暂停，避免带入新文件。
- 删除无关条目不改变预热状态；预热期间 seek 刷新等待期限。
- 连续更改增强选项保留当前用户意图。
- `pause` 表示 UI 应展示的意图，新增 `engine-paused` 保留实际引擎状态；`playback-phase` 和 `enhancement-warming` 说明当前阶段。
- 预热期间显示准备提示、保持控制面板可见，不计入 UI 自动性能降级的稳定播放采样。

没有重写 mpv 的媒体时钟；仍使用原生 seek / frame-step / 文件事件。本轮没有实际验证音画同步或长片播放。

## 减少重复解码与 GPU 工作内存

自适应玻璃不再调用 AVFoundation 解码当前视频。启用 adaptive 主题时，播放器从实际渲染画布每两秒至多采样一次：GPU 缩至 16×9，通过一个 PBO 提交读取，后续使用零超时 fence 检查完成，再读取 576 字节。采样失败保持无数据；不阻塞等待 fence。窗口 live resize / transition 时暂停相关操作，renderer 退出时释放资源。

该值是包含黑边和视频字幕的画布亮度近似，仅用于 UI 明暗迟滞选择，不是色度计或 HDR 亮度测量，也不包含 SwiftUI 控件。时间轴预览仍使用有界、可取消的独立 AVFoundation 生成器。

FSRCNNX 的 `process` 是同步接口、mpv 每个滤镜也只有一个推理 worker。改为一个受信号量保护的 GPU 工作槽，移除未提供流水并行收益的第二份输入/输出张量缓冲及轮转状态。此项减少该工作区的分配数量，不代表整个模型内存减半。

## 诊断指标

原生 SR / Apple FI / RIFE 增加：

- `input_ms`：输入取得、转换和等待。
- `model_call_ms`：模型 API 调用，包含其内部处理与 GPU 等待。
- `output_ms`：输出取出、包装或转换。
- `normalized_inputs`：成功 GPU 规范化的输入累计数。

这些是实际 worker CPU 单调时钟采样，显示在 Live Performance 中。不能把 model_call_ms 当作纯模型 GPU kernel 延迟；RIFE 一次调用可能输出多个帧。冷启动、场景检测等额外工作仍包括在总 job 时间中，三个分段不保证等于总时间。显示队列延迟与 Neural Accelerator 占用率仍未测量。

## 原生动画与可访问性

- SwiftUI SF Symbols replace transition：播放/暂停、静音、信息开关及迷你播放器图标。
- 主控制按钮的轻微弹性按压反馈。
- OSD 数字变化与图标切换；控制面板显示/隐藏带轻微位移。
- 侧栏内容切换淡入淡出，保持原有三个视图实例，不重新创建列表。
- 信息 HUD 和时间轴预览气泡进入/退出过渡；预热提示布局变化平滑过渡。
- 新增动画遵循系统 Reduce Motion。缩放/位移不作用于视频渲染视图；没有给逐帧位置或性能数值添加持续动画。
- 自定义进度条与音量条增加 VoiceOver adjustable action。

## 基础验证与交付

- 最终 Xcode Debug arm64 构建成功：8.169 秒，无错误；包含新 Metal kernel、Objective-C 转换器、原生 C 滤镜、Swift 模型与 UI。
- AppIntents 元数据提取提示仍存在，不影响此次构建。
- 编译了可选回归检查 `tests/NV12NormalizerSmoke.m`，但**没有执行**。覆盖有限/全范围 × center/left、UV 位移、边界钳制和输入附件不变。需要时手动运行 `bash scripts/test-nv12-normalizer.sh`。
- 沙箱命令行首次调用 Metal 工具报告工具链不可见；Xcode 构建可正常编译 Metal。回归检查程序使用已由 Xcode 生成的库完成编译，没有因此安装或下载工具链。
- 日志：`benchmarks/results/pipeline-motion-build-20261015.log`、`pipeline-motion-backends-20261015.log`。
- 应用：`build/PersonalTeam/IIVE Player.app`。个人账户签名的 `codesign --verify --strict` 检查通过；仍依赖工作区和 Homebrew 动态库。

## 后续顺序

1. 用户检查动画、预热中手动暂停/逐帧/切文件；对常见 left-chroma 视频比较新增 GPU 转换与 CPU 回退画面。
2. 根据新增阶段指标选择真正瓶颈，再考虑合并输入转换与推理 command buffer，避免一次额外 GPU 提交/等待。
3. 队列封面的串行读取仍需独立超时和取消服务；继续拆分 PlayerModel 的增强计划与媒体库职责。
4. 独立应用的动态库打包、版本控制和可分发签名流程作为后续工程收敛工作。未在本轮新增解码器、扩大宽色域支持或替换更重模型。
