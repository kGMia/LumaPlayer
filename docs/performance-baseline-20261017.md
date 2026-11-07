# 第一步：可比较的分阶段性能基线

## 已加入的记录

普通播放器的性能信息增加渲染调用/交换调用 P95、FI/SR 队列 P95 和进程峰值采样 footprint。窗口覆盖最近 120 项，seek/reset 清除滤镜窗口；渲染窗口为当前 renderer 最近样本。缺失数据显示 N/A。

原生追踪使用 `IIVE_PROFILE=1` 显式开启，输出逐事件 JSON 行 `IIVE_PROFILE {...}`。日常播放不输出这些逐帧日志。新增记录含义：

- `decode/send`、`decode/receive`：FFmpeg API 调用墙钟耗时。包含调用中的等待，不是异步硬件解码器或 FFmpeg 工作线程的独立计算耗时。成功、EAGAIN、EOF 分开保留，报告仅汇总成功调用。
- `dispatch_ms`：单槽输入提交至 worker 接手的等待。
- `input_ms`、`model_call_ms`、`output_ms`：输入处理、原生模型 API 调用、输出包装/转换。模型 API 包含 CPU 调度和 GPU 等待，不能称为纯 GPU kernel 时间。
- `processing_ms`：完整 worker 任务；RIFE 一次任务可能输出多帧，FSRCNNX 通常每输出帧一次。不同阶段可重叠，不能直接相加推断端到端延迟。
- `backpressure_ms`：任务完成至发布输出的等待/开销，含 ready 队列满时的背压。
- `ready_ms`：输出进入 ready 队列至下游取走的驻留时间。
- `render/draw_ms`：libmpv render 调用墙钟耗时；`swap_ms`：OpenGL flushBuffer 调用耗时。二者不是 GPU 完成时间或屏幕扫描输出延迟。
- 内存区分 RSS 与 footprint。UI footprint 峰值来自约每秒采样，可能漏掉短峰；无窗口工具另用 macOS `/usr/bin/time -l` 记录运行期峰值 RSS/footprint。

实际屏幕显示 FPS、GPU 利用率和输入到屏幕延迟没有可靠测量，明确保留 null/N/A。已有 render-callback FPS 不改名为实际显示 FPS。

## 可重复的预取对比工具

新增 `benchmarks/pipeline_profile.py`：创建自己的无窗口 mpv 进程与临时 IPC；固定同一文件、RIFE fast + FSRCNNX 8；每次新建进程，预取 1/2/4 各重复三次并轮换顺序。默认排除前 1 秒源时间的模型/队列/管线统计，但保留完整原始日志、解码调用和启动至 EOF 时间。

```sh
python3 benchmarks/pipeline_profile.py \
  --input build/checks/profile-720p24.mp4 \
  --output benchmarks/results/my-prefetch-comparison \
  --repetitions 3 --fps 48 --tier fast
```

输出目录必须是新目录，不覆盖之前的结果。记录输入/可执行文件/原生 dylib 的 SHA-256、系统、芯片、媒体参数、执行命令、逐事件日志、IPC 快照和报告。权重文件不另做哈希；需要换权重对比时须额外记录版本。每次进程是新的，但不强行清空系统或驱动模型缓存。

`prefetch=1/2/4` 是诊断用固定的启动下一任务阈值；不是整个队列只能存 1/2/4 张表面。两滤镜默认策略保持原样，参数未传时 RIFE 继续自动迟滞，SR 继续原有有界预取。固定档绕过 RIFE 自适应分辨率/耗时限制，只用于受控对比。

运行要求当前自定义 mpv/后端已构建、可访问本机 Metal、Python 3.11+ 与本地 FFprobe。工具使用 `vo=null/ao=null/untimed`；不能据此证明有画面输出、音画同步或持续实时播放。无增强、降级、缺少模型样本、输出帧数不一致、PTS 倒序、异常退出等均不算有效比较。

## 本机实际结果

Apple M5；软件解码；同一 4 秒 1280×720/24fps 真人片段，48fps RIFE fast → FSRCNNX 8 输出 2560×1440 像素。源素材为仓库已有 Tears of Steel，截取 60–64 秒。缩放保留源显示比例，因此输出 SAR 不为 1；本轮只比较计算，不验收画质。

生成命令（新文件，不改原媒体）：

```sh
ffmpeg -ss 60 -i benchmarks/fixtures/tears_of_steel_1080p.mov \
  -t 4 -map 0:v:0 -an -vf scale=1280:720 -r 24 -c:v libx264 \
  -preset fast -crf 18 -pix_fmt yuv420p -color_primaries bt709 \
  -color_trc bt709 -colorspace bt709 -color_range tv \
  -n build/checks/profile-720p24.mp4
```

正式九次运行均有效：每次 192 个输出，其中 RIFE 合成 95 帧，PTS 严格递增，两级帧数一致，无降级。null 输出报告的显示/解码丢帧计数均为 0；这不能替代实际显示掉帧测试。

- 深度 1：稳定段管线发出帧吞吐中位数 **156.48 fps**，范围 155.04–157.02；三次最大 footprint **371.94 MiB**。
- 深度 2：中位数 **157.71 fps**，范围 152.74–158.75；最大 footprint **375.59 MiB**。
- 深度 4：中位数 **158.01 fps**，范围 155.15–158.61；最大 footprint **373.86 MiB**。

以下是各次 P95 的中位数，**不是合并样本后的总 P95**：深度 1/2/4 的 RIFE 任务 P95 分别为 8.492/8.406/8.325ms；SR 为 7.597/7.415/7.499ms。RIFE ready 驻留 P95 均约 6.18ms，SR 约 0.05ms；调度等待约 0.008–0.010ms，完成到发布约 0.001ms。

首次试跑记录到模型初始化约 22.19 秒，正式比较的驱动/模型缓存已被试跑预热；正式各次启动至 EOF 为 1.55–2.03 秒。这是区分冷启动与稳定段的实际理由，不能把正式结果称为冷缓存启动速度。逐事件日志本身会增加开销，所有比较使用相同记录方式。

证据：`benchmarks/results/prefetch-comparison-20261017/report.json` 及同目录九份 `.log`、九份 `.jsonl`；首次初始化证据在 `prefetch-pilot-metal-20261017/`。初次沙箱尝试被 sysctl 权限拒绝，尚未播放，不计入结果。

**默认策略结论：保持自动策略，不改成固定 4。** 深度 4 相对 1 的中位数差异约 0.98%，落在当前短测波动范围，内存也没有稳定优势。这个 720p 无窗口样本未触及明显背压，不能用于推断 1080p/4K、硬解或长片最优深度。

## 用户侧播放器记录

普通信息面板已经可以查看近期队列与渲染统计。若需要完整可对比的真实窗口记录，可自行完全退出旧进程后运行下面命令（本轮没有代用户启动 GUI）：

```sh
IIVE_PROFILE=1 IIVE_PROFILE_PREFETCH=1 \
  'build/PersonalTeam/IIVE Player.app/Contents/MacOS/IIVE Player' \
  --input '/absolute/path/to/video.mp4' --fi rife --sr fsrcnnx_metal8 \
  --tier fast --fps 48 --metrics '/tmp/iive-profile-depth1.jsonl' \
  > '/tmp/iive-profile-depth1.log' 2>&1
python3 benchmarks/pipeline_profile.py --summarize-player /tmp/iive-profile-depth1.jsonl
```

`--metrics` 文件必须不存在；每档用不同输出文件。环境变量的固定阈值仅在 `IIVE_PROFILE=1` 时生效，不写入用户预设。对比时保持同片段、解码器、窗口大小、显示器、增强开关和电源状态一致。汇总排除暂停/seek/warm-up 快照，不把多个窗口 P95 合并成总 P95。

## 基础验证与下一步

Xcode 构建通过；报告工具的百分位、warm-up、PTS 顺序和原生日志解析三项测试通过。未进行完整测试或 GUI 验收。

最新构建已同步到 `build/PersonalTeam/IIVE Player.app`，`codesign --verify --strict` 校验通过。构建记录已归档为 `benchmarks/results/performance-baseline-build-20261017.log` 和 `performance-baseline-backends-20261017.log`。

接下来先补一个用户真实窗口记录，与本次无窗口数据区分；再针对 1080p、VideoToolbox Copy 和长片比较队列与内存。如果主要耗时仍在模型调用，优先调整模型/分辨率预算；只有 ready/backpressure 明显偏高时才继续改预取。


## 应用内一键性能记录与隐私脱敏（2026-10-17 跟进）

为方便在正常窗口播放下采集同一 1080p 片段的诊断数据，已补齐原生 UI 记录与导出入口，并加固生命周期与路径脱敏：

- **原生启停与导出入口**：
  - 菜单栏：`View` → `Start / Stop Performance Recording`（快捷键 `⌥⌘R`）与 `Export Performance Recording…`。
  - 侧边栏与信息面板：`EnhancementInspector` 的 `Live Performance` 分区与 `VideoInformationRows` 均提供 `Record Metrics / Stop Recording`、`Export…`（`NSSavePanel` 导出 `.jsonl`）和 `Reveal / Show in Finder`。
  - 默认以 4 Hz 采样写入临时诊断目录（`iive-window-profile-<timestamp>-<id>.jsonl`），日常播放与面板录制均不开启 `IIVE_PROFILE=1` 逐事件高频日志；同时保留命令行 `--metrics <path>` 兼容。
- **生命周期与窗口重置**：
  - `MPVSession` 在运行期开始新记录、停止记录、多次复录及 `shutdown` 退出时均在串行客户端队列内执行 `synchronizeFile` 与 `closeFile`。
  - `VideoView` 新增 `-resetRenderTiming`，在 `MPV_EVENT_START_FILE` 切换媒体及每次开启新性能记录时清零 `_drawLatency` / `_swapLatency` 采样窗口，避免旧片段样本污染新记录。
- **元数据路径脱敏**：
  - 写入 `.jsonl` 的记录通过 `-sanitizedMetricsRecordFromSnapshot:` 过滤，剔除完整 `path`、`playlist`、`media-title`、`metadata`、`chapter-list` 与原始 `track-list`，仅保留不可逆哈希标识 `media-id`（`media-<fnv1a64>`）用于识别切片，并对滤镜参数中含 `/` 的路径做 `<redacted-path>` 脱敏。
- **汇总工具增强（`--summarize-player`）**：
  - `benchmarks/pipeline_profile.py --summarize-player <file.jsonl>` 升级至 `schema: 2`，自动排除 `paused`、`seeking` 与 `enhancement-warming` 预热样本，汇总输出 `decoder`（请求/实际解码器与编码格式）、`resolution`（源、滤镜输出、渲染视口）、`enhancement`（激活滤镜、着色器 pass、是否触发降级）、`queues`（各阶段 `state`、`input_surface`、`prefetch_mode/limit`、`pair_budget_ms`、`ready_peak`、`max_queued_sampled`、处理与队列 P95）、`estimated_vf_fps`、`render_callback_fps`、`avsync_ms`、`frame_drop_delta`、`decoder_drop_delta` 及 CPU/内存分布；物理显示帧率 `display_fps` 仍明确保留 `null`。


## 真实窗口 480×854 实测分析与 1080p 预算保护落地（2026-10-17）

- **真实窗口 480×854（30fps → 60fps，RIFE fast + FSRCNNX 8）实测结论**：
  - 109 个稳定播放采样下，`estimated_vf_fps` 稳定在 `60.000 fps`，`render_callback_fps` 中位数 `60.002 fps`（物理显示帧率 `display_fps` 为 `null`/`N/A`），丢帧增量 `0`，`avsync_ms` P95 仅 `0.014 ms`。
  - 队列调度（`p95_dispatch_ms` 为 `0.008 / 0.016 ms`）与发布背压（`p95_backpressure_ms` 均为 `0.001 ms`）无瓶颈；OpenGL `draw_p95_ms = 8.853 ms`、`swap_p95_ms = 2.999 ms`。
  - 解码器处于 `videotoolbox-copy` 时，FFmpeg 输出主存 `PL_CHROMA_LEFT` 软件 `nv12`，使 `iive-rife` 退回 CPU `swscale-copy`（`copied_inputs = 1153`）；而 `iive-rife` 到下游 `iive-sr` 实现了 100% 零拷贝 `shared-iosurface`（`2297` 帧）及重复帧输出缓存复用（`reused_outputs = 552`，单次 `0.007 ms`）。
- **针对 1080p 降级（Degraded）的三项落地修复**：
  - **1080p+ 双重模型预算保护（`PlayerModel.swift`）**：改用源视频短边 `min(w, h)` 判定分辨率档位（兼容 `480×854`、`1080×1920` 等竖屏视频）；当开启自动保护（`automatic`）且 `RIFE` 激活时，对像素量达到 `1920×1080` 及以上的片源自动旁路 `2× MPSGraph FSRCNNX`（状态提示 `Bypassed · 1080p+ RIFE <fps>fps budget guard`），避免 60fps 下 `1080p → 4K` 超分与 1080p RIFE 争用同一块 GPU 超出 `16.67 ms` 帧周期。
  - **冷启动编译宽限期与降级前指标保留（`vf_iive_rife.c`、`vf_iive_apple.c`）**：将冷启动宽限期从 3 帧（60fps 下仅 `50 ms`）放宽至 RIFE 24 对 / SR 48 帧（约 `0.8–1.0 s`），容忍首次 MPSGraph 编译与 OpenGL 管线预热峰值（`~44 ms`），连续 8 次超预算才触发 `degraded`，并在触发后保留最后一次有效推理的 `input_ms / model_ms / output_ms / last_ms`。
  - **降级事件快照汇总（`benchmarks/pipeline_profile.py`）**：`--summarize-player` 新增 `degradation_events`，若播放中途发生降级，自动回溯保留降级前最后一次有效窗口的 P50/P95/Peak 与输入表面类型。
