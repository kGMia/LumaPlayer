# 预览气泡位置与 MKV 固定画面修复

日期：2026-10-15。

用户反馈上轮气泡显示在轨道下方，部分多章节 MKV 始终显示相同图片。本轮替换了上轮的对齐线方案，并修复允许无限复用任意远处缓存图片的呈现逻辑。

## 改动

- `TimelinePreviewAboveTrack` 使用 SwiftUI Layout，在零高度的轨道顶部布局容器中，以 `bottomLeading` 将气泡底部明确放到轨道上方 8 pt。章节、状态与图片高度由子视图自行测量，不依赖 alignmentGuide 传播，也不使用猜测的气泡高度。
- 图片请求与缓存呈现循环使用同一个目标 key，包含 SDR 能力状态。图片缓存仅允许目标附近 3 秒内的样本；不再无限期显示任意位置的旧图。
- 等待新图时，远处旧图最多过渡保留 350 ms，并显示 Updating preview。之后显示 Preparing preview 或对应失败说明；解码失败立即移除不相关旧图。保留实际图片时间，未将悬停时间冒充解码时间。
- SDR MKV/WebM 在有本地 FFmpeg 时直接使用该解码器，避免等待不支持 Matroska 的 AVFoundation 路径。FFmpeg 选择 `0:V:0`，排除封面/附加图片流；输出使用 passthrough，不做帧率复制。
- AVFoundation 与 FFmpeg 结果均检查实际帧 PTS，距目标超过 1.75 秒的结果不会缓存为有效目标图。此容差包含 AVFoundation 原有的 ±1.5 秒近似定位。
- 色彩元数据到达后，旧的 AV-only 失败不能阻止新的 SDR 请求重试。失败状态按请求位置及能力区分，不因另一位置成功而消失。
- 原有超时、单任务、内存限制和文件切换取消机制保留。

## 最小检查

用本地 FFmpeg 生成 6 秒、三个章节的 320×180 H.264 MKV（红、绿、蓝），直接编译并调用应用使用的 `FFmpegPreviewDecoder.swift`，不使用替代解码实现：

| 请求位置 | 返回 PTS | 图片 |
|---|---|---|
| 0.5 s | 0.5 s | 第一张 |
| 2.5 s | 2.5 s | 第二张，与第一张哈希不同 |
| 4.5 s | 4.5 s | 第三张，与前两张哈希不同 |

同时检查拒绝过远/NaN 时间戳及预先取消的请求。均通过。

复现：`bash scripts/check-timeline-preview.sh`。结果见 `benchmarks/results/preview-mkv-smoke-20261015.txt`。该检查只证明此合成片源的实际解码路径，不覆盖用户样片、全部编码器或 SwiftUI 的实际显示。

Xcode arm64 Debug 构建通过；最终应用复制到 `build/PersonalTeam/IIVE Player.app` 并验证开发签名。未使用 Computer Use、启动播放器、检查 GUI 或执行完整测试。

## 仍有边界

FFmpeg 回退仅限已确认 SDR 的本地视频。HDR/Dolby Vision 或色彩未知且 AVFoundation 无法生成有效图片时，明确显示不可用，不提供未经色彩处理的错误缩略图。长 GOP/高分辨率文件仍可能遇到现有 4 秒超时。播放器主解码、模型及 HDR 输出路径没有在本轮改变。

## 2026-10-27 · 预览防抖与 BMP

悬停/拖动预览的目标桶稳定 75 ms 后才请求解码；SwiftUI 任务取消会中止等待，独立的最近邻缓存展示仍立即执行。交互开始即抑制预热，已有在途解码仍可填充缓存，不反复杀掉重启。SDR 时间轴回退改为 BMP/BGR24，经 ImageIO 读取；音频封面继续 PNG。尺寸、输出字节上限、实际 PTS 检查及取消规则保留。

三章节样例加入非对称色块，BMP/PNG 归一化 RGBA 像素、上下方向及时间戳一致；无效时间戳与取消检查通过。交替顺序、每位置排除首轮后各 9 次的小样本：PNG 中位 19.925 ms，BMP 19.384 ms，均含进程启动、定位/视频解码和图片绘制。差异很小，不能视为真实悬停提速证明；未做 GUI 验证。记录：`benchmarks/results/preview-bmp-debounce-20261027.log`。

同日继续：本地 SDR MKV/WebM 优先使用单实例原生 libavformat/libavcodec 解码，省去子进程与图片编码；每次定位刷新解码状态，按实际 PTS 选择帧，五秒闲置释放。路径/文件身份/修改时间/大小改变时重建；只允许普通本地文件，禁止嵌套资源，限制线程、输入像素及读取时限。旋转、非方形像素、HDR 等拒绝原生快路径；原生尝试失败后该媒体继续既有回退。

`scripts/check-native-preview.sh` 检查前后跳转、与 BMP 像素/方向/PTS 一致、关闭重开、取消和输入边界。三章节样例首次约 14.87 ms，后续四次约 0.25–0.31 ms；对应 BMP 子进程约 19–35 ms。仅为小样本，不代表长 GOP、4K 或真实 GUI 悬停延迟。记录 `benchmarks/results/native-preview-20261027.log`；应用集成构建记录 `native-preview-next-player-20261027.log`。
