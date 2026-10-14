# Mac 插帧与播放器方向评估 — 2026-10-13

## 建议

下一轮选择：**现有 libmpv 定制播放器小范围实用化 + Apple VideoToolbox
低延迟插帧后端**。保留已可用的 RIFE fast，优先做 24→48，不再把 balanced 当作
基础款 M5 的默认选择。先得到可日常观看的最小版本，不立即追求功能齐全的 IINA 替代品。

原版 IINA 的 JS 插件接入不作为主线；如果后续需要完整 IINA 的字幕、播放列表、
偏好设置、快捷键和窗口体验，再做独立命名/签名的 IINA 分支。两者共用原生滤镜后端，
避免同时维护两套完整产品界面。无需为了更换插帧算法重写 mpv 的解码、音频或字幕系统。

本轮只做源码/API/构建路线核对与 12 次 Apple API 调用，不修改已安装的 IINA、
现有播放器默认配置或发布包，不运行完整测试矩阵。

## 用户反馈与现有 RIFE 的瓶颈

用户实测：48fps / fast 可用，balanced 几乎不可用。尚未提供此次片源分辨率、
编码和耗时记录，所以不能将该反馈扩展成“所有 720p 或 1080p balanced 都失败”。
但足以把当前 balanced 标为实验性，而不是合适的默认档位。

核对的本地实现：

- `RifeConfiguration.swift`：三个档位仍使用同一份 v4.26 权重。fast 的内部
  运动估计网格为原尺寸的 1/4，balanced 为 1/2，hq 为 1；不是三种不同轻重模型。
- balanced 的内部像素通常约为 fast 的 4 倍，实际还受 128/256 对齐 padding
  影响；这不等于总耗时严格增加 4 倍。最终仍有全分辨率 warp/blend。
- `RifeMetalCore/WeightStore.swift` 和 Metal kernels 已使用 FP16。不能把
  “改 FP16”当作尚未实施的主要加速措施。
- 当前宿主使用软件解码；swscale→BGRA→IOSurface 输入、输出复制、上游 CPU
  padding/cropping 都仍存在。统一内存不会自动消除转换、同步和复制成本。
- 当前性能守护按输入区间评估完整 adapter 耗时。24→48 每 41.67ms 输入区间
  通常生成一张中间帧；24→60 通常要两张非端点帧。不能只拿单次平均推理时间
  与 16.67ms 比较来判断整个播放器是否实时。

## 技术路线排序

| 路线 | 与 Mac 的适配及证据 | 主要限制 | 优先级 |
|---|---|---|---|
| VideoToolbox Low-Latency Frame Interpolation | Apple 官方面向实时视频；CVPixelBuffer、IOSurface/NV12，现机实际处理成功 | macOS 26+；本机本配置仅 420v；时相有离散网格限制；系统模型闭源；真人画质未验收 | **第一候选**，先 24→48 |
| 保留并优化 RIFE fast | 已有真实连续播放；开放权重，任意 t，现有 C ABI 可复用 | CPU 转换/复制、较高 GPU 占用、冷启动；进一步收益需分项测量 | **稳定备选** |
| Practical-RIFE lite + Metal/MPSGraph | 上游提供 v4.25.lite 等降低计算量的模型 | 当前图构建、encoder/warp/feature shape 与权重需要逐项匹配；不是换文件名就能运行 | 第二轮模型候选 |
| RIFE ncnn Vulkan / MoltenVK | C++ `process(..., timestep, ...)` 可做内存帧处理，官方构建支持 MoltenVK | 多一层后端；接口是 ncnn::Mat，现成接口并非 CVPixelBuffer；没有本机速度证据 | 独立对照，暂不迁移主线 |
| Core ML / ANE | 可以探索模型转换及设备分配 | 不能由 computeUnits=all 推断全图上 ANE；warp/grid sampling、分图及传输需核实 | 后置研究 |
| MetalFX Frame Interpolation | 本机设备支持该 API | 游戏路径包含深度、运动纹理等输入；解码视频没有对应可靠数据 | 不作为电影插帧首选 |
| Apple 高质量 Frame Rate Conversion | 视频编辑路线，输入/输出时相更灵活 | 官方定位质量优先，不能套用低延迟版本测量数据 | 将来用于 60fps/离线对照 |

ncnn 依据实际 `src/rife.h`、`src/CMakeLists.txt`、LICENSE；没有运行其 CLI，也
没有下载新 RIFE lite 权重。本轮未用未经验证的移植、INT8 量化、ANE 或第三方
宣传速度给出性能承诺。RIFE lite 的收益必须与原片运动、脸部、遮挡、颗粒和字幕
画质一起比较，轻量模型不保证在相同质量要求下更好。

## Apple 原生路线的本机证据

源文件：`native/Experiments/apple-vt-probe.m`；复现：

```sh
scripts/probe-apple-vt.sh          # 能力读取
scripts/probe-apple-vt.sh --process # 两种尺寸，各 6 次 midpoint 调用
```

真实输出：`benchmarks/results/apple-vt-evaluation.json`。
环境：Apple M5 / macOS 27.2 / 当前 Xcode SDK。

| 项目 | 720p | 1080p |
|---|---:|---:|
| isSupported / session 启动 / 6 次处理 | 成功 | 成功 |
| session 启动时间 | 420.1ms | 660.0ms |
| 首次 process | 7.26ms | 13.06ms |
| 后续 5 次 process 范围 | 3.60–5.64ms | 9.71–9.91ms |
| 本次支持格式 | NV12 video-range (`420v`) | NV12 video-range (`420v`) |

输入是两个预先填充的 NV12 移动棋盘帧，反复使用；输出采样有非零亮度。
这只是 API 与缓冲路径可运行的证据，不证明自然视频画质，也没有验证输出就是
理想运动中点。测量仅覆盖同步 process：排除源解码、池分配/填充、播放器调度、
显示、音频、scene-cut 策略。**不能与前轮 RIFE 的完整 adapter 耗时直接相除，
宣称加速倍数。** 六次调用不应包装成稳定 FPS、可靠 P95 或长片热性能。

本机 scale=1 查询上限是单边 1920、总像素 2,073,600。值得注意：构造 4K
configuration 仍可能返回对象；创建成功不等于能处理。正式适配器必须先检查
尺寸/像素上限，再验证 session 和 process；本轮没有对 4K 发起推理。
一次沙箱内能力读取没有可见 Metal device；最终记录来自允许 GPU 访问的本机
进程，识别 Apple M5。沙箱读到的 false 不被当作硬件不支持。

### 24→60 不能照搬 RIFE 调度

本地 SDK 对低延迟配置规定：插值点来自二分网格，例如参数 1 给 t=.5，参数 2
给 .25/.5/.75。源 24fps→60fps 需要按区间交替 t=.4/.8 与 .2/.6，不能把这些
时刻随意改成 .25/.5/.75 后仍声称运动时间正确。

所以第一版 Apple 后端只开放 2×（24→48、23.976→47.952、30→60）；任意比例
暂留 RIFE。注意 23.976→48 也不是严格 2×。后续另核实 Apple 高质量 FRC 或
合法的多阶段时相方案，计入额外耗时和画质代价；不能用重复帧冒充插值。

若同时启用 Apple 空间增强，该配置当前只支持 2× 空间和单个 t=.5 中间帧，
不是任意目标尺寸和任意帧率的通用组合。另行查询该模式的尺寸上限；不要把
scale=1 的 1080p 支持直接推广到 1080p→4K 插帧+超分。

系统 API 及其模型是 Apple 专有系统组件。本项目可以保留开放源码的适配层和
RIFE 备选，但不能宣称 Apple 模型本身开源、跨平台、或可随项目重分发。
本机格式证据限 8-bit NV12，不推断 HDR/10-bit 支持。

## 产品路线比较

| 选择 | 收益 | 要付出的工程成本 | 判断 |
|---|---|---|---|
| 原版 IINA JS 插件 | 安装方便，保留现有更新和界面 | 已核对 API 没有解码帧注入；也没有可动态加载本滤镜的 native vf ABI | 当前不通，继续投入 UI 开关没有意义 |
| 向 IINA/mpv 上游贡献 | 最终维护成本可能最低，用户无需另装播放器 | 接口设计、可移植性、审核、测试和发布时间不可控 | 可准备提案，不作为近期交付依赖 |
| 独立 IINA 分支 + 自建 libmpv | 复用成熟播放体验，适合完整日用播放器 | 按 IINA deps 构建完整库；不能直接复用我们裁剪过的 mpv；独立 bundle ID、签名、更新、资源、偏好域；长期跟随上游 | 中期备选，比重写所有完整播放器功能合理 |
| 完善当前 libmpv 宿主 | 已有真实帧入口；后端可自由替换；改动范围清楚 | 补文件打开、拖放、快捷键、字幕/音轨、播放列表、记忆和打包；仍需交互质量工作 | **下一轮采用，但限定为精简定制播放器** |

IINA 官方构建文档明确支持自行构建 mpv；因此“原版插件不支持”不等于
“IINA 代码无法支持”。独立分支是可行工程路线，绝不替换现有 IINA.app 内 dylib，
也不能沿用原版自动更新覆盖自己的后端。上游文档要求 UI 变更先做设计提案；
本轮只读取文档，没有向维护者发消息或创建 issue。

IINA 是 GPLv3；当前适配器 GPLv3，RifeMetal Apache-2.0，RIFE 权重 MIT。
未发现必须改成闭源才能继续的依赖；发布分支时仍需保留对应源码/声明。
Apple 系统后端作为可选系统能力，和完全开放的 RIFE 路径明确区分。

## 下一轮具体范围与完成标准

按依赖先后实施，而不是同时重写 UI 和解码渲染：

1. **后端抽象**：RIFE / Apple LLFI 共用 PTS、scene cut、generation、队列、
   错误回退和统计；显示实际后端名，不把 Apple 输出叫作 RIFE。请求/实际模式分开。
2. **先接通 Apple 24→48 SDR**：NV12 pool、尺寸/格式探测、异步 startSession、
   bounded output、seek flush、帧间距正确；不支持时回到 RIFE fast 或原帧率并提示。
   第一版可保留必要的可测复制，不以零复制为先决条件。
3. **恢复 VideoToolbox 硬件解码路径**：核对 libmpv 的 VideoToolbox 帧对象与
   CVPixelBuffer 生命周期、attachments、IOSurface 与同步，争取减少 BGRA 往返；
   独立测转换和渲染成本，不能假定所有像素格式都能直接共享。
4. **实用界面最低集**：文件拖放/最近文件、空格和方向键、全屏、音量、字幕及
   音轨选择、播放进度记忆、配置持久化、窗口关闭及时释放、模型冷启动提示。
   保留 English 默认，状态显示 Off / Warming / Active / Degraded / Unsupported。
5. **小范围验收**：用户同一片段下 RIFE fast 与 Apple 同分辨率同帧率 A/B；
   人脸、快速摇镜、遮挡、硬切各看片段。采集每区间完整耗时、掉帧增量、A/V，
   再做 1080p48。只有完整管线和画质同时合格，Apple 才成为 Auto 首选。

切镜应通过原帧，不跨镜合成；所有新后端沿用有界内存和过载迟滞。macOS 版本、
颜色或帧率不支持时应明确禁用，不自动改变时间轴或把 HDR 当 SDR。

**停止扩张条件**：若需求转为完整复刻 IINA（高级字幕、完整播放列表/PiP/在线
媒体/丰富偏好），停止在当前小宿主逐项重写，转向独立 IINA 分支；增强后端和
上述验收工具可复用。若 Apple 画质不能接受，则保留 RIFE fast 为默认，再投入 lite。

## 核对的主要来源

- [Apple：ML 视频处理与实时低延迟路线](https://developer.apple.com/videos/play/wwdc2025/300/)
- [Low-latency 配置与限制](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration)，同时逐项读取本机 `VTFrameProcessor_LowLatencyFrameInterpolation.h`、`VTFrameProcessor.h`、`VTFrameProcessor_FrameRateConversion.h`。
- [MetalFX frame interpolator](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolator)，并读取 SDK `MTLFXFrameInterpolator.h` 的 depth/motion 接口。
- [RifeMetal](https://github.com/cinemore/rife-metal)，实际核对 vendored `RifeConfiguration.swift`、`RifeStream.swift`、`RifeInterpolator.swift`、`IFNetGraph.swift`、`WeightStore.swift` 与 Metal kernels。
- [Practical-RIFE 模型与 lite 说明](https://github.com/hzwer/Practical-RIFE#trained-model)，当前只作候选，无新增权重分发。
- [ncnn C++ API](https://github.com/nihui/rife-ncnn-vulkan/blob/master/src/rife.h)、[构建](https://github.com/nihui/rife-ncnn-vulkan/blob/master/src/CMakeLists.txt)、[许可证](https://github.com/nihui/rife-ncnn-vulkan/blob/master/LICENSE)。
- [IINA 构建](https://github.com/iina/iina#building)、[贡献要求](https://github.com/iina/iina/blob/develop/CONTRIBUTING.md)，实际读取本地 revision `2afb9f20f6b4a049f9db066e55b4b7a457fa4e81` 的构建说明与 JavascriptAPIMpv.swift。
