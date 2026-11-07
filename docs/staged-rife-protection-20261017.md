# RIFE 分级保护与掉帧上下文 · 2026-10-17

## 行为

启用 Auto Performance Management 后，RIFE 的运行档位按 `balanced/hq → fast → Off` 单向降低。偏好中的档位不变，状态栏与 OSD 提示实际降档。关闭插帧时不主动关闭超分；其他效果仍受原有最终播放保护约束。

UI 策略在正常播放六秒后观察已有滚动统计：至少 48 个处理样本，P95 超过帧对预算 95% 持续两秒时降低一级；低于 80% 清除超预算计时。连续两秒出现每次采样至少三帧掉帧或音画偏差超过 80ms，也触发一级降低。单次掉帧不触发。原生滤镜已经进入 degraded 时，直接转到下一档，不再等待第二次宽限期。

暂停、定位、拖动、窗口过渡、缩放及模型预热阶段不累计压力，重新播放时重新等待宽限期。滤镜的 requested_tier 元数据必须与当前运行档位匹配，避免旧 balanced 的降级快照把刚切换的 fast 再次关闭。

不会自动升档，避免反复编译和卡顿。新文件、用户调整增强配置、Retry Enhancements 会恢复用户请求的档位。关闭自动管理时本策略不生效。EDR 仍搁置，既有 1080p+ 双模型保护和竖屏限制不变。

主要文件：`PlayerSystem/RIFEPerformancePolicy.swift`、`native/Player/Modern/PlayerModel.swift`、`native/mpv-filter/vf_iive_rife.c`。MPVSession 将策略的请求档位、有效档位、阶段、原因写入已有诊断快照。

## 诊断改进

`benchmarks/pipeline_profile.py --summarize-player FILE.jsonl` 新增：

- 按媒体、RIFE 档位、目标帧率、保护开关、滤镜代次与播放阶段分段，避免混合不同设置。
- 分别统计活动阶段掉帧和全记录可观察到的正向增量，显式报告计数重置。无法恢复采样之间未观测到的重置或丢失事件。
- 间隔不超过一秒的同配置掉帧合并为事件，输出前后各两秒的现有采样。最多保留最大的 16 个事件，每个最多 24 个上下文样本；同时报告总数，原始 JSONL 保持完整。
- 输出策略状态变化；降级回溯只使用此前的有效元数据，不从未来记录借用耗时。

没有增加采样频率、GPU 图像读取或额外缓冲池。日志仍是 4Hz 采样，不能确定每个掉帧的精确原因，也不能用于屏幕实际 FPS 测量。

## 对用户已有记录的重新汇总

输出为 `benchmarks/results/window-balanced-analysis-20261017.json` 和 `window-fast-analysis-20261017.json`。仅分析已有记录，未重新播放：balanced 分成 14 段，记录一次计数重置，全记录掉帧正向增量 2014（含暂停边界五帧）；此前连续播放末段的 1957 仍成立。fast 为单一连续段，12 帧、三次事件。

## 基础验证及交付

Swift 策略 smoke 通过：持续压力降档、六秒宽限、迟滞、旧档位快照拒绝、孤立掉帧容忍、暂停保持档位、Retry/reset、关闭保护和 hq 降档。

复跑：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" \
xcrun swiftc PlayerSystem/RIFEPerformancePolicy.swift tests/RIFEPerformancePolicySmoke.swift \
  -o build/checks/rife-performance-policy
build/checks/rife-performance-policy
python3 -m unittest discover -s tests -p test_pipeline_profile.py
```

报告工具五项测试通过。Xcode 项目命令行构建成功，唯一警告为既有 AppIntents 元数据跳过。未运行完整测试、GUI 或新性能基准；本轮不宣称性能提升或已修复内存增长。

开发版交付路径：`build/PersonalTeam/IIVE Player.app`，依赖当前工作区原生库。构建日志归档为 `benchmarks/results/staged-protection-build-20261017.log`。

## 用户验证与下一步

开启自动管理，选择 balanced 和 48fps，使用此前超预算的 1080p 片段。持续压力下应显示 Auto → Fast，用户所选档位仍为 balanced；fast 稳定后不应自动升回。检查切换时播放能否恢复、暂停/拖动后是否正常，点击 Retry 应重新尝试 balanced。若 fast 本身持续超预算，则应关闭插帧。

若正常，优先用新增掉帧上下文定位 fast 偶发卡顿，再为纹理/表面池增加可测的占用计数，区分内存缓存与持续增长。不要据此扩大默认预取或重新启用 EDR。
