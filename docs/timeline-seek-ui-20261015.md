# 时间轴定位回弹修复与 UI 优化（2026-10-15）

## 已完成

原实现松开鼠标时立即清空局部拖动预览，下一次 SwiftUI 渲染读取的是 mpv 尚未更新的旧 `time-pos`，随后又跳到目标位置。现在把测得的播放时间与 UI 临时目标分开：

- 松手前先建立 pending seek，再清除拖动预览。轨道、指针和时间文字继续显示目标。
- 每次绝对定位带独立 request ID；原生串行队列报告命令接受/失败及最新 `seeking`、`time-pos`。旧回报不能解除新请求的目标保持。
- 命令成功不等于定位完成：等待对应请求的 seeking 结束，或快速定位在两次采样之间完成且时钟已经接近目标。考虑采样周期与播放速度保留小范围时间容差。
- 定位超过 300 ms 才显示静态 `Seeking…` 提示，保留目标指针且不自动隐藏播放条。失败/8 秒未确认时解除保持并提示，重新显示实际播放时间。
- 换片、停止、逐帧、窗口关闭均撤销适用的临时目标。窗口/迷你模式切换共用定位状态；拖动过程中换片不会把释放事件定位到新视频。
- 真实时钟继续用于播放历史、字幕和性能信息；不会把 UI 目标时间伪装成解码输出时间。
- 不改变相对快进/快退的原有 mpv 策略；本次确认机制用于进度条、章节、时间标记等绝对定位。

UI：固定时间标签宽度，避免数字挤动轨道；点击右侧时间可切换总时长/剩余时间并记住偏好。播放键更突出，常用按钮的点击区域统一扩大。去掉时间轴容器级隐式动画，进度位置不参与悬停动画；保留章节的局部厚度过渡，无流光。

## 最基础验证

- Xcode arm64 Debug 最终构建通过，8.635 秒、0 errors；保留既有的 AppIntents metadata skipped 提示。
- `tests/TimelineSeekSmoke.swift` 直接调用真实 `PlayerTimelineState`，使用合成时钟回报验证：旧时间、请求次序、完成、短/暂停定位、失败、超时、缺失时钟、换片、边界、reset。全部通过。这是状态单测，不是实际视频定位速度或画面正确性验证。
- 未进行 Computer Use、GUI 验证、真实媒体播放、模型性能测试或完整测试。
- 日志：`benchmarks/results/timeline-seek-smoke-20261015.txt`、`timeline-seek-build-20261015.log`。
- 开发版：`build/PersonalTeam/IIVE Player.app`；仍依赖当前工作区/Homebrew。

重复运行状态检查：

```sh
mkdir -p build/checks .cache/seek-smoke-modules
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path .cache/seek-smoke-modules \
  PlayerSystem/PlayerTimeline.swift tests/TimelineSeekSmoke.swift -o build/checks/timeline-seek
build/checks/timeline-seek
```

## 下一步计划

1. **自适应播放条**：窄窗口优先保留播放、音量、定位和全屏，把次要设置收进菜单；统一主窗口、全屏、迷你模式的操作层级、焦点和快捷键反馈。增加易于定位的章节/标记列表入口。
2. **缩短真实定位等待**：合并尚未执行的绝对定位请求；识别并取消过时的 RIFE/SR 工作；优先预热目标附近的缩略图。先记录 demux/解码/推理/显示的阶段耗时，再决定是否引入快速关键帧定位与最终精确定位两阶段策略。
3. **管线效率**：统一 GPU 在途任务上限与背压，进一步减少重复格式转换和 CPU 回读；按尾延迟、掉帧、音画差决定降级，不能只用模型平均 FPS 判断流畅度。
4. **HDR 现代化**：独立评估可切换的 Metal/EDR 输出原型，保留现有稳定播放路径；完善跨屏、ICC 与杜比视界状态，再考虑替换 OpenGL。
