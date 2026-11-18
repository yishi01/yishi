"""PC DSH Plugins and Sandbox Simulator API routes."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request

from bridge.deps import require_auth
from bridge.sandbox_runner import audit_untrusted_code
from bridge.schemas import (
    DshConfigRequest,
    DshInstallRequest,
    DshToggleRequest,
    PluginConfigUpdateRequest,
    PluginInstallRequest,
    PluginRunRequest,
    PluginToggleRequest,
    SandboxAuditRequest,
    SandboxRunRequest,
)

router = APIRouter()


@router.get("/api/plugins", dependencies=[Depends(require_auth)])
def api_list_plugins(request: Request) -> dict[str, Any]:
    return request.app.state.plugin_service.list_all()


@router.post("/api/plugins/install", dependencies=[Depends(require_auth)])
async def api_install_plugin(request: Request, body: PluginInstallRequest) -> dict[str, Any]:
    plugin_service = request.app.state.plugin_service
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


@router.post("/api/plugins/dsh/toggle", dependencies=[Depends(require_auth)])
def api_dsh_toggle(request: Request, body: DshToggleRequest) -> dict[str, Any]:
    ps = request.app.state.plugin_service
    try:
        if body.kind == "bundle":
            prof = ps.toggle_dsh_bundle(body.id, body.enabled)
        else:
            prof = ps.update_dsh_patch_entry(body.id, enabled=body.enabled)
        return {"ok": True, "dsh_profile": prof}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.put("/api/plugins/dsh/config", dependencies=[Depends(require_auth)])
def api_dsh_config(request: Request, body: DshConfigRequest) -> dict[str, Any]:
    ps = request.app.state.plugin_service
    try:
        prof = ps.update_dsh_patch_entry(body.entry_id, enabled=body.enabled, config=body.config)
        return {"ok": True, "dsh_profile": prof}
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/api/plugins/dsh/install", dependencies=[Depends(require_auth)])
async def api_dsh_install(request: Request, body: DshInstallRequest) -> dict[str, Any]:
    ps = request.app.state.plugin_service
    try:
        return await asyncio.to_thread(ps.install_dsh_package, body.spec)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/api/plugins/{plugin_id}/toggle", dependencies=[Depends(require_auth)])
def api_toggle_plugin(request: Request, plugin_id: str, body: PluginToggleRequest) -> dict[str, Any]:
    ps = request.app.state.plugin_service
    try:
        plugin = ps.toggle_plugin(plugin_id, body.enabled)
        return {"ok": True, "plugin": plugin, **ps.list_all()}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.put("/api/plugins/{plugin_id}/config", dependencies=[Depends(require_auth)])
def api_update_plugin_config(
    request: Request, plugin_id: str, body: PluginConfigUpdateRequest
) -> dict[str, Any]:
    ps = request.app.state.plugin_service
    try:
        plugin = ps.update_plugin_config(plugin_id, config=body.config, env=body.env, enabled=body.enabled)
        return {"ok": True, "plugin": plugin, **ps.list_all()}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/api/plugins/{plugin_id}/run", dependencies=[Depends(require_auth)])
async def api_run_plugin(request: Request, plugin_id: str, body: PluginRunRequest) -> dict[str, Any]:
    st = request.app.state
    try:
        ws_dir = body.workspace or st.config_store.config.effective_active_workspace()
        return await asyncio.to_thread(
            st.plugin_service.run_plugin_tool,
            plugin_id,
            tool_name=body.tool_name,
            args=body.args,
            stdin_text=body.stdin_text,
            workspace_cwd=ws_dir,
            timeout_sec=body.timeout_sec,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.delete("/api/plugins/{plugin_id}", dependencies=[Depends(require_auth)])
def api_delete_plugin(request: Request, plugin_id: str) -> dict[str, Any]:
    ps = request.app.state.plugin_service
    try:
        ps.uninstall_plugin(plugin_id)
        return {"ok": True, **ps.list_all()}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/api/sandbox/audit", dependencies=[Depends(require_auth)])
def api_sandbox_audit(body: SandboxAuditRequest) -> dict[str, Any]:
    return audit_untrusted_code(body.code, language=body.language, filename=body.filename)


@router.post("/api/sandbox/run", dependencies=[Depends(require_auth)])
async def api_sandbox_run(request: Request, body: SandboxRunRequest) -> dict[str, Any]:
    return await asyncio.to_thread(
        request.app.state.sandbox_runner.run_sandbox_script,
        body.code,
        body.language,
        timeout_sec=body.timeout_sec,
        allow_network=body.allow_network,
        args=body.args,
        stdin_text=body.stdin_text,
    )
