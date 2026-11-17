"""FastAPI + WebSocket mobile bridge server powered by DeepSeek."""

from __future__ import annotations

import asyncio
import hmac
import logging
import mimetypes
import os
import socket
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

# Ensure project root is importable when launched from sidecar cwd
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from bridge.config import VERSION, BridgeConfig, ConfigStore
from bridge.deepseek_agent import SessionManager
from bridge.fs_service import (
    FileConflictError,
    WorkspaceSecurityError,
    create_entry,
    delete_entry,
    git_status_and_diff,
    list_directory,
    read_file_content,
    rename_entry,
    search_workspace,
    write_file_content,
)

mimetypes.add_type("application/manifest+json", ".webmanifest")


class AuthVerifyRequest(BaseModel):
    token: str


class SettingsUpdateRequest(BaseModel):
    workspaces: list[str] | None = None
    default_approval_mode: str | None = None
    bark_url: str | None = None
    deepseek_base_url: str | None = None
    model: str | None = None
    deepseek_api_key: str | None = None


class CreateSessionRequest(BaseModel):
    workspace: str | None = None
    title: str = "New Session"
    approval_mode: str | None = None
    model: str | None = None


class SendMessageRequest(BaseModel):
    prompt: str
    model: str | None = None


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


def create_app(data_dir: Path | None = None) -> FastAPI:
    config_store = ConfigStore(data_dir=data_dir)
    session_manager = SessionManager(config_store)
    web_dir = PROJECT_ROOT / "web"

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        yield
        await session_manager.shutdown()

    app = FastAPI(title="DeepSeek Mobile Bridge", version=VERSION, lifespan=lifespan)
    app.state.config_store = config_store
    app.state.session_manager = session_manager

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def no_cache_static(request, call_next):
        response = await call_next(request)
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
    ) -> None:
        token = x_auth_token
        if not token and authorization and authorization.lower().startswith("bearer "):
            token = authorization[7:].strip()
        if not _is_valid_token(token):
            raise HTTPException(status_code=401, detail="Invalid or missing auth token")

    def resolve_allowed_workspace(workspace: str | None) -> Path:
        allowed = [Path(w).resolve() for w in config_store.config.workspaces]
        if not allowed:
            raise HTTPException(status_code=400, detail="No workspaces configured")
        if not workspace:
            return allowed[0]
        candidate = Path(workspace).resolve()
        if candidate not in allowed:
            raise HTTPException(status_code=403, detail="Workspace not in configured allowlist")
        if not candidate.exists() or not candidate.is_dir():
            raise HTTPException(status_code=404, detail="Workspace directory not found")
        return candidate

    @app.get("/health")
    @app.get("/api/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "version": VERSION,
            "host": config_store.config.host,
            "port": config_store.config.port,
        }

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
                p = Path(raw_ws.strip()).expanduser()
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

        updated = config_store.save(BridgeConfig(**cfg_data))
        return updated.to_public_dict()

    # --- Workspace File & Git APIs ---

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
            ev = await sess.send_prompt(body.prompt, model=body.model)
            return {"event": ev, "session": sess.summary()}
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc

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
        queue = sess.subscribe()
        try:
            missed = sess.get_events_after(after_seq)
            last_sent = after_seq
            for ev in missed:
                await websocket.send_json(ev)
                last_sent = max(last_sent, ev["seq"])

            await websocket.send_json({"type": "sync_complete", "session": sess.summary()})

            while True:
                try:
                    ev = await asyncio.wait_for(queue.get(), timeout=25.0)
                    if ev["seq"] > last_sent:
                        await websocket.send_json(ev)
                        last_sent = ev["seq"]
                except asyncio.TimeoutError:
                    await websocket.send_json({"type": "ping"})
        except WebSocketDisconnect:
            pass
        finally:
            sess.unsubscribe(queue)

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
    store = ConfigStore()
    cfg = store.config
    log_path = store.data_dir / "bridge.log"
    pid_path = store.data_dir / "bridge.pid"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_path, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )

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
    print(f"DeepSeek Mobile Bridge v{VERSION} (iOS PWA)")
    print(f"Listening: http://{cfg.host}:{cfg.port} (Health: /api/health)")
    print(f"Workspaces: {', '.join(cfg.workspaces)}")
    print(f"Model: {cfg.model} ({cfg.effective_base_url()})")
    print(f"Auth Token: {cfg.auth_token}")
    print(f"Config Path: {store.config_path}")
    print(f"Log Path: {log_path}")
    print("=" * 60)
    try:
        uvicorn.run(create_app(), host=cfg.host, port=cfg.port, log_level="info")
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
