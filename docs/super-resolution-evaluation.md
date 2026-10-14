# 超分模型评估 — 2026-10-13

结论：原版 IINA 的近期方案继续采用 FSRCNNX，并开放 8 / 16 独立选择。
更强的通用图像模型可以作为原生后端的候选，但目前没有证据证明它们在基础款
M5 的 1080p 连续视频、特别是与 RIFE 同时运行时可以稳定实时。本轮只做源码和
接口评估，没有下载新权重、转换模型或填写推测的 FPS。

“更高质量”必须分别评估细节保真、压缩伪影、颗粒保留、颜色和时间一致性；
不能把更锐、参数更多或单张图更好看直接等同于真人视频质量更好。

## 候选与决定

| 候选 | 接入方式 | 潜在收益及代价 | 本项目决定 |
|---|---|---|---|
| FSRCNNX 16-0-4-1 ×2 | 已有 mpv GLSL fragment shader，无新增原生接口 | 相比已用的 8 通道模型容量更高；更多纹理读写和 pass；不是已验证的普遍画质提升 | 0.2.0 开放 Advanced → Super Resolution Model；保留 8 为 Balanced 默认 |
| RAVU Lite anti-ringing | 上游有 fragment shader 路线 | 减少边缘振铃的候选；不属于更大型深度超分模型 | 后续小范围比较，不把现有 RAVU 名称静默换成另一算法 |
| RealESRGAN_x2plus | 原生 Metal/MPSGraph 或经过验证的 Core ML 转换 | 官方通用 ×2 权重；可作为压缩自然视频的感知质量基线。GAN 恢复的纹理可能失真/闪烁，需真人视频核验 | 首先作为离线画质基线；不承诺实时、不直接加入可用模式 |
| realesr-general-x4v3 | 同样需要原生推理与帧接口 | SRVGG 结构比较直接，支持去噪强度权重混合；仍有 32 个 64→64 的主体卷积，且模型实际输出 ×4 | 优先研究的原生转换原型之一；需证明数值一致性和吞吐后再决定是否采用 |
| SwinIR lightweight ×2 | 需转换窗口注意力、移位窗口、PixelShuffle 等算子 | 可作为经典 ×2 重建基线；不是 real-world SR 权重的轻量等价替代 | 作为第二条质量对照，转换验证成本较高 |
| SwinIR real-world ×4 | 同上，更大模型 | 官方 real_sr 与 lightweight_sr 使用不同配置与权重，不能混称 | 先做离线对照，不设 M5 实时目标 |
| Anime4K | 有 GLSL / IINA 路线 | 官方明确针对动漫，线条处理目标与真人视频不同 | 不作为本项目真人视频默认方案 |

FSRCNNX / RAVU 判断依据：[官方 FSRCNNX 发布](https://github.com/igv/FSRCNN-TensorFlow/releases/tag/1.1)、
[RAVU 说明与源码](https://github.com/bjin/mpv-prescalers)。两个已捆绑 FSRCNNX 文件
均检查过 `HOOK/BIND/DESC`，没有依赖 compute-only hook。Shader 头部 LGPL-3.0-or-later
许可保留。FSRCNNX 16 使用独立的最终 pass 标记，不能拿 8 的历史统计冒充 16 已执行。
本轮在 IINA 1.5.0 的 720p24→1440p 短测中确认 16 的最终 pass 实际执行、
状态为 Active；未进行真人画质比较和持续性能验收，详见 [测试记录](benchmarks.md)。

## 核对的源码事实

Real-ESRGAN 固定 revision `a4abfb2979a7bbff3f69f58f58ae324608821e27`：

- [模型入口](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/inference_realesrgan.py)：x2plus 使用 RRDBNet，64 特征、23 blocks、scale=2；general-x4v3 使用 64 特征、num_conv=32、PReLU、upscale=4。
- [SRVGG 实现](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/realesrgan/archs/srvgg_arch.py)：低分辨率卷积后 PixelShuffle，再加 nearest-upsample 残差；没有现成 Metal 或 mpv Shader 接口。
- [推理工具](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/realesrgan/utils.py)：默认设备选择 CUDA/CPU，不自动选择 Apple GPU；载入 params_ema/params，支持 tile 和权重混合。`outscale=2` 对 ×4 模型是在模型运行后 Lanczos 缩小，并不会把推理成本变成真正的 ×2 模型。
- [模型目录](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/docs/model_zoo.md) 区分 general / anime 权重；不采用 animevideov3 作为真人模型。
- [代码许可](https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/LICENSE)：BSD-3-Clause。尚未分发其权重；引入时另存具体 checkpoint 的来源、hash 和许可说明。

SwinIR 固定 revision `6545850fbf8df298df73d81f3e8cba638787c8bd`：

- [模型构造入口](https://github.com/JingyunLiang/SwinIR/blob/6545850fbf8df298df73d81f3e8cba638787c8bd/main_test_swinir.py) 中 lightweight_sr 的 embed_dim=60、depths=[6,6,6,6]，real_sr 默认 embed_dim=180、六组深度；不是同一模型换个运行档位。
- 检查了 [network_swinir.py](https://github.com/JingyunLiang/SwinIR/blob/6545850fbf8df298df73d81f3e8cba638787c8bd/models/network_swinir.py) 的窗口划分、attention、shift 与上采样路径。原生转换尚未实施，不能假定导出一次便可正确运行。
- [许可](https://github.com/JingyunLiang/SwinIR/blob/6545850fbf8df298df73d81f3e8cba638787c8bd/LICENSE)：Apache-2.0，可在保留声明条件下与本项目 GPLv3 组合；新 checkpoint 仍需单独登记。

[Anime4K 官方说明](https://github.com/bloc97/Anime4K) 明确其动漫优化目标。
上游其他 GPU 的速度陈述不外推为本机 M5 数据。

## 选型实验，按成本排序

1. 用相同输出尺寸比较现有 FSRCNNX 8 / 16：720→1080、1080→2160，包含人脸、细发、颗粒、暗部、运动和硬切。先盲看固定片段，再核对 GPU pass 与掉帧；默认设置不因容量增加自动改为 16。
2. 获取来源可确认的原片，生成可重复的降采样与压缩输入，并另用真实低清片段。受控样本用 PSNR/SSIM；无参考视频只记录盲评和时间闪烁，不能伪造“画质分数”。
3. 在隔离环境导出一个 general-x4v3 原型和 x2plus 离线参考；核对 RGB 顺序、归一化、边缘 padding、PixelShuffle、FP16 误差、tile 接缝。只使用官方来源权重，转换产物记录 hash。
4. 原生推理采用 Metal/MPSGraph 优先；Core ML 可作为转换实验，必须单独证实算子、精度与设备执行情况，不能将“可转换”标为已支持。没有帧输入/输出适配层时不加入 IINA 开关。
5. 先测单独 SR 的完整管线，再测 RIFE→SR。整帧 GPU 时间、P95、掉帧和内存必须测得；不能用模型暖机吞吐替代播放器表现。

如果质量收益不稳定，或实时预算无法满足，则保留 FSRCNNX，重模型仅用于离线
导出。HDR/10-bit 仍单独立项，不通过强制 BGRA8 冒充兼容。
