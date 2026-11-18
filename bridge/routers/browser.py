"""Collaborative Browser REST & WebSocket routes (Module F)."""

from __future__ import annotations

import asyncio
import json
from typing import Any

from fastapi import APIRouter, Body, Depends, Query, Request, WebSocket

from bridge.deps import emit_browser_to_session, is_valid_token, require_auth
from bridge.schemas import (
    BrowserControlRequest,
    BrowserInputRequest,
    BrowserNavigateRequest,
    BrowserSessionCreateRequest,
)

router = APIRouter()


@router.post("/api/browser/sessions", dependencies=[Depends(require_auth)])
async def api_create_browser_session(
    request: Request,
    body: BrowserSessionCreateRequest | None = Body(default=None),
) -> dict[str, Any]:
    st = request.app.state
    req = body or BrowserSessionCreateRequest()
    sess = st.browser_service.create_or_get_session(
        browser_id=req.browser_id,
        session_id=req.session_id,
        workspace_profile_id=req.workspace_profile_id,
    )
    if req.url and req.url.strip() and req.url.strip().lower() != "about:blank":
        snap = await st.browser_service.navigate(sess.browser_id, req.url.strip(), actor="human")
    else:
        snap = st.browser_service.snapshot(sess.browser_id, include_frame=True)
    emit_browser_to_session(st, snap)
    return {"ok": True, **snap}


@router.get("/api/browser/sessions", dependencies=[Depends(require_auth)])
def api_list_browser_sessions(request: Request, session_id: str | None = Query(default=None)) -> dict[str, Any]:
    return {"sessions": request.app.state.browser_service.list_sessions(session_id=session_id)}


@router.get("/api/browser/sessions/{browser_id}", dependencies=[Depends(require_auth)])
def api_get_browser_session(
    request: Request,
    browser_id: str,
    include_frame: bool = Query(default=True),
) -> dict[str, Any]:
    return request.app.state.browser_service.snapshot(browser_id, include_frame=include_frame)


@router.post("/api/browser/sessions/{browser_id}/navigate", dependencies=[Depends(require_auth)])
async def api_browser_navigate(
    request: Request,
    browser_id: str,
    body: BrowserNavigateRequest,
) -> dict[str, Any]:
    st = request.app.state
    res = await st.browser_service.navigate(browser_id, body.url, actor=body.actor)
    emit_browser_to_session(st, res)
    return res


@router.post("/api/browser/sessions/{browser_id}/back", dependencies=[Depends(require_auth)])
async def api_browser_back(request: Request, browser_id: str) -> dict[str, Any]:
    st = request.app.state
    res = await st.browser_service.go_back(browser_id, actor="human")
    emit_browser_to_session(st, res)
    return res


@router.post("/api/browser/sessions/{browser_id}/forward", dependencies=[Depends(require_auth)])
async def api_browser_forward(request: Request, browser_id: str) -> dict[str, Any]:
    st = request.app.state
    res = await st.browser_service.go_forward(browser_id, actor="human")
    emit_browser_to_session(st, res)
    return res


@router.post("/api/browser/sessions/{browser_id}/reload", dependencies=[Depends(require_auth)])
async def api_browser_reload(request: Request, browser_id: str) -> dict[str, Any]:
    st = request.app.state
    res = await st.browser_service.reload(browser_id, actor="human")
    emit_browser_to_session(st, res)
    return res


@router.post("/api/browser/sessions/{browser_id}/close", dependencies=[Depends(require_auth)])
def api_browser_close(request: Request, browser_id: str) -> dict[str, Any]:
    closed = request.app.state.browser_service.close_session(browser_id)
    return {"ok": True, "closed": closed, "browser_id": browser_id}


@router.post("/api/browser/sessions/{browser_id}/input", dependencies=[Depends(require_auth)])
async def api_browser_input(
    request: Request,
    browser_id: str,
    body: BrowserInputRequest,
) -> dict[str, Any]:
    st = request.app.state
    bs = st.browser_service
    act = (body.action or "").strip().lower()
    actor = body.actor or "human"
    if act == "type" or (not act and body.text is not None):
        res = await bs.type_text(
            browser_id,
            text=body.text or "",
            element_id=body.element_id,
            submit=body.submit,
            actor=actor,
        )
    elif act == "scroll" or (
        not act and body.delta_y is not None and body.element_id is None and body.x is None
    ):
        res = await bs.scroll(
            browser_id,
            delta_y=int(body.delta_y if body.delta_y is not None else 360),
            actor=actor,
        )
    else:
        res = await bs.click(
            browser_id,
            element_id=body.element_id,
            x=body.x,
            y=body.y,
            actor=actor,
        )
    emit_browser_to_session(st, res)
    return res


@router.post("/api/browser/sessions/{browser_id}/control", dependencies=[Depends(require_auth)])
def api_browser_control(
    request: Request,
    browser_id: str,
    body: BrowserControlRequest,
) -> dict[str, Any]:
    st = request.app.state
    res = st.browser_service.set_control(browser_id, body.owner, reason=body.reason)
    emit_browser_to_session(st, res)
    return res


@router.post("/api/browser/sessions/{browser_id}/screenshot", dependencies=[Depends(require_auth)])
def api_browser_screenshot(request: Request, browser_id: str) -> dict[str, Any]:
    st = request.app.state
    res = st.browser_service.save_frame_as_attachment(browser_id, st.attachment_service)
    bs = st.browser_service.create_or_get_session(browser_id=browser_id)
    if bs.session_id in st.session_manager.sessions:
        st.session_manager.sessions[bs.session_id].emit_event("image_attachment", res)
    return res


@router.post("/api/browser/sessions/{browser_id}/rpc_result", dependencies=[Depends(require_auth)])
def api_browser_rpc_result(
    request: Request,
    browser_id: str,
    body: dict[str, Any] = Body(...),
) -> dict[str, Any]:
    st = request.app.state
    cmd_id = str(body.get("cmd_id") or "").strip()
    snap = st.browser_service.resolve_mobile_rpc(browser_id, cmd_id, body)
    if not cmd_id:
        emit_browser_to_session(st, snap)
    return {"ok": True, **snap}


@router.websocket("/ws/browser/{browser_id}")
async def ws_browser(
    websocket: WebSocket,
    browser_id: str,
    token: str = Query(default=""),
) -> None:
    st = websocket.app.state
    if not is_valid_token(st, token):
        await websocket.close(code=4401)
        return
    await websocket.accept()
    browser_service = st.browser_service
    queue = browser_service.subscribe(browser_id)
    send_lock = asyncio.Lock()

    async def _safe_send(payload: dict[str, Any]) -> bool:
        try:
            async with send_lock:
                await asyncio.wait_for(websocket.send_json(payload), timeout=10.0)
            return True
        except Exception:
            return False

    async def _sender_loop() -> None:
        try:
            while True:
                try:
                    ev = await asyncio.wait_for(queue.get(), timeout=15.0)
                    if not await _safe_send(ev):
                        return
                except asyncio.TimeoutError:
                    if not await _safe_send({"type": "ping"}):
                        return
        except asyncio.CancelledError:
            return

    async def _receiver_loop() -> None:
        try:
            while True:
                raw_msg = await websocket.receive_text()
                trimmed = raw_msg.strip()
                if trimmed == "ping":
                    await _safe_send({"type": "pong"})
                    continue
                try:
                    cmd = json.loads(trimmed)
                except json.JSONDecodeError:
                    continue
                if not isinstance(cmd, dict):
                    continue
                ctype = str(cmd.get("type") or cmd.get("action") or "").lower()
                if ctype == "navigate" and cmd.get("url"):
                    await browser_service.navigate(browser_id, str(cmd["url"]), actor="human")
                elif ctype == "click":
                    await browser_service.click(
                        browser_id,
                        element_id=cmd.get("element_id"),
                        x=cmd.get("x"),
                        y=cmd.get("y"),
                        actor="human",
                    )
                elif ctype == "type":
                    await browser_service.type_text(
                        browser_id,
                        text=str(cmd.get("text") or ""),
                        element_id=cmd.get("element_id"),
                        submit=bool(cmd.get("submit", False)),
                        actor="human",
                    )
                elif ctype == "scroll":
                    try:
                        step_y = int(cmd.get("delta_y", 360))
                    except (TypeError, ValueError):
                        step_y = 360
                    await browser_service.scroll(browser_id, delta_y=step_y, actor="human")
                elif ctype == "control" and cmd.get("owner") in ("agent", "human"):
                    browser_service.set_control(browser_id, cmd["owner"])
        except Exception:
            return

    sender_task: asyncio.Task[None] | None = None
    receiver_task: asyncio.Task[None] | None = None
    try:
        init_snap = browser_service.snapshot(browser_id, include_frame=True)
        if not await _safe_send({"type": "frame", **init_snap}):
            return
        sender_task = asyncio.create_task(_sender_loop())
        receiver_task = asyncio.create_task(_receiver_loop())
        _, pending = await asyncio.wait(
            [sender_task, receiver_task],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for p in pending:
            p.cancel()
    finally:
        for t in (sender_task, receiver_task):
            if t and not t.done():
                t.cancel()
        browser_service.unsubscribe(browser_id, queue)
