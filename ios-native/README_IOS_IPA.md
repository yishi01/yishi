# 未越狱 iPhone 安装原生 `.ipa` 指南（Windows + Sideloadly）

本目录（`ios-native/`）是完整的 **纯原生 SwiftUI + 豆包同款后台灵动岛（ActivityKit）+ iOS 液态玻璃 UI** 工程源码。因为你的电脑是 Windows、手机未越狱，按以下 **3 步** 即可编译并安装到手机上：

---

## 灵动岛行为说明（豆包式极简设计）

1. **前台不打扰**：当你在 App 前台正常聊天、看代码时，**不会**弹出灵动岛。
2. **切后台自动上岛**：当 DeepSeek 正在运行（深度思考或工具调用中），你上滑把 App 切到后台时，自动在灵动岛显示极简状态：
   - `✨ 深度思考`（展开显示：`DeepSeek · 正在深度思考...`）
   - `🔧 工具调用`（展开显示：`DeepSeek · 正在使用工具调用...`）
   - `🔔 待确认`（展开显示：`DeepSeek · 等待你的操作确认`）
   - **不展示冗长思考文本或命令参数**，保持灵动岛干净克制。
3. **完成提示并自动缩回**：当后台任务输出完毕时，灵动岛切换为绿色的 **`✅ 输出完成`**，停留 **2.2 秒** 后自动缩回消失（切回 App 前台也会立即缩回）。
4. **未越狱后台保活机制**：内置零音量 `AVAudioSession (.mixWithOthers)` 后台保活（仅在 AI 执行回合且切到后台时开启，不影响你听音乐/刷视频，任务一结束立即释放）。

---

## 第一步：使用 GitHub Actions 云端 Mac 自动生成 `.ipa`

1. 在 GitHub 上新建一个仓库（可以是 **Private 私有仓库**）。
2. 在本机项目根目录推送到你的 GitHub 仓库：
   ```powershell
   cd C:\Users\Administrator\.gemini\antigravity\scratch\agy-mobile-bridge
   git add .
   git commit -m "feat: add native iOS SwiftUI app and Dynamic Island extension"
   git branch -M main
   git remote add origin https://github.com/<你的用户名>/<你的仓库名>.git
   git push -u origin main
   ```
3. 打开你 GitHub 仓库顶部的 **Actions** 标签页，点开正在运行的 **`Build iOS Native IPA`**，等待约 2~3 分钟编译完成后，在页面底部的 **Artifacts** 下载 **`DeepSeekMobile-iOS-IPA.zip`**，解压得到 **`DeepSeekMobile-unsigned.ipa`**。

---

## 第二步：在 Windows 上用 Sideloadly 签名安装到未越狱 iPhone

1. 在 Windows 电脑安装以下两个官方免费软件（如已安装可跳过）：
   - **iTunes（非微软商店版）** 与 **iCloud（非微软商店版）**
   - **Sideloadly**（官网 `https://sideloadly.io`）
2. 用数据线将未越狱 iPhone 连接到电脑，在手机上点「信任此电脑」。
3. 打开 **Sideloadly**：
   - 将解压出来的 **`DeepSeekMobile-unsigned.ipa`** 拖入左上角 IPA 图标框。
   - 在 **Apple ID** 栏输入你的个人 Apple 账号（免费账号即可）。
   - **关于免费账号的扩展名额提示**：
     - 免费个人 Apple ID 每 7 天最多可激活 **3 个 App ID**。本项目包含主应用（`DeepSeekMobile`）+ 灵动岛扩展（`DeepSeekIslandExtension`），共占用 **2 个 App ID**。
     - 确保 Sideloadly 高级选项（Advanced Options）里的 **`Remove PlugIns` 不要勾选**，这样灵动岛扩展会被一起签名安装。
   - 点击 **Start**，输入 Apple ID 密码完成签名并安装到手机。

---

## 第三步：在未越狱 iPhone 上首次信任并开启灵动岛

1. **信任开发者证书**：
   - 打开 iPhone **设置 → 通用 → VPN 与设备管理**，点开你的 Apple ID 开发者应用，点击 **「信任」**。
2. **开启开发者模式（iOS 16+ 首次自签需开启）**：
   - 打开 iPhone **设置 → 隐私与安全性 → 开发者模式**，打开开关并重启确认。
3. **打开 DeepSeek Go**：
   - 服务器地址填：`http://dsh-pc`（或 `https://dsh-pc.tail1e24af.ts.net`）
   - Auth Token 填：`data/config.json` 中的 `auth_token`（当前为 `_44dVxHP8puOv1RjHTb-uWrgb5LY4k6s`）
   - 首次切后台触发灵动岛时，iOS 顶部会询问「是否允许 DeepSeek Go 的实时活动」，点击 **允许** 即可！
