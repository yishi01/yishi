"""Managed Cloudflare Tunnel supervisor with automatic restart & QUIC/auto redundancy."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from bridge.config import PROJECT_ROOT, ConfigStore

logger = logging.getLogger("bridge.tunnel")

TRYCLOUDFLARE_RE = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")


class TunnelManager:
    """
    Runs and supervises `tools/cloudflared.exe` alongside the FastAPI bridge server.

    Uses `subprocess.Popen` + background reader thread (compatible with both
    `SelectorEventLoop` and `ProactorEventLoop` on Windows) and an automatic
    backoff restart loop so edge/network disconnects heal without manual action.
    """

    def __init__(self, config_store: ConfigStore):
        self.config_store = config_store
        self._lock = threading.RLock()
        self.proc: subprocess.Popen[bytes] | None = None
        self.reader_thread: threading.Thread | None = None
        self.supervisor_task: asyncio.Task[None] | None = None
        self._stop_requested: bool = False
        self.live_url: str = ""
        self.status: str = "stopped"
        self.last_error: str = ""
        self.recent_logs: list[str] = []
        self.restarts: int = 0

    def _find_binary(self) -> Path | None:
        local_bin = PROJECT_ROOT / "tools" / ("cloudflared.exe" if os.name == "nt" else "cloudflared")
        if local_bin.exists() and local_bin.is_file():
            return local_bin
        which_bin = shutil.which("cloudflared")
        return Path(which_bin) if which_bin else None

    def info(self) -> dict[str, Any]:
        cfg = self.config_store.config
        with self._lock:
            return {
                "enabled": cfg.enable_tunnel,
                "status": self.status,
                "live_url": self.live_url or cfg.public_url,
                "has_token": bool(cfg.cloudflared_token.strip()),
                "restarts": self.restarts,
                "last_error": self.last_error,
                "recent_logs": list(self.recent_logs[-8:]),
            }

    async def start(self) -> None:
        if os.environ.get("PYTEST_CURRENT_TEST"):
            self.status = "disabled_in_test"
            return

        cfg = self.config_store.config
        if not cfg.enable_tunnel:
            self.status = "disabled"
            return

        if not self._find_binary():
            self.status = "missing_binary"
            self.last_error = f"未找到 {PROJECT_ROOT / 'tools' / 'cloudflared.exe'}"
            return

        await self.stop()
        self._stop_requested = False
        self.restarts = 0
        await asyncio.to_thread(self._spawn_process_sync)
        self.supervisor_task = asyncio.create_task(self._supervisor_loop())

    def _spawn_process_sync(self) -> None:
        binary = self._find_binary()
        if not binary:
            self.status = "missing_binary"
            return
        cfg = self.config_store.config
        token = cfg.cloudflared_token.strip()
        # Use `--protocol auto` so QUIC opens 4 redundant edge streams when UDP works,
        # automatically falling back to HTTP/2 when networks block UDP.
        if token:
            cmd = [
                str(binary),
                "tunnel",
                "--no-autoupdate",
                "--protocol",
                "auto",
                "run",
                "--token",
                token,
            ]
        else:
            cmd = [
                str(binary),
                "tunnel",
                "--no-autoupdate",
                "--protocol",
                "auto",
                "--url",
                f"http://127.0.0.1:{cfg.port}",
            ]

        creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        with self._lock:
            self.status = "starting"
            self.last_error = ""
            self.recent_logs.clear()
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                creationflags=creation_flags,
            )
            with self._lock:
                self.proc = proc
            t = threading.Thread(target=self._read_output_thread, args=(proc,), daemon=True)
            self.reader_thread = t
            t.start()
        except Exception as exc:
            with self._lock:
                self.status = "error"
                self.last_error = str(exc)
            logger.exception("Failed to start cloudflared")

    def _read_output_thread(self, proc: subprocess.Popen[bytes]) -> None:
        if not proc.stdout:
            return
        try:
            for raw_line in iter(proc.stdout.readline, b""):
                if self._stop_requested:
                    break
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                with self._lock:
                    self.recent_logs.append(line)
                    if len(self.recent_logs) > 40:
                        self.recent_logs = self.recent_logs[-25:]

                m = TRYCLOUDFLARE_RE.search(line)
                if m:
                    url = m.group(0)
                    changed = False
                    with self._lock:
                        if url != self.live_url:
                            self.live_url = url
                            self.status = "connected"
                            changed = True
                    if changed:
                        self._persist_public_url(url)
                        logger.info("Cloudflare Tunnel ready: %s", url)
                        print(f"[Cloudflare Tunnel] Public HTTPS URL: {url}")

                if "Registered tunnel connection" in line:
                    with self._lock:
                        self.status = "connected"
                        if self.config_store.config.public_url and not self.live_url:
                            self.live_url = self.config_store.config.public_url

                if "ERR" in line and "trycloudflare" not in line.lower():
                    with self._lock:
                        self.last_error = line[-200:]

            rc = proc.wait()
            with self._lock:
                if not self._stop_requested and self.status not in ("stopping", "stopped"):
                    self.status = "restarting"
                    if not self.last_error:
                        self.last_error = f"cloudflared exited with code {rc}"
        except Exception as exc:
            with self._lock:
                if not self._stop_requested:
                    self.status = "restarting"
                    self.last_error = str(exc)

    async def _supervisor_loop(self) -> None:
        """Keep cloudflared alive automatically across transient network drops or crashes."""
        backoff = 2.0
        while not self._stop_requested:
            await asyncio.sleep(3.0)
            if self._stop_requested:
                break
            cfg = self.config_store.config
            if not cfg.enable_tunnel:
                break
            proc = self.proc
            if proc is None or proc.poll() is not None:
                logger.warning("Cloudflare Tunnel exited (%s). Restarting in %.1fs...", self.last_error, backoff)
                await asyncio.sleep(backoff)
                if self._stop_requested:
                    break
                self.restarts += 1
                backoff = min(30.0, backoff * 1.6)
                await asyncio.to_thread(self._spawn_process_sync)
            elif self.status == "connected":
                backoff = 2.0

    def _persist_public_url(self, url: str) -> None:
        try:
            cfg = self.config_store.config
            cfg.public_url = url
            self.config_store.save(cfg)
            (self.config_store.data_dir / "tunnel_url.txt").write_text(url, encoding="utf-8")
        except Exception:
            pass

    async def stop(self) -> None:
        self._stop_requested = True
        with self._lock:
            self.status = "stopping"
        if self.supervisor_task and not self.supervisor_task.done():
            self.supervisor_task.cancel()
            try:
                await self.supervisor_task
            except (asyncio.CancelledError, Exception):
                pass
            self.supervisor_task = None

        proc = self.proc
        if proc is not None and proc.poll() is None:
            def _kill_sync() -> None:
                try:
                    proc.terminate()
                    proc.wait(timeout=4.0)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
            await asyncio.to_thread(_kill_sync)
        with self._lock:
            self.proc = None
            self.status = "stopped"
