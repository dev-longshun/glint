# Glint — Agent 协作协议（Claude / Codex 通用）

> 本文件是 Claude 与 Codex 的**唯一协作协议真源**。`CLAUDE.md` 是指向本文件的符号链接，两个 agent 读到的内容完全一致。改协议只改本文件。

## 项目定位

> **本仓库是官方 Glint 的二开 fork，不是上游原版。**  
> - 我们的仓：`dev-longshun/glint`（`origin`）  
> - 上游官方：`chenbstack/glint`（`upstream`）  
> 日常开发、发版、DMG 下载都以本 fork 为准。上游有更新时可以同步，但**绝不能整仓照搬上游**把我们已改的点冲掉。规则见下文「二开与上游同步」。

Glint 是**为 AI 代理打造的 macOS 终端**，底层基于 [Ghostty](https://ghostty.org)（经 `GhosttyKit.xcframework`），界面用 SwiftUI + AppKit。核心能力：多工作区 / 多分屏终端、Agent 生命周期钩子与状态展示（Claude / Codex / Devin / OpenCode / Omp / **Grok** 等）、Git 状态与 diff 审阅、Sparkle 自动更新。

技术架构：

- **App 层（SwiftUI + AppKit）**：窗口壳、侧边栏、设置、命令面板、主题、审阅窗
- **终端层（GhosttyKit C API + AppKit 嵌入）**：`GhosttyManager` 管理 ghostty app/config/surface；`Pane` 系负责分屏树与 surface 承载
- **Agent 层**：hook 安装、状态桥接、用量与 Codex home、外部控制 socket
- **Git 层**：仓库监视、状态刷新、diff 解析
- **依赖**：`Vendor/GhosttyKit.xcframework`（由 `scripts/setup-ghosttykit.sh` 按 submodule SHA 下载，不入库）、Sparkle 2.x（SPM）

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
- **语言 / 技术栈**：Swift 5.10 · SwiftUI · AppKit · 少量 ObjC（`AEBridge.m` + bridging header）· GhosttyKit · Sparkle
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
   - `Glint/Pane/GhosttySurfaceView.swift`：`textArea` 角色、value/selectedText 读取、插入后 `AXValueChanged` 等（对标 MUX0，保证「复制最后的转录」类工具可用）  
   - 上游若改 surface 嵌入，**保留我们的 AX 行为**，再合入对方无关修复  

3. **终端默认观感（对标 Kaku / MUX0）**  
   - `GhosttyManager.applyGlintTheme`：默认 `JetBrains Mono`、`cursor-style = bar`、padding `16`、`adjust-cell-height = 4`、CJK 默认 `LXGW WenKai Mono`（本机已装且用户未显式清空时）  
   - `WorkspaceStore` 同名默认；`FontCatalog` 推荐列表（JetBrains 置顶、CJK 含霞鹜文楷等宽）  
   - 上游若改默认字体/光标/padding：**不得静默退回 SF Mono / block / 旧 padding**，除非用户明确要求  

4. **本 fork 的 CI / 发版**  
   - `.github/workflows/build-dmg.yml`：push `main` → 自动打 DMG + GitHub Release  
   - 不要被上游只保留 `release.yml`（仅 `v*` tag）的结构删掉或覆盖  

5. **协作协议**  
   - 本文件 `AGENTS.md`、技能树、本「二开」章节：上游若无对应内容，**整段保留**  

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

- `Glint/App/` — 入口（`GlintApp`）、`AppDelegate`、Sparkle 更新、`ReleaseNotes`、`SettingsSafety` 崩溃回滚
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

## 启动协议（进入仓库先读什么）

进入本仓库后，agent 必须先读取本协议文件，并按需检查：

- 本文件（`AGENTS.md` / `CLAUDE.md`，同一份软链）
- `.claude/skills/*/SKILL.md` —— skill 唯一真源（Codex 经 `.codex/skills` 软链读同一份）
- 名字含「协议 / protocol / 规范」的文档、`README.md`、`project.yml`
- 涉及可见文案 / 发版时：`protocol-dev/references/localization-guide.md`、`release-guide.md`（含 `ReleaseNotes.swift` 规则）

同一规则多处重复时，以更具体、更靠近当前任务的文件优先。

## 开发协议（自动触发 skill）

开始任何任务前，凡触发条件匹配，必须先读取对应 skill（位于 `.claude/skills/`）：

- `protocol-dev`：开发工作流协议。代码修改、bug 调试、commit 生成、分支合并、文档更新等任务时触发。强制"先给方案、等授权、再执行"。
- `task-dossier`：大任务分阶段开发与跨会话续接。分析新功能思路时自动评估是否需分阶段并推荐建档；开新会话 / 上下文将满时自动总结进度并产出续接启动词。
- `bug-patrol`：系统化排查 bug 时触发。
- `sync-skills`：把本项目协议智能适配同步到本机其他仓库时触发。

## 工作流唯一性（禁用全局 Superpowers）

- 普通开发任务只用本项目 `.claude/skills/protocol-dev` 作为主工作流；用户明确点名的专项 skill 可按需叠加。
- **禁止自动调用全局 Superpowers skill**（`using-superpowers`、`brainstorming`、`writing-plans`、`test-driven-development`、`systematic-debugging`、`verification-before-completion` 等）。仅当用户在当前请求中明确点名某个 Superpowers skill 时，才为该请求使用它。
- 用户方案确认后回复"执行 / 开始开发 / 改吧 / 做吧"，必须**直接进入实现与验证**；不得再插入额外的规格文档、计划文档、TDD、代码审查或文档提交门槛。
- 未经用户明确要求，不得自动创建 / 提交设计文档，也不得自动 `git commit`。

## 关键约束

> 本文件只列**红线**与**skill 索引**，**不是操作手册**。凡某任务有对应 skill/reference，**产出结果前必须先读它，严禁凭本文件的概述直接生成**（commit/merge 信息尤其如此）。

**Skill 自动触发（强制）**：任何任务开始前，必须检查 `.claude/skills/`。触发条件匹配当前任务的 skill 必须先读取再执行，禁止跳过；本文件的任何概述都**不构成「已了解规范」**，不得据以跳过 skill。

**红线（完整、绝对）**

- **禁止永久删除**：禁止 `rm` / `rm -rf` / `git clean -f`，删除必须用 `trash`（进废纸篓可恢复）。
- **危险 git 前备份**：`git filter-branch` / `git checkout -- .` / `git restore` / `git reset --hard` 等可能丢文件的命令前，先备份受影响文件。
- **macOS 14.0 底线**：所有 API 必须兼容 macOS 14.0；用更高版本 API 必须 `@available` / `if #available` 并给降级方案。详见 `platform-compat-guide.md`。
- **可见文案必须本地化**：面向用户的 UI 文案至少 `en` + `zh-Hans`，同步改 `Glint/Resources/Localizable.xcstrings`。禁止硬编码仅英文可见文本；helper 形参用 `LocalizedStringKey` 而非 `String`。详见 `localization-guide.md`。
- **ReleaseNotes 只在打 tag 那次写**：推版本时才改 `Glint/App/ReleaseNotes.swift` 的 `all`，禁止预先占位。详见 `release-guide.md`。
- **worktree**：新建 worktree 建在项目**同级目录**，命名 `glint--{分支名}`（分支名中的 `/` 换成 `-`），如 `../glint--feat-agent-status/`。禁止用默认 `.git/worktrees` 或项目内部路径。
- **密钥与产物**：禁止提交 `sparkle_priv.key`、`.sparkle/`、`Vendor/GhosttyKit.xcframework`、`dist/`、签名用证书材料。
- **二开保护（同步上游时）**：禁止用上游整仓覆盖本 fork；禁止冲突时无脑选 `theirs` / 上游侧。Grok、Typeless AX、Kaku 默认观感、`build-dmg.yml`、本协议中的二开说明等**必须保留**。详见上文「二开与上游同步」。

**必须先读对应 reference 才能产出（严禁凭本文件直接做）**

- **commit / merge 信息** → `.claude/skills/protocol-dev/references/commit-guide.md`（格式结构 · type↔emoji 映射 · Merge 专用 `chore:🔀` 格式 · merge 用 `git diff --cached` 而非 `git diff HEAD`）——不读不得生成。
- **分支合并** → `merge-guide.md` + `commit-guide.md`；合并必须 `--no-commit --no-ff`，未经用户再次明确要求不执行 `git commit`。**同步 `upstream` 时额外遵守「二开与上游同步」**。
- **Bug 调试** → `debug-guide.md`｜**写 macOS/Swift 代码** → `platform-compat-guide.md`｜**可见文案** → `localization-guide.md`｜**方案输出 / 回复格式** → `format-guide.md`｜**标准交互工作流** → `workflow-guide.md`｜**版本发布** → `release-guide.md`｜**构建 / 运行** → protocol-dev「构建与运行规范」
