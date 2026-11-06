# Glint — Agent 协作协议

> Claude / Codex / Grok 共用本文件（`CLAUDE.md` 是它的软链）。skill 真源在 `.claude/skills/`，`.codex/skills`、`.grok/skills` 软链到同一处。改协议只改本文件，改 skill 只改 `.claude/skills/`。

## 项目定位

> **本仓库是官方 Glint 的二开 fork，不是上游原版。**  
> - 我们的仓：`dev-longshun/glint`（`origin`）  
> - 上游官方：`chenbstack/glint`（`upstream`）  
> 日常开发、发版、DMG 下载都以本 fork 为准。上游有更新时可以同步，但**绝不能整仓照搬上游**把我们已改的点冲掉。规则见下文「二开与上游同步」。

Glint 是**为 AI 代理打造的 macOS 终端**，底层基于 [Ghostty](https://ghostty.org)（经 `GhosttyKit.xcframework`），界面用 SwiftUI + AppKit。核心能力：多工作区 / 多分屏终端、Agent 生命周期钩子与状态展示（Claude / Codex / Devin / OpenCode / Omp / **Grok** 等）、Git 状态与 diff 审阅、**应用内 GitHub Release 一键更新**（下载 DMG → 去隔离 → 覆盖安装 → 重启；本 fork 不用 Sparkle）。

技术架构：

- **App 层（SwiftUI + AppKit）**：窗口壳、侧边栏、设置、命令面板、主题、审阅窗
- **终端层（GhosttyKit C API + AppKit 嵌入）**：`GhosttyManager` 管理 ghostty app/config/surface；`Pane` 系负责分屏树与 surface 承载
- **Agent 层**：hook 安装、状态桥接、用量与 Codex home、外部控制 socket
- **Git 层**：仓库监视、状态刷新、diff 解析
- **依赖**：`Vendor/GhosttyKit.xcframework`（由 `scripts/setup-ghosttykit.sh` 按 submodule SHA 下载，不入库）。本 fork 更新走 GitHub Releases API + 本地安装脚本，无 Sparkle / 无 Apple Developer 签名要求

改层边界：

- 改 UI / 交互 / 主题 / 设置 → `Glint/Chrome/`、`Glint/App/`
- 改分屏 / surface 嵌入 → `Glint/Pane/`、`Glint/Ghostty/`
- 改 Agent 状态 / hook / 控制协议 → `Glint/Agent/`
- 改 Git 状态 / diff / 审阅 → `Glint/Git/`、`Glint/Review/`
- 改工作区持久化 → `Glint/Workspace/`
- 改 Ghostty 引擎本身 → `ghostty/` submodule（fork `chenbstack/ghostty` 的 `glint-dev` 分支），再经 `scripts/publish-ghosttykit.sh` 发预构建包

## 项目基础信息

- **最低支持版本**：macOS 14.0（`project.yml` / `Glint.xcodeproj` 的 `MACOSX_DEPLOYMENT_TARGET`）
- **工程文件**：`Glint.xcodeproj`（主工程，已入库）；`project.yml`（XcodeGen 描述，改 target/源路径后需 `xcodegen generate` 再核 diff）
- **语言 / 技术栈**：Swift 5.10 · SwiftUI · AppKit · 少量 ObjC（`AEBridge.m` + bridging header）· GhosttyKit
- **Bundle ID**：正式 `app.glint.Glint`；Debug 为 `app.glint.Glint.dev`（独立 UserDefaults / 持久化目录，避免污染生产偏好）
- **其他关键配置**：`ghostty` git submodule；`Vendor/GhosttyKit.xcframework` 需 `bash scripts/setup-ghosttykit.sh`；正式发版可走 tag `v*` + 上游式 `release.yml`；**本 fork 日常 DMG 走 push `main` 触发的 `build-dmg.yml`**（ad-hoc 签名，产物在本仓 Releases）
- **Git 远程**：`origin` = 本 fork；`upstream` = 官方。禁止把 `origin` 指回官方后直接 push（无写权限，且会绕开二开发版流）

## 二开与上游同步（强制）

本 fork **有意偏离**上游。同步 `upstream/main` 时，agent / 人 **禁止**「全盘接受上游 / 用上游文件覆盖我们的改动」；必须逐处判断：**保留我们的、吸收上游新增的、两边都改时融合**。

### 已确认的二开改动（同步时优先保留）

清单会随后续提交增长；同步前用 `git log upstream/main..HEAD --oneline` 与 `git diff upstream/main...HEAD --stat` 复核。当前至少包括：

1. **Grok Agent 接入**  
   - 状态 / 选择 / hook / UI：`Glint/Agent/*`、`SettingsView`、`SidebarView`、`ContentView`、`WorkspaceStore` 相关  
   - 资源：`Glint/Resources/Assets.xcassets/Grok*`、`scripts/generate_grok_action_gifs.py`  
   - 测试：`GlintTests/*Grok*`、`AgentHookRoutingTests` 等  

2. **Typeless / 无障碍粘贴（终端 AX）**  
   - `Glint/Pane/GhosttySurfaceAccessibility.swift`：`textArea` 角色、value/selectedText 读取；`GhosttySurfaceView.swift`：插入后 `AXValueChanged`（对标 MUX0，保证「复制最后的转录」类工具可用）  
   - 上游若改 surface 嵌入，**保留我们的 AX 行为**，再合入对方无关修复  

3. **终端默认观感（对标 Kaku / MUX0）**  
   - `GhosttyManager.applyGlintTheme`：默认 `JetBrains Mono`、`cursor-style = bar`、padding `16`、`adjust-cell-height = 4`、CJK 默认 `LXGW WenKai Mono`（本机已装且用户未显式清空时）  
   - `WorkspaceStore` 同名默认；`FontCatalog` 推荐列表（JetBrains 置顶、CJK 含霞鹜文楷等宽）  
   - 上游若改默认字体/光标/padding：**不得静默退回 SF Mono / block / 旧 padding**，除非用户明确要求  

4. **本 fork 的 CI / 发版**  
   - `.github/workflows/build-dmg.yml`：push `main` → 自动打 DMG + GitHub Release  
   - 不要被上游只保留 `release.yml`（仅 `v*` tag）的结构删掉或覆盖  
   - 签名：secrets `GLINT_SIGNING_CERT_P12` / `GLINT_SIGNING_CERT_PASSWORD` 提供固定自签名证书「Glint Fork Code Signing」（证书与密码备份在本机 `~/.glint-signing/`），指定要求 = bundle id + 证书指纹，系统隐私权限跨版本保留；未配置时退回 ad-hoc 并告警  
   - `Glint/App/UpdaterController.swift`：应用内更新只在 `codesign --verify` 失败时才 ad-hoc 兜底重签。上游若改签名 / 更新流程，**不得恢复无条件 ad-hoc 重签**（否则每次更新都要重新授权系统权限）  

5. **应用图标（AppIcon.icon）**  
   - 必须是 **单个** `lastKnownFileType = wrapper.icon` 资源；禁止把 `icon.json` / `background.png` / `foreground.png` 拆成 Copy Bundle Resources  
   - `xcodegen generate` 后必须跑 `python3 scripts/fix-appicon-pbxproj.py`（`project.yml` 的 `postGenCommand` 已挂）  
   - 验证：归档产物 `Glint.app/Contents/Resources/AppIcon.icns` 存在  

6. **协作协议**  
   - 本文件 `AGENTS.md`、技能树、本「二开」章节：上游若无对应内容，**整段保留**  

7. **Agent 恢复时保留启动权限参数**  
   - `Glint/Agent/PaneAgentState.swift`：`permissionFlags(fromArguments:)` 白名单 + `restoreCommand(launchFlags:)`  
   - `Glint/Workspace/WorkspaceStore.swift`：`Pane.launchFlags` 持久化，`captureSurfaceState` 从前台进程参数记录  
   - `Glint/Pane/GhosttySurfaceView.swift`：`foregroundProcessArguments()`  
   - 作用：`cc` / `cx` / `gk` 这类带权限参数启动的 Claude / Codex / Grok，重启恢复时带上同样的参数  
   - 上游若改 `restoreCommand` 或恢复逻辑：保留 `launchFlags` 这条链路  
   - 设置 → 代理：Claude / Codex / Grok 的「恢复时总是跳过权限确认」（`restore*SkipPermissions` + `PaneAgentKind.skipPermissionFlags` + `WorkspaceStore.restoreLaunchFlags`），开启时用固定跳过参数替换记录值，兜住升级后没记到参数、裸命令启动等情况  
   - 上游给 `PaneAgentKind` 新增 case 时，`launchFlagSpecs` / `skipPermissionFlags` 这两个穷举 switch 要补分支，否则编译失败（同步 agy 时踩过）  
   - Codex 白名单里还有非权限参数 `--no-daemon`（`isPermission: false`）：Codex 0.157+ 默认让 TUI 连共享后台进程，hook 在后台进程里带着第一个启动它的窗格的 `GLINT_PANE_ID` / `GLINT_AGENT_SOCK` 执行，Codex 状态会全部丢失。「总是跳过权限确认」只替换权限参数，`--no-daemon` 经 `nonPermissionFlags` 保留  
   - 上游 9425719 的 `WorkspaceStore.codexHookTarget` 不信任 hook 自报的窗格地址（防共享后台进程带错环境），同目录多个 Codex 窗格时会丢掉还没登记 session 的事件。本 fork 在「已登记 session 优先」之后、「cwd 唯一命中」之前加了例外：被寻址窗格正在跑带 `--no-daemon` 的 Codex（`codexRunsInProcess`：先读实时 argv，读不到用 `Pane.launchFlags`）时直接用该地址。测试 `AgentHookRoutingTests.testNoDaemonCodexHookTrustsAddressedPaneInSharedCwd`。上游若改 `codexHookTarget`：保留这条例外  

8. **hook 上报脚本的 plutil 读取写法**  
   - `Glint/Agent/AgentHookInstaller.swift` 的 reporter 脚本：一律写成 `X=$(plutil -extract … 2>/dev/null) || X=""`，禁止上游的 `|| true` 写法  
   - 原因：macOS 15 的 plutil 提取失败时把报错写到 stdout，`|| true` 会把报错文本当成值，导致 `GROK_SESSION_ID` 等兜底逻辑失效  
   - 上游在脚本里新增 plutil 读取时（如 agy 的 `conversationId`），合并时逐行改成这种写法  

9. **应用内更新：退出流程、更新红点与上游提醒**  
   - `Glint/App/AppDelegate.swift`：`terminateAfterDismissingSheets()`，配合 `WorkspaceStore.dismissSheetsForQuit()` 在退出前关闭所有 sheet（sheet 挂着时 AppKit 会在询问 delegate 前直接拒绝 terminate）  
   - `Glint/App/UpdaterController.swift`：退出被取消时进入 `readyToInstall`（「退出并安装」）；replace.sh 不设超时、等进程退出，先复制到 `.Glint-update-staging` 再改名替换；`showsUpdateBadge`；后台检查（启动后一次、每 30 分钟、切回 Glint 且距上次检查 ≥10 分钟时补查）不清空已知结果  
   - `Glint/App/UpstreamTracker.swift`：compare 接口统计上游 `chenbstack:main` 未合并提交数  
   - `Glint/Chrome/SidebarUpdateBadges.swift`：「新建工作区」右侧的更新 / 上游胶囊与弹窗；`ContentView` 齿轮红点；`SettingsView`「显示上游新提交」开关  
   - 上游若改更新流程、`installAndRelaunch` 或侧边栏底部布局：保留以上入口与退出流程，不得退回直接 `NSApp.terminate(nil)`  

10. **⌘R 重命名工作区快捷键**  
   - `Glint/App/ShortcutStore.swift`：`ShortcutID.renameWorkspace`（workspace 组，默认 ⌘R，可在设置里改键）；`Glint/App/GlintApp.swift`：菜单「Rename Workspace」；`Glint/Chrome/CommandPalette.swift`：命令面板同名条目（快捷键显示读 `ShortcutStore`，执行推迟到面板关闭后）  
   - `Glint/Workspace/WorkspaceStore.swift`：`pendingWorkspaceRenameID` + `requestRenameSelectedWorkspace()`（弹层打开或无选中时提示音，侧栏收起时先展开）  
   - `Glint/Chrome/SidebarView.swift`：`WorkspaceCard.consumeRenameRequest()` 在 onAppear / onChange 时进入改名；`SidebarView` 外层包 `ScrollViewReader`，`revealWorkspaceForRename` 负责清空过滤搜索词并滚到卡片  
   - 上游若给 `ShortcutID` 加新快捷键：默认键不得与 ⌘R 冲突（`ShortcutStoreTests.testDefaultChordsAreUnique` 会拦）；上游若重写侧栏列表或卡片改名逻辑：保留这条外部触发改名的链路  

11. **Claude 用量读钥匙串走 /usr/bin/security**  
   - `Glint/Agent/UsageStore.swift`：`ClaudeUsageReader.readKeychainViaSecurityTool` 用 `security find-generic-password -w` 读 `Claude Code-credentials`，禁止改回进程内 `SecItemCopyMatching`  
   - 原因：本 fork 没有 Team ID，进程内读取需要钥匙串分区列表里有 Glint 的 `cdhash:`；但 Claude Code 每次换 token 重写条目时都会把分区列表重置成只剩 `apple-tool:`，再加上每次更新 cdhash 都会变，「始终允许」只能撑到下次换 token（几小时）；`security` 本来就在该条目的 ACL 和 `apple-tool:` 分区里，读取不弹窗  
   - 上游若改 Claude 用量读取：保留这条读取路径  

12. **空闲 agent 自动休眠**  
   - `Glint/Workspace/WorkspaceStore.swift`：`AgentHibernationPolicy`、`hibernateIdleAgentIfEligible`（挂在 `offlineIdleTerminals` 30 秒巡检上）、`agentResumeCommand`（与启动恢复共用）、设置 `hibernateIdleAgentsEnabled` / `idleAgentTimeoutSeconds`  
   - `Glint/Pane/GhosttySurfaceView.swift`：`hibernateAgent(resumeInput:)`、`agentProcessTreeIsDisposable()`、`releaseSurface(_:)`（shell 离线与 agent 休眠共用）  
   - `SettingsView`「空闲 Agent」卡片；`SidebarView`「已休眠」胶囊  
   - 上游若改 idle-offline / `createSurface` / 恢复命令：保留休眠分支与 `pendingInitialInput` 唤醒链路  

13. **Telegram 远程确认（目前只接 Claude）**  
   - `Glint/Agent/TelegramBridge.swift`：Bot API 长轮询、只认发过 `/start` 的那个私聊、Bot Token 存钥匙串（service = bundle id + `.telegram`，Debug 和正式版各用各的机器人，避免两边抢 `getUpdates` 报 409）  
   - `Glint/Agent/ConfirmationRelay.swift`：推送记账与过期判断（每个 hook 事件都让该分屏进入新一轮，`Notification` 除外，旧按钮随之作废）、发送前打码、超长时保留结尾；`Glint/Chrome/TelegramConfirmSettings.swift`：设置 → Agents「Telegram 远程确认」卡片，`SettingsView` 里只有一行挂载  
   - `Glint/Agent/AgentHookInstaller.swift` 的 reporter 脚本：Claude 的 `Stop` 额外转发 `last_assistant_message` 末尾 16KB（`message_b64`）；`AgentBridge.decodeHookLine` 解成 `message`，`utf8DroppingLeadingPartial` 丢掉被 `tail -c` 切断的半个字符  
   - `Glint/Workspace/WorkspaceStore.swift`：`handleAgentEvent` 末尾调 `ConfirmationRelay.shared.agentEvent`；`confirmationTitle` / `deliverConfirmation`（只往停在提示符、推送后没人打过字的分屏里打字）；`hibernateIdleAgentIfEligible` 跳过还有待回复推送的分屏  
   - 上游若改 reporter 脚本、`handleAgentEvent` 结尾或休眠条件：保留这三处挂点  

14. **合盖继续运行（Agent 在干活时 Mac 不睡）**  
   - `Glint/Agent/LidAwakeController.swift`：`LidAwakePolicy`（纯判断：在推进不限时、等你回答默认 30 分钟、无进展默认 2 小时、结束后 5 分钟）、`LidSleepEngine`（经 `sudo -n pmset -a disablesleep` 切换，只放开自己置的值）、`LidAwakeController`（5 秒巡检，同时负责把被其他程序改回的开关重新置上）；`Glint/Chrome/LidAwakeSettings.swift`：设置 → Agents 卡片，`SettingsView` 里只有一行挂载；`SidebarUpdateBadges` 的胶囊  
   - 为什么走 `pmset` + sudoers：`caffeinate` / `IOPMAssertion` 只挡闲置，挡不住合盖；本 fork 没有 Team ID，装不了特权 helper。规则文件 `/etc/sudoers.d/glint-lid` 只放行两条固定命令；机器上已有规则放行时（如 Amphetamine 的 PowerProtect）直接用，不弹密码  
   - SleepDisabled 跨重启保留，塞进包里不睡是最要防的：置 1 必须同时起看门进程，起不来就放弃；标记键 `lidAwake.ownsSleepDisabled` 故意不用 `glint.` 前缀（否则会被 seed 进 Debug，开发版启动时会清掉正式版持有的开关）  
   - 放开时盖子是合上的要主动 `pmset sleepnow`：`pmset sleep 0` 的机器不会闲置睡眠。外接显示器、近 2 分钟有输入（远程桌面）、其他程序持有开关时不睡  
   - 进展只看 hook 事件和 Agent 子进程 CPU，不看 Agent 自身 CPU 和终端输出：转圈动画在卡死时也会刷新  
   - `AgentHookInstaller` reporter：Claude 的 `AskUserQuestion` / `ExitPlanMode` 和 Codex 的 `request_user_input` 的 `PreToolUse` 改判 `NeedsReply`，否则等你回答会被当成在跑工具  
   - `Glint/Pane/GhosttySurfaceView.swift`：`foregroundJobIsRunning`（包装脚本启动时前台是 `bash`，不能只看进程名）、`foregroundChildrenCPUNanoseconds`、`cpuNanoseconds`（Apple Silicon 上 `proc_taskinfo` 单位是 Mach tick，要换算）  
   - `AppDelegate.applicationWillTerminate` 开头的 `shutdown()`；`WorkspaceStore` 的 `lidAwakePanes`、`handleAgentEvent` 结尾的 `agentActivityChanged`  
   - 上游给 `PaneAgentStatus` 新增 case 时，`LidAwakePolicy.classify` 这个穷举 switch 要补分支；上游若改 reporter、退出流程或 `handleAgentEvent` 结尾：保留以上挂点  

### 同步操作红线

- **禁止**：`git reset --hard upstream/main`、`git checkout upstream/main -- .`、无审查的 `theirs` 全收、把冲突一律选成上游。  
- **禁止**：合并完成后不跑构建就宣称「已同步」。  
- **必须**：`git fetch upstream` 后 `git merge upstream/main --no-commit --no-ff`（与 `merge-guide.md` 一致）；有冲突 **先分析 → 方案 → 等用户授权 → 再解**。  
- **冲突取舍原则**（看清楚再动）：  
  - **我们独有的功能 / 默认 / 工作流** → **保留 ours**（或在保留行为的前提下手工融合）  
  - **上游新文件、我们没改过的路径** → 可 **接受上游**  
  - **同一处双方都改** → **禁止二选一糊弄**；读上下文，合并语义（例如上游修了 bug、我们加了 AX：两边逻辑都要在）  
  - 拿不准 → **停下来问用户**，不要猜  
- **合并后自检**（最低）：  
  - `git diff --cached --stat` 确认没有误删 `build-dmg.yml` / Grok 资源 / AX 相关改动  
  - Debug 或 CI 能编过；抽查 Grok 入口、终端默认、粘贴/AX 相关路径仍在  

### 推荐同步命令（仅作备忘；真正执行仍先方案后授权）

```bash
git fetch upstream
git merge upstream/main --no-commit --no-ff
# 有冲突 → 按上表 + merge-guide 处理，禁止直接 commit
# 无冲突 → 仍用 git diff --cached 扫一遍二改路径，再按 commit-guide 生成 merge 信息
```

## 项目结构

- `Glint/App/` — 入口（`GlintApp`）、`AppDelegate`、GitHub DMG 更新（`UpdaterController`）、`ReleaseNotes`、`SettingsSafety` 崩溃回滚
- `Glint/Chrome/` — 主壳 UI：侧边栏、设置、命令面板、主题、新建工作区等
- `Glint/Pane/` — 分屏树、Ghostty surface 嵌入、`PaneView`
- `Glint/Ghostty/` — `GhosttyManager`（ghostty 生命周期与配置）
- `Glint/Agent/` — Agent 状态桥、hook 安装、控制 socket、用量
- `Glint/Git/` — Git 服务、监视、刷新协调
- `Glint/Review/` — Diff 审阅窗与语法高亮
- `Glint/Workspace/` — `WorkspaceStore`（大状态机）、`Persistence`
- `Glint/Resources/` — Info.plist、entitlements、`Localizable.xcstrings`、主题、资源
- `GlintTests/` — 单元测试
- `scripts/` — GhosttyKit 下载/发布、签名公证、appcast、资源生成
- `ghostty/` — Ghostty 子模块（默认空，需 `git submodule update --init`）
- `docs/` — 站点截图等（注意：`docs/*.md` 被 gitignore，本地草稿不入仓）
- `project.yml` — XcodeGen 工程描述

## 开发协议

开始任务前，先读与任务匹配的 skill 正文。本文件只是索引，读过本文件不等于读过 skill。

`.claude/skills/` 下的通用件由模板仓库统一同步，不在本项目改；本项目专属的规则写在本文件和 `.claude/skills/protocol-dev/references/project-guide.md`。

- `protocol-dev` — 主工作流：代码 / 文档修改、bug 调试、commit、分支合并、版本发布
- `task-dossier` — 大任务分阶段开发、跨会话续接
- `model-handoff` — 把机械、高 token 的子任务外包给另一个模型（默认 Grok），回收后验收
- `bug-patrol` — 系统化排查 bug 并追踪进度
- `sync-skills` — 把本项目协议适配同步到本机其他仓库

- 生成 commit / merge 信息前，必须读 `.claude/skills/protocol-dev/references/commit-guide.md`；合并分支前必须读 `merge-guide.md`，合并一律 `--no-commit --no-ff`。**同步 `upstream` 时额外遵守「二开与上游同步」**。
- 普通开发只走 `protocol-dev` 这一个主工作流，用户点名的专项 skill 可以叠加。
- 先给方案；用户回复「执行 / 开始开发 / 改吧 / 做吧」后直接实现并验证，不再插入规格文档、计划文档、TDD、代码审查等关卡。
- 未经用户要求，不创建设计文档，不 `git commit`。
- 同一规则多处出现时，以更具体、离当前任务更近的文件为准。需要背景时看名字含「协议 / protocol / 规范」的文档、`README.md`、`project.yml`；涉及可见文案 / 发版时看 `protocol-dev/references/localization-guide.md`、`release-guide.md`（含 `ReleaseNotes.swift` 规则）。

## 红线

- **删除只用 `trash`**：禁止 `rm` / `rm -rf` / `git clean -f`。
- **危险 git 前先备份**：`git reset --hard` / `git checkout -- .` / `git restore` / `git filter-branch` 等可能丢文件的命令，先备份受影响文件。
- **macOS 14.0 底线**：所有 API 必须兼容 macOS 14.0；用更高版本 API 必须 `@available` / `if #available` 并给降级方案。详见 `protocol-dev/references/project-guide.md`。
- **可见文案必须本地化**：面向用户的 UI 文案至少 `en` + `zh-Hans`，同步改 `Glint/Resources/Localizable.xcstrings`。禁止硬编码仅英文可见文本；helper 形参用 `LocalizedStringKey` 而非 `String`。详见 `localization-guide.md`。
- **ReleaseNotes 只在打 tag 那次写**：推版本时才改 `Glint/App/ReleaseNotes.swift` 的 `all`，禁止预先占位。详见 `release-guide.md`。
- **worktree**：新建 worktree 建在项目**同级目录**，命名 `glint--{分支名}`（分支名中的 `/` 换成 `-`），如 `../glint--feat-agent-status/`。禁止用默认 `.git/worktrees` 或项目内部路径。
- **密钥与产物**：禁止提交 `sparkle_priv.key`、`.sparkle/`、`Vendor/GhosttyKit.xcframework`、`dist/`、签名用证书材料。
- **二开保护（同步上游时）**：禁止用上游整仓覆盖本 fork；禁止冲突时无脑选 `theirs` / 上游侧。Grok、Typeless AX、Kaku 默认观感、`build-dmg.yml`、本协议中的二开说明等**必须保留**。详见上文「二开与上游同步」。
