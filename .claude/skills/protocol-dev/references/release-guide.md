# 版本发布规范（Glint）

## 触发条件

用户说"准备发布新版本"、"我要发布新版本"、"出个新版本"、"打 tag"等。

## 核心原则

1. **先谋后动**：查完信息、生成日志后**展示**，等用户确认再改文件 / 打 tag。
2. **不自动发布**：未经用户明确授权，不执行 `git tag` 推送、上传、部署等对外动作。
3. **ReleaseNotes 与 tag 绑定**：只在准备 tag 这个版本的那次 commit 里写 `ReleaseNotes.all`，禁止预先占位。

## 发布渠道概览

- **版本号来源**：Git tag（`vX.Y.Z` 或 `vX.Y.Z-beta.N`），CI 从 tag 推导
- **构建 / 签名 / 公证**：`.github/workflows/release.yml` + `scripts/sign-and-notarize.sh`
- **分发**：GitHub Releases（DMG 等）+ Homebrew cask `chenbstack/glint`
- **应用内更新**：Sparkle + 仓库根 `appcast.xml`（`scripts/update-appcast.sh`）
- **面向用户的 What's New**：`Glint/App/ReleaseNotes.swift` 的 `ReleaseNotes.all`（手写，不依赖 commit / appcast）

## 工作流程

### 第一步：确定版本号

- 查看已有 tag：`git tag --sort=-v:refname | head`
- 按语义化版本决定下一个：正式 `v0.1.26` 或 beta `v0.1.26-beta.1`
- 避免版本回退；hotfix 从旧 tag 切分支时要在方案里写清

### 第二步：生成更新日志

- **技术日志**：`git log <上一个 tag>..HEAD --oneline`，按 type 归类
- **面向用户的发布说明**：从技术日志提炼用户可感知变化，写成 `ReleaseNotes` 的 `en` / `zh` 双语条目（逐条对应）
- 内容是亮点，不是 commit 罗列；隐藏内部重构 / 调试细节

### 第三步：ReleaseNotes 写入规则（强约束）

源规则来自上游 `CLAUDE.md`，必须遵守：

- **只在准备 tag 这个版本的那次 commit 里**往 `all` 顶部加条目 —— 跟 tag/push 同一个 commit、或紧挨着 tag 的前一个 commit。
- **不允许预先开占位条目**（写下版版本号但等以后再填）。一旦版本号跟实际发出去的不一致，占位里的行会被错挂到错误版本（真实案例：#43 / #45 与 0.1.24）。
- **写条目 ⟺ 这个 commit 接下来就要打 tag 推 release**。否则别动 `all`。
- **每发一个 beta**，在 `all` 顶部加一条，`version` 填完整 beta 号（如 `0.1.25-beta.1`），写这个 beta 的增量。
- **正式版不单独写条目** —— 升到 `0.1.25` 时，所有 `0.1.25-beta.*` 会自动聚合成一条「0.1.25」（`aggregatedStableNote`）。只有当某版**没走过 beta**时（直接发正式 / 热修），才在 tag 前给它写一条 bare base 条目。
- **中英一一对应**：`en` / `zh` 两个数组逐条对应（数据、不进 xcstrings，直接双语写）。
- **不要回填已发布的旧版本**；过老条目可删。
- hotfix 分支（从老 tag 切出）条目写在 release 分支上，再同步回 main。

行为摘要：

- beta 用户：看当前 beta；跨 beta 会 catch-up 同周期错过的 beta
- 正式用户：只看正式（聚合）条目，看不到 per-beta 条目
- 详见 `ReleaseNotes.notesToShow` 文档注释

### 第四步：展示并等待确认

展示：

- 新版本号（tag 名）
- 技术日志摘要
- `ReleaseNotes` 草稿（en / zh）
- 将执行的动作清单（改 `ReleaseNotes.swift`、commit、tag、是否 push）

等用户确认后再动文件 / git。

### 第五步：发布动作（仅授权后）

典型顺序（以用户授权范围为准）：

1. 更新 `Glint/App/ReleaseNotes.swift`
2. 用户确认后 commit
3. 打 annotated tag：`git tag -a vX.Y.Z -m "..."`（**push 需再次明确授权**）
4. push tag 触发 `release.yml`：构建 → Developer ID 签名 → notarytool 公证 → 发布产物 → 更新 appcast（以 workflow 实际步骤为准）
5. Homebrew cask 升级若需手工 PR，在方案里单独列出

本地辅助脚本（一般由 CI 或维护者执行，agent 不擅自跑签名）：

- `scripts/sign-and-notarize.sh`
- `scripts/update-appcast.sh`
- `scripts/sparkle-bootstrap.sh`

## 禁止事项

- ❌ 未经确认直接改版本号 / 打 tag / 推送 / 上传
- ❌ 预先在 `ReleaseNotes.all` 占位下一版
- ❌ 版本号回退或跳号而不说明
- ❌ 把内部调试 / 重构细节直接写进面向用户的发布说明
- ❌ 提交 `sparkle_priv.key` 或证书材料
