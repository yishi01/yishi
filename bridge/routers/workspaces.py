"""Workspace Profiles CRUD routes (Module A)."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request

from bridge.deps import require_auth

router = APIRouter()


@router.get("/api/workspace-profiles", dependencies=[Depends(require_auth)])
def api_list_workspace_profiles(request: Request) -> dict[str, Any]:
    return {"profiles": request.app.state.workspace_service.list_profiles()}


@router.post("/api/workspace-profiles", dependencies=[Depends(require_auth)])
def api_create_workspace_profile(request: Request, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    ws_svc = request.app.state.workspace_service
    try:
        prof = ws_svc.create_profile(payload)
        return {"ok": True, "profile": prof, "profiles": ws_svc.list_profiles()}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.put("/api/workspace-profiles/{profile_id}", dependencies=[Depends(require_auth)])
def api_update_workspace_profile(
    request: Request,
    profile_id: str,
    payload: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    ws_svc = request.app.state.workspace_service
    try:
        prof = ws_svc.update_profile(profile_id, payload)
        return {"ok": True, "profile": prof, "profiles": ws_svc.list_profiles()}
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.delete("/api/workspace-profiles/{profile_id}", dependencies=[Depends(require_auth)])
def api_delete_workspace_profile(
    request: Request,
    profile_id: str,
    delete_sessions: bool = Query(default=False),
) -> dict[str, Any]:
    ws_svc = request.app.state.workspace_service
    try:
        res = ws_svc.delete_profile(profile_id, delete_sessions=delete_sessions)
        return {"ok": True, **res, "profiles": ws_svc.list_profiles()}
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
