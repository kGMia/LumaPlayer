# Luma Player

独立的 macOS 原生视频增强播放器，应用名称 **Luma Player**，Bundle ID 为 `com.august.lumaplayer`。打开 `LumaPlayer.xcodeproj`，选择 **Luma Player** scheme；使用 `bash scripts/build-player-modern.sh Debug` 构建打包，交付路径为 `build/Luma Player.app`。

开发入口：`python3 scripts/dev.py build player` 构建签名包；`python3 scripts/dev.py check transport frame-step` 运行指定的轻量检查；`python3 scripts/dev.py package --source-app "…/Luma Player.app"` 打包已有签名产物。`--dry-run` 放在子命令前可只查看执行命令；原有脚本继续可用。


改名后的首次启动会导入旧播放器的偏好设置和播放记录，不覆盖已存在的新设置。OneDrive 需重新登录，并在 Microsoft 应用注册中使用 `msauth.com.august.lumaplayer://auth`；WebDAV 服务器列表保留，旧钥匙串授权不兼容时需重新保存凭据。历史插件、底层 ABI 名称和第三方署名仍保留，相关内容不表示播放器与 IINA 存在隶属关系。

以下为历史开发记录（旧应用名称/交付路径仅对应当时版本）。

2026-10-26：改用 mpv 官方唤醒回调及时处理加载钩子与切换事件，减少等待 250 ms 遥测轮询的机会；普通遥测仍为 4 Hz。性能记录新增最近 8 次切换的加载、播放重启、初次增强配置/预热暂停和新帧提交观察值。基础检查与无窗口加载检查通过；显示器实际呈现耗时不作推测。见 [切换记录说明](docs/media-switch-20261025.md)。

2026-10-25：优化媒体切换：卸载间隙不再提交临时空增强方案；FSRCNNX 共享同设备的 Metal 着色器管线，并保留小规模输出池供 Seek 后复用。主窗口/迷你播放器加入原生加载过渡，切换期间不返回启动引导；短加载延迟显示指示，支持减少动态效果。状态检查、两个小尺寸模型/缓冲生命周期检查及应用构建签名通过，实际切换体验待用户验证。新版为 `build/IIVE-Player.app`。

2026-10-25：原生增强滤镜新增按媒体时间控制的自动预取窗口，适配 VFR/倍速并在 Seek 后重置。基础构建、短滤镜链检查及应用打包通过；实际交互由用户验证。见 [简要说明](docs/queue-lookahead-20261025.md)。

2026-10-25：新增独立 FSRCNNX Core ML / NV12 原型，128 与 720p 基础输出对比通过。计算计划可分配到 Neural Engine，但单独运行暂未优于 MPSGraph；保持播放器默认管线。见 [结果与运行方法](docs/fsrcnnx-coreml-20261025.md)。

组合跟进：新增 RIFE fast + FSRCNNX 的有界流水线对比工具。720p 四帧对短测中 Core ML 组合仍较慢，暂不接入播放器；后续优先优化现有 Metal 管线的展示期限与排队延迟。

2026-10-25：新增独立 SPAN x2 Core ML 原型与 FSRCNNX 对比工具。FP16 计算计划可分配至 Neural Engine，但压力输入存在数值偏差，暂不接入播放器。见 [简要结果与运行方法](docs/span-prototype-20261025.md)。

SPAN 跟进：已固定受支持的转换环境，加入逐层诊断、混合精度和多类输入检查。工具链更换及注意力 FP32 均未解决压力输入偏差，模型继续保持诊断用途；默认导出会拒绝发布失败的模型。

2026-10-24：修正 RIFE 阶段 mask 更新语义；加入官方 4.25 Lite 的原生实验入口、校验与真实短片对比工具。短片检查尚未显示 Lite 的稳定耗时优势，播放器仍使用 4.26。见 [简要说明及结果](docs/rife-lite-20261024.md)。

2026-10-24：RIFE/FSRCNNX 新增 GPU 区间与 CPU 等待计时；去隔行接入 VideoToolbox/Metal 路径并修正 On/Auto 切换。仅基础验证，见 [简要记录](docs/metal-pipeline-20261024.md)。

## 新：独立原生播放器 0.4（macOS 27）

2026-10-23 Swift 6 迁移：主播放器 Debug / Release 配置采用 `SWIFT_VERSION = 6.0`，实际使用 Xcode 自带的 Swift 6.4 编译器；自有 RIFEBackend / FSRCNNXMetal 包采用 Swift 6 语言模式，第三方包保留各自设置。预览生成器的请求与取消串行化，原生远程探测读取加锁，窗口动画完成回调显式回到 MainActor。基础构建与定向检查记录见 `benchmarks/results/swift6-*20261023.log`；未进行 GUI 或完整性能回归。可运行 `bash scripts/check-asset-image.sh` 检查真实 AVFoundation 预览读取。

2026-10-23 远程目录多选：使用 ⌘/Shift 点击选择，工具栏或右键菜单的 Add to Queue 按当前可见排序追加所选媒体；跳过文件夹、不支持格式及同源已排队项目，不扩展到整个目录、不预取下载链接。现有播放项目保持不变；空闲播放器沿用原有追加后播放行为。“接下来播放”尚未实现。基础检查：`bash scripts/check-remote-batch.sh`（纯逻辑与无界面 libmpv 队列检查）。

2026-10-23 远程目录控件：WebDAV / OneDrive 共用原生 SwiftUI 列表，支持当前目录多关键词搜索、文件名/大小排序（文件夹置顶）。单击选中，双击或 Return 打开；方向键选择，⌘↑ 返回上级，⌘↓ 打开，⌘F 搜索，⌘R 刷新。OneDrive 搜索与排序仅覆盖已加载分页，界面明确显示范围；搜索不会缩减播放时的同目录队列。基础逻辑与编译检查通过，键盘及实际 UI 效果由用户验证。

2026-10-23 远程浏览：WebDAV 已保存连接与 OneDrive 会在本次应用会话恢复上次目录；目录缓存按凭据/账号隔离，每种服务最多 12 个目录、10,000 条记录，45 秒内复用。刷新保留现有列表，OneDrive 刷新当前目录及已加载分页；返回目录尝试定位到上次选中项。Settings → Network 可清空浏览缓存，退出应用自动清除；实际滚动与选中体验待用户验证。

2026-10-23 网络错误提示统一区分 DNS、连接、鉴权、TLS、限流与读取中断，不展示带令牌的地址。目录/API 请求采用 20 秒空闲、30 秒单请求总超时；媒体预检重定向链共用 25 秒预算。OneDrive 仅自动等待不超过 5 秒的 Retry-After（支持 HTTP 日期），更长等待交由用户重试。基础策略检查通过，实际网盘与界面由用户验证。

2026-10-21 独立打包：`build/IIVE-Player.app` 已内置 arm64 动态库、RIFE/FSRCNNX 模型资源及 FFmpeg 预览工具；旧 PersonalTeam 路径指向同一交付包。搬移副本后的无界面加载/解码检查通过，模型推理及实际界面仍由用户验证。应用使用现有个人开发签名，尚未公证或作为公开发行版发布。

2026-10-21 交付与网络恢复更新：统一构建入口与 `build/IIVE-Player.app` 交付路径，新增有界重连和进度恢复、播放优先的元数据调度，以及缓冲/重连后的性能保护宽限期。仅做基础验证，限制与检查记录见 [本轮说明](docs/delivery-network-recovery-20261021.md)。

2026-10-21 新增 **OneDrive · Preview**：Settings → Network 配置 Microsoft Client ID 后登录、浏览与播放，复用现有远程队列和增强管线。账号实测待用户注册后完成，见 [注册与使用说明](docs/onedrive-20261021.md)。

2026-10-20 WebDAV 队列补齐原始文件名、大小、按需时长/缩略图与同目录自动加入；播放时刷新临时下载链接。用法、基本验证及 OneDrive 评估见 [远程队列说明](docs/webdav-queue-onedrive-20261020.md)。

2026-10-19 新增网络播放：**File → Open Network…（⌘N）** 支持媒体直链与 WebDAV 文件夹浏览、Basic 登录和混合播放队列。短片实测 HTTP 认证输入可同时运行 RIFE + FSRCNNX；公网实时性能、HLS/RTSP 与实际 UI 仍待验证。登录型播放支持安全的网盘媒体重定向，暂不支持认证播放列表。新增 **Settings → Network** 与钥匙串服务器保存，详见 [WebDAV 播放修复与服务器保存](docs/webdav-servers-20261019.md)。使用和限制见 [网络串流说明](docs/network-streaming-20261019.md)。

2026-10-17 性能基线：新增解码 API、增强任务、排队、渲染/交换耗时记录及预取 1/2/4 对比工具。M5 同短片九次无窗口对比通过；没有足够证据修改默认自动策略。使用、原始结果与测量边界见 [分阶段性能基线](docs/performance-baseline-20261017.md)。

**当前状态（2026-10-17）：原生 EDR 输出暂时搁置。** 用户实测旧帧停滞/卡死后，已移除播放器中的 EDR 挂载路径并清理旧开启偏好；HDR 文件继续通过现有 SDR 色调映射播放。请使用本轮 `build/PersonalTeam/IIVE Player.app`，先完全退出旧进程。详见 [EDR 停滞处理](docs/edr-suspended-20261017.md)。下方 EDR 开关与挂载记录为历史开发进展。

2026-10-17 跟进验收：补齐 EDR 色彩切换的渲染门控与确认顺序，保留实验开关；修复封面共享任务取消、解码中变更和相邻封面失效，预取增加最低样本要求。基础构建与定向检查通过，HDR 实际画面仍待用户确认。见 [三项跟进验收](docs/followup-acceptance-20261017.md)。

2026-10-17 简要验收：修正动态预取的固定 24fps 预算，封面缓存增加像素内存预算；新 EDR 挂载存在呈现推进和色彩回退问题，暂时关闭应用入口并保留原型。基础构建与定向检查通过，见 [改动验收与下一步](docs/agent-changes-review-20261017.md)。

本轮开发重点已转为 **IIVE Player**：SwiftUI 原生窗口，同时集成 FSRCNNX 8/16、RIFE Metal 和 Apple VideoToolbox 低延迟超分/2× 插帧。打开根目录 `LumaPlayer.xcodeproj`，选择 **Luma Player → My Mac**，在 Xcode 27 中 Run。

2026-10-17 音频支持收尾：可打开音频文件，普通窗口居中显示封面与泛光，迷你窗口封面填满；加入音频元数据与系统 Now Playing 封面。基础构建、音频解码和封面检查通过，实际界面与听音由用户验证。EDR 离屏共享表面检查已通过，尚未接入播放器显示。使用范围、记录与下一步见 [音频与 EDR 进展](docs/audio-artwork-edr-20261017.md)。

```sh
scripts/build-player-modern.sh
open 'build/Luma Player.app'
```

构建说明、处理限制、Neural Accelerator 优化证据和后续路线见 [播放器 0.4 文档](docs/player-0.4.md)。本机 Apple 超分支持 720p→1080p，不支持 1080p→4K；该场景保留 FSRCNNX。构建仍需要本机工作区/Homebrew；统一交付脚本生成的应用运行时已内置这些非系统依赖。直接从 Xcode Run 的产物仍用于开发，搬移时请使用 `build/Luma Player.app`。IINA 插件与 IINA.app 保持独立。

2026-10-16 拖动更新：进度条拖动时由 libmpv 实际更新主画面，移动阶段快速关键帧定位，松手后精确定位并恢复原播放状态；暂停超分对比刷新改为合并请求。仅完成基础验证，见 [实时拖动与对比刷新](docs/live-scrubbing-20261016.md)。

2026-10-16 后续优化：暂停对比分隔线刷新增加防抖，性能面板加入最近 120 个有效 SR/FI 任务的 P50/P95 与样本数。统计不代表显示延迟；见 [交互调度与耗时说明](docs/interaction-latency-20261016.md)。

2026-10-16 管线收尾：RIFE 不可变 timestep 缓存、批次末尾等待、场景签名优化与有界级联预取已落盘。新增独立编译的 IOSurface→Metal/EDR 桥接原型，尚未接入播放器；三项定向检查及半秒无窗口级联检查通过，不代表性能增益已测定。见 [阶段 5/6 收尾](docs/phase5-6-closeout-20261016.md)。

2026-10-15 预览修正：气泡改用明确的 SwiftUI Layout 上方定位；SDR MKV 优先使用 FFmpeg，并校验帧时间、排除封面流，限制旧预览复用。三章节合成 MKV 的生产解码器检查通过；实际 UI 由用户确认。见 [预览位置与 MKV 修复](docs/preview-position-mkv-fix-20261015.md)。

2026-10-15 章节预览更新：修复预览气泡受轨道高度约束的问题，新增可选 FFmpeg SDR 缩略图回退、自适应播放条与章节/标记导航；合并排队中的绝对定位，并让过时原生推理在阶段边界尽早退出。仅完成基础构建与状态检查，实际效果待用户确认。见 [章节预览与管线更新](docs/chapter-preview-pipeline-20261015.md)。

2026-10-15 定位更新：修复松开进度条后的旧位置回弹，加入请求匹配、慢定位提示与失败恢复；固定时间标签宽度，支持总时长/剩余时间切换。仅完成基础构建和定位状态检查，见 [时间轴与 UI 更新](docs/timeline-seek-ui-20261015.md)。

2026-10-15 交互修复：修复多章节进度条整体偏移，统一缩放时的轨道与鼠标坐标，并移除流光。Live Text 改为直接显示识别全文，支持选择与复制，原画面可展开查看。关闭识别窗口会取消任务并丢弃迟到结果。

2026-10-15 画面工具更新：加入实验性 **Dolby Vision RPU → SDR GPU 映射**、可设置目录的一键截图、原生右键菜单、VisionKit Live Text、持久化时间标记与分段章节进度条。当前仍为 SDR 输出，实际 DV 色彩与交互待用户验证。见 [杜比视界与画面工具说明](docs/dolby-vision-frame-tools-20261015.md)。

2026-10-15 更新：修复进度条预览空白呈现，增加后台预热与移动时的图片复用；新增 **Apple 本地实时字幕**、顶部第二字幕和分别加载字幕的入口。RIFE 场景采样与 FSRCNNX 重复表面推理继续优化。仅完成基础构建及无窗口音频旁路短测，语音模型与实际画面由用户验证。使用与限制见 [实时字幕与预览更新](docs/live-captions-preview-20261015.md)。

2026-10-14 原生模型更新：**FSRCNNX Metal 8/16 已真实接入 MPSGraph，RIFE 已支持 Metal NV12 输入与直接输出**。界面选择 FSRCNNX Metal Fast + RIFE fast / 48fps 即可使用。构建和最小组合检查通过，细节与限制见 [原生模型交付记录](docs/native-models-20261014.md)。

2026-10-14 UI / M5 更新：加入 Liquid Glass 悬浮播放条、原生全屏与快捷设置、实时源视频/处理输出信息。原生插帧 → 超分现在共享 NV12 IOSurface，短测验证没有重复输入复制。详见 [本轮开发与基础验证](docs/m5-glass-20261014.md)。

新增原生 **Settings（⌘,）** 窗口、可开关的编码/码率信息、多文件播放队列、章节、循环、静音、逐帧及截图保存。操作与验证范围见 [播放器基础功能更新](docs/player-basics-20261014.md)。

新增 **置顶迷你播放器（⌥⌘P）**、胶囊切换侧边栏、全屏队列气泡和可选同目录自动队列；已使用 Personal Team 开发签名构建。AirPlay 按最新要求不加入。操作、优化判断和验证范围见 [窗口与队列更新](docs/player-window-update-20261014.md)。

最新播放设置：原生二级菜单、旋转与画面效果、ICC 色彩描述档、软解/自动硬解/复制硬解，以及进程 CPU/内存信息已加入。空队列标题与按钮固定在顶部；GPU 占用不可可靠取得时显示 N/A。最终版本仅进行构建和签名检查，实际效果由用户验收。见 [菜单与播放设置说明](docs/player-menu-picture-decoder-20261014.md)。

迷你模式退出修复：隐藏主窗口时不再误触发“最后窗口关闭后退出应用”。已复现根因并验证两次空媒体场景的迷你窗口往返，开发签名校验通过。详见 [修复记录](docs/mini-player-exit-fix-20261014.md)。

最新窗口与队列更新：迷你模式加入淡入淡出并**隐藏主窗口**；修复开启同目录自动队列开关后不立即扫描的问题，加入扫描状态、去重、三种排序、自定义拖动，以及简洁/封面详细视图。全屏切换延后中间尺寸的 GL 更新和增强重配。构建与签名检查通过，实际效果待用户验证。详见 [队列与窗口切换说明](docs/player-queue-transitions-20261014.md)。

最新交互更新：图标式 Liquid Glass 侧栏切换器、透明顶栏、中央迷你播放控件、⌘方向键逐帧和自定义增强阈值。详见 [设置与快捷键](docs/player-interaction-update-20261014.md)。

---

Apple Silicon 上的 IINA 视频增强插件。**当前版本 0.2.0 为可安装的预览版：提供可验证运行状态的超分功能；CPU minterpolate 已移除，RIFE 仍是独立原生原型，尚未接入原版 IINA。**

## 已实现

- IINA 原生 Sidebar 容器内的英文界面，明暗主题，配置持久化，每个播放窗口独立控制。
- FSRCNNX 8 / 16、RAVU Lite r3、CAS，以及 Off / Auto；GPU GLSL 管线中处理。
- 运行时检查 `vo-passes` 的最后一个 Shader 阶段。未实际执行则关闭并提示，不能仅设置参数就宣称开启。
- 保留其他 Shader；只撤销本插件拥有的路径和滤镜标签；插件停用后通过 5 秒心跳租约清理。
- 顶部状态灯与分项状态：Active / Verifying / Paused / Bypassed / Degraded / Unavailable / Error；无视频、关闭和失联分别提示。超过 5.5 秒无更新不再显示旧的运行成功状态。
- 显示实际 FSRCNNX 8 / 16 模型与输出区域；可在 Advanced 独立选择模型，或跟随预设。
- 移除卡顿的 minterpolate；旧配置迁移为 Off，保留旧滤镜清理逻辑。
- 持续掉帧或音画偏差触发逐级降级，有冷却时间；当前文件不自动升级，避免反复切换。
- Swift / Metal / MPSGraph RIFE v4.26 后端，fast / balanced / hq，按 PTS 生成帧，连续视频读写、场景切换保护和有界处理；另有真实 C ABI 动态库。
- 可独立编译的原生 mpv `iive-rife` 滤镜：已验证 24→48/60 的帧输出及 libmpv OpenGL 渲染。它不在原版 IINA 中动态加载，详见 [原生适配层](native/mpv-filter/README.md)。

## 安装与使用

建议 IINA **1.5.0**。2026-10-13 已在用户更新后的安装版本上复验；本项目不修改 IINA.app。

1. 在 IINA → Settings → Plugins → **Install Local Package…** 选择
   `dist/IINA-Video-Enhancer-0.2.0.iinaplgz`，启用插件。
2. 允许声明的 `file-system` 权限：IINA 对 Shader、滤镜和 Lua 加载接口要求该权限。
   插件只写自己的数据目录，不联网、不启动外部命令、不修改原片。
3. 打开视频，在 Plugins → IINA Video Enhancer → **Open Enhancement** 打开面板。
4. 打开 **Master Switch**。默认 SR 为 Auto，插帧默认关闭。
5. 必须把播放画面的实际像素尺寸放大：FSRCNNX 两轴均须超过源尺寸的 1.3 倍，RAVU 超过 √2 倍。
   等待状态从 `VERIFYING` 变为实际模式；否则查看原因。CAS 仅锐化，不属于神经超分。
6. 想尝试更大模型：Advanced → Super Resolution Model → FSRCNNX 16。保持自动性能管理开启；16 的容量更大，但不保证任何片源都更好，也不保证持续实时。
7. 可通过 Plugins → Show Enhancement Status 查看简短 OSD 状态。插帧控件目前禁用，避免开启无效或严重卡顿的效果。

Auto 预设：Performance 使用 CAS；Balanced 使用 FSRCNNX 8；Quality 使用 FSRCNNX 16。
模型选择只在 FSRCNNX 生效时适用；强度滑块只改变 CAS，神经权重固定。显式 RAVU/CAS 选择不受神经预设影响。
源帧率已达到目标时跳过插帧。HDR、宽色域或 mpv 报告的未知传递函数会被绕过并提示。

RIFE AI 在 Sidebar 中禁用：原版 IINA 没有可用的解码帧注入接口；调用 CLI
不会使其自动显示实时 AI 中间帧。使用独立工具见下文。

## 实时 RIFE 独立播放器（原生迭代 0.3）

本轮新增可见播放窗口、异步 RIFE、有界队列、暂停/跳转/倍速和过载回退。
当前机器可直接打开 `build/Luma Player.app`，或执行：

```sh
scripts/run-player.sh "/absolute/path/video.mp4" 48 fast
```

短测已验证 720p24→48/60 的真实 AI 帧、CoreAudio 和实时播放节奏。
这不是原版 IINA 内的功能，也尚非可移植发布包；完整长片稳定性未验证。
[运行与构建](native/Player/README.md) · [实际结果与限制](docs/realtime-rife-results.md)。

## 卸载

先关闭 Master Switch，再在 IINA 的插件设置中移除插件。如果直接停用插件，
租约清理通常在 5–6 秒内撤销效果；播放暂停或窗口变换导致未重绘时，等下次画面更新。
插件缓存位于 `~/Library/Application Support/com.colliderli.iina/plugins/.data/org.iina-community.video-enhancer/`。
卸载不修改 mpv 配置文件；其他用户 Shader 不会被清空。

开发链接如仍存在，可运行：

```sh
/Applications/IINA.app/Contents/MacOS/iina-plugin unlink "$PWD/plugin"
```

再安装打包版，避免同一 identifier 的开发版和安装版重复。

## 构建

```sh
npm ci --ignore-scripts
npm run pack
scripts/build-native.sh
python3 scripts/package-native.py
```

Node.js 20+；原生后端需 Apple Silicon、macOS 13+、完整 Xcode、Metal Toolchain。
脚本只为当前命令选择 Xcode，不改全局 xcode-select。若缺组件：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

原生使用：

```sh
dist/native-arm64/iive-rife bench 1280 720 fast 20
dist/native-arm64/iive-rife process input.mov output.mov 48 fast
dist/native-arm64/iive-rife process input.mov output60.mov 60 balanced --no-fallback
```

保留二进制旁的两个资源 Bundle。视频原型只接收明确标注 SDR BT.709 的未旋转视频，
输出新的 H.264 MOV 和第一条原音轨。没有字幕、章节、多音轨复制或 HDR 支持；输出不是无损。
详见 [原生后端文档](native/RIFEBackend/README.md)。

## 验证与状态

按本次要求只执行关键冒烟与少量逻辑测试，未进行完整测试矩阵或长片稳定性测试。

- TypeScript 类型检查、插件打包通过；13 个 JS 逻辑测试通过；原生时间戳的 3 个 Swift 测试为先前已通过结果，本轮未重复原生全套测试。
- 基础款 M5 上，IINA 1.5.0 的 720p/24fps → 1440p 实际画面执行了 FSRCNNX 8 的全部 14 个 GPU pass；本轮切换到 FSRCNNX 16 也确认最终 GPU pass 执行，暂停状态与恢复默认模型均正确。
- 历史 minterpolate 测试出现严重延迟，用户实测也很卡顿；0.2.0 已移除其启用代码。
- 独立 RIFE fast 原型将 1 秒 720p/24fps 生成 48 帧和 60 帧；FFprobe 核对帧数、帧率和音视频时长。
- 新增原生 mpv 滤镜实际输出 48/60 帧（23/46 帧为 AI 生成），PTS 间隔正确；OpenGL 宿主完成 45 次非黑画面读取，短测掉帧 3。
- 旧版本 hwdec 列表的恢复逻辑仅保留用于兼容清理；0.2.0 不再为增强功能主动关闭硬件解码。
- RAVU、CAS、FSRCNNX 16 已打包且有运行时执行检查，未分别做实机画质验收。
- 1080p→4K、RIFE balanced/hq、长片、多个窗口并发、所有拖动/倍速组合均未完整实测。
- **原版 IINA 中的实时 RIFE，以及 RIFE+超分组合，未完成。**

具体数字、测试条件及不足见 [benchmarks](docs/benchmarks.md)，边界证据见
[feasibility](docs/feasibility.md)，设计见 [architecture](docs/architecture.md)。

```sh
npm test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path native/RIFEBackend -c release --disable-sandbox
python3 benchmarks/run.py --smoke
# 完整矩阵是可选操作，本次未运行：
python3 benchmarks/run.py --full --iterations 30
```

历史播放器 Shader/运动补偿诊断矩阵使用 `benchmarks/player.py --help`，必须使用专门测试的
IINA IPC 实例并关闭本插件，不能指向日常播放窗口。播放器显示 FPS、GPU 利用率等
无法可靠测量的项目保留 N/A。

## 模型评估与实时 RIFE 计划

[超分模型评估](docs/super-resolution-evaluation.md) 对比 FSRCNNX 16、Real-ESRGAN 与 SwinIR，列出源码证据、许可及实际接入成本；没有把未移植的模型加入可用列表。

[实时 RIFE 计划](docs/realtime-rife-plan.md) 明确异步队列、PTS、资源共享、降级、独立宿主和正式 IINA 集成门槛。下一轮首要工作是可见原生播放器与端到端性能指标。

## 下一步

1. 在已编译运行的原生 mpv 滤镜基础上完善异步推理和完整播放控制验收；如开发独立宿主，应使用自己的签名和更新通道，不替换用户安装的 IINA。
2. 先消除原生模型初始化延迟，并将上游 padding/cropping 改为 GPU 路径，再测持续 1080p。
3. 增加真人素材的视觉质量、场景切换、HDR 和长片热稳定性验收。

GPL-3.0-or-later；第三方 Shader、代码、模型许可与固定版本见 [THIRD-PARTY.md](THIRD-PARTY.md)。

后续方向与 Apple 原生插帧的小规模本机探测：[Mac 插帧/播放器路线评估](docs/mac-interpolation-direction.md)。
