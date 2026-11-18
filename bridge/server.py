"""FastAPI + WebSocket mobile bridge server powered by DeepSeek."""

from __future__ import annotations

import asyncio
import logging
import mimetypes
import os
import socket
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

# Ensure project root and local .venv site-packages are importable even when launched via system Python
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
_venv_site = PROJECT_ROOT / ".venv" / "Lib" / "site-packages"
if _venv_site.exists() and str(_venv_site) not in sys.path:
    sys.path.insert(0, str(_venv_site))

import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

from bridge.attachment_service import AttachmentService
from bridge.browser_service import BrowserService
from bridge.config import VERSION, ConfigStore
from bridge.deepseek_agent import SessionManager
from bridge.log_service import get_diagnostics_tracker, install_log_capture
from bridge.plugin_service import PluginService
from bridge.routers import attachments, browser, files, plugins, sessions, system, wallet, workspaces
from bridge.sandbox_runner import SandboxRunner
from bridge.tunnel_manager import TunnelManager
from bridge.wallet_service import WalletService
from bridge.workspace_service import WorkspaceService

mimetypes.add_type("application/manifest+json", ".webmanifest")


def create_app(data_dir: Path | None = None) -> FastAPI:
    install_log_capture()
    diagnostics_tracker = get_diagnostics_tracker()
    config_store = ConfigStore(data_dir=data_dir)
    dsh_dir = Path(config_store.config.dsh_profile_dir) if config_store.config.dsh_profile_dir else None
    plugin_service = PluginService(
        plugins_dir=config_store.data_dir / "plugins",
        dsh_profile_dir=dsh_dir,
    )
    sandbox_runner = SandboxRunner(base_dir=config_store.data_dir / "sandbox_runs")
    attachment_service = AttachmentService(data_dir=config_store.data_dir)
    workspace_service = WorkspaceService(data_dir=config_store.data_dir, config_store=config_store)
    wallet_service = WalletService(data_dir=config_store.data_dir, config_store=config_store)
    browser_service = BrowserService(
        data_dir=config_store.data_dir,
        config_store=config_store,
        attachment_service=attachment_service,
    )
    session_manager = SessionManager(
        config_store,
        plugin_service=plugin_service,
        sandbox_runner=sandbox_runner,
        workspace_service=workspace_service,
        attachment_service=attachment_service,
        wallet_service=wallet_service,
        browser_service=browser_service,
    )
    workspace_service.set_session_manager_getter(lambda: session_manager)
    tunnel_manager = TunnelManager(config_store)
    web_dir = PROJECT_ROOT / "web"

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        loop = asyncio.get_running_loop()
        prev_handler = loop.get_exception_handler()

        def _quiet_win_socket_handler(el: asyncio.AbstractEventLoop, ctx: dict[str, Any]) -> None:
            exc = ctx.get("exception")
            if isinstance(exc, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)):
                return
            if isinstance(exc, OSError) and getattr(exc, "winerror", None) in (64, 995, 10053, 10054):
                return
            if prev_handler is not None:
                prev_handler(el, ctx)
            else:
                el.default_exception_handler(ctx)

        loop.set_exception_handler(_quiet_win_socket_handler)
        await tunnel_manager.start()

        probe_task: asyncio.Task[None] | None = None
        if not os.environ.get("PYTEST_CURRENT_TEST"):
            async def _self_health_probe() -> None:
                await asyncio.sleep(15.0)
                consecutive_failures = 0
                port = int(config_store.config.port)
                while True:
                    await asyncio.sleep(25.0)
                    try:
                        reader, writer = await asyncio.wait_for(
                            asyncio.open_connection("127.0.0.1", port), timeout=4.0
                        )
                        writer.write(b"GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
                        await writer.drain()
                        head = await asyncio.wait_for(reader.read(64), timeout=4.0)
                        writer.close()
                        try:
                            await writer.wait_closed()
                        except Exception:
                            pass
                        if b"200" in head:
                            consecutive_failures = 0
                        else:
                            consecutive_failures += 1
                    except asyncio.CancelledError:
                        return
                    except Exception:
                        consecutive_failures += 1

                    if consecutive_failures >= 3:
                        logging.critical(
                            "Self-health probe failed 3 times on 127.0.0.1:%s; exiting for watchdog respawn",
                            port,
                        )
                        os._exit(75)

            probe_task = asyncio.create_task(_self_health_probe())

        try:
            yield
        finally:
            if probe_task and not probe_task.done():
                probe_task.cancel()
                try:
                    await probe_task
                except (asyncio.CancelledError, Exception):
                    pass
            await tunnel_manager.stop()
            await session_manager.shutdown()

    app = FastAPI(title="DeepSeek Mobile Bridge", version=VERSION, lifespan=lifespan)
    app.state.config_store = config_store
    app.state.session_manager = session_manager
    app.state.tunnel_manager = tunnel_manager
    app.state.plugin_service = plugin_service
    app.state.sandbox_runner = sandbox_runner
    app.state.attachment_service = attachment_service
    app.state.workspace_service = workspace_service
    app.state.wallet_service = wallet_service
    app.state.browser_service = browser_service

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def no_cache_static(request: Request, call_next):
        response = await call_next(request)
        diagnostics_tracker.http_completed(response.status_code, str(request.url.path))
        if request.url.path in ("/", "/index.html", "/app.js", "/styles.css", "/sw.js"):
            response.headers["Cache-Control"] = "no-cache, must-revalidate"
        return response

    for mod in (system, plugins, workspaces, attachments, wallet, browser, files, sessions):
        app.include_router(mod.router)

    if web_dir.exists():
        @app.get("/")
        def serve_index() -> Response:
            return FileResponse(web_dir / "index.html")

        app.mount("/", StaticFiles(directory=str(web_dir), html=True), name="web")

    return app


def _is_port_in_use(host: str, port: int) -> bool:
    check_host = "127.0.0.1" if host in ("0.0.0.0", "::") else host
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex((check_host, port)) == 0


def main() -> None:
    from logging.handlers import RotatingFileHandler

    store = ConfigStore()
    cfg = store.config
    log_path = store.data_dir / "bridge.log"
    pid_path = store.data_dir / "bridge.pid"

    cur_no_proxy = os.environ.get("NO_PROXY", "")
    extra_bypass = "localhost,127.0.0.1,::1,192.168.*,10.*,100.*"
    if not cur_no_proxy:
        os.environ["NO_PROXY"] = extra_bypass
    elif "192.168.*" not in cur_no_proxy:
        os.environ["NO_PROXY"] = f"{cur_no_proxy},192.168.*,10.*,100.*"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            RotatingFileHandler(log_path, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)

    if _is_port_in_use(cfg.host, cfg.port):
        existing_pid = pid_path.read_text(encoding="utf-8").strip() if pid_path.exists() else "unknown"
        logging.error(
            "Port %s:%s is already in use (existing PID: %s). Aborting duplicate instance.",
            cfg.host,
            cfg.port,
            existing_pid,
        )
        sys.exit(1)

    pid_path.write_text(str(os.getpid()), encoding="utf-8")
    print("=" * 60)
    print(f"DeepSeek Mobile Bridge v{VERSION} (SelectorEventLoop Resilient Edition)")
    print(f"Listening: http://{cfg.host}:{cfg.port} (Health: /api/health)")
    print(f"Workspaces: {', '.join(cfg.workspaces)} (AI Mode: {cfg.ai_access_mode})")
    print(f"Model: {cfg.model} ({cfg.effective_base_url()})")
    print(f"Auth Token: {cfg.auth_token}")
    print(f"Config Path: {store.config_path}")
    print(f"Log Path: {log_path}")
    print("=" * 60)
    try:
        uv_cfg = uvicorn.Config(
            create_app(),
            host=cfg.host,
            port=cfg.port,
            log_level="info",
            timeout_keep_alive=30,
        )
        server = uvicorn.Server(uv_cfg)
        if os.name == "nt":
            with asyncio.Runner(loop_factory=asyncio.SelectorEventLoop) as runner:
                runner.run(server.serve())
        else:
            server.run()
    except Exception:
        logging.exception("Fatal bridge server error")
        raise
    finally:
        if pid_path.exists():
            try:
                if pid_path.read_text(encoding="utf-8").strip() == str(os.getpid()):
                    pid_path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    main()
