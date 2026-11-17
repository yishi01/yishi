# agy-mobile-bridge 自检问题清单（已修复并验证）

> 初次自检时间：2026-11-17 10:50
> 修复与复检时间：2026-11-17 10:57
> 环境：Windows，主机 `WIN-0KAPS379A35\administrator`

---

## P0 — 阻塞级（已修复 ✅）

### 1. 主服务端口 / 健康检查路由 / 单实例与日志落盘
- **根因说明**：
  - Bridge 实际监听在 `http://127.0.0.1:8765`（原健康检查路由仅挂载了 `/health`，未挂载 `/api/health`；初次自检误探测了 `8000` 端口和不含 `Host: dsh-pc` 头的 `127.0.0.1:80`）。
- **已实施修复**：
  1. 在 `bridge/server.py` 同时挂载 `GET /health` 与 `GET /api/health`，统一返回 `{"status":"ok","version":"0.3.0","host":"127.0.0.1","port":8765}`。
  2. 新增单实例端口占用预检、PID 文件 `data/bridge.pid` 以及 UTF-8 日志落盘 `data/bridge.log`。
  3. 在 `scripts/start_bridge.ps1` 与 `scripts/start_bridge.bat` 增加启动后轮询 `/api/health` 5 次机制，失败时自动打印 `data/bridge.log` 尾部日志。
  4. 在 `bridge/deepseek_agent.py` 的 `SYSTEM_PROMPT` 中补充本机服务端口（`8765`）与虚拟环境说明。

### 2. 依赖安装与 `pytest` 解释器统一
- **根因说明**：
  - 依赖原先仅安装在项目 `.venv` 中，而全局 `C:\Python313` 未安装 `pytest`，且 `run_command` 工具未将 `.venv\Scripts` 注入 `PATH`。
- **已实施修复**：
  1. 在 `bridge/deepseek_agent.py` 的 `run_command` 执行环境中自动将 `.venv\Scripts` 置于 `PATH` 首位并设置 `VIRTUAL_ENV`。
  2. 新增 `pyproject.toml`、`scripts/setup.ps1` 与 `scripts/setup.bat`（检查 Python `>=3.11`、创建 `.venv`、安装 `requirements.txt`、执行 `pytest -q`）。
  3. 同步在全局 Python 与 `.venv` 安装 `requirements.txt`，确保直接运行 `python -m pytest -q` 与 `.\.venv\Scripts\python.exe -m pytest -q` 均通过。

---

## P1 — 功能/可用性（已修复 ✅）

### 3. Node / npm 零构建前端说明与静态校验
- **已实施修复**：
  1. 在 `README.md` 明确说明 `web/` 采用原生 ES Modules 零构建方案，无需安装 Node.js / npm。
  2. 在 `tests/test_bridge.py` 增加前端静态一致性测试：自动扫描 `web/app.js` 中所有 `$("...")` 引用的 DOM ID，校验其在 `web/index.html` 中 100% 存在。

### 4. 工作区 Git 仓库初始化与非 Git 目录结构化提示
- **已实施修复**：
  1. 在 `bridge/fs_service.py` 中，当工作区无 `.git` 时返回结构化字段 `{"is_git_repo": false, "reason": "not_a_repo", "message": "..."}`。
  2. 在 `web/app.js` 对非 Git 工作区展示友好引导提示。
  3. 已在 `agy-mobile-bridge` 项目根目录完成 `git init` 与初始提交，并将该项目目录加入 `data/config.json` 的 `workspaces` 列表。

### 5. 全链路回归验证清单
- [x] WebSocket / SSE 流式输出（含 `seq` 递增与断线补同步 `?after_seq=`）
- [x] `deepseek-reasoner` 的 `reasoning_content` 折叠卡片事件流
- [x] 命令执行审批（允许/拒绝）与 `ask_user` 选项回传
- [x] 文件树、全文搜索、新建/改名/删除、写文件并发冲突检测（`409`）
- [x] Bark 推送请求触发与 URL 编码
- [x] PWA 安装清单与 `sw.js` 缓存版本号（`v0.3.0`）一致性校验

---

## P2 — 工程规范（已修复 ✅）

- [x] **6. 版本号一致性**：`plugin.json`、`pyproject.toml`、`bridge/config.py` (`VERSION`)、`web/sw.js` (`deepseek-mobile-v0.3.0`) 统一为 `0.3.0`，并由单元测试强校验。
- [x] **7. 统一启动前置检查**：`scripts/start_bridge.ps1` 与 `scripts/start_bridge.bat` 均已包含 Python `>=3.11` 检查、`.venv` 检查、端口冲突检测及 `/api/health` 5 次轮询自检。
