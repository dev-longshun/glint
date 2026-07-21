# 平台 / 版本兼容性规范 (The "VERSION-CHECK" Rule)

在编写任何 macOS / SwiftUI / AppKit / GhosttyKit 代码之前，**必须先确认项目的最低支持版本**，避免使用不兼容的 API。

## 当前项目配置

- **最低支持版本**：macOS 14.0
- **配置位置**：`project.yml` 的 `deploymentTarget.macOS` / `MACOSX_DEPLOYMENT_TARGET`；`Glint.xcodeproj/project.pbxproj` 中的 `MACOSX_DEPLOYMENT_TARGET`
- **Swift 版本**：5.10
- **Bundle ID**：正式 `app.glint.Glint`；Debug `app.glint.Glint.dev`

## 强制检查流程

1. **方案设计阶段**：提出技术方案时，如涉及较新的 SwiftUI / AppKit / Foundation API，必须确认其最低支持版本
2. **编码阶段**：使用的所有 API 必须兼容 macOS 14.0
3. **如需使用新版本 API**：必须用 `@available` / `if #available` 做可用性检查，并提供降级方案

## 常见"高版本 API → 降级写法"（按项目维护）

> 在此积累实际踩过的版本坑。

### macOS 15+ 才支持（禁止直接裸用，须 availability 或降级）

- 使用前查 Apple 文档确认 availability，并在方案里写明降级路径

### macOS 14 可用（本项目基线）

- `@Observable` 宏 ✅（macOS 14+）
- `NavigationSplitView` / `NavigationStack` ✅
- SwiftUI 主流布局与 sheet / alert API ✅

### GhosttyKit / 原生桥接

- 调用 `GhosttyKit` C API 前确认符号来自当前 `Vendor/GhosttyKit.xcframework`，勿假设本地 zig 新构建接口
- 改 `ghostty` submodule 后必须走 `scripts/setup-ghosttykit.sh` / `publish-ghosttykit.sh` 对齐预构建包，禁止在 App 侧硬编码未发布的 C API

### Debug vs Release 行为

- Debug 使用独立 bundle id 与偏好域；首次启动会从生产域 seed `glint.*` 键（见 `GlintApp.init`）
- 改偏好键 / 持久化路径时，确认不会在 dev/prod 之间互相污染

## 🚫 严禁行为

- ❌ 不查版本直接使用新 API
- ❌ 假设用户运行最新系统
- ❌ 编译报错后才发现版本不兼容
- ❌ 在未更新 GhosttyKit 预构建的情况下依赖 submodule 新 C API

## ✅ 正确做法

- ✅ 方案设计时主动说明 API 兼容性
- ✅ 优先选择兼容 macOS 14 的实现
- ✅ 必须用更高版本 API 时，提前告知并提供降级方案

## 渐进式增强策略

1. **基础功能保障**：macOS 14 用户能使用核心能力（工作区、分屏终端、Agent 状态、Git 审阅、更新）
2. **高版本专属功能**：可仅在 macOS 15+ 可用，但需明确告知、说明低版本降级（隐藏入口 / 简化实现）、评估价值 vs 覆盖率
3. **决策参考**："锦上添花"可仅限高版本；"核心体验"必须兼容或提供替代
