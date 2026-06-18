# 方案:Glint 对外终端控制接口(External Pane Control)

> 状态:**已实现**(2026-06-18 落地并端到端验证 —— 见 `Glint/Agent/ControlBridge.swift`)
> 作者:beichen · 起草于 2026-06-18

## 0. 一句话

把 Glint 变成一个**可被本机其它程序遥控的终端** —— 暴露一条稳定的本地 socket 控制协议,
让第三方(MioIsland / 我们自己的手机端 / 自动化脚本 / menubar 工具)能够**聚焦某个 pane、
往里注入文本与按键**。我们只维护协议,**不主动适配任何一家**,谁要接谁照协议接。

## 1. 背景与缘起

起因是评估能否跟 [MioIsland / ClaudeIsland](https://github.com/MioMioOS/MioIsland) 联动 ——
一个给 Claude Code 提供"动态岛"式监控 / 批准 / 跳转、并能与 iPhone 双向同步的 macOS app。
它的卖点是**远程批准 agent 操作**和**跳转到对应会话**,这正好需要"操控终端"的能力。

核心结论先行:

- **现有的 `agent.sock` 帮不上忙。** 它是单向入站、只收 Claude/Codex 的 hook 事件
  (`{"pane","hook","agent"}`),用来驱动侧栏状态;**没有反向命令通道,也从不往终端注入任何东西**。
  它和 MioIsland 的 `/tmp/codeisland.sock` 其实是**同一种东西**(都是 hook 事件汇聚点),是竞争关系,不是互补。
- **要被外部操控,缺的是另一条通道** —— 一个"入站收命令、能驱动 pane"的接口。这就是本方案。

### 战略立场:我们做平台,不做适配器

不主动去兼容 MioIsland 的私有约定。我们对外发布一份**公开、稳定、自有**的控制契约,
第三方主动来适配。好处:

- 不绑死任何一家;同一套接口我们自己也能用(手机遥控、自动化、别的 UI 外壳)。
- 协议由我们掌握、稳定演进。
- 不用替别人维护"找我们二进制 / 猜我们窗口"的脏活。

## 2. 参考:MioIsland 如何控制 cmux

cmux 之所以能被 MioIsland 白嫖控制,是因为 **cmux 本身就被设计成可遥控**,对外暴露了三样东西。
这正是我们要复刻的部分(基于 MioIsland 源码 commit 阅读):

| 能力 | cmux 提供什么 | MioIsland 怎么用 |
|---|---|---|
| **寻址** | 启动 shell 时 export `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` 进 env | hook 脚本 `codeisland-state.py:153` 从 `os.environ` 读出,塞进上报 JSON |
| **注入** | `cmux` CLI 二进制的 `send` / `send-key` 子命令 | `TerminalWriter.swift` shell-out:`cmux send --workspace <w> --surface <s> -- "<text>\r"`、`cmux send-key … -- enter` |
| **聚焦** | cmux 原生 AppleScript 字典(`focus terminal` / `activate`) | `TerminalJumper.swift:236` 按 surface id 聚焦,兜底 `tell application "cmux" to activate` |

要点:

- env 变量必须由 **hook 在 pty 内**读取 —— macOS 对 hardened-runtime 进程隐藏 env,
  事后 `ps -E` 拿不到(MioIsland 在 `codeisland-state.py` 注释里专门说明了这点)。
- MioIsland 的注入路径 `sendViaCmuxDirect`(`TerminalWriter.swift:828`)是**纯 cmux 专用**的:
  `findCmuxTarget` 找不到 cmux target 就直接 `return false`("non-cmux terminal")。
  **它没有"往任意前台终端硬敲键盘"的通用兜底** —— 认死了 `cmux send` 这一个 CLI。

## 3. 现状差距

cmux 那三样,Glint 现在的状态:

| 能力 | cmux | Glint 现状 |
|---|---|---|
| 寻址 id 进 env | `CMUX_SURFACE_ID` | ✅ 有 `GLINT_PANE_ID`(`GhosttySurfaceView.swift:300`),**但名字不同,外部默认不认** |
| 注入入口 | `cmux send/send-key` CLI | ❌ 无对外接口(只有进程内 `ghostty_surface_text/_key`) |
| 聚焦入口 | AppleScript 字典 | ❌ 无 AppleScript / 无 URL scheme(`Info.plist` 无 `CFBundleURLTypes`) |

由此可推出两个关键判断:

1. **光在 env 里放 `GLINT_PANE_ID` 不够。** 一次握手要三步 —— 读 id、知道往哪发、能路由进来 ——
   env 只占第一步,后两步都在主控方代码里。MioIsland 现在这三步全冲着 cmux 写死,对 Glint 一无所知。
2. **所以纯靠现状,外部找不到、也碰不到我们的 pane。** 必须我们这边补一条可寻址 + 能注入的入口。

## 4. 方案:Glint 控制 socket

新增一条**独立于 `agent.sock`** 的控制通道。
关键架构优势:控制 sock 是**被运行中的 Glint 进程本身**接收的,所以聚焦可以直接驱动自己的 UI ——
**注入 + 聚焦 + 查询三件事一个通道全包**,不需要 AppleScript、不需要 URL scheme(比 cmux 的"注入走 CLI、
聚焦走 AppleScript"两套还干净)。

### 4.1 端点

- 路径:`~/.glint/run/control.sock`(Debug 构建用 `control-debug.sock`,与 prod 隔离,同 `agent.sock` 的做法)
- 父目录 `~/.glint/run/` 0700,socket 文件 0600
- AF_UNIX / SOCK_STREAM

### 4.2 线协议

行分隔 JSON,**一问一答**(区别于 `agent.sock` 的只进不出):

```jsonc
// 聚焦/跳转:切到对应 workspace + tab + pane,并 activate 窗口
>> {"cmd":"focus","pane":"<GLINT_PANE_ID>"}
<< {"ok":true}

// 注入文本:默认【不】自动回车(避免误触发)
>> {"cmd":"send-text","pane":"<id>","text":"yes"}
<< {"ok":true}

// 合并:文本 + 回车一条命令搞定(等价 send-text 后再 send-key enter,省一次往返)
//   enter 可选、默认 false;保留"默认不回车"的安全姿势,要回车显式开
>> {"cmd":"send-text","pane":"<id>","text":"yes","enter":true}
<< {"ok":true}

// 注入按键:批准/拒绝/方向键等,白名单
>> {"cmd":"send-key","pane":"<id>","key":"enter"}
<< {"ok":true}

// 合并:一条命令注入一串按键序列(批准流程常见的"↓↓enter"等)
//   keys 取代单数 key;按数组顺序依次注入,任一不在白名单则整条拒绝
>> {"cmd":"send-key","pane":"<id>","keys":["down","down","enter"]}
<< {"ok":true}

// 发现/诊断:列出所有 pane(让接入方拿到 GLINT_PANE_ID 与状态)
>> {"cmd":"list"}
<< {"ok":true,"panes":[{"pane":"<id>","title":"…","cwd":"…","agent":"thinking"}]}

// 认证:token 无状态逐命令携带(不是连接级握手)—— 受限命令(send-*)必带,见 §4.4
>> {"cmd":"send-key","pane":"<id>","key":"enter","token":"a1b2c3…"}
<< {"ok":true}

// 错误形态
<< {"ok":false,"error":"unauthorized"}
//  bad-request | unknown-cmd | unknown-key | unknown-pane | pane-not-ready | unauthorized
//  pane-not-ready:pane 存在但其 surface 尚未渲染(后台 tab/workspace);先 focus 再重试
```

- **寻址 key** = hook env 里的 `GLINT_PANE_ID`,格式 `<workspace-uuid>:<pane-seq>`。
  这是接入方需要遵守的**唯一**"我们这边的约定" —— 在 hook 里读它、当句柄回传即可。
- **send-key 白名单**(初版):`enter` `esc` `tab` `up` `down` `left` `right` `space`,
  以及单字符 `y/n/1/2/…`。不开放任意 raw keycode,缩小注入面。

### 4.3 与现有 hook 链路的关系

- `agent.sock`(`AgentBridge`):保持不变,仍只收 hook 事件、驱动侧栏状态。
- `control.sock`(新增 `ControlBridge`):只收命令、驱动 pane。
- 两者共用 `GLINT_PANE_ID` 作为 pane 句柄,语义一致。

### 4.4 认证(token)与命令分级

token 设计为**无状态**:不做连接级握手,**每条命令各自携带可选 `token` 字段**,服务端逐条校验。
好处 —— 连接可随时断开重连、客户端无需维持会话状态、并发多连接互不影响、不存在
"握手通过后连接被复用 / 劫持"的窗口。

- **token 来源**:Glint 每次启动生成一段高熵随机串,写入 `~/.glint/run/control.token`
  (0600,Debug 用 `control-debug.token`);进程退出即失效。能读到它 ≈ 已具备
  "以你的身份读你的私密文件"的能力,信任门槛因此从「能连 socket」抬到「能读你的文件」。
- **校验**:常量时间比较(避免 `==` 提前返回的时序侧信道,认证代码的肌肉记忆)。

按危险度分级,**是否要 token 取决于命令、不取决于连接**:

| 命令 | 影响 | token |
|---|---|---|
| `focus` | 只切窗口,无副作用 | 不要求 |
| `list` | 暴露 cwd/title(信息泄露) | 不要求*(可选收紧) |
| `send-text` / `send-key` | **改系统状态(注入)** | **必须** |

\* `list` 默认放宽换取发现便利;若在意信息暴露面,可配置为同样要求 token(见 §6)。

受限命令缺失或 token 不匹配时一律回 `{"ok":false,"error":"unauthorized"}`,**不执行任何副作用**。

## 5. 实现要点(若决定做)

可行性已确认 —— 内部零件齐全,这是"接管线"而非"造能力"。涉及 5 处,都在已有结构上接线:

1. **新建 `Glint/Agent/ControlBridge.swift`** —— 照搬 `AgentBridge` 的 socket 搭建
   (0700 目录 / 0600 / Debug 分文件名),但改成一问一答:解析命令 → 派发 → 回 JSON。
2. **`GhosttySurfaceView` 暴露注入入口** —— 加 `inject(text:)` / `inject(key:)`,
   内部复用现有 `ghostty_surface_text` / `ghostty_surface_key`(现仅服务于 private 的 paste 路径,
   抽一个公开方法)。
3. **`WorkspaceStore` 加解析 + 派发** —— `GLINT_PANE_ID`("uuid:seq")→ `WorkspacePaneKey`
   → 现成的 `surfaceViews[key]`(`WorkspaceStore.swift:667`)→ 注入;
   `focus` 走现成 `focus(_:)`(`:1317`)+ `NSApp.activate`。
4. **`AppDelegate` 启动时 `ControlBridge.shared.start()`** —— 与现有 agent bridge 并列。
5. **写 `docs/control-protocol.md`** —— 面向第三方的**成品协议文档**(本文件是内部设计;那份是对外契约)。

关键已知量(已核实):

- `surfaceViews: [WorkspacePaneKey: GhosttySurfaceView]` —— id→活 surface 登记表已存在。
- `WorkspacePaneKey { workspace: UUID, pane: PaneID }`,与 `GLINT_PANE_ID` 格式一一对应。
- `focus(_ id: PaneID)`、`ghostty_surface_text/_key` 均已存在。

## 6. 安全模型

- **默认关闭(opt-in)**:整条控制 socket 由设置里的「External control」开关控制,**默认关**。
  关闭时根本不 bind socket、磁盘上也无 socket/token 文件(`reapStale` 清掉残留);
  开/关**立即生效**(`externalControlEnabled` 的 didSet 直接 start/stop,无需重启)。
  这是最外层闸门 —— 没打开就完全没有攻击面。
- **本机隔离**:沿用 `agent.sock` 同款姿势 —— 0700 父目录把 socket 锁死在当前用户,
  本机其它用户够不着。
- **新增风险**:注入按键比收事件危险得多 —— 任何能连上这条 sock 的**同用户**进程都能往你终端打字。
  0700 目录挡住的是"别的用户",挡不住"同用户的恶意进程"。
- **缓解(分级)**:无状态 `token` + 命令分级,**首版就做**(见 §4.4)。两层叠加 ——
  0700 挡"别的用户",token 挡"同用户里读不到 token 文件的进程"。
- **为何无状态而非握手**:token 跟着每条命令走、服务端逐条验,不维护"已认证连接"状态 ——
  少一份会话状态、断线重连零成本、且不给"握手后连接被复用 / 劫持"留窗口。
- **`list` 的取舍**:它把所有 pane 的 cwd/title 暴露给本机任何能连 sock 的进程。
  对第三方发现很有用,但也是信息泄露面。可选择默认关闭、或纳入 token 门槛。

## 7. 待决问题(决策点)

实现前需要拍板:

1. **要不要做?** MioIsland 在状态监控这块跟我们侧栏高度重叠,它真正的增量只有 **iPhone 远程**。
   如果不在乎手机远程遥控,这个接口的对外价值有限 —— 但**自用价值**(脚本化、自动化、自研遥控)依然成立。
2. **协议定稿** —— 尤其:
   - `send-text` 默认不自动回车 —— 倾向方案:**默认 false + 可选 `enter:true` 合并**
     (保留安全默认,又省一次往返),确认即可定稿。
   - `send-key` 是否支持 `keys` 数组(序列合并)—— 倾向支持,白名单逐项校验。
   - `list` 命令留不留(发现便利 vs 信息暴露)?
3. **安全级别** —— 已定:首版即上无状态 token + 命令分级(§4.4);剩下只是 `list` 要不要也纳入 token。
4. **推进方式** —— 自己先把接口做出来发布,等第三方来接;还是先拿协议草案去对一对
   MioIsland 的接入意愿再投入。

## 8. 工作量评估

小。无底层改动、无新依赖、无二进制要 ship(选了"纯 sock JSON 协议"形态,
绕开了 MioIsland 在 `CmuxBinary.swift` 里为"到处找 cmux 二进制"头疼的整摊事)。
主要是一个 ~150 行的 `ControlBridge` + 几处接线 + 一份协议文档。

## 附:为什么不选其它形态

- **附带 `glint` CLI**(像 `cmux send`):第三方 shell-out 最顺手,但我们要多维护一个二进制 +
  "到处找 CLI 路径"的解析(MioIsland 的 `CmuxBinary.swift` 整个文件都在干这个)。不值。
- **只做 URL scheme**:`open glint://focus?pane=…` 实现最小,但注入大段文本 / 按键序列不优雅,
  且 MioIsland 的"远程批准"(需要 send-key)接不了 —— 只能监控 + 跳转。
- **伪装成 cmux**(env 改 export `CMUX_*` + ship 兼容 `cmux send` 的 shim):注入能骗通,
  但聚焦那条走 `tell application "cmux"` + bundle id `com.cmuxterm.app`,伪装不了;脆且脏。
