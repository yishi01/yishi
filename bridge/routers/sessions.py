"""Session lifecycle, turns, queue, approvals, subagents, and session WebSocket routes."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request, WebSocket, WebSocketDisconnect

from bridge.deps import get_session_or_404, is_valid_token, require_auth, resolve_allowed_workspace
from bridge.log_service import get_diagnostics_tracker
from bridge.schemas import (
    ApprovalDecisionRequest,
    CreateSessionRequest,
    EditTurnRequest,
    InteractionDecisionRequest,
    MoveSessionRequest,
    RegenerateTurnRequest,
    RenameSessionRequest,
    SendMessageRequest,
)

router = APIRouter()


@router.get("/api/sessions", dependencies=[Depends(require_auth)])
def api_list_sessions(
    request: Request,
    workspace_profile_id: str | None = Query(default=None),
) -> dict[str, Any]:
    return {"sessions": request.app.state.session_manager.list_sessions(workspace_profile_id=workspace_profile_id)}


@router.post("/api/sessions", dependencies=[Depends(require_auth)])
def api_create_session(request: Request, body: CreateSessionRequest) -> dict[str, Any]:
    st = request.app.state
    ws_arg = body.workspace
    if not ws_arg and body.workspace_profile_id:
        try:
            wp = st.workspace_service.get_profile(body.workspace_profile_id)
            rpaths = wp.get("root_paths") or []
            if rpaths and Path(rpaths[0]).exists():
                ws_arg = rpaths[0]
        except KeyError:
            pass
    root = resolve_allowed_workspace(st, ws_arg)
    if body.approval_mode and body.approval_mode not in {"ask_commands", "ask_writes", "auto"}:
        raise HTTPException(status_code=400, detail="Invalid approval_mode")
    sess = st.session_manager.create_session(
        workspace=str(root),
        workspace_profile_id=body.workspace_profile_id,
        title=body.title,
        approval_mode=body.approval_mode,
        model=body.model,
        profile_id=body.profile_id,
    )
    return sess.summary()


@router.patch("/api/sessions/{session_id}", dependencies=[Depends(require_auth)])
def api_rename_session(request: Request, session_id: str, body: RenameSessionRequest) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    summary = sess.rename(body.title)
    return {"ok": True, "session": summary, **summary}


@router.post("/api/sessions/{session_id}/move", dependencies=[Depends(require_auth)])
def api_move_session(request: Request, session_id: str, body: MoveSessionRequest) -> dict[str, Any]:
    try:
        sess = request.app.state.session_manager.move_session(session_id, body.workspace_profile_id)
        summary = sess.summary()
        return {"ok": True, "session": summary, **summary}
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.delete("/api/sessions/{session_id}/turns/{turn_id}", dependencies=[Depends(require_auth)])
async def api_delete_turn(request: Request, session_id: str, turn_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    try:
        summary = await sess.delete_turn(turn_id)
        return {"ok": True, "turn_id": turn_id, "session": summary}
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/api/sessions/{session_id}/turns/{turn_id}/edit", dependencies=[Depends(require_auth)])
async def api_edit_turn(
    request: Request,
    session_id: str,
    turn_id: str,
    body: EditTurnRequest,
) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    try:
        new_text = body.text if body.text else body.prompt
        ev = await sess.edit_turn(
            turn_id,
            new_text,
            model=body.model,
            profile_id=body.profile_id,
            attachments=body.attachments,
        )
        return {
            "ok": True,
            "event": ev,
            "turn_id": ev.get("turn_id"),
            "session": sess.summary(),
        }
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/api/sessions/{session_id}/turns/{turn_id}/regenerate", dependencies=[Depends(require_auth)])
async def api_regenerate_turn(
    request: Request,
    session_id: str,
    turn_id: str,
    body: RegenerateTurnRequest | None = Body(default=None),
) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    req = body or RegenerateTurnRequest()
    try:
        ev = await sess.regenerate_turn(turn_id, model=req.model, profile_id=req.profile_id)
        return {
            "ok": True,
            "event": ev,
            "turn_id": ev.get("turn_id"),
            "session": sess.summary(),
        }
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/api/sessions/{session_id}/agents", dependencies=[Depends(require_auth)])
def api_list_session_agents(request: Request, session_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    return {"session_id": session_id, "agents": sess.list_subagents()}


@router.post("/api/sessions/{session_id}/agents/{agent_id}/cancel", dependencies=[Depends(require_auth)])
async def api_cancel_session_agent(request: Request, session_id: str, agent_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    sub = sess.subagents.get(agent_id)
    if sub is None:
        raise HTTPException(status_code=404, detail=f"Sub-agent not found: {agent_id}")
    await sub.cancel_turn()
    team = sess.list_subagents()
    sess.emit_event("agent_team_update", {"agents": team})
    return {"ok": True, "agent_id": agent_id, "status": sub.status, "agents": team}


@router.delete("/api/sessions/{session_id}", dependencies=[Depends(require_auth)])
async def api_delete_session(request: Request, session_id: str) -> dict[str, Any]:
    try:
        await request.app.state.session_manager.delete_session(session_id)
        return {"deleted": session_id}
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/api/sessions/{session_id}/events", dependencies=[Depends(require_auth)])
def api_get_events(
    request: Request,
    session_id: str,
    after_seq: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    return {"session": sess.summary(), "events": sess.get_events_after(after_seq)}


@router.post("/api/sessions/{session_id}/message", dependencies=[Depends(require_auth)])
async def api_send_message(request: Request, session_id: str, body: SendMessageRequest) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    try:
        ev = await sess.send_prompt(
            body.prompt,
            model=body.model,
            profile_id=body.profile_id,
            attachments=body.attachments,
            queue_if_busy=body.queue_if_busy,
        )
        return {
            "event": ev,
            "turn_id": ev.get("turn_id"),
            "queued": bool(ev.get("queued", False)),
            "queue_item": ev.get("queue_item"),
            "session": sess.summary(),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.get("/api/sessions/{session_id}/queue", dependencies=[Depends(require_auth)])
def api_list_queue(request: Request, session_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    return {"queued_messages": sess.list_queue(), "session": sess.summary()}


@router.post("/api/sessions/{session_id}/queue/{item_id}/send_now", dependencies=[Depends(require_auth)])
async def api_send_queued_now(request: Request, session_id: str, item_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    try:
        res = await sess.send_queued_now(item_id)
        return {"ok": True, "result": res, "session": sess.summary()}
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.delete("/api/sessions/{session_id}/queue/{item_id}", dependencies=[Depends(require_auth)])
def api_delete_queued_item(request: Request, session_id: str, item_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    if not sess.remove_queued_item(item_id):
        raise HTTPException(status_code=404, detail="Queue item not found")
    return {"ok": True, "session": sess.summary()}


@router.delete("/api/sessions/{session_id}/queue", dependencies=[Depends(require_auth)])
def api_clear_queue(request: Request, session_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    cleared = sess.clear_queue()
    return {"ok": True, "cleared": cleared, "session": sess.summary()}


@router.post("/api/sessions/{session_id}/cancel", dependencies=[Depends(require_auth)])
async def api_cancel_turn(request: Request, session_id: str) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    await sess.cancel_turn()
    return {"session": sess.summary()}


@router.post("/api/sessions/{session_id}/approvals/{request_id}", dependencies=[Depends(require_auth)])
def api_resolve_approval(
    request: Request,
    session_id: str,
    request_id: str,
    body: ApprovalDecisionRequest,
) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    ok = sess.resolve_approval(
        request_id,
        allow=body.allow,
        reason=body.reason,
        set_approval_mode=body.set_approval_mode,
    )
    if not ok:
        raise HTTPException(status_code=404, detail="Pending approval not found or already resolved")
    return {"ok": True, "session": sess.summary()}


@router.post("/api/sessions/{session_id}/interactions/{request_id}", dependencies=[Depends(require_auth)])
def api_resolve_interaction(
    request: Request,
    session_id: str,
    request_id: str,
    body: InteractionDecisionRequest,
) -> dict[str, Any]:
    sess = get_session_or_404(request, session_id)
    ok = sess.resolve_interaction(
        request_id,
        responses=body.responses,
        cancelled=body.cancelled,
    )
    if not ok:
        raise HTTPException(status_code=404, detail="Pending interaction not found or already resolved")
    return {"ok": True, "session": sess.summary()}


@router.websocket("/ws/sessions/{session_id}")
async def ws_session(
    websocket: WebSocket,
    session_id: str,
    token: str = Query(default=""),
    after_seq: int = Query(default=0),
    client_browser: int = Query(default=0),
) -> None:
    st = websocket.app.state
    if not is_valid_token(st, token):
        await websocket.close(code=4401)
        return
    try:
        sess = st.session_manager.get_session(session_id)
    except KeyError:
        await websocket.close(code=4404)
        return

    diagnostics_tracker = get_diagnostics_tracker()
    browser_service = st.browser_service
    await websocket.accept()
    diagnostics_tracker.ws_connected(is_reconnect=after_seq > 0)
    queue = sess.subscribe()
    mobile_dispatch_fn = (
        (lambda payload: sess.emit_event("browser_rpc", payload, persist=False))
        if client_browser > 0
        else None
    )
    if mobile_dispatch_fn is not None:
        browser_service.add_mobile_executor(session_id, mobile_dispatch_fn)
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
        if mobile_dispatch_fn is not None:
            browser_service.remove_mobile_executor(session_id, mobile_dispatch_fn)
        for t in (sender_task, receiver_task):
            if t and not t.done():
                t.cancel()
                try:
                    await t
                except (asyncio.CancelledError, Exception):
                    pass
        sess.unsubscribe(queue)
        diagnostics_tracker.ws_disconnected(disconnect_reason)
