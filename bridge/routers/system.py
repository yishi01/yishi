"""System, health, auth, tunnel, settings, provider tests, and diagnostics routes."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from xml.sax.saxutils import escape as xml_escape

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import Response

from bridge.attachment_service import ONE_BY_ONE_PNG_BASE64
from bridge.config import VERSION, BridgeConfig
from bridge.deps import discover_local_ipv4s, is_valid_token, require_auth
from bridge.log_service import collect_pc_diagnostics, get_log_handler, run_pc_self_check
from bridge.schemas import (
    AuthorizeWorkspaceRequest,
    AuthVerifyRequest,
    ProviderTestRequest,
    SearchTestRequest,
    SettingsUpdateRequest,
)
from bridge.search_service import execute_web_search
from bridge.utils import normalize_windows_drive_path

router = APIRouter()


@router.get("/health")
@router.get("/api/health")
def health(request: Request) -> dict[str, Any]:
    st = request.app.state
    return {
        "status": "ok",
        "version": VERSION,
        "host": st.config_store.config.host,
        "port": st.config_store.config.port,
        "public_url": st.tunnel_manager.live_url or st.config_store.config.public_url,
        "tunnel_status": st.tunnel_manager.status,
        "lan_ips": discover_local_ipv4s(),
    }


@router.get("/api/tunnel/status", dependencies=[Depends(require_auth)])
def api_tunnel_status(request: Request) -> dict[str, Any]:
    return request.app.state.tunnel_manager.info()


@router.post("/api/tunnel/restart", dependencies=[Depends(require_auth)])
async def api_tunnel_restart(request: Request) -> dict[str, Any]:
    tm = request.app.state.tunnel_manager
    await tm.start()
    for _ in range(16):
        if tm.live_url or tm.status in ("error", "missing_binary", "stopped", "disabled"):
            break
        await asyncio.sleep(0.5)
    return tm.info()


@router.post("/api/tunnel/sync_rendezvous", dependencies=[Depends(require_auth)])
async def api_tunnel_sync_rendezvous(request: Request) -> dict[str, Any]:
    tm = request.app.state.tunnel_manager
    res = await asyncio.to_thread(tm.publish_rendezvous_sync)
    return {"result": res, "tunnel": tm.info()}


@router.get("/install.mobileconfig")
def install_mobileconfig(url: str = Query(default="http://dsh-pc/")) -> Response:
    raw_url = url.strip() or "http://dsh-pc/"
    parsed_url = urlparse(raw_url)
    if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
        raise HTTPException(status_code=400, detail="Invalid URL scheme for mobileconfig")
    safe_url = xml_escape(raw_url, {'"': "&quot;", "'": "&apos;"})
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
      <string>{safe_url}</string>
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


@router.post("/api/auth/verify")
def verify_auth(request: Request, body: AuthVerifyRequest) -> dict[str, Any]:
    if not is_valid_token(request.app.state, body.token):
        raise HTTPException(status_code=401, detail="Invalid token")
    return {"ok": True, "settings": request.app.state.config_store.config.to_public_dict()}


@router.get("/api/settings", dependencies=[Depends(require_auth)])
def get_settings(request: Request) -> dict[str, Any]:
    return request.app.state.config_store.config.to_public_dict()


@router.put("/api/settings", dependencies=[Depends(require_auth)])
def update_settings(request: Request, body: SettingsUpdateRequest) -> dict[str, Any]:
    st = request.app.state
    config_store = st.config_store
    wallet_service = st.wallet_service
    plugin_service = st.plugin_service

    cfg_data = config_store.config.model_dump()
    if body.workspaces is not None:
        valid_ws: list[str] = []
        for raw_ws in body.workspaces:
            clean_ws = normalize_windows_drive_path(raw_ws)
            p = Path(clean_ws).expanduser()
            if not p.exists() or not p.is_dir():
                raise HTTPException(status_code=400, detail=f"Invalid workspace directory: {raw_ws}")
            resolved = str(p.resolve())
            if resolved not in valid_ws:
                valid_ws.append(resolved)
        if not valid_ws:
            raise HTTPException(status_code=400, detail="At least one workspace is required")
        cfg_data["workspaces"] = valid_ws

    if body.active_workspace is not None and body.active_workspace.strip():
        clean_act = normalize_windows_drive_path(body.active_workspace)
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
            model_str = str(raw_p.get("model") or "").strip()
            cleaned_profiles.append(
                {
                    "id": pid,
                    "name": str(raw_p.get("name") or pid).strip(),
                    "provider": str(raw_p.get("provider") or "openai_compatible").strip(),
                    "base_url": str(raw_p.get("base_url") or "").strip().rstrip("/"),
                    "api_key": final_key,
                    "model": model_str,
                    "temperature": float(raw_p.get("temperature") if raw_p.get("temperature") is not None else 0.7),
                    "max_tokens": int(raw_p.get("max_tokens") or 8192),
                    "supports_tools": bool(raw_p.get("supports_tools", True)),
                    "supports_reasoning": bool(raw_p.get("supports_reasoning", False)),
                    "supports_vision": bool(
                        raw_p.get(
                            "supports_vision",
                            any(k in model_str.lower() for k in ("flash", "gpt-4o", "claude", "vision", "vl", "gemini")),
                        )
                    ),
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

    if body.wallet_rules is not None and isinstance(body.wallet_rules, dict):
        cfg_data["wallet_rules"] = wallet_service.update_rules(body.wallet_rules)

    if body.model_pricing is not None and isinstance(body.model_pricing, dict):
        cfg_data["model_pricing"] = wallet_service.update_pricing(body.model_pricing)

    if body.browser_policy is not None and isinstance(body.browser_policy, dict):
        old_bp = dict(cfg_data.get("browser_policy") or {})
        cfg_data["browser_policy"] = {**old_bp, **body.browser_policy}

    cfg_obj = BridgeConfig(**cfg_data)
    if body.active_profile_id is not None and body.active_profile_id.strip():
        cfg_obj.apply_active_profile(body.active_profile_id.strip())
        wallet_service.reset_downgrade()
    elif body.model is not None:
        matched = next((p.get("id") for p in cfg_obj.model_profiles if p.get("model") == cfg_obj.model), None)
        if matched:
            cfg_obj.active_profile_id = str(matched)
        wallet_service.reset_downgrade()

    if body.deepseek_base_url is not None and body.deepseek_base_url.strip():
        clean_url = body.deepseek_base_url.strip().rstrip("/")
        cfg_obj.deepseek_base_url = clean_url
        for prof in cfg_obj.model_profiles:
            if prof.get("id") == cfg_obj.active_profile_id and prof.get("provider", "openai_compatible") == "openai_compatible":
                prof["base_url"] = clean_url
                break

    updated = config_store.save(cfg_obj)
    return updated.to_public_dict()


@router.post("/api/providers/test", dependencies=[Depends(require_auth)])
async def api_test_provider(request: Request, body: ProviderTestRequest) -> dict[str, Any]:
    import time as _time

    cfg = request.app.state.config_store.config
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
            if body.test_vision:
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
                            "messages": [
                                {
                                    "role": "user",
                                    "content": [
                                        {
                                            "type": "image",
                                            "source": {
                                                "type": "base64",
                                                "media_type": "image/png",
                                                "data": ONE_BY_ONE_PNG_BASE64,
                                            },
                                        },
                                        {"type": "text", "text": "ping"},
                                    ],
                                }
                            ],
                        },
                    )
                else:
                    resp = await client.post(
                        f"{base_url}/chat/completions",
                        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                        json={
                            "model": model,
                            "max_tokens": 8,
                            "messages": [
                                {
                                    "role": "user",
                                    "content": [
                                        {"type": "text", "text": "ping"},
                                        {
                                            "type": "image_url",
                                            "image_url": {"url": f"data:image/png;base64,{ONE_BY_ONE_PNG_BASE64}"},
                                        },
                                    ],
                                }
                            ],
                        },
                    )
            elif provider == "anthropic":
                url = f"{base_url}/messages" if base_url.endswith("/v1") else f"{base_url}/v1/messages"
                resp = await client.post(
                    url,
                    headers={
                        "x-api-key": api_key,
                        "anthropic-version": "2023-06-01",
                        "Content-Type": "application/json",
                    },
                    json={"model": model, "max_tokens": 8, "messages": [{"role": "user", "content": "ping"}]},
                )
            else:
                url = f"{base_url}/models"
                resp = await client.get(url, headers={"Authorization": f"Bearer {api_key}"})
                if resp.status_code in (404, 405):
                    resp = await client.post(
                        f"{base_url}/chat/completions",
                        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                        json={"model": model, "max_tokens": 4, "messages": [{"role": "user", "content": "hi"}]},
                    )
        ms = round((_time.perf_counter() - started) * 1000, 1)
        ok = 200 <= resp.status_code < 300
        detail = f"HTTP {resp.status_code} 连通成功 ({model})" if ok else f"HTTP {resp.status_code}: {resp.text[:300]}"
        result: dict[str, Any] = {"ok": ok, "status_code": resp.status_code, "latency_ms": ms, "detail": detail}
        if body.test_vision:
            result["supports_vision"] = ok
        return result
    except Exception as exc:
        ms = round((_time.perf_counter() - started) * 1000, 1)
        res_err: dict[str, Any] = {"ok": False, "status_code": 0, "latency_ms": ms, "detail": str(exc)}
        if body.test_vision:
            res_err["supports_vision"] = False
        return res_err


@router.post("/api/search/test", dependencies=[Depends(require_auth)])
async def api_test_search(request: Request, body: SearchTestRequest) -> dict[str, Any]:
    sc = dict(request.app.state.config_store.config.search_config)
    if body.search_config:
        incoming = dict(body.search_config)
        if not str(incoming.get("api_key") or "").strip() and sc.get("api_key"):
            incoming["api_key"] = sc["api_key"]
        sc.update(incoming)
    return await execute_web_search(body.query.strip() or "DeepSeek", sc, max_results=body.max_results)


@router.get("/api/diagnostics/status", dependencies=[Depends(require_auth)])
def api_diagnostics_status(request: Request) -> dict[str, Any]:
    st = request.app.state
    return collect_pc_diagnostics(
        version=VERSION,
        cfg=st.config_store.config,
        tunnel_status=st.tunnel_manager.info(),
        sessions=st.session_manager.list_sessions(),
        plugins_summary=st.plugin_service.summary(),
    )


@router.get("/api/diagnostics/logs", dependencies=[Depends(require_auth)])
def api_diagnostics_logs(
    level: str | None = Query(default=None),
    q: str | None = Query(default=None),
    after_seq: int = Query(default=0, ge=0),
    limit: int = Query(default=150, ge=1, le=500),
) -> dict[str, Any]:
    return {"logs": get_log_handler().query(level=level, search=q, after_seq=after_seq, limit=limit)}


@router.delete("/api/diagnostics/logs", dependencies=[Depends(require_auth)])
def api_diagnostics_clear_logs() -> dict[str, Any]:
    return {"ok": True, "cleared": get_log_handler().clear()}


@router.post("/api/diagnostics/selfcheck", dependencies=[Depends(require_auth)])
async def api_diagnostics_selfcheck(request: Request) -> dict[str, Any]:
    st = request.app.state
    return await run_pc_self_check(
        cfg=st.config_store.config,
        tunnel_status=st.tunnel_manager.info(),
        plugin_service=st.plugin_service,
        sandbox_runner=st.sandbox_runner,
    )


@router.post("/api/workspaces/authorize", dependencies=[Depends(require_auth)])
def authorize_workspace(request: Request, body: AuthorizeWorkspaceRequest) -> dict[str, Any]:
    st = request.app.state
    clean = normalize_windows_drive_path(body.path)
    target = Path(clean).resolve()
    if not target.exists():
        raise HTTPException(status_code=404, detail=f"路径不存在: {clean}")
    if not target.is_dir():
        target = target.parent
    ws_str = str(target)

    cfg_data = st.config_store.config.model_dump()
    ws_list: list[str] = list(cfg_data.get("workspaces") or [])
    if ws_str not in ws_list:
        ws_list.append(ws_str)
    cfg_data["workspaces"] = ws_list
    if body.set_active:
        cfg_data["active_workspace"] = ws_str
    updated = st.config_store.save(BridgeConfig(**cfg_data))

    if body.session_id and body.set_active:
        try:
            sess = st.session_manager.get_session(body.session_id)
            sess.workspace = ws_str
            sess.save_to_disk()
        except KeyError:
            pass
    return updated.to_public_dict()
