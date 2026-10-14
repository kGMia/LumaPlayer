# Xcode 构建与常见提示解决指南 (Troubleshooting)

## 关于 Xcode 提示 “Failed to open “vf_iive_rife.c””

### 1. 现象成因
在 Xcode 中成功编译后，若弹窗或在编辑器区域出现 `Failed to open “vf_iive_rife.c”` 提示，其原因是**编辑器历史诊断标签页残留**，并非项目代码或链接错误：
* 此前在编译报错时，底层 Meson/Ninja 从构建目录（`build/mpv/`）输出的诊断路径为相对路径：`../../.research/mpv-native/video/filter/vf_iive_rife.c`；
* Xcode 捕获该报错后，尝试在文本编辑器中打开该相对路径；
* 但 Xcode 默认以 `$SRCROOT`（即项目根目录）去解析该相对路径，导致查找路径变成了 `/Users/august/.research/mpv-native/video/filter/vf_iive_rife.c`（此路径并不在系统主目录下）；
* 现在编译已经成功，但 Xcode 仍保留了上一次尝试打开该无效相对路径的编辑器标签页，从而弹出该警告。

### 2. 解决步骤
1. **关闭历史错误标签页**：直接关闭 Xcode 主编辑区中标题为 `vf_iive_rife.c` 的残留灰色/空白标签页即可；
2. **清理构建缓存（Clean Build Folder）**：
   * 在 Xcode 菜单栏点击 **Product → Clean Build Folder**（或快捷键 `⇧⌘K`），清理历史诊断缓存；
3. **正常查看源文件**：
   * 如需查看或编辑 RIFE 滤镜实现，请在 Xcode 左侧的 **Project Navigator**（快捷键 `⌘1`）中，展开 `IIVE Player` 目录，直接点击原生的 `native/mpv-filter/vf_iive_rife.c`，即可正常浏览与高亮。
