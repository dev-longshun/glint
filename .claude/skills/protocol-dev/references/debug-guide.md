# Bug 调试规范 (The "DEBUG-FIRST" Rule)

当用户报告程序中的 Bug 时，**严禁凭直觉猜测问题原因或直接修改业务逻辑**。必须严格遵循以下调试流程。

Glint 是单进程 macOS App，但内部仍有多层边界：SwiftUI 壳 ↔ AppKit/Ghostty surface ↔ Agent hook/socket ↔ Git 子进程。调试时先判断问题落在哪一层，必要时在跨层调用的**两端同时加日志**。

## 第一步：分析问题现象

1. **明确异常行为**：用户描述的实际发生了什么
2. **明确预期行为**：按照设计应该发生什么
3. **定位问题范围**：UI/Chrome · Pane/Ghostty · Agent · Git/Review · Workspace 持久化 · 启动/SettingsSafety · Sparkle 更新

## 第二步：提出调试方案（必须等待用户批准）

**🚨 禁止直接向源代码写入调试信息！** 必须先在对话中向用户描述完整的调试方案，包含：

1. **问题分析**：对问题的理解和初步判断
2. **调试思路**：为什么在这些位置加日志、如何通过日志定位
3. **目标文件清单**：需要加日志的文件及具体位置
4. **日志设计**：
   - 统一前缀便于 Console.app / 终端过滤，与现有代码风格一致优先 `NSLog("[glint] …")` 或临时 `print("📖 [模块.方法] …")`
   - 明确要记录的变量、状态、条件判断结果
   - 标记执行顺序和时机
5. **明确请求批准**：最后一句必须是"确认后我开始添加调试代码"

**方案设计原则**：每个关键分支都有日志覆盖；日志能区分"进入了哪个分支"；异步操作的开始和结束都记录；状态变化前后值都记录；跨层调用两端都记录。

## 第三步：插入调试代码（仅在用户批准后执行）

收到明确批准（如"可以"、"执行"、"开始吧"）后，向代码添加调试日志。

**Swift 日志规范（与仓库现有风格对齐）**：

```swift
// 长期/生产可留：与仓库一致
NSLog("[glint] pane mint ws=%@ pane=%@", wsID, paneID)

// 临时排查：带 emoji 前缀便于捞
print("📖 [WorkspaceStore.select] begin - ws=\(id), panes=\(panes.count)")

if condition {
    print("📖 [AgentBridge] 进入 A 分支 - state=\(state)")
} else {
    print("📖 [AgentBridge] 跳过 - 原因: …")
}
```

**日志插入位置**：函数入口/出口、每个条件分支、异步启动与回调、状态变量修改前后、Ghostty surface 创建/销毁、Agent hook 安装/回调、Git 刷新起止、Persistence 读写失败路径。

> **注意**：不要把调试输出写进用户可见 UI；不要污染 Agent 控制 socket / hook 的协议通道（若向 fd 写数据，日志必须走 `NSLog`/`stderr` 而非协议流）。

## 第四步：用户验证与日志分析

1. **请用户复现问题**并收集完整日志（Xcode console / Console.app 过滤 `glint`）
2. **分析执行路径**：对比实际 vs 预期，定位第一个异常点
3. **明确根因**：基于日志证据得出结论，而非猜测

## 第五步：修复与清理

1. **提出修复方案**：说明根因、修复思路、需改代码，**等待用户确认**
2. **执行修复**（批准后）：改业务逻辑，**保留调试日志**
3. **用户验证**：请用户运行验证是否修复
4. **清理调试代码**（🚨 必须等待用户确认）：确认修复后**主动询问**是否清理；用户明确同意才删；要求保留则不删；**严禁在修复时顺便清理**

## 常见排查入口（速查）

- 启动崩溃 / 偏好连环炸：`Glint/App/SettingsSafety.swift`、`GlintApp.init`
- 分屏 / 黑屏 / surface：`GhosttyManager`、`PaneSurfaceRepresentable`、`GhosttySurfaceView`
- Agent 状态不对：`AgentBridge`、`AgentHookInstaller`、`PaneAgentState`
- Git 状态陈旧：`GitRepositoryWatcher`、`GitRefreshCoordinator`、`GitService`
- 重启丢工作区：`Persistence`、`WorkspaceStore`
- 更新异常：`UpdaterController`、Sparkle / appcast

## 🚫 严禁行为

- ❌ 未经批准直接添加调试日志
- ❌ 不看日志就凭猜测修改逻辑
- ❌ 连续尝试多个"可能的修复"而不通过日志验证
- ❌ 未经确认直接清理调试代码
- ❌ 在修复时顺便删除调试日志
- ❌ 跳过方案描述阶段直接改代码

## 核心原则

1. **先分析，后行动**
2. **日志驱动调试**：结论必须基于日志证据
3. **用户批准制**：任何代码修改前都要明确批准
4. **清理需确认**
