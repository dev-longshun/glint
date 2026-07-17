# Glint（二开 fork）

中文 · [English](README.en.md)

> **这是 [chenbstack/glint](https://github.com/chenbstack/glint) 的二开版本**（本仓：`dev-longshun/glint`），不是官方原版。  
> 面向自己日常使用与开发。上游有更新时可以同步，但**必须保留本 fork 已改的功能与默认**，不能整仓照搬上游。协作细节见仓库根目录 `AGENTS.md` →「二开与上游同步」。

基于 [Ghostty](https://ghostty.org) 的 macOS AI 代理终端（SwiftUI + AppKit）。本 fork 额外包含例如：

- Grok Agent 接入与状态动效  
- 终端无障碍增强（Typeless 等工具可正确写入 / 选中）  
- 更接近 Kaku/MUX0 的默认字体、光标与边距  
- push `main` 自动构建 DMG（GitHub Actions）

## 安装（本 fork）

从本仓库 [Releases](https://github.com/dev-longshun/glint/releases) 下载最新 `Glint-*.dmg`，挂载后拖进「应用程序」。

DMG 内附有 **`首次打开-去除隔离.command`** 与 **`安装说明.txt`**。  
把 App 拖进「应用程序」后双击该脚本即可；也可在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
open /Applications/Glint.app
```

> 官方 Homebrew / 官方 Releases 是上游产物，与本 fork 不是同一条线。需要官方原版请走 [上游仓库](https://github.com/chenbstack/glint)。

## 开发与同步上游

```bash
# 远程约定
# origin   → 本 fork（dev-longshun/glint）
# upstream → 官方（chenbstack/glint）

git fetch upstream
# 合并时务必 --no-commit，逐文件处理冲突；勿 reset --hard 到 upstream
git merge upstream/main --no-commit --no-ff
```

冲突时：**我们独有的改动优先保留**；上游新文件可吸收；同一处双方都改则手工融合。完整清单与红线见 `AGENTS.md`。

## 协议

MIT — 详见 [LICENSE](LICENSE)。上游与本 fork 均基于同一开源许可；本 fork 的额外修改仍遵循 MIT。
