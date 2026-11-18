# DeepSeek Mobile Bridge v0.9.0 (iOS App & PWA)

面向 **iOS 原生客户端（SwiftUI + 灵动岛 + WKWebView）/ Safari PWA** 与 **Windows 本地工作区** 的移动 AI 编程工作台，原生适配 **DeepSeek**（`deepseek-chat` / `deepseek-reasoner` 及任何 OpenAI / 多模态兼容接口）。

## 架构与环境说明（免 Node.js）

- **后端环境**：Python `>= 3.11`，统一使用项目内虚拟环境 `.venv\Scripts\python.exe`（Agent 执行 `run_command` 时会自动将 `.venv\Scripts` 注入 `PATH` 首位）。
- **前端零构建**：`web/` 目录采用原生 ES Modules（`index.html`、`app.js`、`styles.css`、`sw.js`、`manifest.webmanifest`），**无需安装 Node.js 或 npm**。
- **统一监听端口与健康检查**：
  - 默认监听：`http://127.0.0.1:8765`（配置位于 `data/config.json`，单实例 PID 记录于 `data/bridge.pid`，运行与崩溃日志落盘于 `data/bridge.log`）。
  - 健康检查接口：`http://127.0.0.1:8765/health` 与 `http://127.0.0.1:8765/api/health`（返回 `{"status":"ok","version":"0.9.0","host":"127.0.0.1","port":8765}`）。
  - 支持 Tailscale Serve 与 Cloudflare Tunnel / Gist 加密路由解析，本地自检请访问 `http://127.0.0.1:8765/api/health`。
- **Git Diff 前置条件**：工作区需包含 `.git` 仓库（如 `git init`）才可展示分支与 Diff；若当前工作区非 Git 仓库，后端返回 `{"is_git_repo": false, "reason": "not_a_repo"}`，前端展示友好提示。

## 核心能力

- **DeepSeek 原生 Agent 对话与审批**：流式输出回复、`deepseek-reasoner` 思考过程（`reasoning_content` 折叠卡片）、工具调用、命令/写文件前手机审批（允许/拒绝）与 `ask_user` 问答。
- **iOS 锁屏/切后台断线续传**：按递增 `seq` 缓存事件，切回 Safari 时通过 `visibilitychange` + `?after_seq=` 自动补同步。
- **浏览与修改电脑文件**：目录树、全文搜索、新建/改名/删除、CodeMirror 6 编辑器 + iOS 符号快捷栏 + `@引用` 到对话。
- **Git Diff 审查与 Bark 推送**：查看着色 Diff、一键让 DeepSeek 审查改动；支持 Bark 锁屏推送。

## 安装、测试与启动

1. **环境初始化与一键测试**：
   ```powershell
   .\scripts\setup.bat
   # 或在允许脚本策略下运行：
   powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
   ```
   也可直接调用虚拟环境跑测试：
   ```powershell
   .\.venv\Scripts\python.exe -m pytest -q
   ```

2. **启动并自检 `/api/health`**：
   ```powershell
   .\scripts\start_bridge.bat --check
   # 或：
   powershell -ExecutionPolicy Bypass -File .\scripts\start_bridge.ps1 -Background
   ```

3. **在 iPhone 上访问**：
   - 开启 iPhone Tailscale，Safari 打开 `http://dsh-pc/`。
   - 输入 `data/config.json` 中的 `auth_token`，在 **「Diff/设置」** 填入 DeepSeek API Key（`sk-...`）即可使用。
