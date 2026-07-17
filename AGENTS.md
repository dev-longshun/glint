# Glint — Agent 协作协议（Claude / Codex 通用）

> 本文件是 Claude 与 Codex 的**唯一协作协议真源**。`CLAUDE.md` 是指向本文件的符号链接，两个 agent 读到的内容完全一致。改协议只改本文件。

## 项目定位

Glint 是**为 AI 代理打造的 macOS 终端**，底层基于 [Ghostty](https://ghostty.org)（经 `GhosttyKit.xcframework`），界面用 SwiftUI + AppKit。核心能力：多工作区 / 多分屏终端、Agent 生命周期钩子与状态展示（Claude / Codex / Devin / OpenCode / Omp 等）、Git 状态与 diff 审阅、Sparkle 自动更新。

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
- **其他关键配置**：`ghostty` git submodule；`Vendor/GhosttyKit.xcframework` 需 `bash scripts/setup-ghosttykit.sh`；发版走 tag `v*` + GitHub Actions（签名 / 公证 / appcast）

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

**必须先读对应 reference 才能产出（严禁凭本文件直接做）**

- **commit / merge 信息** → `.claude/skills/protocol-dev/references/commit-guide.md`（格式结构 · type↔emoji 映射 · Merge 专用 `chore:🔀` 格式 · merge 用 `git diff --cached` 而非 `git diff HEAD`）——不读不得生成。
- **分支合并** → `merge-guide.md` + `commit-guide.md`；合并必须 `--no-commit --no-ff`，未经用户再次明确要求不执行 `git commit`。
- **Bug 调试** → `debug-guide.md`｜**写 macOS/Swift 代码** → `platform-compat-guide.md`｜**可见文案** → `localization-guide.md`｜**方案输出 / 回复格式** → `format-guide.md`｜**标准交互工作流** → `workflow-guide.md`｜**版本发布** → `release-guide.md`｜**构建 / 运行** → protocol-dev「构建与运行规范」
