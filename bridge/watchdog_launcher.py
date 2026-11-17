r"""Persistent OS-level watchdog launcher for DeepSeek Mobile Bridge.

Spawns `bridge/server.py` cleanly inside `C:\Python313\python.exe` with no console
popup window, restarting it automatically if it exits abnormally or triggers a
self-heal exit (exit code 75 on accept-loop wedge). Intended to be executed via
Windows Task Scheduler (`pythonw.exe`) so IDE/terminal restarts never terminate
the bridge server.
"""

from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess
import sys
import time


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "data"
WATCHDOG_PID_FILE = DATA_DIR / "watchdog.pid"
WATCHDOG_LOG_FILE = DATA_DIR / "watchdog.log"
PYTHON_EXE = Path(r"C:\Python313\python.exe") if Path(r"C:\Python313\python.exe").exists() else Path(sys.executable)
SERVER_SCRIPT = PROJECT_ROOT / "bridge" / "server.py"


def _log(msg: str) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"{ts} [watchdog] {msg}\n"
    try:
        with WATCHDOG_LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


def _is_pid_running(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _port_open(port: int = 8765) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if WATCHDOG_PID_FILE.exists():
        try:
            old_pid = int(WATCHDOG_PID_FILE.read_text(encoding="utf-8").strip())
            if old_pid != os.getpid() and _is_pid_running(old_pid):
                _log(f"Another watchdog (PID {old_pid}) is already running; exiting.")
                return
        except Exception:
            pass

    WATCHDOG_PID_FILE.write_text(str(os.getpid()), encoding="utf-8")
    _log(f"Watchdog started (PID {os.getpid()}) supervising {SERVER_SCRIPT} via {PYTHON_EXE}")

    backoff = 1.5
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    try:
        while True:
            # Wait briefly if port 8765 is still draining from a previous process
            for _ in range(10):
                if not _port_open(8765):
                    break
                time.sleep(0.5)

            started = time.time()
            proc = subprocess.Popen(
                [str(PYTHON_EXE), str(SERVER_SCRIPT)],
                cwd=str(PROJECT_ROOT),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                creationflags=creation_flags,
            )
            _log(f"Launched bridge server PID {proc.pid}")
            rc = proc.wait()
            lived = time.time() - started
            _log(f"Bridge server PID {proc.pid} exited with code {rc} after {lived:.1f}s")
            if lived > 30:
                backoff = 1.5
            else:
                backoff = min(20.0, backoff * 1.5)
            time.sleep(backoff)
    finally:
        if WATCHDOG_PID_FILE.exists():
            try:
                if WATCHDOG_PID_FILE.read_text(encoding="utf-8").strip() == str(os.getpid()):
                    WATCHDOG_PID_FILE.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    main()
