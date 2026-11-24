# 智能电热毯 iOS 原生 App — Apple iOS 26/27 Liquid Glass UI 设计规范与执行流程

本设计规范严格遵循 **Apple Human Interface Guidelines (HIG)** 与 **iOS 26/27 Liquid Glass（液态玻璃）** 视觉语言，吸收 Apple 官方「家庭 (Home)」App 的气候控制（Climate Control）与配件详情弹窗交互范式。所有界面编码必须在动工前以此规范为唯一准绳，严禁引入任何非原生异形控件、杂乱渐变背景或第三方 UI 库。

---

## 一、 核心设计哲学（Core Design Philosophy）

### 1. 纯正原生感（100% Apple Native Authenticity）
- **零自定义杂乱背景**：全局背景严格采用系统语义化背景色 `Color(.systemGroupedBackground)` 与 `Color(.secondarySystemGroupedBackground)`，完美自适应 iOS 浅色模式（Light Mode）与深色模式（Dark Mode）。
- **原生容器与导航架构**：使用 `NavigationStack`、`.navigationTitle`、`.toolbar`、`List`（`.insetGrouped` 样式）、`Section` 及 `.sheet` 模态抽屉（搭配 `.presentationDetents([.medium, .large])` 与 `.presentationDragIndicator(.visible)`），确保手势返回、大标题折叠与系统级弹窗阻尼与 iOS 系统设置及「家庭」App 完全一致。
- **原生交互控件**：所有开关、挡位调节、模式切换、定时设置均采用 SwiftUI 原生 `Toggle`、`Slider`、`Picker`（`.segmented` / `.menu`）与 `Stepper`，拒绝花哨拼凑的第三方旋钮或拟物化仪表盘。

### 2. iOS 26/27 液态玻璃材质体系（Liquid Glass Material System）
- **材质分层（Material Hierarchy）**：
  - **一级悬浮状态舱（Hero Status Capsule & Floating Action Bar）**：采用 `.ultraThinMaterial` 或 `.regularMaterial` 液态毛玻璃基底，叠加极其克制的微光折射高光（Specular Rim Border：顶边与左边 `0.28` 透明度白色至底边 `0.06` 透明度的 `0.5pt` 线性渐变描边）。
  - **动态热力环境折射（Subtle Thermal Ambient Tint）**：液态玻璃卡片内部仅在电热毯处于开机加热状态时，于玻璃层底部注入低饱和度（Opacity `0.08 ~ 0.14`）的语义热力柔光（低温区柔琥珀色 `.orange`、高温/除螨区暖珊瑚红 `.red`、待机态冰川灰 `.secondary`），不破坏系统背景的纯净度。
  - **连续曲率圆角（Continuous Squircle Corners）**：所有玻璃卡片与分组容器统一使用 Apple 连续曲率圆角 `RoundedRectangle(cornerRadius: 22, style: .continuous)`（内嵌子控件采用 `14pt` 连续圆角），实现与 iOS 26 控制中心模块一致的流体边缘。

### 3. Apple 官方无缝动效与触觉反馈（Seamless Motion & Haptics）
- **数字流体滚动（Numeric Text Content Transition）**：所有温度（`18°C ~ 45°C`）、挡位（`1 ~ 9 挡`）、本次已开启时长（如 `2 小时 18 分`）以及剩余倒计时均绑定 `.contentTransition(.numericText())` 与 `.monospacedDigit()`，数字增减时呈现 Apple Watch / iOS 锁屏级别的无缝上下翻滚过渡。
- **SF Symbols 矢量符号动效（SF Symbols Effects）**：
  - 加热火焰图标（`flame.fill`）在加热中启用 `.symbolEffect(.pulse.byLayer, options: .repeating)`；
  - 蓝牙扫描图标（`dot.radiowaves.left.and.right`）在搜索时启用 `.symbolEffect(.variableColor.iterative)`；
  - 快捷操作与模式切换触发 `.symbolEffect(.bounce, value: trigger)`。
- **物理弹簧阻尼与空间变形（Spring Physics & Matched Geometry）**：状态切换统一采用 `.spring(duration: 0.38, bounce: 0.16)`；双温区同步/独立控制切换采用平滑的高度与透明度折叠过渡。
- **原生触觉引擎（Native Sensory Feedback）**：绑定 `.sensoryFeedback(.selection, trigger:)` 于挡位滑块步进，绑定 `.sensoryFeedback(.impact(weight: .medium), trigger:)` 于电源开关与除螨模式切换。

---

## 二、 色彩、排版与 SF Symbols 规范（Typography, Color & Iconography）

| 视觉维度 | 规范定义 | SwiftUI 原生实现方式 |
| :--- | :--- | :--- |
| **全局底色** | 系统分组背景色，禁止花哨壁纸 | `Color(.systemGroupedBackground)` |
| **液态玻璃表面** | iOS 26 悬浮半透明模糊材质 + 0.5pt 镜面高光边 | `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))` |
| **语义主色调** | 随加热状态动态切换系统语义色 | 待机 `.blue` / 普通加热 `.orange` / 高温除螨 `.red` / 在线就绪 `.green` |
| **核心大数字排版** | 系统圆体（SF Pro Rounded）+ 等宽数字对齐 | `.system(size: 38, weight: .bold, design: .rounded).monospacedDigit()` |
| **列表与卡片标题** | 严格遵循动态字体（Dynamic Type） | `.headline` / `.subheadline` / `.caption` + `.foregroundStyle(.primary / .secondary)` |
| **图标体系** | 100% 官方 SF Symbols 6 多层渲染 | `.symbolRenderingMode(.hierarchical)` 或 `.symbolRenderingMode(.multicolor)` |

---

## 三、 页面架构与交互流程规范（Screen Architecture & User Flows）

### 1. 首页：设备中心（`DeviceListView` — 仿 Apple Home「家庭」App 布局）
- **顶部导航栏（NavigationStack Toolbar）**：
  - 大标题：`智能电热毯`（支持下滑自动收缩为内联标题）。
  - 右上角工具栏：原生液态玻璃胶囊按钮 `Label("添加设备", systemImage: "plus")`（点击弹出蓝牙扫描发现抽屉）与快速刷新状态按钮。
- **顶部环境摘要横幅（Summary Header）**：
  - 当存在正在加热的设备时，顶部以紧凑液态玻璃胶囊展示：「`1 台正在加热 · 主卧电热毯 (左 32°C / 右 32°C · 已开启 1.5 小时)`」。
- **设备卡片网格 / 列表（Device Cards）**：
  - 每张设备卡片采用 iOS 26 液态玻璃圆角容器，左侧为动态多层 SF Symbol 图标（开机时暖橙色脉冲火焰 `flame.fill`，待机时静谧蓝 `bed.double.fill`），中间为设备名称、房间标签、实时连接状态徽章（`已直连 · 18ms` / `智能待机就绪`），右侧为**一键原生电源圆形按钮**（无需进详情页即可秒开关）。
  - 卡片底部内嵌四项核心实时遥测指标微胶囊：`左温区 5挡 (32°C)`、`右温区 5挡 (32°C)`、`本次已开启 02:15`、`定时剩余 09:45`。
  - 支持原生左滑菜单（`.swipeActions`）与长按上下文菜单（`.contextMenu`）：重命名设备、编辑硬件 MAC、切换「双区同步调温」、删除设备。

### 2. 设备详情与控制页（`DeviceControlView` — 核心温控与状态遥测面板）
严格按照自上而下的信息优先级分为 5 个原生模块：
1. **模块 A：液态玻璃主控状态舱（Liquid Glass Hero Status Card）**
   - 居左展示当前设备主状态（`正在加热` / `高温除螨中` / `已关机待机`）与模式副标题；居右为大尺寸液态玻璃电源主开关按钮。
   - 中部双栏并列展示**左温区**与**右温区**的实时标称温度（`18°C ~ 45°C` 大号圆体数字）与对应挡位（`1 ~ 9 挡`），下方配有一条细腻的原生热力进度条。
   - 底部通栏实时展示：「**本次已开启时长**（精确到分钟与小时，如 `已开启 2 小时 24 分`）」与「**倒计时状态**（如 `将于 5 小时 36 分后自动关机` 或 `预约 2 小时 10 分后自动开机`）」。
2. **模块 B：工作模式与双区联动分段控制器（Native Mode & Zone Sync Section）**
   - 原生 `.segmented` 分段选择器切换 **「普通加热」** 与 **「除螨模式 (2h 45°C 高温)」**。
   - 原生 `Toggle("双温区同步调节", systemImage: "link")`：开启后滑动单一滑块即可同时毫秒级同步左右温区；关闭后展开左右独立滑块。
3. **模块 C：左右分区挡位原生精准滑块（Zone Gear Control Section）**
   - 左温区 / 右温区独立控制卡片：顶部显示区位名称、实时挡位胶囊（`5 挡 · 32°C 舒适恒温`），底部为 SwiftUI 原生 `Slider(value:in:1...9, step: 1)` 配合左右微调按钮（`-` / `+`）。
   - 内置 **120ms 防抖合并管道（Debounce Coalescing）**：手指连续滑动时界面数字与触觉反馈 0 延迟响应，松手或停顿 120ms 时精准下发加密 BLE 指令，绝不阻塞蓝牙通道。
4. **模块 D：定时关机与预约定时开机（Timers & Scheduling Section）**
   - **自动关机定时（`timeClose`）**：原生 `Picker` 菜单与快捷胶囊（`1h / 2h / 4h / 6h / 8h / 10h / 12h`），并实时显示硬件上报的 `remainingTimeCloseSec` 剩余倒计时。
   - **预约定时开机（`timeOpen`）**：原生 `Picker` 选择（`关闭 / 1h ~ 12h 后开机`），设置后实时展示硬件 `remainingTimeOpenSec` 预约开机倒计时。
5. **模块 E：设备运行状态与硬件诊断信息（Telemetry & Diagnostics Section）**
   - 使用标准 iOS `LabeledContent` 原生键值对列表，清晰展示：
     - **本次已开启时长**：实时计算（`X 小时 Y 分钟` / `0.0 小时`）
     - **历史累计运行时长**：本地持久化累计开启小时数（如 `128.4 小时`）
     - **累计开机次数**：记录历史加热周期次数
     - **指令响应耗时 / 信号强度**：实时测量 GATT 写入往返耗时（如 `14 ms`）与 RSSI（如 `-58 dBm 极佳`）
     - **连接策略与开机记忆恢复**：支持开关「开机自动恢复上次挡位与定时」（完美复刻 Home Assistant 桥接器 `do_turn_on` 的 0.35s 延时恢复逻辑）以及硬件 MAC 地址核验。

### 3. 蓝牙扫描与设备发现抽屉（`ScannerSheetView`）
- 采用 iOS 原生 `.sheet` 模态卡片（`.presentationBackground(.regularMaterial)`）。
- 顶部显示动态脉冲雷达状态栏与「仅显示晶合物联电热毯 (`J*` / `0x5700`)」原生过滤开关。
- 自动从 BLE 广播包 `Service Data (0x5700)` 的第 6~11 字节提取真实硬件 MAC 地址并派生 8 字节 DES 密钥；同时支持手动输入/修正 MAC 地址（兼容未广播 Service Data 的特殊固件）。

---

## 四、 执行与验收清单（Execution Verification Checklist）
1. **禁止项核查**：代码中不得出现 `LinearGradient` 满屏花哨背景、不得自定义异形 Slider 轨道覆盖原生手势、不得使用已废弃的 `NavigationView`。
2. **动效核查**：所有数值变化均需包裹 `withAnimation(.spring(duration: 0.35, bounce: 0.15))` 并声明 `.contentTransition(.numericText())`。
3. **响应速度核查**：用户点击开关或拖动滑块时，UI 必须**乐观更新（Optimistic UI）**，后台异步通过 `retrievePeripherals(withIdentifiers:)` 零扫描直连并下发 DES-ECB 加密 TLV 指令。
