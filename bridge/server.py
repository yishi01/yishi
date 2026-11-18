"""FastAPI + WebSocket mobile bridge server powered by DeepSeek."""

from __future__ import annotations

import asyncio
import base64
import hmac
import logging
import mimetypes
import os
import socket
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

# Ensure project root and local .venv site-packages are importable even when launched via system Python (which has Windows Firewall allow rule)
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
_venv_site = PROJECT_ROOT / ".venv" / "Lib" / "site-packages"
if _venv_site.exists() and str(_venv_site) not in sys.path:
    sys.path.insert(0, str(_venv_site))

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from bridge.config import VERSION, BridgeConfig, ConfigStore
from bridge.deepseek_agent import SessionManager
from bridge.log_service import (
    collect_pc_diagnostics,
    get_diagnostics_tracker,
    get_log_handler,
    install_log_capture,
    run_pc_self_check,
)
from bridge.plugin_service import PluginService
from bridge.sandbox_runner import SandboxRunner, audit_untrusted_code
from bridge.search_service import execute_web_search
from bridge.tunnel_manager import TunnelManager
from bridge.fs_service import (
    FileConflictError,
    WorkspaceSecurityError,
    copy_pc_entry,
    create_entry,
    create_pc_entry,
    delete_entry,
    delete_pc_entry,
    git_status_and_diff,
    list_directory,
    list_pc_directory,
    list_pc_drives,
    read_file_content,
    read_pc_file,
    rename_entry,
    rename_or_move_pc_entry,
    search_workspace,
    stat_pc_entry,
    write_file_content,
    write_pc_file,
)

mimetypes.add_type("application/manifest+json", ".webmanifest")


class AuthVerifyRequest(BaseModel):
    token: str


class SettingsUpdateRequest(BaseModel):
    workspaces: list[str] | None = None
    active_workspace: str | None = None
    ai_access_mode: str | None = None
    default_approval_mode: str | None = None
    bark_url: str | None = None
    deepseek_base_url: str | None = None
    model: str | None = None
    deepseek_api_key: str | None = None
    enable_tunnel: bool | None = None
    cloudflared_token: str | None = None
    public_url: str | None = None
    rendezvous_gist_id: str | None = None
    tailscale_urls: list[str] | None = None
    active_profile_id: str | None = None
    model_profiles: list[dict[str, Any]] | None = None
    search_config: dict[str, Any] | None = None
    appearance_config: dict[str, Any] | None = None
    dsh_profile_dir: str | None = None


class ProviderTestRequest(BaseModel):
    profile_id: str | None = None
    provider: str | None = None
    base_url: str | None = None
    api_key: str | None = None
    model: str | None = None


class SearchTestRequest(BaseModel):
    query: str
    search_config: dict[str, Any] | None = None
    max_results: int = 5


class PluginInstallRequest(BaseModel):
    source_type: str = "inline"  # upload | local_path | git | inline
    name: str = ""
    description: str = ""
    local_path: str = ""
    git_url: str = ""
    branch: str = ""
    filename: str = ""
    content_base64: str = ""
    skill_markdown: str = ""
    script_code: str = ""
    script_language: str = "python"
    config: dict[str, Any] | None = None
    env: dict[str, str] | None = None


class PluginToggleRequest(BaseModel):
    enabled: bool


class PluginConfigUpdateRequest(BaseModel):
    config: dict[str, Any] | None = None
    env: dict[str, str] | None = None
    enabled: bool | None = None


class PluginRunRequest(BaseModel):
    tool_name: str = ""
    args: list[str] = Field(default_factory=list)
    stdin_text: str = ""
    workspace: str | None = None
    timeout_sec: int = 20


class DshToggleRequest(BaseModel):
    kind: str = "bundle"  # bundle | patch
    id: str
    enabled: bool


class DshConfigRequest(BaseModel):
    entry_id: str
    config: dict[str, Any] = Field(default_factory=dict)
    enabled: bool | None = None


class DshInstallRequest(BaseModel):
    spec: str


class SandboxAuditRequest(BaseModel):
    code: str
    language: str = "python"
    filename: str = ""


class SandboxRunRequest(BaseModel):
    code: str
    language: str = "python"
    timeout_sec: int = 10
    allow_network: bool = False
    args: list[str] = Field(default_factory=list)
    stdin_text: str = ""


class AuthorizeWorkspaceRequest(BaseModel):
    path: str
    set_active: bool = True
    session_id: str | None = None


class CreateSessionRequest(BaseModel):
    workspace: str | None = None
    title: str = "New Session"
    approval_mode: str | None = None
    model: str | None = None
    profile_id: str | None = None


class SendMessageRequest(BaseModel):
    prompt: str
    model: str | None = None
    profile_id: str | None = None
    queue_if_busy: bool = True


class ApprovalDecisionRequest(BaseModel):
    allow: bool
    reason: str = ""
    set_approval_mode: str | None = None


class InteractionDecisionRequest(BaseModel):
    cancelled: bool = False
    responses: list[dict[str, Any]] = Field(default_factory=list)


class WriteFileRequest(BaseModel):
    workspace: str
    path: str
    content: str
    expected_mtime: float | None = None
    force: bool = False


class CreateEntryRequest(BaseModel):
    workspace: str
    path: str
    is_dir: bool = False
    content: str = ""


class RenameEntryRequest(BaseModel):
    workspace: str
    old_path: str
    new_path: str


# --- Full PC File System Request Models ---

class PCWriteFileRequest(BaseModel):
    path: str
    content: str


class PCCreateEntryRequest(BaseModel):
    path: str
    is_dir: bool = False
    content: str = ""


class PCMoveOrCopyRequest(BaseModel):
    src_path: str
    dst_path: str
    overwrite: bool = False


class PCUploadBase64Request(BaseModel):
    dir_path: str = ""
    filename: str
    base64_data: str


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
    session_manager = SessionManager(
        config_store,
        plugin_service=plugin_service,
        sandbox_runner=sandbox_runner,
    )
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
                        logging.critical("Self-health probe failed 3 times on 127.0.0.1:%s; exiting for watchdog respawn", port)
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

    def _is_valid_token(candidate: str | None) -> bool:
        expected = config_store.config.auth_token
        if not candidate or not expected:
            return False
        return hmac.compare_digest(candidate.strip(), expected)

    def require_auth(
        authorization: str | None = Header(default=None),
        x_auth_token: str | None = Header(default=None),
        token: str | None = Query(default=None),
    ) -> None:
        tok = x_auth_token
        if not tok and authorization and authorization.lower().startswith("bearer "):
            tok = authorization[7:].strip()
        if not tok and token:
            tok = token.strip()
        if not _is_valid_token(tok):
            raise HTTPException(status_code=401, detail="Invalid or missing auth token")

    def resolve_allowed_workspace(workspace: str | None) -> Path:
        cfg = config_store.config
        allowed = [Path(w).resolve() for w in cfg.workspaces]
        if not allowed:
            raise HTTPException(status_code=400, detail="No workspaces configured")
        if not workspace:
            return Path(cfg.effective_active_workspace()).resolve()
        candidate = Path(workspace).resolve()
        if cfg.ai_access_mode == "full_access" and candidate.exists() and candidate.is_dir():
            return candidate
        if candidate not in allowed:
            raise HTTPException(status_code=403, detail="Workspace not in configured allowlist")
        if not candidate.exists() or not candidate.is_dir():
            raise HTTPException(status_code=404, detail="Workspace directory not found")
        return candidate

    def _discover_local_ipv4s() -> list[str]:
        found: list[str] = []
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                ip = str(info[4][0])
                if ip.startswith("127.") or ip.startswith("169.254.") or ip.startswith("198.18."):
                    continue
                if ip not in found:
                    found.append(ip)
        except OSError:
            pass
        return found

    @app.get("/health")
    @app.get("/api/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "version": VERSION,
            "host": config_store.config.host,
            "port": config_store.config.port,
            "public_url": tunnel_manager.live_url or config_store.config.public_url,
            "tunnel_status": tunnel_manager.status,
            "lan_ips": _discover_local_ipv4s(),
        }

    @app.get("/api/tunnel/status", dependencies=[Depends(require_auth)])
    def api_tunnel_status() -> dict[str, Any]:
        return tunnel_manager.info()

    @app.post("/api/tunnel/restart", dependencies=[Depends(require_auth)])
    async def api_tunnel_restart() -> dict[str, Any]:
        await tunnel_manager.start()
        for _ in range(16):
            if tunnel_manager.live_url or tunnel_manager.status in ("error", "missing_binary", "exited", "disabled"):
                break
            await asyncio.sleep(0.5)
        return tunnel_manager.info()

    @app.post("/api/tunnel/sync_rendezvous", dependencies=[Depends(require_auth)])
    async def api_tunnel_sync_rendezvous() -> dict[str, Any]:
        res = await asyncio.to_thread(tunnel_manager.publish_rendezvous_sync)
        return {"result": res, "tunnel": tunnel_manager.info()}

    @app.get("/install.mobileconfig")
    def install_mobileconfig(url: str = Query(default="http://dsh-pc/")) -> Response:
        target_url = url.strip() or "http://dsh-pc/"
        plist_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>FullScreen</key>
      <true/>
      <key>IsRemovable</key>
      <true/>
      <key>Label</key>
      <string>DeepSeek Go</string>
      <key>PayloadDescription</key>
      <string>DeepSeek Mobile Bridge 全屏工作台</string>
      <key>PayloadDisplayName</key>
      <string>DeepSeek Go</string>
      <key>PayloadIdentifier</key>
      <string>com.agy.deepseek.webclip</string>
      <key>PayloadType</key>
      <string>com.apple.webClip.managed</string>
      <key>PayloadUUID</key>
      <string>8C7F9A21-4E5B-4D3A-9C12-6F0E8B2D4A11</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Precomposed</key>
      <true/>
      <key>URL</key>
      <string>{target_url}</string>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>在 iPhone 主屏幕安装全屏版 DeepSeek Go</string>
  <key>PayloadDisplayName</key>
  <string>DeepSeek Go 桌面安装文件</string>
  <key>PayloadIdentifier</key>
  <string>com.agy.deepseek.profile</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>2A5E7B90-1C3D-4F8E-8A45-9D1C7E6B3F22</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>"""
        return Response(
            content=plist_xml.encode("utf-8"),
            media_type="application/x-apple-aspen-config",
            headers={"Content-Disposition": 'attachment; filename="DeepSeekGo.mobileconfig"'},
        )

    @app.post("/api/auth/verify")
    def verify_auth(body: AuthVerifyRequest) -> dict[str, Any]:
        if not _is_valid_token(body.token):
            raise HTTPException(status_code=401, detail="Invalid token")
        return {"ok": True, "settings": config_store.config.to_public_dict()}

    @app.get("/api/settings", dependencies=[Depends(require_auth)])
    def get_settings() -> dict[str, Any]:
        return config_store.config.to_public_dict()

    @app.put("/api/settings", dependencies=[Depends(require_auth)])
    def update_settings(body: SettingsUpdateRequest) -> dict[str, Any]:
        cfg_data = config_store.config.model_dump()
        if body.workspaces is not None:
            valid_ws: list[str] = []
            for raw_ws in body.workspaces:
                clean_ws = raw_ws.strip()
                if len(clean_ws) == 2 and clean_ws[1] == ":":
                    clean_ws += "\\"
                p = Path(clean_ws).expanduser()
                if not p.exists() or not p.is_dir():
                    raise HTTPException(
                        status_code=400,
                        detail=f"Invalid workspace directory: {raw_ws}",
                    )
                resolved = str(p.resolve())
                if resolved not in valid_ws:
                    valid_ws.append(resolved)
            if not valid_ws:
                raise HTTPException(status_code=400, detail="At least one workspace is required")
            cfg_data["workspaces"] = valid_ws

        if body.active_workspace is not None and body.active_workspace.strip():
            clean_act = body.active_workspace.strip()
            if len(clean_act) == 2 and clean_act[1] == ":":
                clean_act += "\\"
            act_p = Path(clean_act).expanduser()
            if act_p.exists() and act_p.is_dir():
                act_str = str(act_p.resolve())
                cfg_data["active_workspace"] = act_str
                if act_str not in cfg_data["workspaces"]:
                    cfg_data["workspaces"].insert(0, act_str)

        if body.ai_access_mode is not None:
            if body.ai_access_mode not in {"workspace_only", "workspace_read_all", "full_access"}:
                raise HTTPException(status_code=400, detail="Invalid ai_access_mode")
            cfg_data["ai_access_mode"] = body.ai_access_mode

        if body.default_approval_mode is not None:
            if body.default_approval_mode not in {"ask_commands", "ask_writes", "auto"}:
                raise HTTPException(status_code=400, detail="Invalid approval mode")
            cfg_data["default_approval_mode"] = body.default_approval_mode
        if body.bark_url is not None:
            cfg_data["bark_url"] = body.bark_url.strip()
        if body.deepseek_base_url is not None:
            cfg_data["deepseek_base_url"] = body.deepseek_base_url.strip() or "https://api.deepseek.com"
        if body.model is not None:
            cfg_data["model"] = body.model.strip() or "deepseek-chat"
        if body.deepseek_api_key is not None and body.deepseek_api_key != "":
            cfg_data["deepseek_api_key"] = body.deepseek_api_key.strip()
        if body.enable_tunnel is not None:
            cfg_data["enable_tunnel"] = body.enable_tunnel
        if body.cloudflared_token is not None and body.cloudflared_token != "":
            cfg_data["cloudflared_token"] = body.cloudflared_token.strip()
        if body.public_url is not None:
            cfg_data["public_url"] = body.public_url.strip().rstrip("/")
        if body.rendezvous_gist_id is not None:
            cfg_data["rendezvous_gist_id"] = body.rendezvous_gist_id.strip()
        if body.tailscale_urls is not None:
            cfg_data["tailscale_urls"] = [str(u).strip().rstrip("/") for u in body.tailscale_urls if str(u).strip()]

        if body.model_profiles is not None:
            old_map = {
                str(p.get("id") or ""): p
                for p in (cfg_data.get("model_profiles") or [])
                if isinstance(p, dict)
            }
            cleaned_profiles: list[dict[str, Any]] = []
            for raw_p in body.model_profiles:
                if not isinstance(raw_p, dict):
                    continue
                pid = str(raw_p.get("id") or "").strip()
                if not pid:
                    continue
                prev_key = str(old_map.get(pid, {}).get("api_key") or "")
                new_key_raw = str(raw_p.get("api_key") or "").strip()
                clear_flag = bool(raw_p.get("clear_api_key", False))
                final_key = "" if clear_flag else (new_key_raw if new_key_raw else prev_key)
                cleaned_profiles.append(
                    {
                        "id": pid,
                        "name": str(raw_p.get("name") or pid).strip(),
                        "provider": str(raw_p.get("provider") or "openai_compatible").strip(),
                        "base_url": str(raw_p.get("base_url") or "").strip().rstrip("/"),
                        "api_key": final_key,
                        "model": str(raw_p.get("model") or "").strip(),
                        "temperature": float(raw_p.get("temperature") if raw_p.get("temperature") is not None else 0.7),
                        "max_tokens": int(raw_p.get("max_tokens") or 8192),
                        "supports_tools": bool(raw_p.get("supports_tools", True)),
                        "supports_reasoning": bool(raw_p.get("supports_reasoning", False)),
                    }
                )
            if cleaned_profiles:
                cfg_data["model_profiles"] = cleaned_profiles

        if body.search_config is not None and isinstance(body.search_config, dict):
            old_sc = dict(cfg_data.get("search_config") or {})
            new_sc = dict(body.search_config)
            clear_sk = bool(new_sc.pop("clear_api_key", False))
            new_sk = str(new_sc.get("api_key") or "").strip()
            new_sc.pop("has_api_key", None)
            new_sc.pop("api_key_masked", None)
            merged_sc = {**old_sc, **new_sc}
            merged_sc["api_key"] = "" if clear_sk else (new_sk if new_sk else str(old_sc.get("api_key") or ""))
            cfg_data["search_config"] = merged_sc

        if body.appearance_config is not None and isinstance(body.appearance_config, dict):
            old_app = dict(cfg_data.get("appearance_config") or {})
            cfg_data["appearance_config"] = {**old_app, **body.appearance_config}

        if body.dsh_profile_dir is not None and body.dsh_profile_dir.strip():
            cfg_data["dsh_profile_dir"] = body.dsh_profile_dir.strip()
            plugin_service.set_paths(dsh_profile_dir=Path(cfg_data["dsh_profile_dir"]))

        cfg_obj = BridgeConfig(**cfg_data)
        if body.active_profile_id is not None and body.active_profile_id.strip():
            cfg_obj.apply_active_profile(body.active_profile_id.strip())
        elif body.model is not None:
            matched = next(
                (p.get("id") for p in cfg_obj.model_profiles if p.get("model") == cfg_obj.model),
                None,
            )
            if matched:
                cfg_obj.active_profile_id = str(matched)

        if body.deepseek_base_url is not None and body.deepseek_base_url.strip():
            clean_url = body.deepseek_base_url.strip().rstrip("/")
            cfg_obj.deepseek_base_url = clean_url
            for prof in cfg_obj.model_profiles:
                if prof.get("id") == cfg_obj.active_profile_id and prof.get("provider", "openai_compatible") == "openai_compatible":
                    prof["base_url"] = clean_url
                    break

        updated = config_store.save(cfg_obj)
        return updated.to_public_dict()

    @app.post("/api/providers/test", dependencies=[Depends(require_auth)])
    async def api_test_provider(body: ProviderTestRequest) -> dict[str, Any]:
        import time as _time
        import httpx

        cfg = config_store.config
        creds = cfg.resolve_credentials(profile_id=body.profile_id, model_override=body.model)
        provider = (body.provider or creds["provider"]).strip()
        base_url = (body.base_url or creds["base_url"]).strip().rstrip("/")
        api_key = (body.api_key or creds["api_key"]).strip()
        model = (body.model or creds["model"]).strip()
        if not api_key:
            return {"ok": False, "status_code": 0, "latency_ms": 0.0, "detail": "未填写 API Key"}

        started = _time.perf_counter()
        try:
            async with httpx.AsyncClient(timeout=12.0, http2=False) as client:
                if provider == "anthropic":
                    url = f"{base_url}/messages" if base_url.endswith("/v1") else f"{base_url}/v1/messages"
                    resp = await client.post(
                        url,
                        headers={
                            "x-api-key": api_key,
                            "anthropic-version": "2023-06-01",
                            "Content-Type": "application/json",
                        },
                        json={
                            "model": model,
                            "max_tokens": 8,
                            "messages": [{"role": "user", "content": "ping"}],
                        },
                    )
                else:
                    url = f"{base_url}/models"
                    resp = await client.get(url, headers={"Authorization": f"Bearer {api_key}"})
                    if resp.status_code == 404 or resp.status_code == 405:
                        # Fallback to tiny non-streaming chat completion probe
                        resp = await client.post(
                            f"{base_url}/chat/completions",
                            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                            json={"model": model, "max_tokens": 4, "messages": [{"role": "user", "content": "hi"}]},
                        )
            ms = round((_time.perf_counter() - started) * 1000, 1)
            ok = 200 <= resp.status_code < 300
            detail = f"HTTP {resp.status_code} 连通成功 ({model})" if ok else f"HTTP {resp.status_code}: {resp.text[:300]}"
            return {"ok": ok, "status_code": resp.status_code, "latency_ms": ms, "detail": detail}
        except Exception as exc:
            ms = round((_time.perf_counter() - started) * 1000, 1)
            return {"ok": False, "status_code": 0, "latency_ms": ms, "detail": str(exc)}

    @app.post("/api/search/test", dependencies=[Depends(require_auth)])
    async def api_test_search(body: SearchTestRequest) -> dict[str, Any]:
        sc = dict(config_store.config.search_config)
        if body.search_config:
            incoming = dict(body.search_config)
            if not str(incoming.get("api_key") or "").strip() and sc.get("api_key"):
                incoming["api_key"] = sc["api_key"]
            sc.update(incoming)
        return await execute_web_search(body.query.strip() or "DeepSeek", sc, max_results=body.max_results)

    # --- PC DSH Plugins & Sandbox Simulator APIs ---

    @app.get("/api/plugins", dependencies=[Depends(require_auth)])
    def api_list_plugins() -> dict[str, Any]:
        return plugin_service.list_all()

    @app.post("/api/plugins/install", dependencies=[Depends(require_auth)])
    async def api_install_plugin(body: PluginInstallRequest) -> dict[str, Any]:
        stype = (body.source_type or "inline").lower()
        try:
            if stype == "upload":
                if not body.filename or not body.content_base64:
                    raise HTTPException(status_code=400, detail="上传插件需要 filename 与 content_base64")
                plugin = await asyncio.to_thread(
                    plugin_service.install_from_upload,
                    filename=body.filename,
                    content_base64=body.content_base64,
                    name=body.name,
                    description=body.description,
                    config=body.config,
                )
            elif stype == "local_path":
                plugin = await asyncio.to_thread(
                    plugin_service.install_from_local_path,
                    body.local_path,
                    name=body.name,
                    config=body.config,
                )
            elif stype == "git":
                plugin = await asyncio.to_thread(
                    plugin_service.install_from_git,
                    body.git_url,
                    name=body.name,
                    branch=body.branch,
                    config=body.config,
                )
            else:
                if not body.name.strip():
                    raise HTTPException(status_code=400, detail="请填写插件名称")
                plugin = await asyncio.to_thread(
                    plugin_service.install_inline,
                    name=body.name,
                    description=body.description,
                    skill_markdown=body.skill_markdown,
                    script_code=body.script_code,
                    script_language=body.script_language,
                    config=body.config,
                    env=body.env,
                )
            logging.getLogger("bridge").info("Installed PC plugin '%s' via %s", plugin.get("id"), stype)
            return {"ok": True, "plugin": plugin, **plugin_service.list_all()}
        except HTTPException:
            raise
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except (ValueError, RuntimeError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/plugins/dsh/toggle", dependencies=[Depends(require_auth)])
    def api_dsh_toggle(body: DshToggleRequest) -> dict[str, Any]:
        try:
            if body.kind == "bundle":
                prof = plugin_service.toggle_dsh_bundle(body.id, body.enabled)
            else:
                prof = plugin_service.update_dsh_patch_entry(body.id, enabled=body.enabled)
            return {"ok": True, "dsh_profile": prof}
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.put("/api/plugins/dsh/config", dependencies=[Depends(require_auth)])
    def api_dsh_config(body: DshConfigRequest) -> dict[str, Any]:
        try:
            prof = plugin_service.update_dsh_patch_entry(
                body.entry_id, enabled=body.enabled, config=body.config
            )
            return {"ok": True, "dsh_profile": prof}
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/plugins/dsh/install", dependencies=[Depends(require_auth)])
    async def api_dsh_install(body: DshInstallRequest) -> dict[str, Any]:
        try:
            return await asyncio.to_thread(plugin_service.install_dsh_package, body.spec)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except (ValueError, RuntimeError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/plugins/{plugin_id}/toggle", dependencies=[Depends(require_auth)])
    def api_toggle_plugin(plugin_id: str, body: PluginToggleRequest) -> dict[str, Any]:
        try:
            plugin = plugin_service.toggle_plugin(plugin_id, body.enabled)
            return {"ok": True, "plugin": plugin, **plugin_service.list_all()}
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.put("/api/plugins/{plugin_id}/config", dependencies=[Depends(require_auth)])
    def api_update_plugin_config(plugin_id: str, body: PluginConfigUpdateRequest) -> dict[str, Any]:
        try:
            plugin = plugin_service.update_plugin_config(
                plugin_id, config=body.config, env=body.env, enabled=body.enabled
            )
            return {"ok": True, "plugin": plugin, **plugin_service.list_all()}
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/plugins/{plugin_id}/run", dependencies=[Depends(require_auth)])
    async def api_run_plugin(plugin_id: str, body: PluginRunRequest) -> dict[str, Any]:
        try:
            ws_dir = body.workspace or config_store.config.effective_active_workspace()
            return await asyncio.to_thread(
                plugin_service.run_plugin_tool,
                plugin_id,
                tool_name=body.tool_name,
                args=body.args,
                stdin_text=body.stdin_text,
                workspace_cwd=ws_dir,
                timeout_sec=body.timeout_sec,
            )
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.delete("/api/plugins/{plugin_id}", dependencies=[Depends(require_auth)])
    def api_delete_plugin(plugin_id: str) -> dict[str, Any]:
        try:
            plugin_service.uninstall_plugin(plugin_id)
            return {"ok": True, **plugin_service.list_all()}
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/sandbox/audit", dependencies=[Depends(require_auth)])
    def api_sandbox_audit(body: SandboxAuditRequest) -> dict[str, Any]:
        return audit_untrusted_code(body.code, language=body.language, filename=body.filename)

    @app.post("/api/sandbox/run", dependencies=[Depends(require_auth)])
    async def api_sandbox_run(body: SandboxRunRequest) -> dict[str, Any]:
        return await asyncio.to_thread(
            sandbox_runner.run_sandbox_script,
            body.code,
            body.language,
            timeout_sec=body.timeout_sec,
            allow_network=body.allow_network,
            args=body.args,
            stdin_text=body.stdin_text,
        )

    # --- Diagnostics & Logs APIs ---

    @app.get("/api/diagnostics/status", dependencies=[Depends(require_auth)])
    def api_diagnostics_status() -> dict[str, Any]:
        return collect_pc_diagnostics(
            version=VERSION,
            cfg=config_store.config,
            tunnel_status=tunnel_manager.info(),
            sessions=session_manager.list_sessions(),
            plugins_summary=plugin_service.summary(),
        )

    @app.get("/api/diagnostics/logs", dependencies=[Depends(require_auth)])
    def api_diagnostics_logs(
        level: str | None = Query(default=None),
        q: str | None = Query(default=None),
        after_seq: int = Query(default=0, ge=0),
        limit: int = Query(default=150, ge=1, le=500),
    ) -> dict[str, Any]:
        handler = get_log_handler()
        return {"logs": handler.query(level=level, search=q, after_seq=after_seq, limit=limit)}

    @app.delete("/api/diagnostics/logs", dependencies=[Depends(require_auth)])
    def api_diagnostics_clear_logs() -> dict[str, Any]:
        cleared = get_log_handler().clear()
        return {"ok": True, "cleared": cleared}

    @app.post("/api/diagnostics/selfcheck", dependencies=[Depends(require_auth)])
    async def api_diagnostics_selfcheck() -> dict[str, Any]:
        return await run_pc_self_check(
            cfg=config_store.config,
            tunnel_status=tunnel_manager.info(),
            plugin_service=plugin_service,
            sandbox_runner=sandbox_runner,
        )

    @app.post("/api/workspaces/authorize", dependencies=[Depends(require_auth)])
    def authorize_workspace(body: AuthorizeWorkspaceRequest) -> dict[str, Any]:
        clean = body.path.strip()
        if len(clean) == 2 and clean[1] == ":":
            clean += "\\"
        target = Path(clean).resolve()
        if not target.exists():
            raise HTTPException(status_code=404, detail=f"路径不存在: {clean}")
        if not target.is_dir():
            target = target.parent
        ws_str = str(target)

        cfg_data = config_store.config.model_dump()
        ws_list: list[str] = list(cfg_data.get("workspaces") or [])
        if ws_str not in ws_list:
            ws_list.append(ws_str)
        cfg_data["workspaces"] = ws_list
        if body.set_active:
            cfg_data["active_workspace"] = ws_str
        updated = config_store.save(BridgeConfig(**cfg_data))

        if body.session_id and body.set_active:
            try:
                sess = session_manager.get_session(body.session_id)
                sess.workspace = ws_str
                sess.save_to_disk()
            except KeyError:
                pass
        return updated.to_public_dict()

    # =========================================================================
    # Full PC File System Manager APIs (Drives C/D/E, Metadata, Move/Copy/Upload/Download)
    # =========================================================================

    @app.get("/api/pc/drives", dependencies=[Depends(require_auth)])
    def api_pc_drives() -> dict[str, Any]:
        cfg = config_store.config
        return list_pc_drives(
            cfg.workspaces,
            cfg.effective_active_workspace(),
            cfg.ai_access_mode,
        )

    @app.get("/api/pc/list", dependencies=[Depends(require_auth)])
    def api_pc_list(
        path: str = Query(default=""),
        show_hidden: bool = Query(default=False),
    ) -> dict[str, Any]:
        cfg = config_store.config
        try:
            return list_pc_directory(
                path,
                cfg.workspaces,
                cfg.ai_access_mode,
                show_hidden=show_hidden,
            )
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except NotADirectoryError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.get("/api/pc/stat", dependencies=[Depends(require_auth)])
    def api_pc_stat(path: str = Query(...)) -> dict[str, Any]:
        cfg = config_store.config
        try:
            return stat_pc_entry(path, cfg.workspaces, cfg.ai_access_mode)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/api/pc/read", dependencies=[Depends(require_auth)])
    def api_pc_read(path: str = Query(...)) -> dict[str, Any]:
        try:
            return read_pc_file(path)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except IsADirectoryError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.put("/api/pc/write", dependencies=[Depends(require_auth)])
    def api_pc_write(body: PCWriteFileRequest) -> dict[str, Any]:
        try:
            return write_pc_file(body.path, body.content)
        except IsADirectoryError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.post("/api/pc/create", dependencies=[Depends(require_auth)])
    def api_pc_create(body: PCCreateEntryRequest) -> dict[str, Any]:
        try:
            return create_pc_entry(body.path, is_dir=body.is_dir, content=body.content)
        except FileExistsError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.post("/api/pc/move", dependencies=[Depends(require_auth)])
    def api_pc_move(body: PCMoveOrCopyRequest) -> dict[str, Any]:
        try:
            return rename_or_move_pc_entry(body.src_path, body.dst_path, overwrite=body.overwrite)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except FileExistsError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.post("/api/pc/copy", dependencies=[Depends(require_auth)])
    def api_pc_copy(body: PCMoveOrCopyRequest) -> dict[str, Any]:
        try:
            return copy_pc_entry(body.src_path, body.dst_path, overwrite=body.overwrite)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except FileExistsError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.delete("/api/pc/delete", dependencies=[Depends(require_auth)])
    def api_pc_delete(path: str = Query(...)) -> dict[str, Any]:
        try:
            return delete_pc_entry(path)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.post("/api/pc/upload", dependencies=[Depends(require_auth)])
    async def api_pc_upload(
        request: Request,
        dir_path: str = Query(default=""),
        filename: str = Query(default=""),
    ) -> dict[str, Any]:
        """Upload a file from the phone to the PC (supports either JSON base64 or raw binary body)."""
        cfg = config_store.config
        content_type = request.headers.get("content-type", "").lower()

        if "application/json" in content_type:
            body_json = await request.json()
            target_dir_str = str(body_json.get("dir_path") or dir_path or "").strip()
            fname = str(body_json.get("filename") or filename or "uploaded_file").strip()
            b64 = str(body_json.get("base64_data") or "")
            raw_bytes = base64.b64decode(b64)
        else:
            target_dir_str = dir_path.strip()
            fname = filename.strip() or "uploaded_file"
            raw_bytes = await request.body()

        safe_fname = Path(fname).name
        if not target_dir_str:
            target_dir = Path(cfg.effective_active_workspace()) / "uploads"
        else:
            if len(target_dir_str) == 2 and target_dir_str[1] == ":":
                target_dir_str += "\\"
            target_dir = Path(target_dir_str).resolve()

        target_dir.mkdir(parents=True, exist_ok=True)
        dest_file = target_dir / safe_fname
        dest_file.write_bytes(raw_bytes)
        st = dest_file.stat()
        return {
            "ok": True,
            "name": dest_file.name,
            "path": str(dest_file.resolve()),
            "dir": str(target_dir.resolve()),
            "size": st.st_size,
            "mtime": st.st_mtime,
        }

    @app.get("/api/pc/download", dependencies=[Depends(require_auth)])
    def api_pc_download(path: str = Query(...)) -> FileResponse:
        """Download any file from the PC to the user's phone."""
        target = Path(path.strip()).resolve()
        if not target.exists():
            raise HTTPException(status_code=404, detail=f"File not found: {path}")
        if target.is_dir():
            raise HTTPException(status_code=400, detail="Cannot download a directory directly")
        mime, _ = mimetypes.guess_type(target.name)
        return FileResponse(
            path=target,
            filename=target.name,
            media_type=mime or "application/octet-stream",
        )

    # --- Workspace File & Git APIs (Legacy & Workspace-Scoped) ---

    @app.get("/api/files/tree", dependencies=[Depends(require_auth)])
    def api_list_tree(
        workspace: str | None = Query(default=None),
        path: str = Query(default=""),
        include_ignored: bool = Query(default=False),
    ) -> dict[str, Any]:
        root = resolve_allowed_workspace(workspace)
        try:
            return list_directory(root, path, include_ignored=include_ignored)
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except (FileNotFoundError, NotADirectoryError) as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/api/files/read", dependencies=[Depends(require_auth)])
    def api_read_file(
        workspace: str | None = Query(default=None),
        path: str = Query(...),
    ) -> dict[str, Any]:
        root = resolve_allowed_workspace(workspace)
        try:
            return read_file_content(root, path)
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except (FileNotFoundError, IsADirectoryError) as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.put("/api/files/write", dependencies=[Depends(require_auth)])
    def api_write_file(body: WriteFileRequest) -> dict[str, Any]:
        root = resolve_allowed_workspace(body.workspace)
        try:
            return write_file_content(
                root,
                body.path,
                body.content,
                expected_mtime=body.expected_mtime,
                force=body.force,
            )
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except FileConflictError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        except IsADirectoryError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/files/create", dependencies=[Depends(require_auth)])
    def api_create_entry(body: CreateEntryRequest) -> dict[str, Any]:
        root = resolve_allowed_workspace(body.workspace)
        try:
            return create_entry(root, body.path, is_dir=body.is_dir, content=body.content)
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except FileExistsError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.post("/api/files/rename", dependencies=[Depends(require_auth)])
    def api_rename_entry(body: RenameEntryRequest) -> dict[str, Any]:
        root = resolve_allowed_workspace(body.workspace)
        try:
            return rename_entry(root, body.old_path, body.new_path)
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except FileExistsError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.delete("/api/files/delete", dependencies=[Depends(require_auth)])
    def api_delete_entry(
        workspace: str = Query(...),
        path: str = Query(...),
    ) -> dict[str, Any]:
        root = resolve_allowed_workspace(workspace)
        try:
            return delete_entry(root, path)
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/api/files/search", dependencies=[Depends(require_auth)])
    def api_search_files(
        workspace: str | None = Query(default=None),
        q: str = Query(default=""),
    ) -> dict[str, Any]:
        root = resolve_allowed_workspace(workspace)
        return search_workspace(root, q)

    @app.get("/api/git/status", dependencies=[Depends(require_auth)])
    async def api_git_status(
        workspace: str | None = Query(default=None),
        path: str | None = Query(default=None),
    ) -> dict[str, Any]:
        root = resolve_allowed_workspace(workspace)
        try:
            return await git_status_and_diff(root, path)
        except WorkspaceSecurityError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    # --- Session & DeepSeek Agent APIs ---

    @app.get("/api/sessions", dependencies=[Depends(require_auth)])
    def api_list_sessions() -> dict[str, Any]:
        return {"sessions": session_manager.list_sessions()}

    @app.post("/api/sessions", dependencies=[Depends(require_auth)])
    def api_create_session(body: CreateSessionRequest) -> dict[str, Any]:
        root = resolve_allowed_workspace(body.workspace)
        if body.approval_mode and body.approval_mode not in {"ask_commands", "ask_writes", "auto"}:
            raise HTTPException(status_code=400, detail="Invalid approval_mode")
        sess = session_manager.create_session(
            workspace=str(root),
            title=body.title,
            approval_mode=body.approval_mode,
            model=body.model,
            profile_id=body.profile_id,
        )
        return sess.summary()

    @app.delete("/api/sessions/{session_id}", dependencies=[Depends(require_auth)])
    async def api_delete_session(session_id: str) -> dict[str, Any]:
        try:
            await session_manager.delete_session(session_id)
            return {"deleted": session_id}
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/api/sessions/{session_id}/events", dependencies=[Depends(require_auth)])
    def api_get_events(
        session_id: str,
        after_seq: int = Query(default=0, ge=0),
    ) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return {
            "session": sess.summary(),
            "events": sess.get_events_after(after_seq),
        }

    @app.post("/api/sessions/{session_id}/message", dependencies=[Depends(require_auth)])
    async def api_send_message(session_id: str, body: SendMessageRequest) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        try:
            ev = await sess.send_prompt(
                body.prompt,
                model=body.model,
                profile_id=body.profile_id,
                queue_if_busy=body.queue_if_busy,
            )
            return {
                "event": ev,
                "queued": bool(ev.get("queued", False)),
                "queue_item": ev.get("queue_item"),
                "session": sess.summary(),
            }
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

    @app.get("/api/sessions/{session_id}/queue", dependencies=[Depends(require_auth)])
    def api_list_queue(session_id: str) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return {"queued_messages": sess.list_queue(), "session": sess.summary()}

    @app.post("/api/sessions/{session_id}/queue/{item_id}/send_now", dependencies=[Depends(require_auth)])
    async def api_send_queued_now(session_id: str, item_id: str) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
            res = await sess.send_queued_now(item_id)
            return {"ok": True, "result": res, "session": sess.summary()}
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.delete("/api/sessions/{session_id}/queue/{item_id}", dependencies=[Depends(require_auth)])
    def api_delete_queued_item(session_id: str, item_id: str) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        if not sess.remove_queued_item(item_id):
            raise HTTPException(status_code=404, detail="Queue item not found")
        return {"ok": True, "session": sess.summary()}

    @app.delete("/api/sessions/{session_id}/queue", dependencies=[Depends(require_auth)])
    def api_clear_queue(session_id: str) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        cleared = sess.clear_queue()
        return {"ok": True, "cleared": cleared, "session": sess.summary()}

    @app.post("/api/sessions/{session_id}/cancel", dependencies=[Depends(require_auth)])
    async def api_cancel_turn(session_id: str) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        await sess.cancel_turn()
        return {"session": sess.summary()}

    @app.post("/api/sessions/{session_id}/approvals/{request_id}", dependencies=[Depends(require_auth)])
    def api_resolve_approval(
        session_id: str,
        request_id: str,
        body: ApprovalDecisionRequest,
    ) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        ok = sess.resolve_approval(
            request_id,
            allow=body.allow,
            reason=body.reason,
            set_approval_mode=body.set_approval_mode,
        )
        if not ok:
            raise HTTPException(status_code=404, detail="Pending approval not found or already resolved")
        return {"ok": True, "session": sess.summary()}

    @app.post("/api/sessions/{session_id}/interactions/{request_id}", dependencies=[Depends(require_auth)])
    def api_resolve_interaction(
        session_id: str,
        request_id: str,
        body: InteractionDecisionRequest,
    ) -> dict[str, Any]:
        try:
            sess = session_manager.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        ok = sess.resolve_interaction(
            request_id,
            responses=body.responses,
            cancelled=body.cancelled,
        )
        if not ok:
            raise HTTPException(status_code=404, detail="Pending interaction not found or already resolved")
        return {"ok": True, "session": sess.summary()}

    @app.websocket("/ws/sessions/{session_id}")
    async def ws_session(
        websocket: WebSocket,
        session_id: str,
        token: str = Query(default=""),
        after_seq: int = Query(default=0),
    ) -> None:
        if not _is_valid_token(token):
            await websocket.close(code=4401)
            return
        try:
            sess = session_manager.get_session(session_id)
        except KeyError:
            await websocket.close(code=4404)
            return

        await websocket.accept()
        diagnostics_tracker.ws_connected(is_reconnect=after_seq > 0)
        queue = sess.subscribe()
        send_lock = asyncio.Lock()
        disconnect_reason = "closed"

        async def _safe_send(payload: dict[str, Any]) -> bool:
            try:
                async with send_lock:
                    await asyncio.wait_for(websocket.send_json(payload), timeout=10.0)
                return True
            except (asyncio.TimeoutError, WebSocketDisconnect, ConnectionResetError, BrokenPipeError, RuntimeError, OSError):
                return False

        async def _sender_loop(start_seq: int) -> None:
            last_sent = start_seq
            try:
                while True:
                    try:
                        ev = await asyncio.wait_for(queue.get(), timeout=12.0)
                        if ev["seq"] > last_sent:
                            if not await _safe_send(ev):
                                return
                            last_sent = ev["seq"]
                    except asyncio.TimeoutError:
                        if not await _safe_send({"type": "ping", "ts": asyncio.get_running_loop().time()}):
                            return
            except asyncio.CancelledError:
                return

        async def _receiver_loop() -> None:
            nonlocal disconnect_reason
            try:
                while True:
                    msg = await websocket.receive_text()
                    trimmed = msg.strip()
                    if trimmed == "ping" or '"ping"' in trimmed:
                        if not await _safe_send({"type": "pong"}):
                            return
            except WebSocketDisconnect as exc:
                disconnect_reason = f"ws_disconnect:{exc.code}"
            except (ConnectionResetError, BrokenPipeError, RuntimeError, OSError) as exc:
                disconnect_reason = f"socket:{type(exc).__name__}"
            except asyncio.CancelledError:
                return

        sender_task: asyncio.Task[None] | None = None
        receiver_task: asyncio.Task[None] | None = None
        try:
            missed = sess.get_events_after(after_seq)
            last_sent = after_seq
            for ev in missed:
                if not await _safe_send(ev):
                    disconnect_reason = "send_missed_failed"
                    return
                last_sent = max(last_sent, ev["seq"])

            if not await _safe_send({"type": "sync_complete", "session": sess.summary()}):
                disconnect_reason = "send_sync_failed"
                return

            sender_task = asyncio.create_task(_sender_loop(last_sent))
            receiver_task = asyncio.create_task(_receiver_loop())
            done, pending = await asyncio.wait(
                [sender_task, receiver_task],
                return_when=asyncio.FIRST_COMPLETED,
            )
            for p in pending:
                p.cancel()
                try:
                    await p
                except (asyncio.CancelledError, Exception):
                    pass
            for d in done:
                try:
                    exc = d.exception()
                except asyncio.CancelledError:
                    exc = None
                if exc and not isinstance(exc, (WebSocketDisconnect, ConnectionResetError, BrokenPipeError)):
                    disconnect_reason = f"{type(exc).__name__}: {exc}"
        except WebSocketDisconnect as exc:
            disconnect_reason = f"ws_disconnect:{exc.code}"
        except (ConnectionResetError, BrokenPipeError, RuntimeError, OSError) as exc:
            disconnect_reason = f"socket:{type(exc).__name__}"
        except asyncio.CancelledError:
            disconnect_reason = "cancelled"
        finally:
            for t in (sender_task, receiver_task):
                if t and not t.done():
                    t.cancel()
                    try:
                        await t
                    except (asyncio.CancelledError, Exception):
                        pass
            sess.unsubscribe(queue)
            diagnostics_tracker.ws_disconnected(disconnect_reason)

    # --- Static PWA Frontend ---

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

    # Keep local LAN & Tailscale traffic out of desktop HTTP proxies
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
            # Use SelectorEventLoop on Windows to avoid ProactorEventLoop [WinError 64] accept burnout
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
