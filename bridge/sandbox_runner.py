from __future__ import annotations

import ast
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid
from typing import Any


SECRET_ENV_SUBSTRINGS = (
    "KEY",
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASS",
    "AUTH",
    "CREDENTIAL",
    "COOKIE",
    "PRIVATE",
    "AWS_",
    "DEEPSEEK",
    "OPENAI",
    "ANTHROPIC",
    "TAVILY",
    "BRAVE",
)

DANGEROUS_PY_CALLS: dict[str, tuple[str, str, str]] = {
    "os.system": ("high", "命令执行", "调用系统 Shell 执行外部命令"),
    "os.popen": ("high", "命令执行", "通过管道执行系统命令"),
    "subprocess.run": ("high", "子进程执行", "启动外部进程"),
    "subprocess.Popen": ("high", "子进程执行", "启动后台外部进程"),
    "subprocess.call": ("high", "子进程执行", "启动外部进程"),
    "subprocess.check_output": ("high", "子进程执行", "执行并捕获外部命令"),
    "eval": ("high", "动态代码", "使用 eval 动态执行表达式"),
    "exec": ("high", "动态代码", "使用 exec 动态执行任意代码"),
    "__import__": ("medium", "动态导入", "动态加载未知模块"),
    "shutil.rmtree": ("critical", "破坏性操作", "递归删除目录树"),
    "os.remove": ("medium", "文件删除", "删除磁盘文件"),
    "os.unlink": ("medium", "文件删除", "删除磁盘文件"),
    "winreg.OpenKey": ("high", "注册表访问", "读取或修改 Windows 注册表"),
    "ctypes.windll": ("high", "底层系统调用", "直接调用 Windows DLL API"),
}

SUSPICIOUS_PY_IMPORTS: dict[str, tuple[str, str, str]] = {
    "subprocess": ("medium", "系统执行", "导入 subprocess 模块可启动外部进程"),
    "socket": ("medium", "网络通信", "导入 socket 可进行底层网络连接"),
    "http": ("low", "网络请求", "导入 http 客户端模块"),
    "urllib": ("low", "网络请求", "导入 urllib 可发起网络请求"),
    "requests": ("low", "网络请求", "导入 requests 可发起网络请求"),
    "httpx": ("low", "网络请求", "导入 httpx 可发起网络请求"),
    "ctypes": ("high", "底层调用", "导入 ctypes 可绕过纯 Python 限制"),
    "winreg": ("high", "系统注册表", "导入 winreg 可读写系统注册表"),
    "shutil": ("low", "文件系统", "导入 shutil 可批量移动/删除文件"),
}

SECRET_PATH_PATTERNS = (
    r"\.ssh",
    r"\.aws",
    r"\.dsh",
    r"\.env",
    r"config\.json",
    r"auth_token",
    r"DEEPSEEK_API_KEY",
    r"id_rsa",
    r"AppData",
)

REGEX_RULES: list[tuple[str, str, str, str, tuple[str, ...]]] = [
    ("critical", "远端脚本执行", "检测到直接从网络拉取并在本地执行命令 (curl/iwr | sh/iex)", ("powershell", "bash", "sh"),
     (r"(curl|wget|Invoke-WebRequest|iwr)\b.*\|.*(sh|bash|iex|Invoke-Expression)",)),
    ("critical", "破坏性删除", "检测到高危递归强制删除指令 (rm -rf / Remove-Item -Recurse)", ("powershell", "bash", "sh"),
     (r"rm\s+-rf\s+(/|~|\$HOME|\*)", r"Remove-Item\b.*-Recurse\b.*-Force")),
    ("high", "编码混淆载荷", "检测到 Base64 / EncodedCommand 可疑混淆执行", ("powershell", "bash", "sh", "javascript", "js"),
     (r"-(enc|EncodedCommand)\s+[A-Za-z0-9+/=]{16,}", r"\bInvoke-Expression\b", r"\biex\s*\(", r"String\.fromCharCode\(")),
    ("high", "进程执行", "检测到 Node child_process 或 eval 动态执行", ("javascript", "js", "ts"),
     (r"require\(['\"]child_process['\"]\)", r"\bchild_process\b", r"\beval\s*\(", r"new\s+Function\s*\(")),
    ("medium", "环境凭证读取", "检测到读取系统环境变量或敏感路径关键字", ("python", "javascript", "js", "powershell", "bash", "sh"),
     (r"DEEPSEEK_API_KEY|auth_token|\.ssh|id_rsa|\.dsh\\\\\.credentials", r"process\.env\b", r"\$env:[A-Za-z0-9_]+")),
    ("high", "HTML 跨域外传脚本", "HTML 内嵌脚本包含外部请求或可疑 DOM 注入", ("html",),
     (r"<\s*script\b[^>]*src\s*=\s*['\"]https?://", r"\bfetch\s*\(\s*['\"]https?://", r"XMLHttpRequest")),
]


def _attr_chain(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        prefix = _attr_chain(node.value)
        return f"{prefix}.{node.attr}" if prefix else node.attr
    return ""


def _snippet_at(lines: list[str], line_no: int) -> str:
    if 1 <= line_no <= len(lines):
        return lines[line_no - 1].strip()[:180]
    return ""


def audit_untrusted_code(code: str, language: str = "python", filename: str = "") -> dict[str, Any]:
    """Perform static security self-check on untrusted scripts before simulation or execution."""
    lang = (language or "").strip().lower()
    if not lang and filename:
        ext = Path(filename).suffix.lower()
        lang = {
            ".py": "python",
            ".js": "javascript",
            ".mjs": "javascript",
            ".cjs": "javascript",
            ".ps1": "powershell",
            ".sh": "bash",
            ".html": "html",
            ".htm": "html",
        }.get(ext, "python")

    lines = code.splitlines()
    findings: list[dict[str, Any]] = []
    seen_keys: set[tuple[int, str]] = set()

    def add_finding(line: int, severity: str, category: str, message: str) -> None:
        key = (line, category + ":" + message[:30])
        if key in seen_keys:
            return
        seen_keys.add(key)
        findings.append(
            {
                "line": line,
                "severity": severity,
                "category": category,
                "message": message,
                "snippet": _snippet_at(lines, line),
            }
        )

    # AST analysis for Python
    if lang == "python":
        try:
            tree = ast.parse(code)
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        top = alias.name.split(".")[0]
                        if top in SUSPICIOUS_PY_IMPORTS:
                            sev, cat, msg = SUSPICIOUS_PY_IMPORTS[top]
                            add_finding(node.lineno, sev, cat, msg)
                elif isinstance(node, ast.ImportFrom):
                    top = (node.module or "").split(".")[0]
                    if top in SUSPICIOUS_PY_IMPORTS:
                        sev, cat, msg = SUSPICIOUS_PY_IMPORTS[top]
                        add_finding(node.lineno, sev, cat, msg)
                elif isinstance(node, ast.Call):
                    dotted = _attr_chain(node.func)
                    if dotted in DANGEROUS_PY_CALLS:
                        sev, cat, msg = DANGEROUS_PY_CALLS[dotted]
                        add_finding(node.lineno, sev, cat, f"{msg} ({dotted})")
                    elif dotted.endswith(".system") or dotted.endswith(".popen"):
                        add_finding(node.lineno, "high", "命令执行", f"可疑命令执行调用 ({dotted})")
        except SyntaxError as exc:
            add_finding(exc.lineno or 1, "low", "语法告警", f"Python 语法错误: {exc.msg}")

    # Line-by-line regex rules & secret path checks
    for idx, line_text in enumerate(lines, start=1):
        for pat in SECRET_PATH_PATTERNS:
            if re.search(pat, line_text, re.IGNORECASE):
                add_finding(idx, "medium", "敏感路径/凭据引用", f"代码提及敏感标识符 ({pat})")
        for sev, cat, msg, langs, patterns in REGEX_RULES:
            if lang not in langs:
                continue
            for rx in patterns:
                if re.search(rx, line_text, re.IGNORECASE):
                    add_finding(idx, sev, cat, msg)

    weights = {"low": 8, "medium": 20, "high": 40, "critical": 70}
    score = min(100, sum(weights.get(f["severity"], 10) for f in findings))
    max_sev = "safe"
    order = {"safe": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
    for f in findings:
        if order.get(f["severity"], 0) > order.get(max_sev, 0):
            max_sev = f["severity"]

    if not findings:
        summary = "未检出高风险系统调用、凭据读取或外部网络载荷，可在沙箱中安全模拟运行。"
    elif max_sev in ("low", "medium"):
        summary = f"检测到 {len(findings)} 项低/中风险特征，已建议仅在隔离沙箱运行。"
    else:
        summary = f"检测到 {len(findings)} 项高危特征（含 {max_sev.upper()} 级风险），禁止直接访问宿主机凭据；仅可在隔离沙箱断网测试。"

    findings.sort(key=lambda item: (-order.get(item["severity"], 0), item["line"]))
    return {
        "ok": True,
        "language": lang,
        "risk_level": max_sev,
        "score": score,
        "safe_to_auto_run": max_sev in ("safe", "low"),
        "summary": summary,
        "findings": findings[:50],
        "stats": {
            "lines": len(lines),
            "chars": len(code),
            "finding_count": len(findings),
        },
    }


class SandboxRunner:
    """Isolated PC script simulator for running untrusted code from mobile without leaking host secrets."""

    def __init__(self, base_dir: Path | None = None) -> None:
        self.base_dir = Path(base_dir) if base_dir else (Path(__file__).resolve().parent.parent / "data" / "sandbox_runs")
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def _find_node_binary(self) -> str | None:
        dsh_node = Path(r"E:\新建文件夹\resources\runtime\bin\node.cmd")
        if dsh_node.exists():
            return str(dsh_node)
        return shutil.which("node")

    def _sanitized_env(self, run_dir: Path) -> dict[str, str]:
        safe_env: dict[str, str] = {}
        allow_exact = {
            "PATH",
            "SYSTEMROOT",
            "WINDIR",
            "COMSPEC",
            "PATHEXT",
            "NUMBER_OF_PROCESSORS",
            "PROCESSOR_ARCHITECTURE",
            "OS",
            "LANG",
            "LC_ALL",
        }
        for k, v in os.environ.items():
            ku = k.upper()
            if ku in allow_exact and not any(bad in ku for bad in SECRET_ENV_SUBSTRINGS):
                safe_env[k] = v
        # Confine home & temp inside ephemeral sandbox folder
        tmp_dir = run_dir / "tmp"
        tmp_dir.mkdir(parents=True, exist_ok=True)
        safe_env["HOME"] = str(run_dir)
        safe_env["USERPROFILE"] = str(run_dir)
        safe_env["TEMP"] = str(tmp_dir)
        safe_env["TMP"] = str(tmp_dir)
        safe_env["PYTHONIOENCODING"] = "utf-8"
        safe_env["PYTHONUNBUFFERED"] = "1"
        safe_env["PYTHONDONTWRITEBYTECODE"] = "1"
        safe_env["DSH_SANDBOX"] = "1"
        safe_env["DSH_SANDBOX_DIR"] = str(run_dir)
        return safe_env

    def _cleanup_old_runs(self, keep: int = 40) -> None:
        try:
            dirs = [d for d in self.base_dir.iterdir() if d.is_dir()]
            dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            for old in dirs[keep:]:
                shutil.rmtree(old, ignore_errors=True)
        except Exception:
            pass

    def run_sandbox_script(
        self,
        code: str,
        language: str = "python",
        *,
        timeout_sec: int = 10,
        allow_network: bool = False,
        args: list[str] | None = None,
        stdin_text: str = "",
    ) -> dict[str, Any]:
        audit = audit_untrusted_code(code, language=language)
        lang = audit["language"]
        run_id = uuid.uuid4().hex[:12]
        run_dir = self.base_dir / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        started = time.perf_counter()
        timeout = max(1, min(int(timeout_sec), 30))

        # HTML runs purely in mobile WKWebView preview without executing anything on PC
        if lang == "html":
            index_file = run_dir / "preview.html"
            index_file.write_text(code, encoding="utf-8")
            self._cleanup_old_runs()
            return {
                "ok": True,
                "run_id": run_id,
                "language": "html",
                "exit_code": 0,
                "stdout": "HTML 已完成静态安全自检，可在手机端隔离 WebView 中实时预览。",
                "stderr": "",
                "duration_ms": round((time.perf_counter() - started) * 1000, 1),
                "timed_out": False,
                "audit": audit,
                "preview_html": code,
                "artifacts": [{"name": "preview.html", "size": len(code.encode("utf-8"))}],
            }

        env = self._sanitized_env(run_dir)
        cmd: list[str]
        entry_name: str
        if lang == "python":
            entry_name = "sandbox_entry.py"
            wrapped_code = code
            if not allow_network:
                # Lightweight Python-level network block when simulation denies network
                guard = (
                    "import socket as _sb_socket\n"
                    "def _sb_blocked(*a, **kw):\n"
                    "    raise PermissionError('Sandbox policy: outbound network is disabled in simulator')\n"
                    "_sb_socket.socket.connect = _sb_blocked\n"
                    "_sb_socket.create_connection = _sb_blocked\n"
                )
                wrapped_code = guard + "\n" + code
            (run_dir / entry_name).write_text(wrapped_code, encoding="utf-8")
            cmd = [sys.executable, "-I", "-B", str(run_dir / entry_name), *(args or [])]
        elif lang in ("javascript", "js"):
            node_bin = self._find_node_binary()
            if not node_bin:
                return {
                    "ok": False,
                    "run_id": run_id,
                    "language": lang,
                    "exit_code": -1,
                    "stdout": "",
                    "stderr": "PC 端未检测到 Node.js 运行时。",
                    "duration_ms": 0.0,
                    "timed_out": False,
                    "audit": audit,
                    "artifacts": [],
                }
            entry_name = "sandbox_entry.mjs" if "export " in code or "import " in code else "sandbox_entry.js"
            (run_dir / entry_name).write_text(code, encoding="utf-8")
            cmd = [node_bin, str(run_dir / entry_name), *(args or [])]
        elif lang == "powershell":
            entry_name = "sandbox_entry.ps1"
            (run_dir / entry_name).write_text(code, encoding="utf-8")
            cmd = [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(run_dir / entry_name),
                *(args or []),
            ]
        elif lang in ("bash", "sh"):
            bash_bin = shutil.which("bash")
            if not bash_bin:
                return {
                    "ok": False,
                    "run_id": run_id,
                    "language": lang,
                    "exit_code": -1,
                    "stdout": "",
                    "stderr": "PC 端未检测到 bash（建议使用 Python / PowerShell / Node）。",
                    "duration_ms": 0.0,
                    "timed_out": False,
                    "audit": audit,
                    "artifacts": [],
                }
            entry_name = "sandbox_entry.sh"
            (run_dir / entry_name).write_text(code, encoding="utf-8")
            cmd = [bash_bin, str(run_dir / entry_name), *(args or [])]
        else:
            return {
                "ok": False,
                "run_id": run_id,
                "language": lang,
                "exit_code": -1,
                "stdout": "",
                "stderr": f"不支持的沙箱脚本语言: {lang}",
                "duration_ms": 0.0,
                "timed_out": False,
                "audit": audit,
                "artifacts": [],
            }

        timed_out = False
        stdout = ""
        stderr = ""
        exit_code = -1
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(run_dir),
                env=env,
                input=stdin_text,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
            )
            exit_code = proc.returncode
            stdout = (proc.stdout or "")[:65536]
            stderr = (proc.stderr or "")[:32768]
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            exit_code = 124
            stdout = (exc.stdout or "")[:32768] if isinstance(exc.stdout, str) else ""
            stderr = f"沙箱执行超时（超过 {timeout}s 上限已自动中止）"
        except Exception as exc:
            stderr = str(exc)

        artifacts: list[dict[str, Any]] = []
        preview_html = ""
        for item in run_dir.iterdir():
            if item.is_file() and item.name != entry_name:
                sz = item.stat().st_size
                art: dict[str, Any] = {"name": item.name, "size": sz}
                if item.suffix.lower() in (".html", ".htm", ".svg") and sz <= 128_000 and not preview_html:
                    preview_html = item.read_text(encoding="utf-8", errors="replace")
                artifacts.append(art)

        self._cleanup_old_runs()
        return {
            "ok": (not timed_out) and exit_code == 0,
            "run_id": run_id,
            "language": lang,
            "exit_code": exit_code,
            "stdout": stdout,
            "stderr": stderr,
            "duration_ms": round((time.perf_counter() - started) * 1000, 1),
            "timed_out": timed_out,
            "audit": audit,
            "preview_html": preview_html,
            "artifacts": artifacts,
        }
