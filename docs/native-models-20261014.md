# 原生超分与插帧：2026-10-14 交付记录

本轮将 FSRCNNX 8/16 真正移植到 Swift / MPSGraph / Metal，并将 RIFE 的 NV12 输出接入独立播放器。不是原版 IINA 插件更新；未修改 IINA.app。历史交接中曾经错误宣称完成的占位实现已经被替换。

## 直接使用

打开 `IIVEPlayer.xcodeproj`，选择 **IIVE Player / My Mac**，在 Xcode 27 Run。或运行现有开发应用：

```sh
scripts/build-player-modern.sh
open 'build/Xcode/Build/Products/Debug/IIVE Player.app'
```

在 Inspector 中选择：

- Super Resolution：**FSRCNNX Metal · Fast (MPSGraph)**，或 **Quality (MPSGraph)**。
- Interpolation：**RIFE**，先用 **fast / 48fps**。
- 保留 Performance Fallback。新安装默认 SR 为 Metal Fast，已有偏好不强制覆盖。

超分要求播放视口两轴都超过源尺寸 1.3×。模型固定输出 2×，再由播放器适配显示尺寸。支持 BT.709 / BT.1886 SDR、偶数尺寸；HDR、其他不支持的色彩或尺寸会明确 bypass。原 GLSL 8/16 和 Apple SR/FI 仍可选择。

## FSRCNNX 原生后端

- `scripts/export-fsrcnnx.py` 严格解析已有 igv GLSL 中每条计算语句，遇到未知结构直接报错。导出实际卷积权重、偏置、PReLU 与残差关系，记录源文件 SHA-256 和许可证。
- 两个模型各合并为七级计算：5×5 特征层、四级 3×3 映射、1×1 残差层、3×3 子像素层。保留 GLSL 矩阵列优先含义和 `x*2+y` 子像素索引。
- 8 通道含 2,856 个卷积权重，16 通道含 10,448 个卷积权重，另有偏置和 PReLU 参数。没有使用旧实验目录中无效的 `.bin`。
- Swift 编译 FP16 NHWC/HWIO MPSGraph，边界采用 clamp-to-edge；一个图处理全部卷积阶段。同一尺寸复用编译结果、GPU 缓冲和 IOSurface 池。
- Metal 读取 NV12 亮度，输出 2× 子像素亮度及双线性缩放色度。图与输出均在 GPU 执行。
- `native/FSRCNNXMetal` 生成 `libIIVEFSR.dylib`，经 C ABI 接入 `iive-fsrcnnx=tier=fast|quality`。与 Apple 适配层共用有界 worker、代际取消、颜色转换和降级逻辑。
- UI 只有在 `vf-metadata/iive-sr` 返回匹配的 backend 和真实 active 状态时才显示已启用；GLSL 则继续检查实际 aggregation pass。

MPSGraph 使用 Level 1 编译优化和系统默认布局策略，提供 GPU 张量优化路径；没有测得 Neural Accelerator 占用率，也没有声称迁移到 ANE。

## RIFE 原生 NV12 输入与输出

- 保留原 RIFE v4.26 推理与 PTS 调度。
- 新 `NV12Output.metal` 将 mask 重采样、sigmoid、两帧混合、裁剪、BT.709 有限范围转换、2×2 色度下采样合并为 Metal kernel，直接写 IOSurface NV12。
- 张量索引使用 padded 源尺寸，输出使用原视频尺寸。NV12 路径不再生成中间 BGRA CVPixelBuffer，也不再 CPU 裁剪/转换合成帧。
- 原始帧与生成帧均可通过引用返回 mpv；输出池有容量限制，纹理包装保留到 GPU 完成。
- 非 NV12 的旧 BGRA API 保留，文件处理工具不被强制改变输出契约。
- UI 从实际滤镜元数据读取 `input_path` / `output_path`，成功时显示 **Metal NV12 in/out**。

组合顺序为 **原尺寸 RIFE → FSRCNNX 2× → mpv 显示**，避免在放大后的尺寸执行 RIFE。

## 最基础验证结果

按用户要求，没有完整测试、GUI 验收、长片性能或画质评测。

| 检查 | 结果 | 原始记录 |
|---|---|---|
| Xcode Debug / arm64 / macOS 27 构建 | 成功 | `benchmarks/results/native-models-xcode-20261014.json` |
| FSRCNNX 8 和 16 小图 GPU 推理 | 成功；输出尺寸正确，与标量参考的平均绝对误差低于 0.01（归一化亮度） | `native-fsrcnnx-basic-20261014.log` |
| RIFE NV12 基础检查 | 2 项通过，覆盖输入转换、真实 NV12 合成输出、PTS、EOF 和 reset | `native-rife-output-basic-20261014.log` |
| 720p24 → RIFE fast 48 → FSRCNNX Metal Fast 2× | 成功；观察到 10 帧含 5 个 AI 中间帧，输出 2560×1440 NV12，正常退出 | `native-models-20261014-005516.json` |

记录均位于 `benchmarks/results/`。组合检查使用 null VO、无音频，证明真实原生滤镜链路，不代表显示帧率、音画同步或持续实时性能。冷启动计入原始 processing_ms，不将这些短测数字换算成性能承诺。

可重复执行：

```sh
scripts/test-fsrcnnx-native.sh
scripts/test-rife-nv12.sh
python3 scripts/smoke-native-models.py
```

前两个脚本只运行本次相关 GPU 检查。后一个脚本限制最多 48 帧，观察到至少 8 帧超分输出即退出。

## 仍需后续工作

- 软件解码写入 IOSurface、RIFE 与 SR 之间的输入布局拷贝、最终 OpenGL 上传仍存在；这不是端到端零拷贝。
- 显示仍为 libmpv OpenGL；模型原生化不等于播放器已经改为 Metal 呈现。
- 没有证明 balanced/HQ 已能在本机实时，也未验证 1080p→4K 的持续吞吐。
- 小图标量检查不是 GLSL 全链路的逐像素、全片源画质等价证明；FP16 舍入、色度重采样、切镜阈值仍需之后针对性评估。
- 优先下一步：VideoToolbox 解码帧共享与滤镜间 IOSurface 传递，再做 GPU 时间分析；最后推进 Metal 显示、HDR/EDR 与更完整的播放器体验。
- 当前应用仍依赖工作区与 Homebrew 动态库，并非可移走安装的便携发行包。
