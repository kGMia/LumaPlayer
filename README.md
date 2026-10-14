# IINA Video Enhancer

## 新：独立原生播放器 0.4（macOS 27）

本轮开发重点已转为 **IIVE Player**：SwiftUI 原生窗口，同时集成 FSRCNNX 8/16、RIFE Metal 和 Apple VideoToolbox 低延迟超分/2× 插帧。打开根目录 `IIVEPlayer.xcodeproj`，选择 **IIVE Player → My Mac**，在 Xcode 27 中 Run。

```sh
scripts/build-player-modern.sh
open 'build/Xcode/Build/Products/Debug/IIVE Player.app'
```

构建说明、处理限制、Neural Accelerator 优化证据和后续路线见 [播放器 0.4 文档](docs/player-0.4.md)。本机 Apple 超分支持 720p→1080p，不支持 1080p→4K；该场景保留 FSRCNNX。当前是依赖工作区/Homebrew 的开发应用，并非可移走发布的安装包。IINA 插件与 IINA.app 保持独立。

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
当前机器可直接打开 `build/IIVE-Player.app`，或执行：

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
