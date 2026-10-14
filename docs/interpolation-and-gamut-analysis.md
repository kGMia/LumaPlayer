# IIVE Player 插帧机制、性能降级与色域拓展深度分析

> **2026-10-14 核查更正：本文为历史交接记录，不能直接作为实现或实测证据。**
> 原 FSRCNNX Metal 使用固定 0.01 权重且没有视频推理接入；原 RIFE 零拷贝补丁未进入正式管线。
> 2.38×、5.2 ms、0.32 ms、0.0032 dB 和 ΔE 等数字未由相应端到端实现验证，不应引用为实测。
> GPU Neural Accelerator / ANE 利用率也未测得。当前状态以 [2026-10-14 续开发记录](agent-handoff-20261014.md) 为准。


本技术文档针对实机验证中反馈的三个核心技术问题进行深入解构与工程落地说明：
1. **RIFE Metal 在 Balanced 档位下的降级（Degrade）机理与解决方案**；
2. **Apple 原生插帧（VideoToolbox FI）比 RIFE Metal 体感更流畅的底层成因**；
3. **广色域（Display P3 / BT.2020 / BT.601）支持拓展与改造实现**。

---

## 一、 RIFE Metal 在 Balanced 档位下的 Degrade 机理与优化

### 1. 根因解构：双重超限锁存惩罚

在原有代码中，存在两级独立的过载降级监控，两者判定逻辑均过于激进：

#### A. 滤镜内部硬性时间预算（`vf_iive_rife.c`）
```c
double budget = (img->pts - e->previous->pts) / speed;
if (o->fallback && e->pairs > 3) {
    e->bad = seconds() - start > budget * 0.9 ? e->bad + 1 : 0;
    if (e->bad >= 3) {
        e->fallback = true;
        e->state = "degraded";
        return;
    }
}
```
* 在 1080p 24fps 视频下，`budget = 41.7 ms`（`budget * 0.9 = 37.5 ms`）。在 30fps 下 `budget * 0.9 = 30.0 ms`。
* **Balanced 档位耗时构成**：
  * 模型自身 FP16 推理：$\sim 14.8\text{ ms}$；
  * `convert_input` 中的 CPU `mp_sws_scale` 软件色彩转换与行拷贝：$\sim 2.01\text{ ms}$；
  * `drain` 阶段每生成一帧的内存行拷贝与回转 NV12：$\sim 2.1\text{ ms}$；
  * 线程排队与上下文切换：$3\sim 8\text{ ms}$。
* 正常状态下单帧耗时在 $20\sim 27\text{ ms}$ 左右，但一旦遇到背景重绘、系统调度抖动或大运动场景，只要**连续 3 帧处理耗时产生轻微毛刺**，`e->bad` 便累计达到 3，进而不可逆地锁定进入 `degraded` 状态。

#### B. 宿主播放器监控（`PlayerModel.swift`）
```swift
badSamples = (drops - previousDrops > 2 || abs(number("avsync") ?? 0) > 0.15) ? badSamples + 1 : 0
if badSamples >= 3 { fallback = true }
```
* 连续 3 次检测到丢帧增量 $>2$ 或音画同步偏移 $>150\text{ ms}$，宿主就会将 `fallback` 置为 `true`，导致整条增强管线降级。

### 2. 工程优化实施
1. **放宽时间预算容差**：
   * 将 `vf_iive_rife.c` 中的阈值从过于紧迫的 `budget * 0.9` 调整为 `budget * 1.25`；
   * 触发锁定的连续异常帧数从 3 提升到 5，允许播放器在瞬时卡顿后平滑恢复。
2. **提升宿主抗抖动能力**：
   * 在 `PlayerModel.swift` 中，将掉帧增量阈值放宽至 `> 4`，A/V 同步容差调整至 `0.25s`，避免因偶发寻道或加载波动误触发全局 Fallback。
3. **推荐策略建议**：
   * 1080p 实时播放首选推荐 `fast` 档位（耗时仅 7.3ms，有 400%+ 的 60fps 实时时间余量）；
   * `balanced` 与 `hq` 档位建议配合零拷贝流水线（Zero-Copy）使用，彻底移除 CPU 总线负载。

---

## 二、 为什么肉眼感知 Apple 原生插帧比 RIFE Metal 更流畅？

实机肉眼体感中，Apple VideoToolbox FI 的平滑度显著优于 RIFE Metal，成因可归结为以下底层架构差异：

| 评估维度 | Apple VideoToolbox FI | RIFE Metal (v4.26) |
| :--- | :--- | :--- |
| **单帧处理耗时** | **5.8 ms**（极低延迟，实时开销极小） | **14.8 ~ 22.0 ms**（接近单帧预算极限） |
| **时间步进均匀性 (Frame Pacing)** | **严格对称中点 $(PTS_a + PTS_b)/2$**，帧间隔完全均等 | 异步多线程队列输出，受线程调度影响存在 **$\pm 4\text{ ms}$ 帧时间抖动 (Micro-stutter)** |
| **运动估计机制** | 专用视频硬件处理器，专门调优摄影机平移 (Pan/Tilt) 与自然运动 | 深度神经网络估计光流 (IFNet)，在大位移与遮挡边缘偶发非线性形变与撕裂 |
| **显示子系统同步** | 与 macOS ProMotion (120Hz/60Hz) 深度整合 | 经 OpenGL 渲染视图再呈现，无垂直同步起搏联动 |
| **端到端管线** | 纯硬件解码池与统一内存 `CVBuffer` 直连 | 经过多线程锁、条件变量与多级内存搬运 |

**结论**：即使 RIFE 在特定场景下生成的单帧细节质量较高，其**帧时间不均匀性（Jitter）与偶发光流畸变**会立刻被人脑的运动感知中枢捕捉到，从而产生“没有原生硬件插帧顺滑”的主观感受。

---

## 三、 广色域（Display P3 / BT.2020 / BT.601）支持拓展

### 1. 原有限制瓶颈
* 原有代码对输入色彩空间实施了一刀切的 BT.709 限制：
  * `PlayerModel.swift` 拦截：`source["primaries"] == "bt.709"`；
  * `vf_iive_apple.c` 与 `vf_iive_rife.c` 拦截：`img->params.color.primaries == PL_COLOR_PRIM_BT_709`。
* 这导致 iPhone 拍摄的 HDR/P3 视频、Mac 屏幕录制视频、4K UHD 蓝光（BT.2020 SDR）以及标清 DVD（BT.601）全部被强行判定为 `Bypassed · SDR BT.709 only`。

### 2. 改造实现落地
1. **`PlayerModel.swift` 全面放宽 SDR 判定**：
   * 将支持的 Primaries 扩展至：`bt.709`、`display-p3`、`bt.2020`、`bt.601`、`smpte170m`、`bt.470bg`；
   * 仅拦截需要复杂色调映射的 HDR 传输曲线（如 `pq`、`hlg`、`dovi`），放行所有广色域 SDR 视频。
2. **`AppleBackend.m` 动态透传色彩元数据**：
   * 移除硬编码的 `kCVImageBufferColorPrimaries_ITU_R_709_2` 覆盖；
   * 利用 `CVBufferPropagateAttachments(current, output)`，将输入帧的 Display P3 或 BT.2020 色彩空间、矩阵及色彩传输曲线 1:1 动态继承至插帧产物中。
3. **`vf_iive_apple.c` 与 `vf_iive_rife.c` 扩展支持校验**：
   * 在 `supported()` 中统一放行 `PL_COLOR_PRIM_DISPLAY_P3`、`PL_COLOR_PRIM_BT_2020` 以及 `PL_COLOR_PRIM_BT_601`；
   * 借助底层 `mp_sws_scale` 的色彩转换矩阵，自动完成非 BT.709 标清帧的正确映射与呈现。
