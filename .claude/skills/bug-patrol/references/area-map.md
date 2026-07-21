# 功能区域地图（Glint）

> 本文件是 bug-patrol 的排查坐标系：把 App 拆成若干功能区，每区记录核心文件、风险等级、检查点。排查时对照本表定位区域，排查结果写入 `00_debug-notes/bug-patrol/`。
>
> 风险等级：🔴 高 / 🟡 中 / 🟢 低。随二次开发持续补全。

## R1 启动与设置安全 🔴

- **核心文件**：
  - `Glint/App/GlintApp.swift`
  - `Glint/App/AppDelegate.swift`
  - `Glint/App/SettingsSafety.swift`
- **检查点**：
  - [ ] 崩溃连环启动时偏好回滚是否正确
  - [ ] Debug 首次 seed 生产 `glint.*` 偏好是否符合预期
  - [ ] 语言覆盖（`AppleLanguages`）是否在首帧前生效

## R2 工作区与持久化 🔴

- **核心文件**：
  - `Glint/Workspace/WorkspaceStore.swift`
  - `Glint/Workspace/Persistence.swift`
- **检查点**：
  - [ ] 损坏 JSON 的备份 / 拒绝覆盖路径
  - [ ] 无法解码的 pane/workspace 剥离后是否可再保存
  - [ ] Debug（`Glint-Dev`）与正式持久化目录隔离

## R3 分屏与 Ghostty Surface 🔴

- **核心文件**：
  - `Glint/Ghostty/GhosttyManager.swift`
  - `Glint/Pane/PaneTreeView.swift`、`PaneView.swift`
  - `Glint/Pane/GhosttySurfaceView.swift`、`PaneSurfaceRepresentable.swift`
- **检查点**：
  - [ ] surface 创建 / 销毁 / 可见性与模型一致
  - [ ] 分屏树操作后 focus 与布局
  - [ ] GhosttyKit 初始化失败的降级与日志

## R4 Agent 桥接与 Hook 🔴

- **核心文件**：
  - `Glint/Agent/AgentBridge.swift`、`PaneAgentState.swift`
  - `Glint/Agent/AgentHookInstaller.swift`、`ShellRcBlock.swift`
  - `Glint/Agent/ControlBridge.swift`、`UsageStore.swift`、`CodexHome.swift`
- **检查点**：
  - [ ] 各 Agent 种类的 hook 安装 / 卸载幂等
  - [ ] 状态机转换完整（idle / working / tool / failed 等）
  - [ ] 控制 socket 生命周期与错误路径
  - [ ] 协议通道不被日志污染

## R5 Git 状态与审阅 🟡

- **核心文件**：
  - `Glint/Git/GitService.swift`、`GitDiff.swift`
  - `Glint/Git/GitRepositoryWatcher.swift`、`GitRefreshCoordinator.swift`
  - `Glint/Review/ReviewWindow.swift`、`SyntaxHighlighter.swift`
  - `Glint/Chrome/GitStatusPopover.swift`
- **检查点**：
  - [ ] 刷新节流 / 竞态 / 取消
  - [ ] SSH / 远程仓库路径
  - [ ] diff 解析边界与大文件

## R6 Chrome UI / 主题 / 命令面板 🟡

- **核心文件**：
  - `Glint/Chrome/ContentView.swift`、`SidebarView.swift`、`SettingsView.swift`
  - `Glint/Chrome/CommandPalette.swift`、`Theme.swift`、`GlintTheme.swift`
  - `Glint/Chrome/WhatsNewView.swift`、`NewWorkspaceSheet.swift`
- **检查点**：
  - [ ] 可见文案本地化（en + zh-Hans）
  - [ ] 主题 / 字体切换即时性
  - [ ] 命令面板路由与键盘焦点

## R7 自动更新（Sparkle） 🟡

- **核心文件**：
  - `Glint/App/UpdaterController.swift`
  - `Glint/App/ReleaseNotes.swift`
  - `appcast.xml`、`scripts/update-appcast.sh`、`.github/workflows/release.yml`
- **检查点**：
  - [ ] appcast 版本与 tag 一致
  - [ ] ReleaseNotes 与真实发版内容一致（禁止错挂）
  - [ ] 签名 / 公证失败时的用户提示

## R8 资源与本地化 🟢

- **核心文件**：
  - `Glint/Resources/Localizable.xcstrings`
  - `Glint/Resources/themes.json`、Assets
- **检查点**：
  - [ ] 新 key 是否补 zh-Hans
  - [ ] `LocalizedStringKey` vs `String` 误用
  - [ ] 数据字符串未被误翻

---

## 排查状态总览

排查后在此登记各区状态（✅ 已排查 / 🔄 需复查 / ⬜ 未排查）与基线 commit：

- R1 启动与设置安全：⬜ 未排查
- R2 工作区与持久化：⬜ 未排查
- R3 分屏与 Ghostty：⬜ 未排查
- R4 Agent 桥接与 Hook：⬜ 未排查
- R5 Git 与审阅：⬜ 未排查
- R6 Chrome UI：⬜ 未排查
- R7 Sparkle 更新：⬜ 未排查
- R8 资源与本地化：⬜ 未排查
