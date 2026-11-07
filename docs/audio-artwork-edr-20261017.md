# 音频播放与 EDR 后续进展（2026-10-17 收尾）

## 音频播放

独立 IIVE Player 现在根据 mpv 音轨/视频轨识别纯音频，使用实际 FILE_LOADED 事件更新加载状态，不再要求存在 video-params。通过 Open Media、拖放、播放列表打开音频；保留暂停、定位、倍速、音量和队列控制。封面流不视为运动视频，纯音频不启动超分、插帧、自适应画面亮度采样或视频缩略图预热；逐帧、画面截图和 Live Text 不适用于纯音频。

SwiftUI 封面展示：普通窗口居中显示封面及柔和泛光、标题、艺人和专辑；迷你窗口封面裁切填满，原有播放控件覆盖其上。没有封面时显示音乐占位图。遵循减少动态效果/降低透明度偏好，封面层不拦截原播放器鼠标操作。

封面读取顺序为本地 AVFoundation 元数据、确认存在嵌入封面时的可选 FFmpeg 回退，以及同目录 cover/folder/front 的 JPG/PNG。后台解码最大 1024 像素缩略图，限制输入大小，并取消换片后的旧任务、拒绝过期结果。不会下载封面或修改媒体。播放列表封面使用 AVFoundation/同目录图片；当前曲目的嵌入封面另有 FFmpeg 回退。FFmpeg 使用现有本地安装或已有应用资源，未新增下载、未保证每种封装都能提取封面。

音频信息面板显示编码、码率、采样率、声道与样本格式；系统 Now Playing 更新为音频类型，并提供艺人、专辑和已加载封面。没有增加新的 Finder 文件关联。

## 最小验证记录

以下检查实际运行于 2026-10-16，本次只完成交付收尾，没有重跑完整测试或使用 Computer Use：

- Xcode arm64 Debug 构建通过，日志见 [audio-player-build](../benchmarks/results/audio-player-build-20261016.log)。
- 合成 MP3、FLAC、WAV 经当前 libmpv 解码至 EOF，audio-display=no 下没有将封面作为活动视频。使用 null 音视频输出，**不是扬声器/耳机听音验证**。见 [音频解码记录](../benchmarks/results/audio-playback-smoke-20261016.txt)。
- 生产 FFmpeg 封面解码器读取 MP3/FLAC 嵌入封面成功；无封面与取消请求返回空结果。见 [封面检查](../benchmarks/results/audio-artwork-smoke-20261016.txt)。这不替代 AVFoundation 和最终 SwiftUI 效果验证。
- 共用预览解码器回归：三个章节位置返回不同图片及匹配 PTS，拒绝过时结果与取消请求。见 [预览检查](../benchmarks/results/audio-preview-regression-20261016.txt)。

应用交付于 `build/PersonalTeam/IIVE Player.app`，仍是依赖当前工作区的开发版本。实际封面布局、音频设备输出、音视频混合队列和迷你窗口往返由用户验收。

## 按计划推进的 EDR 检查

新增 `tests/EDRSurfaceSmoke.m` 与 `scripts/check-edr-surface.sh`，在不创建窗口的情况下，检查 16×8 RGBA16F IOSurface：OpenGL 写入已知色块，等待 GL fence 完成，Metal 读取同一表面并回读校验。通道、行次序及 2.0/4.0 浮点值均保留，见 [原始记录](../benchmarks/results/edr-surface-smoke-20261016.txt)。脚本支持 `--build-only`。

此结果仅证明本机共享表面与同步路径可行。CAMetalLayer 最终显示方向、mpv 输出的线性光/色域映射、EDR headroom、屏幕切换和开销仍未验证。现有 OpenGL 默认呈现不变，独立桥接原型尚未接入应用，不能宣称已支持原生 HDR/杜比视界输出。

## 下一步顺序

1. 根据用户反馈完善音视频混合队列、快速换片和迷你窗口中的封面一致性；统一主画面与队列封面缓存，避免重复读取同一资源，保持内存上限与取消机制。
2. 接入可显式启用、可退回现有渲染的实验 EDR 呈现器。先确定 mpv 线性光输出与 SDR 白点/headroom 映射，再接入 resize、屏幕切换、迷你/全屏和资源释放；默认路径保持稳定。
3. 用同一片源和预设比较 RIFE→FSRCNNX 的任务 P95、吞吐与峰值内存，区分推理、排队及显示耗时。根据实测决定预取深度与 timestep 缓存预算，不以线程重叠推断加速比例。

前阶段实现与同步约束见 [阶段 5/6 收尾](phase5-6-closeout-20261016.md)。
