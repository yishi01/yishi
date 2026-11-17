"""Managed Cloudflare Tunnel supervisor (Quick Tunnel or Named Tunnel Token)."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
from pathlib import Path
from typing import Any

from bridge.config import PROJECT_ROOT, ConfigStore

logger = logging.getLogger("bridge.tunnel")

TRYCLOUDFLARE_RE = re.compile(r"https://[a-zA-Z0-9-]+\.trycloudflare\.com")


class TunnelManager:
    """Runs and supervises `tools/cloudflared.exe` alongside the FastAPI bridge server."""

    def __init__(self, config_store: ConfigStore):
        self.config_store = config_store
        self.proc: asyncio.subprocess.Process | None = None
        self.reader_task: asyncio.Task[None] | None = None
        self.live_url: str = ""
        self.status: str = "stopped"
        self.last_error: str = ""
        self.recent_logs: list[str] = []

    def _find_binary(self) -> Path | None:
        local_bin = PROJECT_ROOT / "tools" / ("cloudflared.exe" if os.name == "nt" else "cloudflared")
        if local_bin.exists() and local_bin.is_file():
            return local_bin
        which_bin = shutil.which("cloudflared")
        return Path(which_bin) if which_bin else None

    def info(self) -> dict[str, Any]:
        cfg = self.config_store.config
        return {
            "enabled": cfg.enable_tunnel,
            "status": self.status,
            "live_url": self.live_url or cfg.public_url,
            "has_token": bool(cfg.cloudflared_token.strip()),
            "last_error": self.last_error,
            "recent_logs": self.recent_logs[-8:],
        }

    async def start(self) -> None:
        if os.environ.get("PYTEST_CURRENT_TEST"):
            self.status = "disabled_in_test"
            return

        cfg = self.config_store.config
        if not cfg.enable_tunnel:
            self.status = "disabled"
            return

        binary = self._find_binary()
        if not binary:
            self.status = "missing_binary"
            self.last_error = f"未找到 {PROJECT_ROOT / 'tools' / 'cloudflared.exe'}"
            return

        await self.stop()

        token = cfg.cloudflared_token.strip()
        if token:
            cmd = [
                str(binary),
                "tunnel",
                "--no-autoupdate",
                "--protocol",
                "http2",
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
                "http2",
                "--url",
                f"http://127.0.0.1:{cfg.port}",
            ]

        self.status = "starting"
        self.last_error = ""
        self.recent_logs.clear()
        try:
            self.proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            self.reader_task = asyncio.create_task(self._read_output())
        except Exception as exc:
            self.status = "error"
            self.last_error = str(exc)
            logger.exception("Failed to start cloudflared")

    async def _read_output(self) -> None:
        assert self.proc and self.proc.stdout
        try:
            while True:
                raw_line = await self.proc.stdout.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                self.recent_logs.append(line)
                if len(self.recent_logs) > 30:
                    self.recent_logs = self.recent_logs[-20:]

                m = TRYCLOUDFLARE_RE.search(line)
                if m:
                    url = m.group(0)
                    if url != self.live_url:
                        self.live_url = url
                        self.status = "connected"
                        self._persist_public_url(url)
                        logger.info("Cloudflare Tunnel ready: %s", url)
                        print(f"[Cloudflare Tunnel] Public HTTPS URL: {url}")

                if "Registered tunnel connection" in line:
                    self.status = "connected"
                    if self.config_store.config.public_url and not self.live_url:
                        self.live_url = self.config_store.config.public_url

                if "ERR" in line and "trycloudflare" not in line.lower():
                    self.last_error = line[-200:]

            rc = await self.proc.wait()
            if self.status not in ("stopping", "stopped"):
                self.status = "exited"
                if not self.last_error:
                    self.last_error = f"cloudflared exited with code {rc}"
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            self.status = "error"
            self.last_error = str(exc)

    def _persist_public_url(self, url: str) -> None:
        try:
            cfg = self.config_store.config
            cfg.public_url = url
            self.config_store.save(cfg)
            (self.config_store.data_dir / "tunnel_url.txt").write_text(url, encoding="utf-8")
        except Exception:
            pass

    async def stop(self) -> None:
        self.status = "stopping"
        if self.reader_task and not self.reader_task.done():
            self.reader_task.cancel()
            try:
                await self.reader_task
            except Exception:
                pass
            self.reader_task = None

        if self.proc and self.proc.returncode is None:
            try:
                self.proc.terminate()
                await asyncio.wait_for(self.proc.wait(), timeout=5.0)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self.proc = None
        self.status = "stopped"
