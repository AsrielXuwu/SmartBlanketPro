# 智能电热毯 iOS 原生 App — Apple iOS 26/27 Liquid Glass（液态玻璃）官方原生 UI 设计规范与执行流程

本规范严格遵循 **Apple WWDC25 / WWDC26 (iOS 26 / iOS 27 SDK)** 官方 **Liquid Glass（液态玻璃）** 设计规范与《Adopting Liquid Glass》官方开发准则，必须使用 **Xcode 26 (`iPhoneOS26.sdk`)** 编译，彻底摒弃旧版 iOS 17/18 的自定义 `.regularMaterial` 伪毛玻璃卡片、自定义渐变描边与自定义背景色。

---

## 一、 iOS 26/27 Liquid Glass 核心设计铁律（Apple HIG Official Rules）

### 1. 「内容沉入底层，控制与导航漂浮于液态玻璃层」（Content vs. Floating Glass Layer）
- **严禁覆盖系统背景**：全局严禁使用 `.background(Color(.systemGroupedBackground))` 或任何自定义渐变/图片背景。必须完全交由 iOS 26/27 系统底层自动渲染背景延伸（Background Extension）与滚动边缘折射（Scroll Edge Effect）。
- **严禁手写伪毛玻璃卡片**：彻底废除用 `.regularMaterial` + `LinearGradient` 描边 + `.shadow` 模拟旧版卡片的做法。大面积内容列表必须直接使用原汁原味的 SwiftUI `List`（`.insetGrouped`）与 `Section`，让系统的原生控件（液态玻璃滑块 `Slider`、液态玻璃开关 `Toggle`、原生分段选择器 `Picker`）直接承载表单内容。
- **真正使用原生 `.glassEffect` 与 `GlassEffectContainer`**：
  - Liquid Glass 材质（`.glassEffect(_:in:)`）专门用于**悬浮控制面板（Floating Control Chrome）**、**双温区动态融合状态舱（Morphing Thermal Orbs）**、**快捷定时胶囊组**以及**悬浮底部操作坞（Floating Bottom Action Dock）**。
  - 所有相邻的液态玻璃元素必须包裹在同一个 **`GlassEffectContainer(spacing:)`** 中，使它们共享光学采样区域（Lensing & Refraction），并在靠近或状态变化时像真实水滴一样无缝融合与分离。

### 2. 原生 iOS 26/27 专有控件与 API 规范清单
| 组件层级 | 必须使用的 iOS 26/27 原生 SwiftUI API | 视觉与交互行为 |
| :--- | :--- | :--- |
| **顶层导航架构** | `TabView` + `Tab("标题", systemImage:)` + `.tabBarMinimizeBehavior(.onScrollDown)` | iOS 26/27 标志性的悬浮胶囊液态玻璃底栏，向下滚动列表时自动优雅收缩最小化 |
| **顶部液态玻璃工具栏** | `.toolbar` + `ToolbarItem(placement: .primaryAction)` + `ToolbarSpacer(.fixed)` | 系统自动将工具栏按钮包裹在悬浮液态玻璃胶囊中，`ToolbarSpacer(.fixed)` 实现原生玻璃分组隔离 |
| **多玻璃融合与形变容器** | `GlassEffectContainer(spacing: 16)` + `@Namespace` + `.glassEffectID(_:in:)` | 当用户切换「双温区同步调节」或开关电源时，左右两个独立的液态玻璃温区球通过 `glassEffectID` 产生物理级流体合并/分裂形变（Morphing） |
| **自定义悬浮玻璃表面** | `.glassEffect(.regular.tint(color).interactive(), in: .rect(cornerRadius: 24))` / `.capsule` / `.circle` | 具备边缘光线折射（Lensing）、触控点实时高光扩散（Interactive Illumination）与按压弹性缩放 |
| **原生液态玻璃按钮** | `.buttonStyle(.glass)` 与 `.buttonStyle(.glassProminent)` | 所有普通操作按钮统一使用 `.buttonStyle(.glass)`，主电源/确认动作使用 `.buttonStyle(.glassProminent)` |
| **表单与温控滑块** | 原生 `List` + `Section` + `Slider(value:in:1...9, step: 1)` + `Toggle` + `Picker` | 在 iOS 26+ SDK 编译下，`Slider` 滑块在拖动时自动化身透明液态水滴透镜，`Toggle` 切换时同样呈现液态玻璃折射 |

---

## 二、 三大原生页面结构与交互流程（App Architecture）

### 1. Tab 1：温控中心（`DeviceControlView` — 核心液态玻璃交互页面）
- **顶部液态玻璃工具栏（Floating Glass Toolbar）**：
  - 左侧/中部：当前电热毯切换菜单（支持多设备一键切换）；
  - 右侧：使用 `ToolbarSpacer(.fixed)` 分隔的「立即同步状态」与「扫描添加设备」原生玻璃工具栏按钮。
- **模块 1：双温区液态玻璃流体形变状态舱（`GlassEffectContainer` + Morphing `.glassEffectID`）**：
  - 置于 `List` 顶部 Section（清空 Section 默认底色 `.listRowBackground(Color.clear)`），内部由 `GlassEffectContainer(spacing: 16)` 承载：
  - **独立双区态（`syncDualZones == false`）**：并列呈现「左温区 (`glassEffectID("leftZone")`)」与「右温区 (`glassEffectID("rightZone")`)」两块独立的 `.glassEffect(.regular.tint(zoneColor).interactive(), in: .rect(cornerRadius: 24))` 液态玻璃晶体，实时显示 `18°C ~ 45°C` 圆体大字与 `1 ~ 9 挡`；
  - **双区同步态（`syncDualZones == true`）**：当用户开启「双温区同步调节」时，在 `GlassEffectContainer` 作用下，左右两块液态玻璃通过 fluid morphing 无缝融合为一块通栏双区同步液态玻璃舱（`glassEffectID("unifiedZone")`）！
  - 状态舱下方并列展示两个紧凑的液态玻璃胶囊（`.glassEffect(.regular.interactive(), in: .capsule)`）：**「本次已开启时长（如 `已开启 1h 25m`）」** 与 **「自动关机/预约开机倒计时」**。
- **模块 2：底部悬浮液态玻璃主控坞（`.safeAreaInset(edge: .bottom)` + `GlassEffectContainer`）**：
  - 悬浮在列表上方的 iOS 26/27 原生风格快捷控制条：
  - 左侧：大尺寸主电源开关按钮（`.buttonStyle(.glassProminent)` + `.tint(device.isOn ? .orange : .blue)`）；
  - 中部：一键切换「普通加热 / 2h 高温除螨」按钮（`.buttonStyle(.glass)`）；
  - 右侧：一键切换「双区同步 / 独立调温」圆形玻璃按钮（`.buttonStyle(.glass)`）。
- **模块 3：原生 `List` 分区挡位与定时控制（100% 纯系统 `List` + `Section`）**：
  - **温区挡位调节 Section**：使用 iOS 26/27 原生 `Slider(value:in: 1...9, step: 1)`（拖动时呈现官方液态水滴滑块）配合 `.buttonStyle(.glass)` 的 `-` / `+` 微调按钮；
  - **工作模式与联动 Section**：原生 `Picker`（`.segmented` 样式）切换「普通加热」与「除螨模式 (2h 45°C)」，原生 `Toggle` 控制「双温区同步调节」；
  - **定时关机与预约开机 Section**：原生 `Picker` 设置「自动关机定时 (1~12h)」与「预约定时开机 (关闭 / 1~12h)」，下方提供一行包裹在 `GlassEffectContainer(spacing: 8)` 中的 `.buttonStyle(.glass)` 快捷定时胶囊（`2h / 4h / 6h / 8h / 10h / 12h`）。

### 2. Tab 2：状态与时长（`RuntimeStatusView` — 设备实时遥测与开启小时数看板）
- 顶部采用 `GlassEffectContainer(spacing: 14)` 展示两枚液态玻璃统计徽章：**「本次已开启小时数」** 与 **「历史累计开启总小时数」**（所有数字绑定 `.contentTransition(.numericText())`）。
- 下方采用纯正 iOS 原生 `List` + `Section` + `LabeledContent` 展示：
  - 当前工作状态、左右温区实时标称温度与挡位；
  - 本次已开启精确时长（小时 + 分钟）、剩余自动关机倒计时、剩余预约开机倒计时；
  - 历史累计开启总时长（小时）、累计开机次数；
  - 蓝牙直连策略（智能极速唤醒省电模式 / 常连实时同步）、开机自动恢复上次挡位记忆开关（0.35s 延时恢复）、GATT 指令往返耗时（`ms`）、RSSI 信号强度与硬件 MAC 密钥源。

### 3. Tab 3：设备列表（`DeviceListView` — 多设备管理与蓝牙扫描发现）
- 使用纯正 iOS 原生 `List`（`.insetGrouped`）管理所有已保存的电热毯设备。
- 每行展示设备名称、房间标签、实时温度/已开启时长摘要，右侧配備 `.buttonStyle(.glassProminent)` / `.buttonStyle(.glass)` 原生液态玻璃电源快控按钮。
- 支持原生左滑（`.swipeActions`）编辑名称/房间/硬件 MAC 或删除设备；右上角工具栏按钮弹出原生 `.sheet` 蓝牙扫描抽屉（`ScannerSheetView`），自动从 `0x5700` 14 字节广播包提取真实硬件 MAC 地址并实现 `retrievePeripherals` 0.15 秒零扫描极速直连。
