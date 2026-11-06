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

## 外部控制 CLI

在设置 → 终端 → 外部控制中，点击「安装 CLI」会创建 `~/.local/bin/glint` 链接；必要时将 `~/.local/bin` 加入 `PATH`。CLI 随应用打包，无需 Node.js、Python 或 MCP。「复制 Agent 使用说明」可复制包含完整 CLI 路径的操作说明，不安装链接也能使用。

已安装时设置页显示状态并禁用重复安装，可点击「卸载」移除命令链接；命令行也支持 `glint uninstall`。卸载不会删除应用内的 CLI，也不会修改控制开关。应用移动后，指向已不存在 Glint 安装位置的悬空链接可重新安装修复或卸载。指向另一份现存 Glint 的正常链接会单独显示，安装或卸载不会更改该链接；其他程序的文件和链接也不会被覆盖。

安装与控制授权相互独立。必须开启「允许外部控制」才能读取、输入或聚焦终端；关闭立即撤销访问，重新开启后旧连接和旧令牌仍不可用。CLI 不会自动启动 Glint 或开启控制。

```sh
glint --help
glint panes list
glint pane read '<pane-id>' --scrollback --max-lines 1000
glint pane send '<pane-id>' --text 'pwd' --enter
glint pane key '<pane-id>' down enter
```

`<pane-id>` 使用列表返回的完整标识。普通读写不会切换本地工作区；只有显式 `glint pane focus '<pane-id>'` 才切换。读取默认返回纯文本，可加 `--json`；其他命令返回 JSON。开发版使用 `glint --debug …`。也可直接运行 `/Applications/Glint.app/Contents/Helpers/glint`，或执行该程序的 `install` 子命令安装链接。

CLI 可直接读写已就绪的后台终端，也可唤醒没有待恢复历史或启动任务的终端，不切换本地工作区。

**重启后的后台访问限制：**滚动历史恢复默认开启。应用重启后，后台 pane 若有待恢复存档，CLI 的读取与输入都会返回 `pane-requires-local-open`，需要先在 Glint 中打开该终端、完成恢复后再操作；不带 `--scrollback` 的读取也受此限制。因此，本版本不能直接通过 CLI 唤醒所有重启后有存档的后台终端。Web 仍可按浏览器指定网格完成历史恢复。

若终端有待执行的一次性启动命令或 agent 自动恢复，CLI 和 Web 也会提示先在 Glint 中打开，不会在无本地视图时隐式执行这些命令。

自定义 `--socket` 要求目录归当前用户所有且权限为 0700，socket 和 token 文件归当前用户所有且权限为 0600；token 不可为软链接。编码后的单条请求最多 1 MiB，超限会返回明确错误。

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
