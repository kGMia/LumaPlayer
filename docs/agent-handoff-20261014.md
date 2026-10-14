# 2026-10-14 续开发记录：RIFE NV12 正式接入

> 本文件记录较早的输入优化阶段。后续已完成 FSRCNNX MPSGraph 和 RIFE 原生 NV12 输出，当前状态见 [原生模型交付记录](native-models-20261014.md)。以下未完成项是当时的历史状态。

## 先纠正上一份交接

阅读 `agent-handoff-20261013.md` 后核对了实际源码。以下内容不能视为已经完成或实测：

- `FSRCNNXModel.swift` 的所有权重是常量 0.01，没有加载模型，也没有视频处理入口；网络结构与已有 GLSL 8/16 不一致。UI 选中 Metal 后仅设置了 Active 文案，没有启动任何效果。
- `extract_glsl_weights.py` 将 GLSL 中的所有浮点数字（包括控制常量）按正则导出，不能作为有效权重布局。旧 `.bin` 和 manifest 不再打包；保留实验文件供审计。
- `vf_iive_rife_zerocopy.patch` 未接入正式编译，软件平面包装没有正确所有权，也没有 IOSurface 保证；实验内核使用 NCHW，实际 RIFE 流使用 NHWC。
- `verify_side_effects.py` 的 PSNR 损失等数据来自固定假设，没有运行模型或 GPU。已禁止该脚本继续生成“验证通过”报告。
- 历史报告中的 2.38×、5.2 ms、0.32 ms、0.0032 dB、ΔE、张量硬件利用率等，不能作为已验证的本项目结果。历史文档保留并加醒目更正。此前真实日志中的短测数据仅代表各自场景，不能替代新管线测试。

## 本轮实际实现

### RIFE 输入转换进入生产路径

`vendor/rife-metal/Sources/RifeMetalCore/StreamInput.swift` 和 `Shaders/NV12Input.metal`：

- 使用 `CVMetalTextureCache` 绑定 IOSurface NV12 的 Y / UV 两个纹理，保留 CoreVideo 纹理包装及输入帧直至同步 GPU 调用结束。
- 明确要求 420v、BT.709 矩阵、居中色度；Y 使用 (Y−16)/219，UV 使用 (UV−128)/224。输出是 gamma 编码 RGB，不能称为线性光 RGB。
- 单内核直接写入 FP16 NHWC 张量；融合边缘补齐和内部推理尺寸采样。兼容原 BGRA 路径。
- `RifeStream.push(timesteps:)` 接受 NV12，跳过 CPU 输入补边。原 `push(into:)` 和独立 pair API 仍保持 BGRA/RGBA 契约。
- FrameProcessor 使用稀疏 NV12 亮度与色度采样作切镜/重复帧启发式判断；格式变化须 reset。与旧 RGB 采样的阈值响应可能不同，需要电影场景检查；定向测试包含相同亮度、不同色度的一对帧，防止仅凭亮度误判重复。

`native/mpv-filter/vf_iive_rife.c`：

- 对偶数宽高、BT.709/BT.1886 的 BT.709 矩阵源使用 NV12 Metal 路径；其他已经允许的 SDR 输入继续走 BGRA 转换。
- swscale 直接写进 IOSurface 池的 NV12/BGRA 平面，避免之前的临时 RGB mp_image + 整帧 memcpy。
- 精确 source tick、切镜 hold 和 EOF 等返回的 NV12 帧通过引用交给 mpv；最终释放时解锁并释放 CVPixelBuffer。
- 合成帧仍为 BGRA，需要 CPU 裁剪（非对齐尺寸时）和转 NV12，使 FSRCNNX LUMA shader 能执行。**不是完整零拷贝，也未接入硬件解码直通。**
- `vf-metadata/iive-rife/input_path` 提供 `nv12-metal` / `bgra-cpu` / `pending`。UI Active 状态显示实际输入路径；没有测得的硬件利用率不显示。
- 矩阵、范围、色域变化触发流重置；保留有界队列、代际丢弃和既有降级阈值。

### 播放器和颜色保护

- 新安装默认选择可用的 FSRCNNX GLSL 8。Metal 两项禁用；旧持久化 Metal 选择明确显示 Unavailable，不偷偷替换为另一个模型。请手动选择 GLSL 8/16。
- FSRCNNXMetal 保留接口，但构造时明确抛错，移除了假权重网络。
- Apple 适配层限制为 BT.709 / BT.1886 SDR，将样本实际转换为有限范围、居中色度 NV12，设置匹配的 CoreVideo 附件和 mpv 输出标记。避免 420v 缓冲区继承错误的 full-range 或其他矩阵标记。
- 主界面对未知色域/传递函数不再凭任意一个字段匹配就视作 SDR。Apple 广色域、HDR 不在本轮支持范围。
- 保留现有 SwiftUI 控件、图标、OpenGL 渲染以及独立 IINA 插件；未修改 IINA.app。

## 验证范围

按用户要求未执行完整验证、长片测试或 GUI 测试。

- `scripts/test-rife-nv12.sh`：2 项实际 Metal/MPSGraph 测试通过，0 失败。覆盖五组色彩值、FP16 NHWC、范围/通道、补边和内部缩放、缺失附件拒绝，以及 128×72 两帧 RIFE fast 24→48 输出的格式、合成标记、PTS、EOF 和 reset。
- 原始测试输出：`benchmarks/results/rife-nv12-focused-20261014.log`。测试总时长不是推理延迟或 FPS 指标。
- Xcode Debug arm64 应用构建通过（`xcode-nv12-build-20261014.json`），仅有未使用 AppIntents 框架的元数据提取提示。原生适配层短检通过：`nv12-metal`，真实合成帧，48fps PTS 步进，正常退出。首次命令限制 8 帧，mpv 预取使适配层发出 9 帧。一次重跑错过已释放的滤镜元数据而超时，记录于 `rife-nv12-adapter-retry-timeout-20261014.json`；短检脚本改为最多 48 帧、观察到至少 8 帧即退出，按时间戳保存独立结果，避免旧成功文件掩盖新失败。最终通过记录为 `rife-nv12-adapter-20261014-003419.json`。使用 null 输出，不验证显示、音频或实时性。
- 本轮没有模型吞吐、完整播放器 FPS、画质等价性或 Neural Accelerator 占用测量。两帧与色块检查不能证明所有内容下的画质。

## 使用

打开根目录 `IIVEPlayer.xcodeproj`，选择 `IIVE Player` / `My Mac`，Xcode 27 Run。或执行 `scripts/build-player-modern.sh`，运行 `build/Xcode/Build/Products/Debug/IIVE Player.app`。应用仍依赖本工作区及 Homebrew 动态库。

选择 **FSRCNNX GLSL 8 + RIFE fast / 48fps**。符合输入条件且滤镜 active 时，插帧状态显示 `NV12 → Metal`。Apple SR/FI 继续通过系统能力查询选择可用尺度。此处不承诺 balanced 已能实时。

## 下一步（按依赖顺序）

1. 将 RIFE 最终 warp/blend 直接输出 IOSurface NV12，包括裁剪、UV 下采样与色度位置；用合成色图及真实视频对照当前输出，之后消除合成帧的 BGRA CPU 往返。
2. 接入 VideoToolbox 硬件解码帧：先确认 pinned mpv 的 AVFrame/CVPixelBuffer 导出和生命周期，再复用 IOSurface。不得用软件平面包装冒充可共享硬件纹理。
3. 正确移植 FSRCNNX：逐 pass 解析卷积矩阵/偏置/PReLU/残差/子像素通道顺序，校验完整模型导出；先完成 GLSL 输出等价对比，再接入原生滤镜与 UI。不能继续使用旧 regex 权重文件。
4. 分别采样端到端延迟、输出节奏和 Metal 计数器，再决定 MPSGraph 布局、分辨率与 balanced 优化。使用 MPSGraph 本身不代表测得 Neural Accelerator/ANE 使用率。
5. 广色域逐一添加附件、矩阵、范围和播放器输出验证；Metal 呈现迁移需同时保住字幕、HDR/EDR、色彩和音频时钟。
