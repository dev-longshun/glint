# 项目专属指南（Glint）

> 本文件是项目件：只写本项目特有的做法，模板同步时不会覆盖。protocol-dev 的通用规则与本文件冲突时，以本文件为准。

## 授权与方案要求

- **可见文案检查**：若涉及面向用户的字符串，方案里必须规划 `en` + `zh-Hans` 本地化，执行前先读 `references/localization-guide.md`。

## 运行环境与版本底线

编写任何 macOS / SwiftUI / AppKit / GhosttyKit 代码之前，必须先确认项目的最低支持版本。

- 最低支持版本：macOS 14.0
- 配置位置：`project.yml` 的 `deploymentTarget.macOS` / `MACOSX_DEPLOYMENT_TARGET`；`Glint.xcodeproj/project.pbxproj` 中的 `MACOSX_DEPLOYMENT_TARGET`
- Swift 版本：5.10
- Bundle ID：正式 `app.glint.Glint`；Debug `app.glint.Glint.dev`
- 检查流程：
  1. **方案设计阶段**：提出技术方案时，如涉及较新的 SwiftUI / AppKit / Foundation API，必须确认其最低支持版本，优先选择兼容 macOS 14 的实现。
  2. **编码阶段**：使用的所有 API 必须兼容 macOS 14.0。
  3. **如需使用新版本 API**：必须用 `@available` / `if #available` 做可用性检查，并提供降级方案。
- 渐进式增强：macOS 14 用户必须能使用核心能力（工作区、分屏终端、Agent 状态、Git 审阅、更新）；高版本专属功能可仅在 macOS 15+ 可用，但需明确告知、说明低版本降级（隐藏入口 / 简化实现）、评估价值 vs 覆盖率。

## 构建与验证

本项目是 **macOS App**，可在本机直接构建与运行验证：

1. **依赖就绪**（首次 / submodule 变更后）：
   ```bash
   git submodule update --init --recursive
   bash scripts/setup-ghosttykit.sh   # 下载 Vendor/GhosttyKit.xcframework
   ```
2. **编译验证**：
   ```bash
   xcodebuild \
     -project Glint.xcodeproj \
     -scheme Glint \
     -configuration Debug \
     -derivedDataPath build \
     CODE_SIGN_IDENTITY="-" \
     CODE_SIGNING_REQUIRED=NO \
     CODE_SIGNING_ALLOWED=NO \
     ARCHS=arm64 \
     ONLY_ACTIVE_ARCH=YES \
     build
   ```
3. **测试**（改了逻辑后优先跑）：
   ```bash
   xcodebuild \
     -project Glint.xcodeproj \
     -scheme GlintTests \
     -configuration Debug \
     -derivedDataPath build \
     CODE_SIGN_IDENTITY="-" \
     CODE_SIGNING_REQUIRED=NO \
     CODE_SIGNING_ALLOWED=NO \
     ARCHS=arm64 \
     ONLY_ACTIVE_ARCH=YES \
     test
   ```
4. **本机运行**：允许用 Xcode 打开 `Glint.xcodeproj` 选 scheme `Glint`（Debug）⌘R 验证。Debug 使用 bundle id `app.glint.Glint.dev`，与正式版偏好隔离。
5. **失败处理**：GhosttyKit 缺失、签名、Xcode 版本、submodule 未初始化等环境问题不当作代码错误；记录关键错误并说明需在何处处理。

## 调试

Glint 是单进程 macOS App，但内部仍有多层边界：SwiftUI 壳 ↔ AppKit/Ghostty surface ↔ Agent hook/socket ↔ Git 子进程。调试时先判断问题落在哪一层，必要时在跨层调用的**两端同时加日志**。

- 问题范围：UI/Chrome · Pane/Ghostty · Agent · Git/Review · Workspace 持久化 · 启动/SettingsSafety · Sparkle 更新
- 日志前缀：统一前缀便于 Console.app / 终端过滤，与现有代码风格一致优先 `NSLog("[glint] …")` 或临时 `print("📖 [模块.方法] …")`
- 日志查看：Xcode console / Console.app 过滤 `glint`

Swift 日志写法（与仓库现有风格对齐）：

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

- 日志插入位置（本项目额外关注）：Ghostty surface 创建/销毁、Agent hook 安装/回调、Git 刷新起止、Persistence 读写失败路径。
- 注意：不要把调试输出写进用户可见 UI；不要污染 Agent 控制 socket / hook 的协议通道（若向 fd 写数据，日志必须走 `NSLog`/`stderr` 而非协议流）。

常见排查入口（速查）：

- 启动崩溃 / 偏好连环炸：`Glint/App/SettingsSafety.swift`、`GlintApp.init`
- 分屏 / 黑屏 / surface：`GhosttyManager`、`PaneSurfaceRepresentable`、`GhosttySurfaceView`
- Agent 状态不对：`AgentBridge`、`AgentHookInstaller`、`PaneAgentState`
- Git 状态陈旧：`GitRepositoryWatcher`、`GitRefreshCoordinator`、`GitService`
- 重启丢工作区：`Persistence`、`WorkspaceStore`
- 更新异常：`UpdaterController`、Sparkle / appcast

## 新文件登记

Swift 源文件落在 `Glint/` 下时，方案里说明是否需要 `xcodegen generate` 或手动加入 Xcode target：

- `Glint/<Module>/Foo.swift`：优先落在 `Glint/` 目录树内（`project.yml` 以 `path: Glint` 收录）。若工程由 XcodeGen 管理且 pbxproj 需同步，改完后提醒执行 `xcodegen generate` 并核 diff；若直接维护 `Glint.xcodeproj`，提醒加入 **Glint** target 并确认 Target Membership
- `GlintTests/FooTests.swift`：加入 **GlintTests** target
- `scripts/*.sh` / 纯资源：一般无需改 target，说明脚本用途即可
- 有新文案时，修改文件清单里带上 `Glint/Resources/Localizable.xcstrings`（补 zh-Hans）

创建新 Swift 文件后，必须提醒用户：

1. 确认文件在 **Glint**（或 **GlintTests**）target 的 Target Membership 中
2. 若本轮改了 `project.yml` 的 sources/settings，执行 `xcodegen generate` 并 review `Glint.xcodeproj` diff
3. 涉及用户可见文案时，确认 `Localizable.xcstrings` 已更新

## 项目专属流程

- 版本发布 → `references/release-guide.md`（含 `ReleaseNotes.swift` 规则）
  - 流程：查找最新 tag / 版本号 → 生成技术更新日志 + 面向用户的 `ReleaseNotes` 草稿 → 展示结果，等待用户确认后再改 `ReleaseNotes.swift` / 打 tag
- 可见文案 / 本地化 → `references/localization-guide.md`
- 同步上游 `upstream` → 先读 `AGENTS.md`「二开与上游同步」，再按 merge-guide

## 踩过的坑

### macOS 15+ 才支持（禁止直接裸用，须 availability 或降级）

- 使用前查 Apple 文档确认 availability，并在方案里写明降级路径

### macOS 14 可用（本项目基线）

- `@Observable` 宏 ✅（macOS 14+）
- `NavigationSplitView` / `NavigationStack` ✅
- SwiftUI 主流布局与 sheet / alert API ✅

### GhosttyKit / 原生桥接

- 调用 `GhosttyKit` C API 前确认符号来自当前 `Vendor/GhosttyKit.xcframework`，勿假设本地 zig 新构建接口
- 改 `ghostty` submodule 后必须走 `scripts/setup-ghosttykit.sh` / `publish-ghosttykit.sh` 对齐预构建包，禁止在 App 侧硬编码未发布的 C API；不得在未更新 GhosttyKit 预构建的情况下依赖 submodule 新 C API

### Debug vs Release 行为

- Debug 使用独立 bundle id 与偏好域；首次启动会从生产域 seed `glint.*` 键（见 `GlintApp.init`）
- 改偏好键 / 持久化路径时，确认不会在 dev/prod 之间互相污染
