r"""Persistent OS-level watchdog launcher for DeepSeek Mobile Bridge.

Prefers `.venv\Scripts\python.exe` cleanly with no console popup window,
reads the configured port from `data/config.json`, avoids crash-looping when
the bridge is already serving `/api/health`, rotates `data/watchdog.log`,
and restarts the bridge server automatically if it exits unexpectedly.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

if os.name == "nt":
    import msvcrt


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "data"
WATCHDOG_PID_FILE = DATA_DIR / "watchdog.pid"
WATCHDOG_LOCK_FILE = DATA_DIR / "watchdog.lock"
WATCHDOG_LOG_FILE = DATA_DIR / "watchdog.log"
MAX_WATCHDOG_LOG_BYTES = 512 * 1024
SERVER_SCRIPT = PROJECT_ROOT / "bridge" / "server.py"


def _resolve_python_exe() -> Path:
    candidates = [
        PROJECT_ROOT / ".venv" / "Scripts" / "python.exe",
        PROJECT_ROOT / ".venv" / "bin" / "python",
        Path(sys.executable),
    ]
    for cand in candidates:
        if cand.exists() and cand.is_file():
            # Avoid launching via pythonw.exe as server interpreter if python.exe exists beside it
            if cand.name.lower() == "pythonw.exe":
                console_sibling = cand.with_name("python.exe")
                if console_sibling.exists():
                    return console_sibling
            return cand
    return Path(sys.executable)


def _resolve_port() -> int:
    if env_port := os.environ.get("AGY_MOBILE_PORT", "").strip():
        try:
            p = int(env_port)
            if 1 <= p <= 65535:
                return p
        except ValueError:
            pass
    cfg_file = DATA_DIR / "config.json"
    if cfg_file.exists():
        try:
            raw = json.loads(cfg_file.read_text(encoding="utf-8"))
            p = int(raw.get("port") or 8765)
            if 1 <= p <= 65535:
                return p
        except Exception:
            pass
    return 8765


def _log(msg: str) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} [watchdog] {msg}\n"
    try:
        if WATCHDOG_LOG_FILE.exists() and WATCHDOG_LOG_FILE.stat().st_size > MAX_WATCHDOG_LOG_BYTES:
            rotated = WATCHDOG_LOG_FILE.with_suffix(".log.1")
            WATCHDOG_LOG_FILE.replace(rotated)
        with WATCHDOG_LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def _acquire_singleton_lock():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    fh = open(WATCHDOG_LOCK_FILE, "a+", encoding="utf-8")
    if os.name == "nt":
        try:
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            fh.close()
            return None
    return fh


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _health_ok(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1.5) as resp:
            return resp.status == 200
    except Exception:
        return False


def main() -> None:
    os.chdir(str(PROJECT_ROOT))
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    lock_fh = _acquire_singleton_lock()
    if lock_fh is None:
        _log("Another watchdog instance holds watchdog.lock; exiting.")
        return

    python_exe = _resolve_python_exe()
    WATCHDOG_PID_FILE.write_text(str(os.getpid()), encoding="utf-8")
    _log(f"Watchdog started (PID {os.getpid()}) supervising {SERVER_SCRIPT} via {python_exe}")

    backoff = 1.5
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    active_proc: subprocess.Popen[bytes] | None = None

    try:
        while True:
            port = _resolve_port()
            # Wait briefly if port is still draining from a previous process
            for _ in range(10):
                if not _port_open(port):
                    break
                time.sleep(0.5)

            if _port_open(port) and _health_ok(port):
                _log(f"Port {port} already has a healthy bridge server; standing by.")
                while _health_ok(port):
                    time.sleep(5.0)
                continue

            started = time.time()
            active_proc = subprocess.Popen(
                [str(python_exe), str(SERVER_SCRIPT)],
                cwd=str(PROJECT_ROOT),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                creationflags=creation_flags,
            )
            _log(f"Launched bridge server PID {active_proc.pid} on port {port}")
            rc = active_proc.wait()
            active_proc = None
            lived = time.time() - started
            _log(f"Bridge server exited with code {rc} after {lived:.1f}s")
            if lived > 30:
                backoff = 1.5
            else:
                backoff = min(20.0, backoff * 1.5)
            time.sleep(backoff)
    finally:
        if active_proc is not None and active_proc.poll() is None:
            try:
                active_proc.terminate()
                active_proc.wait(timeout=3.0)
            except Exception:
                try:
                    active_proc.kill()
                except Exception:
                    pass
        if WATCHDOG_PID_FILE.exists():
            try:
                if WATCHDOG_PID_FILE.read_text(encoding="utf-8").strip() == str(os.getpid()):
                    WATCHDOG_PID_FILE.unlink()
            except OSError:
                pass
        try:
            lock_fh.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()
