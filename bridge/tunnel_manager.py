"""Managed Cloudflare Tunnel supervisor with automatic restart & QUIC/auto redundancy."""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import os
import re
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from bridge.config import PROJECT_ROOT, ConfigStore
from bridge.rendezvous import publish_route_to_gist

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
        self.rendezvous_status: str = "idle"
        self.rendezvous_last_error: str = ""
        self.rendezvous_updated_at: int = 0

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
                "rendezvous_gist_id": cfg.rendezvous_gist_id,
                "rendezvous_status": self.rendezvous_status,
                "rendezvous_last_error": self.rendezvous_last_error,
                "rendezvous_updated_at": self.rendezvous_updated_at,
                "tailscale_urls": list(cfg.tailscale_urls),
            }

    async def start(self) -> None:
        if os.environ.get("PYTEST_CURRENT_TEST"):
            self.status = "disabled_in_test"
            return

        cfg = self.config_store.config
        if cfg.rendezvous_gist_id.strip():
            threading.Thread(target=self.publish_rendezvous_sync, daemon=True).start()
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
        """Keep cloudflared alive automatically across transient network drops, boot delays, or crashes."""
        backoff = 2.0
        starting_since = time.time()
        while not self._stop_requested:
            await asyncio.sleep(3.0)
            if self._stop_requested:
                break
            cfg = self.config_store.config
            if not cfg.enable_tunnel:
                break
            proc = self.proc
            stalled_at_boot = (
                self.status == "starting"
                and not self.live_url
                and (time.time() - starting_since) > 45.0
            )
            if proc is None or proc.poll() is not None or stalled_at_boot:
                reason = "boot/network handshake timeout" if stalled_at_boot else (self.last_error or "process exited")
                logger.warning("Cloudflare Tunnel restarting (%s) in %.1fs...", reason, backoff)
                if proc is not None and proc.poll() is None:
                    try:
                        proc.terminate()
                    except Exception:
                        pass
                await asyncio.sleep(backoff)
                if self._stop_requested:
                    break
                self.restarts += 1
                backoff = min(30.0, backoff * 1.6)
                starting_since = time.time()
                await asyncio.to_thread(self._spawn_process_sync)
            elif self.status == "connected":
                backoff = 2.0
                starting_since = time.time()

    def _collect_route_urls(self, cfg: Any) -> tuple[list[str], list[str]]:
        cgnat = ipaddress.ip_network("100.64.0.0/10")
        tun_bench = ipaddress.ip_network("198.18.0.0/15")
        lan_urls: list[str] = []
        tailscale_urls: list[str] = [str(u).strip().rstrip("/") for u in (cfg.tailscale_urls or []) if str(u).strip()]
        seen_lan: set[str] = set()
        seen_ts: set[str] = set(tailscale_urls)
        try:
            for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                ip_str = item[4][0]
                if not ip_str or ip_str.startswith("127.") or ip_str.startswith("169.254."):
                    continue
                try:
                    ip_obj = ipaddress.ip_address(ip_str)
                except ValueError:
                    continue
                if ip_obj in tun_bench:
                    continue
                candidate = f"http://{ip_str}:{cfg.port}"
                if ip_obj in cgnat:
                    if candidate not in seen_ts:
                        seen_ts.add(candidate)
                        tailscale_urls.append(candidate)
                elif candidate not in seen_lan:
                    seen_lan.add(candidate)
                    lan_urls.append(candidate)
        except OSError:
            pass
        return lan_urls, tailscale_urls

    def publish_rendezvous_sync(self, url: str | None = None) -> dict[str, Any]:
        if os.environ.get("PYTEST_CURRENT_TEST"):
            return {"ok": False, "skipped": "pytest"}
        try:
            cfg = self.config_store.config
            target_url = (url or self.live_url or cfg.public_url or "").strip().rstrip("/")
            if not cfg.auth_token.strip():
                raise RuntimeError("auth_token is empty")
            lan_urls, tailscale_urls = self._collect_route_urls(cfg)
            new_gist_id = publish_route_to_gist(
                gist_id=cfg.rendezvous_gist_id,
                auth_token=cfg.auth_token,
                public_url=target_url,
                lan_urls=lan_urls,
                tailscale_urls=tailscale_urls,
            )
            if new_gist_id and new_gist_id != cfg.rendezvous_gist_id:
                cfg.rendezvous_gist_id = new_gist_id
                self.config_store.save(cfg)
            now_ts = int(time.time())
            with self._lock:
                self.rendezvous_status = "synced"
                self.rendezvous_last_error = ""
                self.rendezvous_updated_at = now_ts
            logger.info("Encrypted fixed rendezvous synced (gist=%s)", cfg.rendezvous_gist_id or new_gist_id)
            return {
                "ok": True,
                "gist_id": cfg.rendezvous_gist_id or new_gist_id,
                "updated_at": now_ts,
                "public_url": target_url,
                "lan_urls": lan_urls,
                "tailscale_urls": tailscale_urls,
            }
        except Exception as exc:
            err_msg = str(exc)[:200]
            with self._lock:
                self.rendezvous_status = "error"
                self.rendezvous_last_error = err_msg
            logger.warning("Rendezvous publish failed: %s", err_msg)
            return {"ok": False, "error": err_msg}

    def _persist_public_url(self, url: str) -> None:
        try:
            cfg = self.config_store.config
            cfg.public_url = url
            self.config_store.save(cfg)
            (self.config_store.data_dir / "tunnel_url.txt").write_text(url, encoding="utf-8")
            if not os.environ.get("PYTEST_CURRENT_TEST"):
                threading.Thread(
                    target=self.publish_rendezvous_sync,
                    args=(url,),
                    daemon=True,
                ).start()
            bark = cfg.bark_url.strip().rstrip("/")
            if bark:
                import urllib.parse
                import urllib.request

                def _notify_bark() -> None:
                    try:
                        title = urllib.parse.quote("DeepSeek 电脑已上线", safe="")
                        body = urllib.parse.quote(url, safe="")
                        urllib.request.urlopen(f"{bark}/{title}/{body}?group=deepseek", timeout=4)
                    except Exception:
                        pass

                threading.Thread(target=_notify_bark, daemon=True).start()
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
