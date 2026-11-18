"""Attachment storage, native PC screenshot, and multimodal vision payload service."""

from __future__ import annotations

import base64
import copy
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import threading
import time
from typing import Any
from uuid import uuid4

from PIL import Image, ImageDraw, ImageGrab, ImageOps

from bridge.utils import atomic_write_bytes, atomic_write_text

MAX_ATTACHMENT_BYTES = 15 * 1024 * 1024  # 15 MB
MAX_IMAGE_DIMENSION = 2048
THUMB_MAX_DIMENSION = 360


def _build_one_by_one_png_base64() -> str:
    buf = io.BytesIO()
    img = Image.new("RGB", (1, 1), color=(255, 255, 255))
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


ONE_BY_ONE_PNG_BASE64: str = _build_one_by_one_png_base64()

_FORMAT_SPEC: dict[str, tuple[str, str, str]] = {
    "PNG": ("PNG", "image/png", ".png"),
    "JPEG": ("JPEG", "image/jpeg", ".jpg"),
    "JPG": ("JPEG", "image/jpeg", ".jpg"),
    "WEBP": ("WEBP", "image/webp", ".webp"),
    "GIF": ("GIF", "image/gif", ".gif"),
}

_EXT_TO_FORMAT: dict[str, str] = {
    ".png": "PNG",
    ".jpg": "JPEG",
    ".jpeg": "JPEG",
    ".webp": "WEBP",
    ".gif": "GIF",
}


def _to_rgb(img: Image.Image) -> Image.Image:
    """Convert an image (including RGBA/LA/P with transparency) to RGB on a white background."""
    if img.mode == "RGB":
        return img
    if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
        rgba = img.convert("RGBA")
        background = Image.new("RGB", rgba.size, (255, 255, 255))
        background.paste(rgba, mask=rgba.split()[3])
        return background
    return img.convert("RGB")


def _find_window_bbox_windows(window_title: str) -> tuple[int, int, int, int] | None:
    """Find the bounding box (left, top, right, bottom) of a visible window matching title on Windows."""
    if os.name != "nt":
        return None
    needle = window_title.strip().lower()
    if not needle:
        return None

    try:
        user32 = ctypes.windll.user32
        matches: list[tuple[int, int, int, int]] = []

        WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

        def _callback(hwnd: int, _lparam: int) -> bool:
            if not user32.IsWindowVisible(hwnd):
                return True
            length = user32.GetWindowTextLengthW(hwnd)
            if length <= 0:
                return True
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            title = buf.value or ""
            if needle in title.lower():
                rect = wintypes.RECT()
                if user32.GetWindowRect(hwnd, ctypes.byref(rect)):
                    left, top, right, bottom = (
                        int(rect.left),
                        int(rect.top),
                        int(rect.right),
                        int(rect.bottom),
                    )
                    if right > left and bottom > top:
                        matches.append((left, top, right, bottom))
                        return False  # stop enumeration on first valid visible match
            return True

        enum_proc = WNDENUMPROC(_callback)
        user32.EnumWindows(enum_proc, 0)
        return matches[0] if matches else None
    except Exception:
        return None


def _create_fallback_screenshot_image(reason: str = "Screenshot fallback") -> Image.Image:
    """Generate a clean 1280x720 fallback image when native screen capture is unavailable."""
    width, height = 1280, 720
    img = Image.new("RGB", (width, height), color=(24, 28, 36))
    draw = ImageDraw.Draw(img)
    draw.rectangle([(40, 40), (width - 40, height - 40)], outline=(72, 85, 106), width=2)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines = [
        "DeepSeek Mobile Bridge - PC Screenshot Fallback",
        f"Reason: {reason}",
        f"Timestamp: {timestamp}",
        "Resolution: 1280x720 (headless / locked display session fallback)",
    ]
    y = 260
    for line in lines:
        draw.text((80, y), line, fill=(220, 228, 240))
        y += 40
    return img


class AttachmentService:
    """Thread-safe attachment storage, thumbnailing, PC screenshot, and multimodal payload builder."""

    def __init__(self, data_dir: Path) -> None:
        self.data_dir = Path(data_dir)
        self.attachments_dir = self.data_dir / "attachments"
        self.index_path = self.attachments_dir / "index.json"
        self._lock = threading.RLock()
        self.attachments_dir.mkdir(parents=True, exist_ok=True)
        self._index: dict[str, dict[str, Any]] = self._load_index()

    def _load_index(self) -> dict[str, dict[str, Any]]:
        with self._lock:
            if not self.index_path.exists():
                return {}
            try:
                raw = self.index_path.read_text(encoding="utf-8")
                data = json.loads(raw)
                if isinstance(data, dict):
                    return {
                        str(k): dict(v)
                        for k, v in data.items()
                        if isinstance(v, dict)
                    }
            except Exception:
                pass
            return {}

    def _save_index(self) -> None:
        with self._lock:
            self.attachments_dir.mkdir(parents=True, exist_ok=True)
            payload = json.dumps(self._index, ensure_ascii=False, indent=2)
            atomic_write_text(self.index_path, payload)

    def _atomic_write_bytes(self, target_path: Path, data: bytes) -> None:
        self.attachments_dir.mkdir(parents=True, exist_ok=True)
        atomic_write_bytes(target_path, data)

    def save_image_bytes(
        self,
        raw_bytes: bytes,
        *,
        filename: str = "image.jpg",
        session_id: str = "global",
        source: str = "upload",
    ) -> dict[str, Any]:
        if not isinstance(raw_bytes, (bytes, bytearray)):
            raise ValueError("raw_bytes must be bytes")
        byte_len = len(raw_bytes)
        if byte_len <= 0 or byte_len > MAX_ATTACHMENT_BYTES:
            raise ValueError(
                f"Attachment size must be between 1 and {MAX_ATTACHMENT_BYTES} bytes (got {byte_len})"
            )

        try:
            with Image.open(io.BytesIO(raw_bytes)) as opened:
                opened.load()
                detected_format = (opened.format or "").upper()
                try:
                    img = ImageOps.exif_transpose(opened)
                except Exception:
                    img = opened.copy()
        except Exception as exc:
            raise ValueError("Invalid or unsupported image format") from exc

        clean_name = Path(filename or "image.jpg").name or "image.jpg"
        ext_hint = Path(clean_name).suffix.lower()
        if not detected_format and ext_hint in _EXT_TO_FORMAT:
            detected_format = _EXT_TO_FORMAT[ext_hint]

        save_format, mime_type, ext = _FORMAT_SPEC.get(
            detected_format, ("JPEG", "image/jpeg", ".jpg")
        )

        # Resize proportionally if larger than MAX_IMAGE_DIMENSION
        width, height = img.size
        if width <= 0 or height <= 0:
            raise ValueError("Invalid image dimensions")
        if max(width, height) > MAX_IMAGE_DIMENSION:
            scale = MAX_IMAGE_DIMENSION / float(max(width, height))
            new_w = max(1, int(round(width * scale)))
            new_h = max(1, int(round(height * scale)))
            img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
            width, height = img.size

        # Encode main image
        main_buf = io.BytesIO()
        if save_format == "JPEG":
            img_to_save = _to_rgb(img)
            img_to_save.save(main_buf, format="JPEG", quality=88, optimize=True)
        elif save_format == "PNG":
            if img.mode not in ("RGB", "RGBA", "L", "LA", "P"):
                img = img.convert("RGBA")
            img.save(main_buf, format="PNG", optimize=True)
        elif save_format == "WEBP":
            if img.mode not in ("RGB", "RGBA"):
                img = img.convert("RGBA" if "A" in img.mode else "RGB")
            img.save(main_buf, format="WEBP", quality=88)
        elif save_format == "GIF":
            img.save(main_buf, format="GIF")
        else:
            img_to_save = _to_rgb(img)
            img_to_save.save(main_buf, format="JPEG", quality=88, optimize=True)
            save_format, mime_type, ext = ("JPEG", "image/jpeg", ".jpg")

        saved_bytes = main_buf.getvalue()

        # Generate JPEG thumbnail with max dimension THUMB_MAX_DIMENSION
        thumb_img = _to_rgb(img)
        t_w, t_h = thumb_img.size
        if max(t_w, t_h) > THUMB_MAX_DIMENSION:
            t_scale = THUMB_MAX_DIMENSION / float(max(t_w, t_h))
            thumb_w = max(1, int(round(t_w * t_scale)))
            thumb_h = max(1, int(round(t_h * t_scale)))
            thumb_img = thumb_img.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS)
        thumb_buf = io.BytesIO()
        thumb_img.save(thumb_buf, format="JPEG", quality=80, optimize=True)
        thumb_bytes = thumb_buf.getvalue()

        att_id = f"att_{uuid4().hex[:12]}"
        main_path = self.attachments_dir / f"{att_id}{ext}"
        thumb_path = self.attachments_dir / f"{att_id}_thumb.jpg"

        metadata: dict[str, Any] = {
            "att_id": att_id,
            "session_id": str(session_id or "global"),
            "filename": clean_name,
            "mime_type": mime_type,
            "ext": ext,
            "width": int(width),
            "height": int(height),
            "size": len(saved_bytes),
            "source": str(source or "upload"),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "url": f"/api/attachments/{att_id}",
            "thumb_url": f"/api/attachments/{att_id}/thumb",
        }

        with self._lock:
            self._atomic_write_bytes(main_path, saved_bytes)
            self._atomic_write_bytes(thumb_path, thumb_bytes)
            self._index[att_id] = metadata
            self._save_index()

        return copy.deepcopy(metadata)

    def get_metadata(self, att_id: str) -> dict[str, Any]:
        key = (att_id or "").strip()
        with self._lock:
            if key not in self._index:
                self._index = self._load_index()
            meta = self._index.get(key)
            if not meta:
                raise KeyError(f"Attachment not found: {att_id}")
            return copy.deepcopy(meta)

    def list_session_attachments(self, session_id: str) -> list[dict[str, Any]]:
        target = (session_id or "").strip()
        with self._lock:
            items = [
                copy.deepcopy(meta)
                for meta in self._index.values()
                if meta.get("session_id") == target
            ]
        items.sort(key=lambda item: item.get("created_at", ""))
        return items

    def delete_session_attachments(self, session_id: str) -> int:
        """Delete attachments belonging to session_id (and any child subagent prefix)."""
        target = (session_id or "").strip()
        if not target or target == "global":
            return 0
        removed = 0
        with self._lock:
            victim_ids = [
                att_id
                for att_id, meta in self._index.items()
                if str(meta.get("session_id") or "") == target
                or str(meta.get("session_id") or "").startswith(f"{target}_")
            ]
            for att_id in victim_ids:
                meta = self._index.pop(att_id, None) or {}
                ext = str(meta.get("ext") or ".jpg")
                for fp in (
                    self.attachments_dir / f"{att_id}{ext}",
                    self.attachments_dir / f"{att_id}_thumb.jpg",
                ):
                    try:
                        fp.unlink(missing_ok=True)
                    except OSError:
                        pass
                removed += 1
            if removed:
                self._save_index()
        return removed

    def get_file_path(self, att_id: str, *, thumb: bool = False) -> tuple[Path, str]:
        meta = self.get_metadata(att_id)
        if thumb:
            thumb_path = self.attachments_dir / f"{meta['att_id']}_thumb.jpg"
            if not thumb_path.exists():
                raise KeyError(f"Thumbnail file missing for attachment: {att_id}")
            return thumb_path, "image/jpeg"

        ext = meta.get("ext") or ".jpg"
        file_path = self.attachments_dir / f"{meta['att_id']}{ext}"
        if not file_path.exists():
            raise KeyError(f"Attachment file missing on disk: {att_id}")
        return file_path, str(meta.get("mime_type") or "image/jpeg")

    def get_base64_payload(self, att_id: str) -> dict[str, Any]:
        meta = self.get_metadata(att_id)
        file_path, mime = self.get_file_path(att_id, thumb=False)
        raw = file_path.read_bytes()
        b64_str = base64.b64encode(raw).decode("ascii")
        return {
            "att_id": meta["att_id"],
            "mime_type": mime,
            "base64": b64_str,
            "data_uri": f"data:{mime};base64,{b64_str}",
            "width": int(meta["width"]),
            "height": int(meta["height"]),
        }

    def take_pc_screenshot(
        self,
        *,
        target: str = "full",
        window_title: str = "",
        region: list[int] | None = None,
        monitor: int = 0,
        session_id: str = "global",
    ) -> dict[str, Any]:
        normalized_target = (target or "full").strip().lower()
        if normalized_target not in ("full", "window", "region"):
            raise ValueError(f"Unsupported screenshot target: {target}")

        bbox: tuple[int, int, int, int] | None = None
        if normalized_target == "window":
            if window_title and window_title.strip() and os.name == "nt":
                bbox = _find_window_bbox_windows(window_title)
        elif normalized_target == "region":
            if region is not None:
                if len(region) != 4:
                    raise ValueError("region must be a list of 4 integers [x, y, width, height]")
                x, y, w, h = (int(region[0]), int(region[1]), int(region[2]), int(region[3]))
                if w <= 0 or h <= 0:
                    raise ValueError("region width and height must be positive")
                bbox = (x, y, x + w, y + h)

        try:
            img = ImageGrab.grab(bbox=bbox, all_screens=(monitor < 0))
        except OSError as exc:
            img = _create_fallback_screenshot_image(str(exc) or "OSError during ImageGrab.grab")
        except Exception as exc:
            img = _create_fallback_screenshot_image(str(exc) or "Error during ImageGrab.grab")

        buf = io.BytesIO()
        img.save(buf, format="PNG")
        png_bytes = buf.getvalue()

        filename = f"screenshot_{int(time.time())}.png"
        return self.save_image_bytes(
            png_bytes,
            filename=filename,
            session_id=session_id,
            source="pc_screenshot",
        )

    def build_multimodal_content(
        self,
        text: str,
        attachment_ids: list[str],
        *,
        provider: str = "openai_compatible",
        include_binary: bool = True,
    ) -> str | list[dict[str, Any]]:
        if not attachment_ids:
            return text

        clean_ids = [str(aid).strip() for aid in attachment_ids if str(aid).strip()]
        if not clean_ids:
            return text

        if not include_binary:
            placeholders: list[str] = []
            for aid in clean_ids:
                try:
                    meta = self.get_metadata(aid)
                    w = meta.get("width", 0)
                    h = meta.get("height", 0)
                    fname = meta.get("filename", "image")
                    placeholders.append(f"[历史图片附件: {aid} ({w}x{h} {fname})]")
                except KeyError:
                    placeholders.append(f"[历史图片附件: {aid}]")
            suffix = "\n".join(placeholders)
            return f"{text}\n{suffix}" if text else suffix

        prompt_text = text or "请查看图片"
        norm_provider = (provider or "openai_compatible").strip().lower()

        if norm_provider == "anthropic":
            blocks: list[dict[str, Any]] = []
            for aid in clean_ids:
                payload = self.get_base64_payload(aid)
                blocks.append(
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": payload["mime_type"],
                            "data": payload["base64"],
                        },
                    }
                )
            blocks.append({"type": "text", "text": prompt_text})
            return blocks

        # Default: openai_compatible (DeepSeek deepseek-flash, OpenAI, etc.)
        blocks = [{"type": "text", "text": prompt_text}]
        for aid in clean_ids:
            payload = self.get_base64_payload(aid)
            blocks.append(
                {
                    "type": "image_url",
                    "image_url": {
                        "url": payload["data_uri"],
                    },
                }
            )
        return blocks
