# 阶段 5/6 收尾（2026-10-16）

## 已落盘：阶段 5

- RifeMetal 的 timestep 缓存按 binary16 位模式索引，惰性分配最多 8 个不可变张量；相同值命中不再重写整幅 timestep 内存。命中不改变 FIFO 顺序。淘汰仅移除缓存引用，批次及 Metal 命令仍持有在途资源，不会覆写 GPU 正在使用的数据。
- `runStream` 将预处理编码到第一个时间步的 command buffer，后续时间步在同一 Metal 队列依序提交。正常路径只在批次末尾进行一次显式 CPU 等待；诊断 dump 仍需阶段等待。失败退出也排空已提交的批次，输出 NV12 纹理包装与 timestep 张量保留至完成。共享 scratch 依赖 tracked hazards 与同队列排序，没有声称各时间步 GPU 并行执行。
- 场景签名一次分配结果并按索引填充，保持原采样点和 NV12/BGRA 通道次序；差值先用整数按通道累计，再进行归一化。阈值不变。
- RIFE 与 Apple/FSRCNNX 适配层在发出输出的同时，可请求下一输入启动 worker。队列满时 worker 通过条件变量等待，消费、seek/reset、关闭均会唤醒；generation 检查仍丢弃过期结果。EOF 入队后不再预取。
- **内存上界有所增加**：每个滤镜最多 8 个 ready 输出 + 8 个 worker 批次输出，以及原有前帧、单个输入和下游持有帧。不是“仍只缓存总共 8 帧”。不会无界积压。
- timestep 缓存每槽 `intW × intH × 2` 字节；4K HQ 内部 3840×2176 时，8 槽约 127.5 MiB（只在访问足够多不同值后分配）。这是减少 CPU 写入的内存代价，不代表所有预设均值得使用 HQ。
- verbose 中的 GPU 命令耗时改标 `stream last-command`；它不能代表整批次耗时。播放器 worker P50/P95 仍是整个任务的墙钟时间，不含显示与排队。

## 阶段 6：隔离、可编译的桥接原型

源码：`native/Player/Experimental/IIVEEDRBridge.h/.m`。运行 `bash scripts/build-edr-prototype.sh` 生成 `build/edr-prototype/libIIVEEDRPrototype.dylib`。它**尚未连接播放器 UI/VideoView**，没有加入没有实际作用的 EDR 开关，也没有改变现有播放器色彩设置。

已实现双槽 RGBA16F IOSurface、CGL FBO 和 Metal texture 共享绑定；GL fence 完成检测后才允许 Metal blit 到 CAMetalLayer。Metal 命令完成前禁止重用槽位。初始化检查分配、绑定和 FBO 完整性；失败返回明确错误；退出排空两侧 GPU 后释放资源。`nextDrawable` 可能等待，要求调用于渲染队列；仅 teardown 使用阻塞式 drain。

原型调用约定：在相应 CGL context 当前且加锁的串行队列上 `beginFrame` → 渲染到返回的非零 FBO → `endFrame`；另在该队列定期 `presentReadyFrame`。返回 0 意味着暂时没有空槽，**不得当作默认 FBO 渲染**。图层配置/挂载在主线程。固定尺寸，resize 须停止生产、排空并重建；屏幕切换、mini/fullscreen、字幕/截图/亮度采样和 swap 回报尚未接入。

色彩前提是源内容已经为 **extended-linear sRGB，SDR white=1.0**。`RGBA16Float` 与 `wantsExtendedDynamicRangeContent` 本身不能恢复此前已 tone-map/clamp 的 HDR 内容，也不能自动正确显示 PQ/HLG/Dolby Vision。未来接入必须核实 mpv 输出传递函数、色域、SDR 白点、EDR headroom 和上下翻转。当前不能宣称播放器已获得 EDR/HDR 输出。

原设计必须修正的假设：

1. `glFlush`/`glFlushRenderAPPLE` 是提交，不等于 GPU 完成；SDK 的 CGLIOSurface 文档描述 OpenGL 上下文间 flush/bind 规则，不能据此跳过 Metal 读取前的完成检查。
2. IOSurface 共享省去 CPU 像素拷贝；到 drawable 仍有一次 GPU blit，不能称为整条链路零复制。
3. 两张 RGBA16F 表面的名义像素内存为 1080p **31.64 MiB**、4K **126.56 MiB**，未包括行对齐、drawable、命令与播放器缓冲。
4. `flip=0` 是否与最终呈现方向匹配仍需角标图案验证，不能仅根据坐标系名称下结论。

参考：[Apple EDR tone mapping](https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping)、[Metal resource synchronization](https://developer.apple.com/documentation/metal/resource-synchronization)，以及本机 SDK `OpenGL.framework/Headers/CGLIOSurface.h`。

## 测量证据与验证范围

交接中引用的旧 `rife-stream-48-final.json`、`rife-stream-60.json` 和 `native-models-20261014-114514.json` 存在。没有找到交接中“优化后”签名微基准和 timestep 微基准的原始日志；未把 2.49×/3.62× 或 <0.0001 ms 作为本轮实测结果。24→60 本来就需要更多推理，旧单步/双步耗时差异不能全部归因于同步屏障。

同样，桥接 <0.02 ms、1080p blit 0.08–0.15 ms 和 4K 0.30–0.55 ms 没有本轮测量支持，均不作为性能保证。

本轮只执行：

- Xcode arm64 Debug 构建：通过；EDR dylib 独立编译（`-Wall -Wextra -Werror`）：通过。
- `Phase5SafetyTests` 三项：通过。NV12/BGRA 签名与旧采样算法一致、差值误差 <1e-12；缓存命中与淘汰不改写仍持有缓冲；256×128 fast 模型 `[0.4,0.8]` 批次输出对比分别执行每个时间步，最大逐字节误差 ≤1。
- 0.5 秒 256×128/24fps 合成视频，`vo=null`、RIFE fast 60fps → FSRCNNX fast：30 个输出、其中 26 个 RIFE 合成帧；两级 PTS 严格递增且对应一致，SR 输出 512×256 NV12，正常 EOF。记录 `benchmarks/results/phase5-prefetch-20261016.log`。未显示窗口。
- 初次沙箱内无窗口运行未获得增强输出，**不算通过**；允许 Metal 访问后的重跑才得到上述结果。GPU 单测初次输入缺少色彩附件，修正 fixture 后通过。
- `git diff --check` 通过。未做全套测试、性能 benchmark、GUI/EDR 实际显示测试或长时间稳定性验证。

复跑定向检查：设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 后执行 `swift test --package-path native/RIFEBackend -c release --disable-sandbox --filter Phase5SafetyTests`；级联小检查为 `python3 tests/pipeline_prefetch_smoke.py`。需正常 Metal 与 Xcode 工具链权限。

## 后续优先级

2026-10-17 收尾补充：第 3 项中的 RGBA16F 共享表面、跨 API 读取与 >1.0 数值已完成离屏小检查；最终显示方向及色彩映射仍待验证。见 [音频与 EDR 后续记录](audio-artwork-edr-20261017.md)。

1. 用户验证 48/60fps 组合播放、暂停/seek/换片。若 GPU 争用增加 P95，再将预取调整为可配置；线程可重叠不等于 GPU 吞吐一定提高。
2. 仅在相同片源、预设和冷/热状态下测前后吞吐、P95 与内存，再决定进一步减少 CPU/GPU 同步的价值。
3. EDR 接入独立实验呈现器前，先验证 RGBA16F CGL 绑定、跨 API 可见性、方向与 >1.0 数值保持，再做屏幕/headroom 和 mpv 色彩映射。原型编译通过不等于这些运行条件已验证。
