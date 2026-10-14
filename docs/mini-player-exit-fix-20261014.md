# 迷你模式异常退出修复 · 2026-10-14

## 根因与证据

修复前，即使没有打开媒体，使用 ⌥⌘P 进入迷你模式也会导致应用退出，没有生成新的 crash report。

在 Xcode 中对 `applicationShouldTerminateAfterLastWindowClosed` 设置断点后，同样操作命中了主线程上的调用链：

```text
SwiftUI AppDelegate.applicationShouldTerminateAfterLastWindowClosed(_:)
AppKit -[NSApplication(NSWindowCache) _checkForTerminateAfterLastWindowClosed:saveWindows:]
AppKit _scheduleCheckForTerminateAfterLastWindowClosed
```

`PlayerAppDelegate` 原先无条件返回 true。主窗口在淡出后执行 `orderOut`，浮动 NSPanel 不阻止 AppKit 的最后窗口退出检查，因此触发了正常终止流程，而不是模型推理或内存访问崩溃。

## 修复

- 迷你模式启用、窗口转换中或迷你面板实例仍存在时，退出策略返回 false。
- 恢复动画开始后 `miniPlayer` 会先变为 false，所以额外检查实际面板生命周期，直到 `dismissPanel` 完成。
- 真正关闭主窗口后，现有清理流程释放迷你面板并复位状态，保留正常退出行为；⌘Q 的显式退出行为不受影响。
- 保留隐藏主窗口和淡入淡出，不撤回用户要求的交互。

修改文件：`native/Player/Modern/IIVEPlayerApp.swift`、`PlayerSystem/PlayerWindowModes.swift`。

## 针对性验证

- Xcode build + launch 成功，日志 `RunProject-Log-20261014-211141.txt`；只有既有 AppIntents 无依赖提示。
- GUI 空媒体场景两次进入迷你模式均保持运行：分别通过恢复按钮、关闭迷你面板按钮回到主窗口。
- 主窗口关闭后观察到进程不可用（CUA 返回 procNotFound）。
- Personal Team 开发签名严格校验通过，更新应用 `build/PersonalTeam/IIVE Player.app`。
- 未完成媒体播放中的切换回归；本次复现和修复验证针对的是无需媒体即可触发的窗口退出错误，不代表全片或全部增强组合验证。
