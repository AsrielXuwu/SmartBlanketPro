# Windows 本地连接 GitHub 仓库与 GitHub Actions 云端自动编译 iOS App 完整指南

由于 Apple 的 iOS 编译工具链（Xcode / Swift SDK）仅能运行在 macOS 系统上，在**没有 Mac 设备、仅有 Windows 电脑**的情况下，本工程已预置了 **XcodeGen (`project.yml`)** 与 **GitHub Actions 云端自动化流水线 (`.github/workflows/ios-build.yml`)**。

您只需在 Windows 本地把代码推送到自己的 GitHub 仓库，GitHub 官方提供的免费云端 `macos-15` 服务器就会自动为您生成 Xcode 工程、编译 SwiftUI 源码，并打包出可直接安装到 iPhone 的 `SmartBlanketPro-Unsigned.ipa` 安装包。

---

## 一、 准备工作（在 Windows 上安装 Git）

1. **下载并安装 Git for Windows**：
   - 访问 Git 官网下载安装程序（或打开 Windows PowerShell 运行 `winget install --id Git.Git -e --source winget`）。
   - 安装完成后打开 **Git Bash** 或 **Windows PowerShell**。
2. **配置您的 Git 用户名与邮箱**：
   ```powershell
   git config --global user.name "您的GitHub用户名"
   git config --global user.email "您的GitHub注册邮箱"
   ```

---

## 二、 在 GitHub 网页端创建仓库

1. 打开浏览器登录 GitHub，点击右上角 **`+`** -> **`New repository`**。
2. 填写仓库信息：
   - **Repository name**：`SmartBlanketPro`
   - **Public / Private**：建议选 **Public**（公开仓库使用 GitHub Actions 的 macOS 云服务器完全免费，无分钟数限制；私有仓库每月也有免费额度；**本工程源码中不包含任何私钥或密码，公开仓库完全安全**）。
   - **不要勾选** `Add a README file` 或 `.gitignore`，保持空仓库状态，直接点击 **`Create repository`**。
3. 创建后复制页面上显示的仓库地址（例如：`https://github.com/您的用户名/SmartBlanketPro.git`）。

---

## 三、 在 Windows 本地初始化并同步代码到 GitHub

1. 将我为您打包的 `SmartBlanketPro_iOS_Project.zip` 解压到 Windows 本地文件夹（例如 `D:\SmartBlanketPro`）。
2. 在该文件夹空白处**右键 -> 在终端中打开（或 Open Git Bash here）**，确认当前目录下可以看到 `project.yml`、`Sources`、`Resources` 和 `.github` 文件夹。
3. 依次执行以下 5 条命令，即可将代码同步至 GitHub：
   ```powershell
   # 1. 初始化本地 Git 仓库并指定主分支名为 main
   git init -b main

   # 2. 将所有 SwiftUI 源码、XcodeGen 配置与 GitHub Actions 工作流加入暂存区
   git add .

   # 3. 提交本地版本
   git commit -m "feat: initial iOS 26 Liquid Glass Smart Blanket SwiftUI App"

   # 4. 关联您的远程 GitHub 仓库（请将下方 URL 替换为您刚才复制的仓库地址）
   git remote add origin https://github.com/您的用户名/SmartBlanketPro.git

   # 5. 推送到 GitHub（首次推送会弹出浏览器让您一键授权登录 GitHub）
   git push -u origin main
   ```

> **后续如果在 Windows 上用 VS Code 修改了代码（比如修改默认预设名称或 UI 文案），如何再次同步？**
> 只需在同一终端执行三行命令，GitHub 就会立刻重新触发云编译：
> ```powershell
> git add .
> git commit -m "update: Tweak UI or default MAC"
> git push
> ```

---

## 四、 使用 GitHub Actions 云端自动编译并下载 `.ipa`

1. 代码推送成功后，打开您的 GitHub 仓库网页，点击顶部导航栏的 **`Actions`** 标签页。
2. 您会看到一个名为 **`Build iOS SmartBlanketPro IPA`** 的工作流正在自动运行（黄色旋转图标 🟡；您也可以随时点击左侧工作流名称，再点击右侧 **`Run workflow`** 手动触发编译）。
3. 等待约 **2 ~ 3 分钟**，当状态变为绿色勾号 ✅ 时，点击这次构建记录进入详情页。
4. 滑动到页面最下方的 **`Artifacts`** 区域，点击 **`SmartBlanketPro-iOS-IPA`**，即可下载编译好的压缩包，解压后得到 **`SmartBlanketPro-Unsigned.ipa`**！

---

## 五、 在 Windows 上将 `.ipa` 安装到 iPhone（免付费开发者账号）

拿到 GitHub Actions 编译好的 `SmartBlanketPro-Unsigned.ipa` 后，您可以通过在 Windows 上使用以下任意一款免费自签名工具将其安装到您的 iPhone：

### 推荐方案 A：使用 Sideloadly（Windows 最简单的一键安装方式）
1. 在 Windows 上确保已安装 **Apple 官方非商店版 iTunes** 和 **iCloud**（用于提供 iOS USB 驱动），并安装 **Sideloadly**。
2. 用数据线将 iPhone 连接到 Windows 电脑，在手机上点击「信任此电脑」。
3. 打开 Sideloadly：
   - 将 `SmartBlanketPro-Unsigned.ipa` 拖入左侧 **IPA** 图标框中；
   - 在 **Apple Account** 栏填入您的普通免费 Apple ID 邮箱；
   - 点击 **`Start`**（首次使用会提示输入 Apple ID 密码和手机收到的双重验证码，Sideloadly 会自动向 Apple 申请免费个人开发证书并为该 IPA 完成签名安装）。
4. 安装完成后，在 iPhone 上进入：
   - **设置 -> 通用 -> VPN 与设备管理**，点击您的 Apple ID 开发者证书并选择 **「信任」**；
   - **设置 -> 隐私与安全性 -> 开发者模式**，开启开发者模式并重启手机。

### 推荐方案 B：使用 AltStore / SideStore（支持手机端无线自动续签）
- 如果您的 iPhone 已经安装了 **SideStore** 或 **AltStore**，直接将下载的 `SmartBlanketPro-Unsigned.ipa` 发送到 iPhone 的「文件」App（或通过微信文件传输助手发到手机），在 SideStore / AltStore 中点击左上角 `+` 选择该 `.ipa` 即可直接在手机上完成签名与安装。

---

## 六、 首次打开 App 与配置「快捷指令」指南

1. **首次打开「智能电热毯」App**：
   - 系统会弹窗请求 **「蓝牙权限」**，请点击 **「允许」**。
   - App 已默认为您内置了 `config.yaml` 中的电热毯硬件 MAC（`8E:B2:D6:64:F8:60`）。
   - 点击首页右上角的 **`+`（添加设备）** 按钮，App 会自动扫描周边名称以 `J` 开头或包含 `0x5700` 广播的晶合物联电热毯，点击一下即可绑定该设备的 `CBPeripheral UUID` 实现 **0.15 秒零扫描极速直连**。
2. **在 iOS「快捷指令 (Shortcuts)」中使用**：
   - 打开 iPhone 自带的 **「快捷指令」** App -> 点击右上角 `+` 新建快捷指令 -> 搜索 **「智能电热毯」**。
   - 您将直接看到 5 个原生动作：
     - **控制电热毯开关**（可下拉选择具体哪台电热毯，执行开启/关闭/切换，开机自动恢复记忆挡位）
     - **调节电热毯温区挡位**（可选择左温区、右温区或双温区同步，设置 1~9 挡）
     - **切换电热毯工作模式**（普通恒温加热 / 2小时高温除螨模式）
     - **设置电热毯定时关机或预约开机**（1~12 小时定时关机 / 0~12 小时预约开机）
     - **查询电热毯状态与开启时长**（支持 Siri 语音直接播报当前左右温度、本次已开启小时数和历史累计运行时长）
