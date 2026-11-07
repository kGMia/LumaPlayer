# FSRCNNX Core ML 原型 · 2026-10-25

独立 Swift Package：`native/FSRCNNXCoreML`，可在 Xcode 打开。播放器仍使用原有 MPSGraph 后端，本轮未重新打包应用。

复用现有 FSRCNNX 8/16 JSON 权重，导出前验证 SHA-256、层布局和子像素顺序。转换为固定尺寸 FP16 灰阶 Core ML 模型，保持原始 Y 码值，不进行范围扩张。转换工具支持 8/16，本轮仅验证 8。

原生路径：NV12 Y 平面 → Metal 打包灰阶 IOSurface → Core ML → Metal 重建 NV12；UV 双线性放大。使用官方 `MLPredictionOptions.outputBackings` 提供 Metal 兼容输出，检查真实返回对象后再使用。两个 GPU 等待均计入耗时；Core ML 内部传输不可见，不宣称端到端零拷贝。固定输入表面、12 个输出表面的分配上限，串行处理。仅接受明确标注 BT.709 SDR 的 8-bit video-range NV12；HDR、P010、未知色彩和尺寸不匹配会报错。

## 基础结果

Release 构建通过。M5，系统报告 macOS 27.2（26B118）。每组仅预热一次、测量三次同一帧，不代表连续视频或持续实时性能。

- 128×128 转换：常量、渐变、噪声和硬边缘全部通过 CPU 输出检查。
- 128×128 NV12：CPU/NE 噪声相对 MPSGraph 的 Y 最大差异 2/255、UV 一致；CPU/GPU 硬边缘 Y/UV 一致。
- 1280×720 → 2560×1440：同一真实视频帧，CPU/NE 的 Y MAE 0.084/255，Y/UV 最大差异均为 1/255。
- CPU/NE：含打包与重建平均 **11.32 ms**，同组 MPSGraph **8.52 ms**。自动设备选择：**10.79 ms**，同组 MPSGraph **6.96 ms**。小样本有波动，不能据此量化稳定速度差。
- 两种 720p 配置的计算计划均为 **39 个 Neural Engine 运算、2 个未知运算**；这不是 ANE 实测利用率。请求的 IOSurface 输出 backing 均被实际采用。

原始结果：`benchmarks/results/fsrcnnx-coreml-{128,720p}-*-20261025.json`。转换清单和模型位于 `build/models/fsrcnnx8-coreml-{128,720p}.*`。大型模型清单中的 `shape_unvalidated` 指导出器未执行 CPU parity；本次原生对比结果另存报告，未冒充导出验证。

720p 输入由 `build/quality-smoke/tos-60s-tagged.mov` 的第一帧缩放为 1280×720 后保存为单帧 NV12；此片段源文件色彩未知，之前的夹具已显式按 SDR BT.709 假设标记。缩放改变纵横比，仅用于相同输入的数值和耗时对照，不用于画质评分。报告记录输入字节 SHA-256。原片未修改。

## 运行

转换环境沿用 `scripts/setup-span-toolchain.sh` 的 PyTorch 2.7.0 / coremltools 9.0。使用新的输出路径：

```sh
build/span-toolchain/bin/python scripts/export-fsrcnnx-coreml.py --width 128 --height 128 --output /tmp/NEW-fsr.mlpackage
bash scripts/build-fsrcnnx-coreml.sh
native/FSRCNNXCoreML/.build/release/iive-fsrcnnx-coreml /tmp/NEW-fsr.mlpackage pattern:noise cpu-ne 3 /tmp/NEW-fsr.json
```

亦支持 `all`、`cpu-gpu`、`cpu`；输入可为 `pattern:ramp|edge|constant` 或恰好一帧、无行填充的 NV12 文件。文件必须已是所声明的 SDR BT.709，CLI 不负责色彩转换。8-bit 差异门槛 MAE/RMSE ≤1、最大值 ≤8；失败会保存报告并以非零退出。

下一步：保留当前默认后端，做独立的 RIFE + Core ML FSRCNNX 有界并行对照，记录组合延迟、队列深度和峰值内存。只有在组合负载下确有收益，才考虑接入播放器；届时还需处理动态尺寸、取消/Seek、异步表面生命周期和异常回退。当前不支持播放器实时切换，也未验证 HDR、1080p、FSRCNNX16 或持续播放。

## 组合短测跟进

已增加独立 `native/EnhancementBench`，在相同 5 帧 720p 输入上运行 RIFE 4.26 fast、24→48fps、FSRCNNX8 2×。每组处理 4 个源帧区间、输出 8 帧，预热一次；CPU 输入准备不计时。原始帧与中间帧都执行超分，按 1/48 秒排序，末尾源帧端点不计入区间结果。每组单独进程、顺序运行。

- MPSGraph：串行每帧对摊销 **14.41 ms**；有界流水线 **12.37 ms**。
- Core ML CPU/NE：串行 **31.78 ms**；有界流水线 **25.21 ms**。
- 流水线帧对完成延迟（从 RIFE 开始至该对两帧 SR 完成）均值：MPSGraph **25.47 ms**，Core ML **51.79 ms**。这与摊销处理时间不同，包含排队。
- 进程生命周期峰值 RSS 约 **104.7 MiB / 116.1 MiB**，包含初始化，不是 GPU 总内存。

Release 构建、输入哈希一致性、帧数/时间戳顺序及队列上限检查通过。SR 队列包含正在运行任务最多 2 批，生产者最多另持有 1 批；记录实际背压和 RIFE/SR 调用重叠区间。调用重叠包含等待，不能当作 GPU/ANE 同时执行的证据。短测无播放节奏，不代表持续实时性能，也不能推断真实播放器掉帧。汇总：[enhancement-combo-summary-20261025.json](../benchmarks/results/enhancement-combo-summary-20261025.json)。

```sh
bash scripts/build-enhancement-bench.sh
# INPUT 必须为恰好 5 帧紧密排列的 SDR BT.709 NV12；本轮夹具为同一 tagged.mov 的前 5 帧按上文缩放。
native/EnhancementBench/.build/release/iive-enhancement-bench coreml pipeline build/models/fsrcnnx8-coreml-720p.mlpackage INPUT.nv12 1280 720 4 /tmp/NEW-combo.json
# 比较其他组合：coreml → mpsgraph（模型参数用 -），pipeline → serial。
```

同时修复 FSRCNNX 与 RifeMetal 合并依赖图时的 SwiftPM shader 插件同名冲突，仅为 FSRCNNX 插件增加独立 target 名称；着色器内容未改动。

结论：现有数据不支持接入 Core ML 替换默认 SR。下一步优先沿用 Metal/MPSGraph，优化按展示期限控制预取和背压，避免吞吐提高却增加交互延迟；随后评估输出表面复用及跨滤镜等待。先保持取消/Seek 时有界排空，再考虑更深流水线。本轮未改播放器配置、未重新打包应用、未进行 GUI 或完整测试。
