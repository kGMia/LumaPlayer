# HDR/EDR 与原生界面：2026-11-06

当前播放器支持读取 HDR 并映射至 SDR，不支持原生 EDR 输出。此前桥接的旧帧/卡死风险仍见 edr-suspended-20261017.md，本次不重新启用。

本地 libmpv/include/mpv/render.h 仅定义 OpenGL 与软件 render API。改用 CAMetalLayer 或设置 vo=gpu-next 并不能直接替代当前宿主接口。上游 PR #16818 检索时仍为草案，其描述的首个后端仍为 OpenGL，不能视为已具备 Metal 接入能力。

建议先做独立 HDR10/PQ 呈现验证：有界 IOSurface 队列，生产/呈现分离，持 CGL 锁期间不请求 drawable、不等待 GPU；验证暂停、seek、遮挡、resize、跨屏、退出。同步与色彩两部分分别验收。线性浮点输出需明确参考白、色域、动态 EDR headroom，不能仅靠 RGBA16F。随后再研究 HLG/杜比视界；先保持 HDR 下增强旁路，当前 RIFE/Apple 滤镜有 SDR 输入约束。

本次界面：侧栏选择器改为 SwiftUI tabs Picker + capsule；首页增加文件浏览；SR 对比收纳至 DisclosureGroup；增强状态补齐名称；清除历史使用 confirmationDialog。修正全屏侧栏的详细遥测需求判定。新增文字纳入 Xcode 字符串目录。

只做构建检查，不宣称验证 HDR、Liquid Glass 实际观感或 VoiceOver 行为。

参考：
- https://developer.apple.com/documentation/metal/performing-your-own-tone-mapping
- https://github.com/mpv-player/mpv/pull/16818
