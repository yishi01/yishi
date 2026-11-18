"""FastAPI dependency helpers for auth, workspace lookup, session lookup, and LAN discovery."""

from __future__ import annotations

import hmac
import socket
from pathlib import Path
from typing import Any

from fastapi import Header, HTTPException, Query, Request


def is_valid_token(app_state: Any, candidate: str | None) -> bool:
    expected = app_state.config_store.config.auth_token
    if not candidate or not expected:
        return False
    return hmac.compare_digest(candidate.strip(), expected)


def require_auth(
    request: Request,
    authorization: str | None = Header(default=None),
    x_auth_token: str | None = Header(default=None),
    token: str | None = Query(default=None),
) -> None:
    tok = x_auth_token
    if not tok and authorization and authorization.lower().startswith("bearer "):
        tok = authorization[7:].strip()
    if not tok and token:
        tok = token.strip()
    if not is_valid_token(request.app.state, tok):
        raise HTTPException(status_code=401, detail="Invalid or missing auth token")


def resolve_allowed_workspace(app_state: Any, workspace: str | None) -> Path:
    cfg = app_state.config_store.config
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


def get_session_or_404(request: Request, session_id: str) -> Any:
    try:
        return request.app.state.session_manager.get_session(session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


def discover_local_ipv4s() -> list[str]:
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


def emit_browser_to_session(app_state: Any, snap: dict[str, Any]) -> None:
    sid = str(snap.get("session_id") or "").strip()
    sm = app_state.session_manager
    if sid and sid in sm.sessions:
        try:
            sm.sessions[sid].emit_event("browser_state", snap)
        except Exception:
            pass
