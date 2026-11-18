"""Full PC file manager and workspace-scoped file/git routes."""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import mimetypes
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse

from bridge.deps import require_auth, resolve_allowed_workspace
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
from bridge.schemas import (
    CreateEntryRequest,
    PCCreateEntryRequest,
    PCMoveOrCopyRequest,
    PCWriteFileRequest,
    RenameEntryRequest,
    WriteFileRequest,
)
from bridge.utils import atomic_write_bytes, normalize_windows_drive_path

router = APIRouter()


@router.get("/api/pc/drives", dependencies=[Depends(require_auth)])
def api_pc_drives(request: Request) -> dict[str, Any]:
    cfg = request.app.state.config_store.config
    return list_pc_drives(cfg.workspaces, cfg.effective_active_workspace(), cfg.ai_access_mode)


@router.get("/api/pc/list", dependencies=[Depends(require_auth)])
def api_pc_list(
    request: Request,
    path: str = Query(default=""),
    show_hidden: bool = Query(default=False),
) -> dict[str, Any]:
    cfg = request.app.state.config_store.config
    try:
        return list_pc_directory(path, cfg.workspaces, cfg.ai_access_mode, show_hidden=show_hidden)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except NotADirectoryError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc


@router.get("/api/pc/stat", dependencies=[Depends(require_auth)])
def api_pc_stat(request: Request, path: str = Query(...)) -> dict[str, Any]:
    cfg = request.app.state.config_store.config
    try:
        return stat_pc_entry(path, cfg.workspaces, cfg.ai_access_mode)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/api/pc/read", dependencies=[Depends(require_auth)])
def api_pc_read(path: str = Query(...)) -> dict[str, Any]:
    try:
        return read_pc_file(path)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except IsADirectoryError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.put("/api/pc/write", dependencies=[Depends(require_auth)])
def api_pc_write(body: PCWriteFileRequest) -> dict[str, Any]:
    try:
        return write_pc_file(body.path, body.content)
    except IsADirectoryError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/api/pc/create", dependencies=[Depends(require_auth)])
def api_pc_create(body: PCCreateEntryRequest) -> dict[str, Any]:
    try:
        return create_pc_entry(body.path, is_dir=body.is_dir, content=body.content)
    except FileExistsError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/api/pc/move", dependencies=[Depends(require_auth)])
def api_pc_move(body: PCMoveOrCopyRequest) -> dict[str, Any]:
    try:
        return rename_or_move_pc_entry(body.src_path, body.dst_path, overwrite=body.overwrite)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except FileExistsError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/api/pc/copy", dependencies=[Depends(require_auth)])
def api_pc_copy(body: PCMoveOrCopyRequest) -> dict[str, Any]:
    try:
        return copy_pc_entry(body.src_path, body.dst_path, overwrite=body.overwrite)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except FileExistsError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.delete("/api/pc/delete", dependencies=[Depends(require_auth)])
def api_pc_delete(path: str = Query(...)) -> dict[str, Any]:
    try:
        return delete_pc_entry(path)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/api/pc/upload", dependencies=[Depends(require_auth)])
async def api_pc_upload(
    request: Request,
    dir_path: str = Query(default=""),
    filename: str = Query(default=""),
) -> dict[str, Any]:
    """Upload a file from the phone to the PC (supports either JSON base64 or raw binary body)."""
    cfg = request.app.state.config_store.config
    content_type = request.headers.get("content-type", "").lower()
    cl_header = request.headers.get("content-length")
    if cl_header and cl_header.isdigit() and int(cl_header) > 70 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Upload payload too large (max 50MB)")

    try:
        if "application/json" in content_type:
            body_json = await request.json()
            target_dir_str = str(body_json.get("dir_path") or dir_path or "").strip()
            fname = str(body_json.get("filename") or filename or "uploaded_file").strip()
            b64 = str(body_json.get("base64_data") or "")
            raw_bytes = base64.b64decode(b64, validate=True)
        else:
            target_dir_str = dir_path.strip()
            fname = filename.strip() or "uploaded_file"
            raw_bytes = await request.body()
    except (ValueError, binascii.Error, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid upload payload: {exc}") from exc

    if len(raw_bytes) > 50 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Upload exceeds 50MB limit")

    safe_fname = Path(fname.replace("\\", "/")).name
    if not safe_fname or safe_fname in (".", "..") or "\x00" in safe_fname:
        raise HTTPException(status_code=400, detail=f"Invalid filename: {fname}")

    if not target_dir_str:
        target_dir = Path(cfg.effective_active_workspace()) / "uploads"
    else:
        target_dir = Path(normalize_windows_drive_path(target_dir_str)).resolve()

    dest_file = (target_dir / safe_fname).resolve()
    if dest_file.parent != target_dir.resolve():
        raise HTTPException(status_code=400, detail=f"Invalid upload destination: {safe_fname}")

    try:
        await asyncio.to_thread(atomic_write_bytes, dest_file, raw_bytes)
        st = dest_file.stat()
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {
        "ok": True,
        "name": dest_file.name,
        "path": str(dest_file),
        "dir": str(target_dir.resolve()),
        "size": st.st_size,
        "mtime": st.st_mtime,
    }


@router.get("/api/pc/download", dependencies=[Depends(require_auth)])
def api_pc_download(path: str = Query(...)) -> FileResponse:
    target = Path(normalize_windows_drive_path(path)).resolve()
    if not target.exists():
        raise HTTPException(status_code=404, detail=f"File not found: {path}")
    if target.is_dir():
        raise HTTPException(status_code=400, detail="Cannot download a directory directly")
    mime, _ = mimetypes.guess_type(target.name)
    return FileResponse(path=target, filename=target.name, media_type=mime or "application/octet-stream")


@router.get("/api/files/tree", dependencies=[Depends(require_auth)])
def api_list_tree(
    request: Request,
    workspace: str | None = Query(default=None),
    path: str = Query(default=""),
    include_ignored: bool = Query(default=False),
) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, workspace)
    try:
        return list_directory(root, path, include_ignored=include_ignored)
    except WorkspaceSecurityError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except (FileNotFoundError, NotADirectoryError) as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/api/files/read", dependencies=[Depends(require_auth)])
def api_read_file(
    request: Request,
    workspace: str | None = Query(default=None),
    path: str = Query(...),
) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, workspace)
    try:
        return read_file_content(root, path)
    except WorkspaceSecurityError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except (FileNotFoundError, IsADirectoryError) as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.put("/api/files/write", dependencies=[Depends(require_auth)])
def api_write_file(request: Request, body: WriteFileRequest) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, body.workspace)
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


@router.post("/api/files/create", dependencies=[Depends(require_auth)])
def api_create_entry(request: Request, body: CreateEntryRequest) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, body.workspace)
    try:
        return create_entry(root, body.path, is_dir=body.is_dir, content=body.content)
    except WorkspaceSecurityError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except FileExistsError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.post("/api/files/rename", dependencies=[Depends(require_auth)])
def api_rename_entry(request: Request, body: RenameEntryRequest) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, body.workspace)
    try:
        return rename_entry(root, body.old_path, body.new_path)
    except WorkspaceSecurityError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except FileExistsError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@router.delete("/api/files/delete", dependencies=[Depends(require_auth)])
def api_delete_entry(
    request: Request,
    workspace: str = Query(...),
    path: str = Query(...),
) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, workspace)
    try:
        return delete_entry(root, path)
    except WorkspaceSecurityError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/api/files/search", dependencies=[Depends(require_auth)])
def api_search_files(
    request: Request,
    workspace: str | None = Query(default=None),
    q: str = Query(default=""),
) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, workspace)
    return search_workspace(root, q)


@router.get("/api/git/status", dependencies=[Depends(require_auth)])
async def api_git_status(
    request: Request,
    workspace: str | None = Query(default=None),
    path: str | None = Query(default=None),
) -> dict[str, Any]:
    root = resolve_allowed_workspace(request.app.state, workspace)
    try:
        return await git_status_and_diff(root, path)
    except WorkspaceSecurityError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
