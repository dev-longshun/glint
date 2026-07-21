# 回复格式规范

## 禁止使用 Markdown 表格

由于对话框不支持表格渲染，所有需要对比或列举的信息，请使用以下替代格式：

- **列表形式**：用无序列表或有序列表展示
- **分组描述**：用加粗标题 + 缩进描述的方式
- **对比格式**：使用 `A vs B` 或分段描述的方式

## 功能对比示例（禁止用表格）

**方案 A**
- 特性 1：✅ 支持
- 特性 2：⚠️ 需额外工作

**方案 B**
- 特性 1：❌ 不支持
- 特性 2：✅ 支持

## 文件修改清单格式

需要修改的文件：

- `路径/文件`：修改说明

## 方案输出规范

在提出技术方案时，文件清单必须遵循以下格式：

### 新增文件

标注完整路径（从项目根目录开始）和说明；并注明构建系统登记方式：

- `Glint/<Module>/Foo.swift`：说明
  - 构建登记：优先落在 `Glint/` 目录树内（`project.yml` 以 `path: Glint` 收录）。若工程由 XcodeGen 管理且 pbxproj 需同步，改完后提醒执行 `xcodegen generate` 并核 diff；若直接维护 `Glint.xcodeproj`，提醒加入 **Glint** target 并确认 Target Membership
- `GlintTests/FooTests.swift`：说明
  - 构建登记：加入 **GlintTests** target
- `scripts/*.sh` / 纯资源：一般无需改 target，说明脚本用途即可

### 修改文件

同样标注完整路径：

- `Glint/Chrome/SettingsView.swift`：说明
- `Glint/Resources/Localizable.xcstrings`：补 zh-Hans（若有新文案）

### 执行后提醒

创建新 Swift 文件后，必须提醒用户：

1. 确认文件在 **Glint**（或 **GlintTests**）target 的 Target Membership 中
2. 若本轮改了 `project.yml` 的 sources/settings，执行 `xcodegen generate` 并 review `Glint.xcodeproj` diff
3. 涉及用户可见文案时，确认 `Localizable.xcstrings` 已更新
