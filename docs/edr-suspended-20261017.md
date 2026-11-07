# EDR 旧帧/卡死处理（2026-10-17）

用户实测开启 EDR 后旧帧停滞并卡死。本轮按用户允许的降级方案，暂时搁置原生 EDR 输出，恢复播放器单一 OpenGL 呈现路径。**这是移除不稳定路径的修复，不是宣称 EDR 本身已修好。**

## 检查发现

- `VideoView` 持有 CGL 上下文锁时进入 `presentReadyFrame`，后者调用可能等待的 `CAMetalLayer.nextDrawable`。窗口 reshape/update 同样需要该上下文锁，drawable 供给、窗口布局和渲染之间存在互相阻塞的风险。
- 原型 resize/invalidate 同步 `waitUntilCompleted` 和 `glFinish`；它们发生在渲染队列，关闭/窗口迁移又依赖该队列，不能保证故障时回退及时完成。
- 新帧与重绘标记的 `||` 短路会跳过标记清除，可能带来多余绘制。

以上为代码层面的风险证据，未通过用户现场的线程采样证明此次死机的唯一根因。新增 watchdog 或延长超时不能消除这些跨 API 等待。

## 已实施

- 移除 `VideoView` 的 EDR 实例、呈现/轮询/回退路径及相关 API；应用不会调用独立桥接原型。保留 `native/Player/Experimental` 源码供后续独立研究。
- 移除可开启的 EDR 开关，设置明确显示 `HDR Output: SDR Tone Mapping`。不读取 `IIVE_EXPERIMENTAL_EDR`；启动清除旧 `experimentalEDRPresenter` 偏好，避免重启自动进入故障路径。
- 输出参数恢复 auto，保留现有 ICC、BT.2390 tone mapping 和 Dolby Vision RPU 映射。仍可以打开 HDR 文件，但不提供屏幕原生 HDR/EDR 输出，不代表完整 Dolby Vision 支持。
- 正常 SDR/ICC 更新不再使用 EDR 渲染暂停门控，配置失败显示错误而不是永久停在旧画面。
- 无论 mpv 是否报告新帧，都消费显式重绘标记。

## 最小验证与使用

Xcode Debug arm64 构建通过（9.66 秒），记录 `benchmarks/results/edr-suspended-build-20261017.log`；`git diff --check` 通过。未启动应用、未使用 Computer Use、未做完整测试。

本次交付入口为 `build/PersonalTeam/IIVE Player.app`。请完全退出旧版本后打开此版本；旧进程若已无响应，需要先在系统中强制退出。不需要手动删除设置。其他历史构建目录不作为本次交付入口。

## 后续

先由用户确认普通播放、暂停定位和窗口切换恢复稳定。原生 HDR 暂不继续叠加补丁；重新开展时须先在独立呈现器中拆分 GL 生产和 Metal drawable/present 队列，避免持 CGL 锁获取 drawable 或等待呈现，建立有界队列、遮挡/resize/退出取消机制。数值色彩验证和故障注入通过后再接回播放器。
