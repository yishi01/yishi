from __future__ import annotations

import asyncio
from collections import deque
import ctypes
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
import logging
import os
from pathlib import Path
import platform
import shutil
import sys
import threading
import time
from typing import Any


def _utc_iso(ts: float | None = None) -> str:
    dt = datetime.fromtimestamp(ts if ts is not None else time.time(), tz=timezone.utc)
    return dt.isoformat(timespec="milliseconds")


@dataclass
class LogEntry:
    seq: int
    ts: str
    level: str
    logger: str
    message: str
    source: str = "pc"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class RingBufferLogHandler(logging.Handler):
    """Thread-safe in-memory ring buffer capturing PC bridge logs for mobile diagnostics."""

    def __init__(self, maxlen: int = 600) -> None:
        super().__init__()
        self._lock = threading.RLock()
        self._entries: deque[LogEntry] = deque(maxlen=maxlen)
        self._seq = 0

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = self.format(record) if self.formatter else record.getMessage()
            if record.exc_info and not msg.endswith("\n"):
                import traceback

                tb = "".join(traceback.format_exception(*record.exc_info))
                msg = f"{msg}\n{tb.rstrip()}"
            # Truncate pathological log lines to keep mobile log payloads snappy
            if len(msg) > 2000:
                msg = msg[:2000] + " ...[truncated]"
            with self._lock:
                self._seq += 1
                self._entries.append(
                    LogEntry(
                        seq=self._seq,
                        ts=_utc_iso(record.created),
                        level=record.levelname,
                        logger=record.name or "bridge",
                        message=msg,
                        source="pc",
                    )
                )
        except Exception:
            pass

    def push(self, level: str, logger_name: str, message: str, source: str = "pc") -> dict[str, Any]:
        with self._lock:
            self._seq += 1
            entry = LogEntry(
                seq=self._seq,
                ts=_utc_iso(),
                level=level.upper(),
                logger=logger_name,
                message=message[:2000],
                source=source,
            )
            self._entries.append(entry)
            return entry.to_dict()

    def query(
        self,
        *,
        level: str | None = None,
        search: str | None = None,
        after_seq: int = 0,
        limit: int = 150,
    ) -> list[dict[str, Any]]:
        with self._lock:
            items = list(self._entries)
        if after_seq > 0:
            items = [e for e in items if e.seq > after_seq]
        if level and level.upper() != "ALL":
            lvl = level.upper()
            items = [e for e in items if e.level == lvl]
        if search:
            q = search.strip().lower()
            if q:
                items = [
                    e
                    for e in items
                    if q in e.message.lower() or q in e.logger.lower() or q in e.level.lower()
                ]
        capped = items[-max(1, min(limit, 500)) :]
        return [e.to_dict() for e in capped]

    def clear(self) -> int:
        with self._lock:
            n = len(self._entries)
            self._entries.clear()
            return n


class DiagnosticsTracker:
    """Tracks PC uptime, WebSocket connection health, and telemetry."""

    def __init__(self) -> None:
        self.started_at = time.time()
        self._lock = threading.RLock()
        self.active_ws: int = 0
        self.total_ws_connects: int = 0
        self.total_ws_disconnects: int = 0
        self.total_ws_reconnects: int = 0
        self.last_ws_disconnect_reason: str = ""
        self.last_ws_event_at: str = ""
        self.last_http_error: str = ""
        self.total_http_requests: int = 0
        self.total_http_errors: int = 0

    def ws_connected(self, is_reconnect: bool = False) -> None:
        with self._lock:
            self.active_ws += 1
            self.total_ws_connects += 1
            if is_reconnect:
                self.total_ws_reconnects += 1
            self.last_ws_event_at = _utc_iso()

    def ws_disconnected(self, reason: str = "") -> None:
        with self._lock:
            self.active_ws = max(0, self.active_ws - 1)
            self.total_ws_disconnects += 1
            if reason:
                self.last_ws_disconnect_reason = reason[:200]
            self.last_ws_event_at = _utc_iso()

    def http_completed(self, status_code: int, path: str = "") -> None:
        with self._lock:
            self.total_http_requests += 1
            if status_code >= 500:
                self.total_http_errors += 1
                self.last_http_error = f"{status_code} {path} @ {_utc_iso()}"

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "uptime_sec": round(time.time() - self.started_at, 1),
                "active_ws": self.active_ws,
                "total_ws_connects": self.total_ws_connects,
                "total_ws_disconnects": self.total_ws_disconnects,
                "total_ws_reconnects": self.total_ws_reconnects,
                "last_ws_disconnect_reason": self.last_ws_disconnect_reason,
                "last_ws_event_at": self.last_ws_event_at,
                "total_http_requests": self.total_http_requests,
                "total_http_errors": self.total_http_errors,
                "last_http_error": self.last_http_error,
            }


def _get_process_memory_mb() -> float | None:
    if os.name == "nt":
        try:
            class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
                _fields_ = [
                    ("cb", ctypes.c_ulong),
                    ("PageFaultCount", ctypes.c_ulong),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t),
                ]

            counters = PROCESS_MEMORY_COUNTERS()
            counters.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
            handle = ctypes.windll.kernel32.GetCurrentProcess()
            if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                return round(counters.WorkingSetSize / (1024 * 1024), 1)
        except Exception:
            pass
    return None


def _get_disk_free_gb(path_str: str) -> float | None:
    try:
        target = Path(path_str) if path_str else Path.home()
        if not target.exists():
            target = Path.home()
        usage = shutil.disk_usage(str(target))
        return round(usage.free / (1024**3), 2)
    except Exception:
        return None


_LOG_HANDLER = RingBufferLogHandler(maxlen=600)
_TRACKER = DiagnosticsTracker()
_LOGGING_INSTALLED = False
_LOGGING_LOCK = threading.Lock()


def get_log_handler() -> RingBufferLogHandler:
    return _LOG_HANDLER


def get_diagnostics_tracker() -> DiagnosticsTracker:
    return _TRACKER


def install_log_capture() -> RingBufferLogHandler:
    """Attach the ring buffer handler idempotently without spamming console."""
    global _LOGGING_INSTALLED
    with _LOGGING_LOCK:
        if _LOGGING_INSTALLED:
            return _LOG_HANDLER
        fmt = logging.Formatter("%(message)s")
        _LOG_HANDLER.setFormatter(fmt)
        _LOG_HANDLER.setLevel(logging.INFO)
        for name in ("", "bridge", "uvicorn.error", "uvicorn.access"):
            lg = logging.getLogger(name)
            if _LOG_HANDLER not in lg.handlers:
                lg.addHandler(_LOG_HANDLER)
            if lg.level == logging.NOTSET or lg.level > logging.INFO:
                lg.setLevel(logging.INFO)
        _LOGGING_INSTALLED = True
        logging.getLogger("bridge").info("PC Diagnostics & RingBufferLogHandler initialized.")
        return _LOG_HANDLER


def collect_pc_diagnostics(
    *,
    version: str,
    cfg: Any,
    tunnel_status: dict[str, Any],
    sessions: list[dict[str, Any]],
    plugins_summary: dict[str, Any],
) -> dict[str, Any]:
    snap = _TRACKER.snapshot()
    running_count = sum(1 for s in sessions if s.get("status") == "running")
    waiting_count = sum(1 for s in sessions if s.get("status") in ("waiting_approval", "waiting_input"))
    queued_count = sum(int(s.get("queued_count", 0) or 0) for s in sessions)
    active_prof = cfg.get_active_profile() if hasattr(cfg, "get_active_profile") else {}
    return {
        "version": version,
        "server_time": _utc_iso(),
        "uptime_sec": snap["uptime_sec"],
        "pid": os.getpid(),
        "python_version": sys.version.split()[0],
        "platform": platform.platform(),
        "memory_mb": _get_process_memory_mb(),
        "disk_free_gb": _get_disk_free_gb(getattr(cfg, "active_workspace", "")),
        "network": {
            "host": getattr(cfg, "host", ""),
            "port": getattr(cfg, "port", 8765),
            "tunnel": tunnel_status,
            "websocket": {
                "active_connections": snap["active_ws"],
                "total_connects": snap["total_ws_connects"],
                "total_disconnects": snap["total_ws_disconnects"],
                "total_reconnects": snap["total_ws_reconnects"],
                "last_disconnect_reason": snap["last_ws_disconnect_reason"],
                "last_event_at": snap["last_ws_event_at"],
            },
            "http": {
                "total_requests": snap["total_http_requests"],
                "total_errors": snap["total_http_errors"],
                "last_error": snap["last_http_error"],
            },
        },
        "model": {
            "active_profile_id": getattr(cfg, "active_profile_id", ""),
            "active_profile_name": active_prof.get("name", ""),
            "provider": active_prof.get("provider", "openai_compatible"),
            "model": getattr(cfg, "model", ""),
            "base_url": getattr(cfg, "deepseek_base_url", ""),
            "api_key_configured": bool(getattr(cfg, "deepseek_api_key", "")),
            "profiles_count": len(getattr(cfg, "model_profiles", []) or []),
        },
        "search": {
            "enabled": bool(getattr(cfg, "search_config", {}).get("enabled", True)),
            "provider": getattr(cfg, "search_config", {}).get("provider", "duckduckgo"),
            "has_api_key": bool(getattr(cfg, "search_config", {}).get("api_key", "")),
        },
        "sessions": {
            "total": len(sessions),
            "running": running_count,
            "waiting_action": waiting_count,
            "queued_messages": queued_count,
        },
        "plugins": plugins_summary,
    }


async def run_pc_self_check(
    *,
    cfg: Any,
    tunnel_status: dict[str, Any],
    plugin_service: Any,
    sandbox_runner: Any,
) -> dict[str, Any]:
    """Run non-destructive runtime checks across config, workspace, plugins, and sandbox."""
    checks: list[dict[str, Any]] = []

    def add_check(key: str, name: str, status: str, detail: str, started: float) -> None:
        checks.append(
            {
                "key": key,
                "name": name,
                "status": status,  # ok | warn | fail
                "detail": detail,
                "latency_ms": round((time.perf_counter() - started) * 1000, 1),
            }
        )

    # 1. Config & Auth
    t0 = time.perf_counter()
    if getattr(cfg, "auth_token", ""):
        add_check("auth", "配对认证令牌", "ok", "Auth token 已配置", t0)
    else:
        add_check("auth", "配对认证令牌", "fail", "未配置 auth_token", t0)

    # 2. Active Model API Key
    t0 = time.perf_counter()
    active_prof = cfg.get_active_profile() if hasattr(cfg, "get_active_profile") else {}
    api_key = active_prof.get("api_key") or getattr(cfg, "deepseek_api_key", "")
    if api_key:
        add_check(
            "model_key",
            "模型 API 配置",
            "ok",
            f"当前使用 {active_prof.get('provider', 'openai_compatible')} / {getattr(cfg, 'model', '')}",
            t0,
        )
    else:
        add_check("model_key", "模型 API 配置", "warn", "当前激活模型缺少 API Key", t0)

    # 3. Active Workspace
    t0 = time.perf_counter()
    ws = getattr(cfg, "active_workspace", "")
    if ws and Path(ws).exists():
        add_check("workspace", "活动工作区", "ok", f"可访问: {ws}", t0)
    else:
        add_check("workspace", "活动工作区", "warn", f"工作区路径不存在或未设置: {ws or '未设置'}", t0)

    # 4. Tunnel Status
    t0 = time.perf_counter()
    tunnel_url = tunnel_status.get("live_url") or tunnel_status.get("public_url") or ""
    tunnel_state = str(tunnel_status.get("status") or "").lower()
    if tunnel_state in ("connected", "running") and tunnel_url:
        add_check("tunnel", "外网穿透隧道", "ok", f"在线: {tunnel_url}", t0)
    elif getattr(cfg, "enable_tunnel", False):
        add_check(
            "tunnel",
            "外网穿透隧道",
            "warn",
            f"隧道状态: {tunnel_status.get('status', 'unknown')} {tunnel_status.get('error', '')}".strip(),
            t0,
        )
    else:
        add_check("tunnel", "外网穿透隧道", "warn", "外网隧道已关闭（仅局域网/Tailscale 可用）", t0)

    # 5. DSH Plugins Service
    t0 = time.perf_counter()
    try:
        ps = plugin_service.summary()
        add_check(
            "plugins",
            "DSH 插件运行时",
            "ok",
            f"已加载 {ps.get('enabled', 0)}/{ps.get('total', 0)} 个插件，DSH Profile={'已检测到' if ps.get('dsh_profile_exists') else '独立目录模式'}",
            t0,
        )
    except Exception as exc:
        add_check("plugins", "DSH 插件运行时", "fail", str(exc), t0)

    # 6. Sandbox Isolation Dry-Run
    t0 = time.perf_counter()
    try:
        res = await asyncio.to_thread(
            sandbox_runner.run_sandbox_script,
            "import os\nassert 'DEEPSEEK_API_KEY' not in os.environ\nprint('SANDBOX_OK')",
            "python",
            timeout_sec=5,
            allow_network=False,
        )
        if res.get("ok") and "SANDBOX_OK" in (res.get("stdout") or ""):
            add_check("sandbox", "代码隔离沙箱自检", "ok", f"隔离环境密匙屏蔽校验通过 ({res.get('duration_ms')} ms)", t0)
        else:
            add_check("sandbox", "代码隔离沙箱自检", "fail", res.get("stderr") or res.get("error") or "未知错误", t0)
    except Exception as exc:
        add_check("sandbox", "代码隔离沙箱自检", "fail", str(exc), t0)

    overall = "ok"
    if any(c["status"] == "fail" for c in checks):
        overall = "fail"
    elif any(c["status"] == "warn" for c in checks):
        overall = "warn"

    return {
        "ok": overall != "fail",
        "overall_status": overall,
        "checked_at": _utc_iso(),
        "checks": checks,
    }
