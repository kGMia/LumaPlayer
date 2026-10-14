# 实时 RIFE 实施计划 — 2026-10-13

> 进度更新：原生迭代 0.3 已完成可见宿主、异步工作线程、有界队列、generation
> 跳转失效与初步过载回退；720p fast48/60 短测已通过。见
> [实际结果](realtime-rife-results.md)。以下分阶段表保留为计划，完整验收仍未完成。

## 目标与当前边界

目标顺序：基础款 M5，SDR 720p24→48，720p24→60，1080p24→48，再研究
1080p 插帧与超分组合。每个实时结论仅适用于实际测过的分辨率、模型和输出条件。
用户已报告 minterpolate 严重卡顿，与本机先前掉帧/音画延迟一致；0.2.0 已移除
插件中的启动路径与可选模式，旧设置自动迁移为 Off。它不再作为 RIFE 失败时的降级方案。

已有可复用实现：

- `native/RIFEBackend` 的 RifeMetal、时间戳调度、连续帧处理、C ABI 和 CLI。
- `native/mpv-filter/vf_iive_rife.c`：真实 mpv 视频滤镜；48/60 帧输出与 PTS 已通过短测。
- `scripts/render-smoke.c`：真实 libmpv OpenGL 渲染；48 帧短测有 45 次非黑读回、3 帧掉帧。
- 原版 IINA 插件只能设置参数与 shader，没有 CVPixelBuffer 输入接口；其 libmpv
  没有可动态加载的原生 vf ABI，已检查的版本也没有 VapourSynth。

尚未完成：持续实时与全交互验收，以及让正式 IINA 使用该滤镜。
初版异步后端、可见宿主和基础交互已在迭代 0.3 完成。
本文件是实施计划，以下验收指标是目标，均不冒充已经达成。

## 架构选择与分发边界

短期使用现有 compile-time mpv 滤镜，新增一个可见的独立 libmpv 播放宿主，建立
可重现的真实播放验证。输入与音频解码、主时钟、seek、字幕仍由 mpv 管理；
原生视频滤镜只生成带原始媒体时间轴 PTS 的新帧。

```text
mpv decode → bounded native RIFE filter → mpv GPU scaling / FSRCNNX → render API
                    ↑ generation / reset / telemetry
mpv audio ───────────────────────────────→ unchanged playback clock
```

下一步若要进入 IINA 产品，首选向上游提出可维护的原生集成方案。另一个可行但
维护成本较高的路径是自有 bundle ID、签名、资源和更新通道的明确标识的独立构建。
不能替换用户 IINA.app 内的 libmpv、重签用户应用、劫持原应用更新，或对原版插件
宣称“安装后端即可启用”。独立宿主先验证成功也不等于原版 IINA 支持。

VapourSynth 只作为另一个宿主已明确启用该能力时的替代路线，当前不优先。
CLI 编码后通过管道喂回 IINA 会增加编解码、seek 和音频同步复杂性，不作正式实时方案。

## 分阶段任务与验收门槛

| 阶段 | 具体实施与交付 | 进入下一阶段的门槛 |
|---|---|---|
| R1：可见播放与测量 | 基于现有 OpenGL host 增加可见窗口、音频、媒体时钟、播放/暂停/seek/速度控制；固定构建依赖；记录冷启动、模型、转换、排队、渲染各阶段时间 | 显示确由 AI 生成的帧；记录实际 PTS、合成计数、掉帧与音画偏差；不能仅展示目标 fps |
| R2：异步与有界队列 | Metal 工作线程串行推理；mpv filter 线程只通过其正式唤醒 API 收取结果；输入最多一个相邻帧对，待输出最多一个时间区间；整体在途帧初始上限 8 | 人为变慢时不无限排队；seek 后旧 generation 的结果不得显示；停止/关闭无泄漏或死锁 |
| R3：减少复制和冷启动 | 模型/graph 按尺寸与 tier 缓存并受内存限额控制；GPU NV12→BGRA 转换；验证 VideoToolbox CVPixelBuffer/IOSurface 的所有权及 fence；再评估输出纹理共享；迁移上游 CPU padding/cropping | 与当前参考输出核对颜色/边缘/PTS；资源可回收；分别测复制、转换和模型时间，未达成前不称 zero-copy |
| R4：720p48 实时与降级 | 先只 fast；给完整管线留渲染余量；三次持续超预算后降到原始帧率；带冷却、可解释状态与显式 Retry；scene cut 保留原帧 | 下述短测与后续持续测试达标；若失败，功能保持实验性，不以重复帧充数 |
| R5：60fps 与组合 | 用已有任意 t 调度扩展60；然后分别验证 balanced/hq、1080p、RIFE→FSRCNNX 8/16；必要时仅降低运动估计分辨率 | 每种档位有独立结果；不根据 fast48 成功推断其他档位成功；视觉检查边缘、遮挡、切镜 |
| R6：宿主能力与发布 | 插件先检查原生滤镜存在、ABI/模型版本及本次会话握手，再开放 RIFE 控件；接入原生指标；单独签名/分发或上游合入 | 只有真实兼容宿主允许启用；原版 IINA 仍显示 Unavailable；升级、退出、多窗口资源隔离验证通过 |

R1/R2 是下一轮首要开发范围。R3 的纹理共享并非先决假设：先验证具体 mp_image / 
VideoToolbox / OpenGL interop 支持；无法可靠共享时保留一次有记录、可测量的转换，
而不是让字幕、色彩或播放时钟失效。

## 时间预算与调度

- 24fps 输入帧间隔约 41.67ms。24→48 每个相邻区间通常需要一次 t=.5 推理；
  输出间隔约20.83ms。相邻帧插值还需要等待后一个输入帧，不能宣称零延迟。
- 24→60 输出间隔约16.67ms。调度交替为 `{0,.4,.8}` 与 `{.2,.6}`；每个区间
  都通常要生成两个非端点帧，并不是“48fps 模型加重复帧”。23.976 与 VFR 必须
  使用真实 PTS，而非硬编码24的间隔。
- 处理预算应按输入区间的**总工作量**计算，并留出解码、转换、输出复制和渲染余量。
  仅以模型平均耗时小于16.67ms判定60fps是错误的。2×播放速度需按墙钟预算重算，
  媒体PTS不倍乘；预算不足则退回源帧率。
- 暖机在有界状态中执行，界面显示 Warming up，初期正常播放源帧；切换时保持
  输出PTS严格递增。seek 增加 generation ID、flush 队列；不可取消的 GPU 工作
  可以结束，但结果丢弃，不能写入新一代队列。
- 提议上限：新增排队时间 Performance 100ms、Balanced 150ms、Quality 250ms；
  尚未实测。如果固定观察延迟超过此值，先退回源帧率，不继续囤积。
- RIFE 使用独立状态：Unavailable / Warming up / Verifying / Active / Paused /
  Degraded / Error。“Active”至少要求生成计数增加且已向当前渲染会话交付帧。

## 故障、颜色与并发

模型推理失败、队列超限、持续错过展示期限：清空未来中间帧，保留严格递增的源
帧PTS，退回原始播放；不得回退至 minterpolate。场景切换、重复帧和EOF允许按
明确策略保留原帧，但这些帧不计入AI生成数。稀疏差分检测仍需片段验证。

先限 SDR BT.709/BGRA8；HDR/P010、旋转、未知颜色不转换，明确绕过。多窗口各自
持有时序/队列；若共享 GPU 调度器，只共享推理资源配额，不共享帧状态。关闭窗口
取消该会话任务并回收 CVPixelBuffer、Metal texture、graph cache 引用。

## 计划验收，非已完成测试

用户不要求当前进行完整测试，本轮只测试插件变更。未来先做每项10–30秒的
功能验收；通过后才运行3–5分钟及热稳定性测试，不在每次开发迭代跑全矩阵。

| 类别 | 提议验收条件 |
|---|---|
| 正确性 | 24→48/60 与23.976、VFR的PTS单调、顺序正确；输出间隔和目标一致；音频PTS未改写；场景切换不跨镜合成 |
| 交互 | pause/resume、反复seek、0.5/1/1.5/2倍速、切文件、EOF、关窗；旧帧不回流，无持续排队 |
| 实时 | 暖机后固定条件下完整处理吞吐≥目标；同时展示实际 dropped-frame delta，目标≤1%；A/V偏差P95目标≤50ms；记录真实失败条件 |
| 内存 | 在途帧和cache均有上限；持续播放内存无单调增长；报告CPU与GPU内存口径，未知项N/A |
| 组合 | 先720p24→48+1080p输出，再1080p+4K；两种顺序只在实测收益明确时更换，默认先RIFE后SR |
| 画质 | 真人运动、面部、遮挡、闪光、字幕、硬切；与无插帧对照，不用纯合成图代表自然视频结论 |

门槛是候选发布标准，不能直接推断基础款 M5 能达到。如果720p48完整管线不达标，
应保留独立实验工具并继续优化，原版插件继续只提供已验证的超分功能。

## 核对依据

- 现有 [可行性证据](feasibility.md)、[真实测试记录](benchmarks.md)、[原生适配层](../native/mpv-filter/README.md)。
- [mpv filter API](https://github.com/mpv-player/mpv/blob/88eb9f2e73945d8bc9c133a2f67babaa9af34680/filters/filter_internal.h)：线程唤醒与 filter 回调约束。
- [RifeMetal RifeStream](https://github.com/cinemore/rife-metal/blob/1fef4869a44fca32848102b9f6a774a20eb50db6/Sources/RifeMetal/RifeStream.swift)：序列推理、任意t与缓存重置。
- 本仓库 `Timeline.swift`、`FrameProcessor.swift`、`vf_iive_rife.c` 已逐项核对；现有
  推理预算不包含全部转换成本，迭代 0.3 已改为异步执行，并将转换/复制计入预算；完整解码与渲染期限仍需跟踪。
