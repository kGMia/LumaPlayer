# Auto Hardware 输入旁路修复 · 2026-10-17

## 原因与修复

当前锁定的 mpv 在 `mp_image_sethwfmt()` 中，将 `img->fmt` 设置为底层软件格式描述。例如 VideoToolbox 硬解帧的 `imgfmt` 是 `IMGFMT_VIDEOTOOLBOX`，但 `fmt` 是 NV12/P010，因此 `fmt.flags` 不含 `MP_IMGFLAG_HWACCEL`。

`native/mpv-filter/iive_surface.c` 原先通过这个 flag 判断存储方式，使有效硬解输入进入软件格式检查并被拒绝。它的 CPU 转换入口也使用了相同判断，若单独放开输入检查，转换仍会错误地把硬件帧交给 swscale。

两个入口现均通过 `mp_imgfmt_get_desc(img->imgfmt)` 判定实际存储格式。VideoToolbox 的 CVPixelBuffer 仍从 `planes[3]` 获取；CPU 转换时在锁定期间建立临时 NV12/P010 视图，不修改解码帧的布局或所有权。原有尺寸、像素格式及色彩限制保留，没有将 Auto 暗中改成 Copy，也没有新增 HDR 支持。

保留前序更改：1080p+ RIFE 与原生 SR 的自动预算保护、短边分辨率阈值、冷启动 24 对 / 48 帧宽限期、报告中的 degradation_events。固定帧数宽限期只是近似时间，不表示所有源帧率下均为一秒。

## 必要验证

- Xcode 构建成功，12.835 秒，无构建错误。
- `tests/vt_surface_smoke.c` 使用真实 CoreVideo IOSurface 和当前 mpv 对象，无窗口、无模型推理。修复前链接的程序在有效 VT 输入接受断言处失败；修复后 NV12/P010 输入接受及转换后像素值通过。缺失句柄、其他硬解类型正确拒绝，软件帧继续接受。
- 复跑命令：先构建项目，再执行 `python3 scripts/check-vt-surface.py`。需要允许创建 IOSurface 的本机执行环境。
- 报告工具四项单元测试通过，`git diff --check` 通过。
- `build/PersonalTeam/IIVE Player.app` 已同步最新开发构建，`codesign --verify --deep --strict` 通过。该开发应用依赖工作区构建库，并非独立分发包。

记录：`benchmarks/results/vt-input-build-20261017.log`、`vt-input-backends-20261017.log`、`vt-surface-smoke-20261017.log`。

没有进行 GUI 验证。一次四帧 `vo=null` 检查因无呈现端硬解设备而回退到软件解码，不能作为 Auto 硬解验收；上述回归验证的是硬件表面适配边界。

## 用户验证与下一步

完全退出旧播放器后打开新版，选择 Auto · Hardware Enabled，用此前出问题的 SDR 视频检查实际解码器和 RIFE 状态。720p 可同时检查 RIFE 与原生 FSRCNNX；1080p+ 在自动保护下 SR 显示 budget guard 是预期行为。

若仍旁路，提供性能记录中的 `hwdec-current`、视频色彩/尺寸和滤镜状态，再按具体输入定位；不要通过放宽 HDR/尺寸检查来掩盖问题。若正常，下一步记录同一 1080p 片段在 Auto 与 Hardware Copy 下的队列等待、渲染 P95、掉帧及内存，按实际瓶颈决定优化方向。EDR 继续搁置。
