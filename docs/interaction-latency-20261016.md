# 暂停对比调度与滚动耗时（2026-10-16）

## 改动

- 暂停时合并分隔线拖动：目标变化后等待约 180 ms 安静期；持续拖动时约 600 ms 允许一次刷新。现有 120 ms 调度周期、正在执行的 seek 和模型耗时可能增加等待，这些数值不是实测响应时间。
- 重复的相同比例同步不会推迟最终刷新。正常播放只更新滤镜参数；拖动进度条或松手精确定位会同时应用最新分隔比例，避免额外对比定位。
- 性能面板新增 SR/FI 任务 P50/P95、样本数、拖动预览 seek 次数和暂停对比 seek 次数。
- 每个原生增强滤镜保留最多 120 个有效任务耗时，使用 nearest-rank 百分位。空窗口显示 N/A；seek/reset 清空窗口，旧 generation 的任务不能写入新窗口。
- 统计成功输出的 active/scene-cut-hold 视频任务，包括重复表面复用；不计无输出预热、旁路、EOF 或取消任务。包含首次成功任务中可能发生的初始化，不代表纯模型推理耗时。每个任务可能输出多帧。
- 耗时是 worker 墙钟时间，包含输入转换、模型调用及 GPU 等待、输出处理；不含排队和显示延迟。不能据此直接换算实际播放 FPS。

## 缓存帧刷新结论

本地固定 mpv 源码 `player/video.c::mp_force_video_refresh` 在暂停时调用 `issue_refresh_seek`；`player/command.c::cmd_filter_command` 只转发滤镜命令，未触发已显示帧重新处理。当前滤镜输出由下游请求驱动。

因此本轮仍使用合并后的精确 seek 刷新暂停对比，并未声称实现缓存帧重渲染。下一步若要消除 seek，应设计播放器/渲染层保留源帧与增强帧并重合成的接口，同时覆盖色彩、字幕、画面变换和资源寿命，不能直接修改正在显示的 IOSurface。

## 基础验证

- Xcode arm64 Debug 构建通过（2026-10-16，10.035 秒，0 errors），含原生滤镜编译。
- `clang -std=c11 -Wall -Wextra -Werror tests/latency_window_smoke.c -o build/checks/latency-window-smoke`；运行通过：空窗口、非法数值、零值、百分位排序、环形淘汰、reset。
- `git diff --check` 通过。
- 未进行 GUI、真实视频性能、全套测试或观感验证；没有新增模型性能实测数据。
- 构建记录：`benchmarks/results/interaction-latency-build-20261016.log`；检查记录：`benchmarks/results/interaction-latency-smoke-20261016.txt`。
- 开发版：`build/PersonalTeam/IIVE Player.app`。仍依赖本机工作区和 Homebrew 库。

## 后续

1. 用同一片源比较关闭增强、仅 SR、仅 FI 和组合模式的 P95、复制次数与掉帧，确定实际瓶颈。
2. 若暂停对比仍明显卡顿，再实现渲染层缓存重合成；若拖动进度条卡顿，则优先调整预览 seek 调度及长 GOP 的体验。
3. 在采集排队与呈现时刻之前，不将 worker P95 标注为端到端延迟，也不以它单独决定自动降级。
