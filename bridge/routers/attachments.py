"""Image attachment upload/serving and native PC screenshot routes (Module B)."""

from __future__ import annotations

import asyncio
import base64
from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse

from bridge.deps import require_auth
from bridge.schemas import PCScreenshotRequest, extract_multipart_file_bytes

router = APIRouter()


@router.post("/api/attachments", dependencies=[Depends(require_auth)])
async def api_upload_attachment(
    request: Request,
    filename: str = Query(default="image.jpg"),
    session_id: str = Query(default="global"),
) -> dict[str, Any]:
    att_svc = request.app.state.attachment_service
    content_type = (request.headers.get("content-type") or "").lower()
    cl_header = request.headers.get("content-length")
    if cl_header and cl_header.isdigit() and int(cl_header) > 22 * 1024 * 1024:
        raise HTTPException(status_code=413, detail="Attachment payload exceeds 15MB limit")
    try:
        if "application/json" in content_type:
            body_json = await request.json()
            fname = str(body_json.get("filename") or filename or "image.jpg")
            sid = str(body_json.get("session_id") or session_id or "global")
            b64_raw = str(body_json.get("base64_data") or body_json.get("data") or "").strip()
            if b64_raw.startswith("data:") and "," in b64_raw:
                b64_raw = b64_raw.split(",", 1)[1]
            raw_bytes = base64.b64decode(b64_raw)
        elif "multipart/form-data" in content_type:
            raw_body = await request.body()
            raw_bytes, extracted_name = extract_multipart_file_bytes(raw_body, content_type)
            fname = filename if filename != "image.jpg" else extracted_name
            sid = session_id or "global"
        else:
            raw_bytes = await request.body()
            fname = filename or "image.jpg"
            sid = session_id or "global"

        meta = await asyncio.to_thread(
            att_svc.save_image_bytes,
            raw_bytes,
            filename=fname,
            session_id=sid,
            source="upload",
        )
        return {"ok": True, "attachment": meta, **meta}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid attachment upload: {exc}") from exc


@router.get("/api/attachments/{att_id}", dependencies=[Depends(require_auth)])
def api_get_attachment(request: Request, att_id: str) -> FileResponse:
    try:
        file_path, mime = request.app.state.attachment_service.get_file_path(att_id, thumb=False)
        return FileResponse(path=file_path, media_type=mime, filename=file_path.name)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/api/attachments/{att_id}/thumb", dependencies=[Depends(require_auth)])
def api_get_attachment_thumb(request: Request, att_id: str) -> FileResponse:
    try:
        thumb_path, mime = request.app.state.attachment_service.get_file_path(att_id, thumb=True)
        return FileResponse(path=thumb_path, media_type=mime, filename=thumb_path.name)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.post("/api/pc/screenshot", dependencies=[Depends(require_auth)])
async def api_pc_screenshot(
    request: Request,
    body: PCScreenshotRequest | None = Body(default=None),
) -> dict[str, Any]:
    st = request.app.state
    req = body or PCScreenshotRequest()
    try:
        meta = await asyncio.to_thread(
            st.attachment_service.take_pc_screenshot,
            target=req.target,
            window_title=req.window_title,
            region=req.region,
            monitor=req.monitor,
            session_id=req.session_id or "global",
        )
        if req.session_id and req.session_id in st.session_manager.sessions:
            st.session_manager.sessions[req.session_id].emit_event("image_attachment", meta)
        return {"ok": True, "attachment": meta, **meta}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
