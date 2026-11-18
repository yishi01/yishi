"""Built-in Collaborative Browser Service for DeepSeek Mobile Bridge (v0.9.0).

Manages interactive browser sessions (`BrowserSession`) shared between the AI Agent
and the human user on iPhone/Web, supporting:
- Inline chat viewport cards & real-time JPEG frame streaming (`960x640`) over WebSocket
- Numbered interactive element snapshots (`[1]`, `[2]`, ...) with layout bounding boxes
- Seamless human/agent control handoff (`control_owner: "agent" | "human"`)
- Anti-bot / CAPTCHA / password / payment security gates (`human_required = True`)
"""

from __future__ import annotations

import asyncio
import base64
import copy
from dataclasses import dataclass, field
from datetime import datetime, timezone
from html.parser import HTMLParser
import inspect
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
from typing import Any, Awaitable, Callable, Literal
from urllib.parse import urlencode, urljoin, urlparse
import uuid

import httpx
from PIL import Image, ImageDraw, ImageFont

from bridge.config import DEFAULT_DATA_DIR

DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)

VIEWPORT_WIDTH = 960
VIEWPORT_HEIGHT = 640
CHROME_HEIGHT = 76
MAX_INTERACTIVE_ELEMENTS = 60

DISALLOWED_SCHEMES = {"file", "javascript", "vbscript", "data"}

CAPTCHA_MARKERS = (
    "cf-turnstile",
    "challenges.cloudflare.com",
    "g-recaptcha",
    "hcaptcha",
    "h-captcha",
    "verify you are human",
    "are you a human",
    "please verify you are a human",
    "human verification",
    "bot verification",
    "人机验证",
    "安全验证",
    "请完成安全验证",
    "滑动验证",
)

PAYMENT_MARKERS = (
    "确认支付",
    "立即支付",
    "收银台",
    "银行卡号",
    "card-number",
    "cc-number",
    "cc-csc",
)


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class UrlPolicyResult(tuple):
    """A `(allowed: bool, reason: str)` tuple whose boolean truthiness equals `allowed`."""

    def __new__(cls, allowed: bool, reason: str = "") -> "UrlPolicyResult":
        return super().__new__(cls, (bool(allowed), str(reason)))

    @property
    def allowed(self) -> bool:
        return bool(self[0])

    @property
    def reason(self) -> str:
        return str(self[1])

    def __bool__(self) -> bool:
        return bool(self[0])

    def __eq__(self, other: object) -> bool:
        if isinstance(other, bool):
            return bool(self[0]) is other
        return super().__eq__(other)


_FONT_CACHE: dict[int, ImageFont.ImageFont | ImageFont.FreeTypeFont] = {}


def _get_font(size: int = 15) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    cached = _FONT_CACHE.get(size)
    if cached is not None:
        return cached

    candidates = [
        r"C:\Windows\Fonts\msyh.ttc",
        r"C:\Windows\Fonts\msyhbd.ttc",
        r"C:\Windows\Fonts\simhei.ttf",
        r"C:\Windows\Fonts\simsun.ttc",
        r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                font = ImageFont.truetype(path, size=size)
                _FONT_CACHE[size] = font
                return font
            except Exception:
                continue

    default_font = ImageFont.load_default()
    _FONT_CACHE[size] = default_font
    return default_font


def _safe_draw_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int | float, int | float],
    text: str,
    fill: str | tuple[int, int, int],
    font: ImageFont.ImageFont | ImageFont.FreeTypeFont,
) -> None:
    if not text:
        return
    try:
        draw.text(xy, text, fill=fill, font=font)
    except Exception:
        ascii_text = text.encode("ascii", errors="replace").decode("ascii")
        draw.text(xy, ascii_text, fill=fill, font=ImageFont.load_default())


class _PageHTMLParser(HTMLParser):
    """Stdlib HTMLParser extracting title, readable Markdown, layout blocks, and interactive elements."""

    SKIP_TAGS = {"script", "style", "noscript", "svg", "template", "iframe"}
    HEADING_TAGS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}
    BLOCK_TAGS = {"p", "div", "section", "article", "main", "header", "footer", "blockquote", "pre", "li", "tr"}
    INTERACTIVE_TAGS = {"a", "button", "input", "textarea", "select"}

    def __init__(self, base_url: str, max_elements: int = MAX_INTERACTIVE_ELEMENTS) -> None:
        super().__init__(convert_charrefs=True)
        self.base_url = base_url
        self.max_elements = max_elements

        self.title: str = ""
        self._in_title = False
        self._title_parts: list[str] = []

        self._skip_depth = 0
        self._current_heading: int = 0
        self._in_li = False
        self._in_tr = False
        self._tr_cells: list[str] = []
        self._in_cell = False
        self._cell_parts: list[str] = []

        self._text_buffer: list[str] = []
        self.markdown_lines: list[str] = []
        self.raw_blocks: list[dict[str, Any]] = []

        self._active_interactive: dict[str, Any] | None = None
        self._active_interactive_text: list[str] = []
        self._active_select_options: list[str] = []
        self._in_option = False
        self._option_parts: list[str] = []

        self._current_form_action: str = ""
        self._current_form_method: str = "GET"

        self.elements: list[dict[str, Any]] = []

    def _flush_text_buffer(self, kind: str = "paragraph", level: int = 0) -> None:
        raw = " ".join("".join(self._text_buffer).split()).strip()
        self._text_buffer = []
        if not raw:
            return
        if kind == "heading" and level > 0:
            prefix = "#" * min(level, 6)
            self.markdown_lines.append(f"{prefix} {raw}")
            self.raw_blocks.append({"kind": "heading", "level": level, "text": raw})
        elif kind == "li":
            self.markdown_lines.append(f"- {raw}")
            self.raw_blocks.append({"kind": "li", "text": f"• {raw}"})
        else:
            self.markdown_lines.append(raw)
            self.raw_blocks.append({"kind": "paragraph", "text": raw})

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        t = tag.lower()
        attr_map = {k.lower(): (v or "") for k, v in attrs if k}

        if t in self.SKIP_TAGS:
            self._skip_depth += 1
            return
        if self._skip_depth > 0:
            return

        if t == "title":
            self._in_title = True
            self._title_parts = []
            return

        if t == "form":
            raw_action = attr_map.get("action", "").strip()
            self._current_form_action = urljoin(self.base_url, raw_action) if raw_action else self.base_url
            self._current_form_method = (attr_map.get("method") or "GET").upper()
            return

        if t in self.HEADING_TAGS:
            self._flush_text_buffer()
            self._current_heading = self.HEADING_TAGS[t]
            return

        if t == "li":
            self._flush_text_buffer()
            self._in_li = True
            return

        if t == "tr":
            self._flush_text_buffer()
            self._in_tr = True
            self._tr_cells = []
            return

        if t in ("td", "th") and self._in_tr:
            self._in_cell = True
            self._cell_parts = []
            return

        if t == "br":
            self._flush_text_buffer()
            return

        if t in self.BLOCK_TAGS:
            self._flush_text_buffer()

        if t == "option" and self._active_interactive and self._active_interactive.get("tag") == "select":
            self._in_option = True
            self._option_parts = []
            return

        if t in self.INTERACTIVE_TAGS and len(self.elements) < self.max_elements:
            if t == "input":
                input_type = (attr_map.get("type") or "text").strip().lower()
                if input_type == "hidden":
                    return
                placeholder = attr_map.get("placeholder", "").strip()
                value = attr_map.get("value", "").strip()
                name = attr_map.get("name", "").strip()
                aria_label = attr_map.get("aria-label", "").strip() or attr_map.get("title", "").strip()
                label_text = placeholder or value or aria_label or name or input_type
                el_id = len(self.elements) + 1
                el: dict[str, Any] = {
                    "id": el_id,
                    "tag": "input",
                    "type": input_type,
                    "text": label_text[:80],
                    "href": self._current_form_action if input_type in ("submit", "image") else "",
                    "value": value,
                    "placeholder": placeholder,
                    "name": name,
                    "form_action": self._current_form_action,
                    "form_method": self._current_form_method,
                    "bbox": [0, 0, 0, 0],
                }
                self.elements.append(el)
                self.raw_blocks.append({"kind": "element", "element_id": el_id})
                self.markdown_lines.append(f"[{el_id}] <input:{input_type}> {label_text}")
                return

            # Container interactive tags: a, button, textarea, select
            if self._active_interactive is not None:
                self._finalize_active_interactive()

            raw_href = attr_map.get("href", "").strip()
            resolved_href = ""
            if t == "a" and raw_href:
                if raw_href.startswith(("javascript:", "mailto:", "tel:", "#")):
                    resolved_href = raw_href
                else:
                    resolved_href = urljoin(self.base_url, raw_href)

            el_type = "link" if t == "a" else (attr_map.get("type", "").strip().lower() or t)
            if t == "button" and el_type not in ("submit", "reset", "button"):
                el_type = "button"

            self._active_interactive = {
                "tag": t,
                "type": el_type,
                "href": resolved_href,
                "value": attr_map.get("value", "").strip(),
                "placeholder": attr_map.get("placeholder", "").strip(),
                "name": attr_map.get("name", "").strip(),
                "aria_label": (attr_map.get("aria-label") or attr_map.get("title") or "").strip(),
                "form_action": self._current_form_action,
                "form_method": self._current_form_method,
            }
            self._active_interactive_text = []
            self._active_select_options = []

    def _finalize_active_interactive(self) -> None:
        info = self._active_interactive
        self._active_interactive = None
        if not info or len(self.elements) >= self.max_elements:
            return

        t = info["tag"]
        inner_text = " ".join("".join(self._active_interactive_text).split()).strip()
        self._active_interactive_text = []

        if t == "select" and self._active_select_options and not info["value"]:
            info["value"] = self._active_select_options[0]
        if t == "textarea" and inner_text and not info["value"]:
            info["value"] = inner_text

        label = (
            inner_text
            or info.get("aria_label")
            or info.get("placeholder")
            or info.get("value")
            or info.get("name")
            or info.get("href")
            or t
        )
        el_id = len(self.elements) + 1
        href = info.get("href", "")
        if t == "button" and not href and info.get("type") == "submit" and info.get("form_action"):
            href = ""

        el: dict[str, Any] = {
            "id": el_id,
            "tag": t,
            "type": info["type"],
            "text": str(label)[:100],
            "href": href,
            "value": info.get("value", ""),
            "placeholder": info.get("placeholder", ""),
            "name": info.get("name", ""),
            "form_action": info.get("form_action", ""),
            "form_method": info.get("form_method", "GET"),
            "bbox": [0, 0, 0, 0],
        }
        self.elements.append(el)
        self.raw_blocks.append({"kind": "element", "element_id": el_id})
        if t == "a" and href:
            self.markdown_lines.append(f"[{el_id}] [{el['text']}]({href})")
        else:
            self.markdown_lines.append(f"[{el_id}] <{t}> {el['text']}")

    def handle_endtag(self, tag: str) -> None:
        t = tag.lower()
        if t in self.SKIP_TAGS:
            if self._skip_depth > 0:
                self._skip_depth -= 1
            return
        if self._skip_depth > 0:
            return

        if t == "title" and self._in_title:
            self._in_title = False
            candidate = " ".join("".join(self._title_parts).split()).strip()
            if candidate and not self.title:
                self.title = candidate
            return

        if t == "form":
            self._current_form_action = ""
            self._current_form_method = "GET"
            return

        if t == "option" and self._in_option:
            self._in_option = False
            opt_text = " ".join("".join(self._option_parts).split()).strip()
            if opt_text:
                self._active_select_options.append(opt_text)
            return

        if self._active_interactive and t == self._active_interactive.get("tag"):
            self._finalize_active_interactive()
            return

        if t in self.HEADING_TAGS and self._current_heading > 0:
            lvl = self._current_heading
            self._current_heading = 0
            self._flush_text_buffer(kind="heading", level=lvl)
            return

        if t == "li" and self._in_li:
            self._in_li = False
            self._flush_text_buffer(kind="li")
            return

        if t in ("td", "th") and self._in_cell:
            self._in_cell = False
            cell_txt = " ".join("".join(self._cell_parts).split()).strip()
            if cell_txt:
                self._tr_cells.append(cell_txt)
            return

        if t == "tr" and self._in_tr:
            self._in_tr = False
            if self._tr_cells:
                row_str = " | ".join(self._tr_cells)
                self.markdown_lines.append(f"| {row_str} |")
                self.raw_blocks.append({"kind": "table_row", "text": f"| {row_str} |"})
            self._tr_cells = []
            return

        if t in self.BLOCK_TAGS:
            self._flush_text_buffer()

    def handle_data(self, data: str) -> None:
        if self._skip_depth > 0:
            return
        if self._in_title:
            self._title_parts.append(data)
            return
        if self._in_option:
            self._option_parts.append(data)
            self._active_interactive_text.append(data)
            return
        if self._active_interactive is not None:
            self._active_interactive_text.append(data)
            return
        if self._in_cell:
            self._cell_parts.append(data)
            return
        if data.strip():
            self._text_buffer.append(data)

    def close(self) -> None:
        if self._active_interactive is not None:
            self._finalize_active_interactive()
        self._flush_text_buffer()
        super().close()


def _wrap_text_lines(text: str, max_chars_per_line: int = 68) -> list[str]:
    cleaned = " ".join((text or "").split()).strip()
    if not cleaned:
        return []
    lines: list[str] = []
    current = ""
    current_weight = 0
    for ch in cleaned:
        weight = 2 if ord(ch) > 127 else 1
        if current_weight + weight > max_chars_per_line and current:
            lines.append(current)
            current = ch
            current_weight = weight
        else:
            current += ch
            current_weight += weight
    if current:
        lines.append(current)
    return lines[:8]


def _parse_html_page(base_url: str, html: str) -> dict[str, Any]:
    """Parse HTML into title, readable Markdown, interactive elements with `[x, y, w, h]` bboxes, and layout blocks."""
    parser = _PageHTMLParser(base_url=base_url, max_elements=MAX_INTERACTIVE_ELEMENTS)
    try:
        parser.feed(html or "")
        parser.close()
    except Exception:
        pass

    title = parser.title
    if not title:
        for blk in parser.raw_blocks:
            if blk.get("kind") == "heading" and blk.get("text"):
                title = str(blk["text"])[:80]
                break
    if not title:
        parsed_url = urlparse(base_url)
        title = parsed_url.netloc or parsed_url.path or base_url or "Untitled Page"

    elements_by_id = {el["id"]: el for el in parser.elements}
    layout_blocks: list[dict[str, Any]] = []

    cursor_y = CHROME_HEIGHT + 18
    left_margin = 24
    max_width = VIEWPORT_WIDTH - 48
    row_x = left_margin
    row_height = 0

    def flush_inline_row() -> None:
        nonlocal cursor_y, row_x, row_height
        if row_height > 0:
            cursor_y += row_height + 10
            row_x = left_margin
            row_height = 0

    for raw in parser.raw_blocks:
        kind = raw.get("kind")
        if kind == "element":
            el_id = raw.get("element_id")
            el = elements_by_id.get(el_id)
            if not el:
                continue
            tag = el["tag"]
            el_type = el["type"]
            label = el.get("value") or el.get("text") or el.get("placeholder") or tag
            char_weight = sum(2 if ord(c) > 127 else 1 for c in label[:36])

            if tag in ("input", "textarea", "select") and el_type not in ("submit", "button", "checkbox", "radio"):
                flush_inline_row()
                box_w = min(max_width, max(320, char_weight * 9 + 110))
                box_h = 54 if tag == "textarea" else 38
                bx = left_margin
                by = cursor_y
                el["bbox"] = [bx, by, box_w, box_h]
                layout_blocks.append({"kind": "element", "element_id": el_id, "x": bx, "y": by, "w": box_w, "h": box_h})
                cursor_y += box_h + 12
            else:
                box_w = min(max_width, max(120, char_weight * 8 + 64))
                box_h = 34
                if row_x + box_w > VIEWPORT_WIDTH - 24 and row_x > left_margin:
                    flush_inline_row()
                bx = row_x
                by = cursor_y
                el["bbox"] = [bx, by, box_w, box_h]
                layout_blocks.append({"kind": "element", "element_id": el_id, "x": bx, "y": by, "w": box_w, "h": box_h})
                row_x += box_w + 12
                row_height = max(row_height, box_h)
        else:
            flush_inline_row()
            text = str(raw.get("text") or "").strip()
            if not text:
                continue
            if kind == "heading":
                level = int(raw.get("level") or 1)
                lines = _wrap_text_lines(text, max_chars_per_line=56 if level <= 2 else 66)
                line_h = 28 if level == 1 else (24 if level == 2 else 22)
                blk_h = len(lines) * line_h + 6
                layout_blocks.append(
                    {
                        "kind": "heading",
                        "level": level,
                        "lines": lines,
                        "x": left_margin,
                        "y": cursor_y,
                        "w": max_width,
                        "h": blk_h,
                    }
                )
                cursor_y += blk_h + 8
            else:
                lines = _wrap_text_lines(text, max_chars_per_line=76)
                line_h = 20
                blk_h = len(lines) * line_h + 4
                layout_blocks.append(
                    {
                        "kind": kind or "paragraph",
                        "lines": lines,
                        "x": left_margin,
                        "y": cursor_y,
                        "w": max_width,
                        "h": blk_h,
                    }
                )
                cursor_y += blk_h + 8

    flush_inline_row()
    content_height = max(VIEWPORT_HEIGHT, cursor_y + 32)
    text_markdown = "\n\n".join(parser.markdown_lines).strip()
    if not text_markdown:
        text_markdown = f"# {title}"

    return {
        "title": title,
        "text_markdown": text_markdown,
        "elements": parser.elements,
        "blocks": layout_blocks,
        "content_height": content_height,
    }


def _check_security_gate(
    url: str,
    title: str,
    html: str,
    elements: list[dict[str, Any]],
) -> tuple[bool, str]:
    """Detect CAPTCHA / anti-bot challenges, password fields, or payment checkout gates."""
    lower_html = (html or "").lower()
    lower_title = (title or "").lower()
    lower_url = (url or "").lower()
    combined = f"{lower_title}\n{lower_url}\n{lower_html}"

    for marker in CAPTCHA_MARKERS:
        if marker.lower() in combined:
            return True, f"检测到人机验证 / 安全验证 ({marker})，需真人接管操作"

    for el in elements or []:
        if str(el.get("tag") or "").lower() == "input" and str(el.get("type") or "").lower() == "password":
            return True, "检测到密码输入框 (password)，出于安全策略需真人接管输入"

    if re.search(r"<input\b[^>]*type\s*=\s*['\"]?password['\"]?", lower_html):
        return True, "检测到密码输入框 (password)，出于安全策略需真人接管输入"

    for marker in PAYMENT_MARKERS:
        if marker.lower() in combined:
            return True, f"检测到支付/收银台敏感页面 ({marker})，需真人确认并操作"

    if re.search(r"autocomplete\s*=\s*['\"]?cc-(number|csc|exp)['\"]?", lower_html):
        return True, "检测到信用卡支付输入字段，需真人接管操作"

    return False, ""


@dataclass
class BrowserSession:
    """Interactive browser session shared between AI Agent and human user."""

    browser_id: str = field(default_factory=lambda: "br_" + uuid.uuid4().hex[:10])
    session_id: str = "global"
    workspace_profile_id: str = "ws_default"
    url: str = "about:blank"
    title: str = "空白页"
    history: list[str] = field(default_factory=list)
    history_index: int = -1
    control_owner: Literal["agent", "human"] = "agent"
    human_required: bool = False
    human_reason: str = ""
    scroll_y: int = 0
    viewport_width: int = VIEWPORT_WIDTH
    viewport_height: int = VIEWPORT_HEIGHT
    elements: list[dict[str, Any]] = field(default_factory=list)
    text_markdown: str = ""
    last_frame_b64: str = ""
    last_status_code: int = 200
    updated_at: str = field(default_factory=_utc_now_iso)
    subscribers: set[asyncio.Queue[dict[str, Any]]] = field(default_factory=set, repr=False)

    # Internal rendering & interaction metadata
    blocks: list[dict[str, Any]] = field(default_factory=list, repr=False)
    content_height: int = VIEWPORT_HEIGHT
    focused_element_id: int | None = None
    raw_html: str = field(default="", repr=False)
    last_frame_bytes: bytes = field(default=b"", repr=False)
    engine: str = "fast"

    @property
    def frame_b64(self) -> str:
        return self.last_frame_b64

    @frame_b64.setter
    def frame_b64(self, value: str) -> None:
        self.last_frame_b64 = value


class BrowserService:
    """Built-in Collaborative Browser Service supporting AI + Human shared control."""

    def __init__(
        self,
        data_dir: Path | str | None = None,
        config_store: Any = None,
        attachment_service: Any = None,
        http_fetcher: Callable[[str], Awaitable[tuple[int, str, str]]] | None = None,
    ) -> None:
        self._lock = threading.RLock()
        self.data_dir = Path(data_dir or DEFAULT_DATA_DIR).resolve()
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.config_store = config_store
        self.attachment_service = attachment_service
        self.http_fetcher = http_fetcher
        self._sessions: dict[str, BrowserSession] = {}

    @property
    def sessions(self) -> dict[str, BrowserSession]:
        return self._sessions

    # ------------------------------------------------------------------
    # URL Domain & Scheme Policy Check
    # ------------------------------------------------------------------
    def _get_browser_policy(self) -> dict[str, Any]:
        if self.config_store is not None:
            cfg = getattr(self.config_store, "config", None)
            if cfg is not None:
                policy = getattr(cfg, "browser_policy", None)
                if isinstance(policy, dict):
                    return policy
                if hasattr(policy, "model_dump"):
                    return policy.model_dump()
        return {}

    def check_url_allowed(self, url: str) -> UrlPolicyResult:
        raw = (url or "").strip()
        if not raw:
            return UrlPolicyResult(False, "URL 不能为空")
        if raw.lower() == "about:blank":
            return UrlPolicyResult(True, "")

        lower = raw.lower()
        for scheme in DISALLOWED_SCHEMES:
            if lower.startswith(f"{scheme}:"):
                return UrlPolicyResult(False, f"安全策略禁止访问协议: {scheme}:")

        candidate = raw if "://" in raw else f"https://{raw}"
        parsed = urlparse(candidate)
        scheme = (parsed.scheme or "").lower()
        if scheme in DISALLOWED_SCHEMES:
            return UrlPolicyResult(False, f"安全策略禁止访问协议: {scheme}://")
        if scheme not in ("http", "https", "about"):
            return UrlPolicyResult(False, f"不支持的 URL 协议: {scheme}")

        host = (parsed.hostname or "").lower().strip(".")
        if not host and scheme != "about":
            return UrlPolicyResult(False, "无效的 URL 主机名")

        policy = self._get_browser_policy()
        if policy.get("enabled") is False:
            return UrlPolicyResult(False, "内置浏览器已在策略中禁用")

        blocked_domains = [
            str(d).lower().strip(".")
            for d in (policy.get("blocked_domains") or policy.get("blocklist") or [])
            if str(d).strip()
        ]
        for bd in blocked_domains:
            if host == bd or host.endswith("." + bd):
                return UrlPolicyResult(False, f"域名已被安全策略拦截: {host}")

        allowed_domains = [
            str(d).lower().strip(".")
            for d in (policy.get("allowed_domains") or policy.get("allowlist") or [])
            if str(d).strip()
        ]
        if allowed_domains:
            if not any(host == ad or host.endswith("." + ad) for ad in allowed_domains):
                return UrlPolicyResult(False, f"域名不在允许列表中: {host}")

        return UrlPolicyResult(True, "")

    # ------------------------------------------------------------------
    # HTML Parsing, Security Gate & Viewport Rendering
    # ------------------------------------------------------------------
    def _parse_html_page(self, base_url: str, html: str) -> dict[str, Any]:
        return _parse_html_page(base_url, html)

    def _check_security_gate(
        self,
        url: str,
        title: str,
        html: str,
        elements: list[dict[str, Any]],
    ) -> tuple[bool, str]:
        return _check_security_gate(url, title, html, elements)

    def _render_viewport_jpeg(self, session: BrowserSession, *, engine: str | None = None) -> bytes:
        use_engine = (engine or session.engine or "fast").lower()
        if use_engine == "edge" and session.url.startswith(("http://", "https://")):
            edge_bytes = self._try_render_edge_headless(session.url, session.viewport_width, session.viewport_height)
            if edge_bytes:
                session.last_frame_bytes = edge_bytes
                session.last_frame_b64 = base64.b64encode(edge_bytes).decode("ascii")
                return edge_bytes

        w = session.viewport_width or VIEWPORT_WIDTH
        h = session.viewport_height or VIEWPORT_HEIGHT
        img = Image.new("RGB", (w, h), (248, 250, 252))
        draw = ImageDraw.Draw(img)

        font_xs = _get_font(12)
        font_sm = _get_font(13)
        font_md = _get_font(15)
        font_lg = _get_font(18)
        font_xl = _get_font(22)

        body_top = CHROME_HEIGHT
        if session.human_required:
            body_top += 34

        # 1. Render non-interactive text blocks
        for blk in session.blocks:
            kind = blk.get("kind")
            if kind == "element":
                continue
            bx = int(blk.get("x", 24))
            by = int(blk.get("y", CHROME_HEIGHT + 16)) - session.scroll_y
            bh = int(blk.get("h", 24))
            if by + bh < body_top or by > h:
                continue

            lines = blk.get("lines") or []
            if kind == "heading":
                lvl = int(blk.get("level") or 1)
                fnt = font_xl if lvl == 1 else (font_lg if lvl == 2 else font_md)
                line_h = 28 if lvl == 1 else (24 if lvl == 2 else 22)
                color = (15, 23, 42)
            elif kind == "li":
                fnt = font_md
                line_h = 20
                color = (51, 65, 85)
            elif kind == "table_row":
                fnt = font_sm
                line_h = 20
                color = (30, 41, 59)
            else:
                fnt = font_md
                line_h = 20
                color = (51, 65, 85)

            cur_y = by
            for line in lines:
                if body_top - 12 <= cur_y <= h - 8:
                    _safe_draw_text(draw, (bx, cur_y), str(line), fill=color, font=fnt)
                cur_y += line_h

        # 2. Render interactive elements with [id] badges at bbox coordinates
        for el in session.elements:
            bbox = el.get("bbox") or [24, CHROME_HEIGHT + 20, 220, 34]
            if len(bbox) < 4:
                continue
            bx, by_doc, bw, bh = int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])
            by = by_doc - session.scroll_y
            if by + bh < body_top - 8 or by > h:
                continue

            el_id = el.get("id", 0)
            tag = str(el.get("tag") or "a").lower()
            el_type = str(el.get("type") or "").lower()
            is_focused = session.focused_element_id == el_id

            rect = [bx, by, bx + bw, by + bh]
            if tag in ("input", "textarea", "select") and el_type not in ("submit", "button"):
                fill_color = (255, 255, 255)
                if el_type == "password":
                    border_color = (239, 68, 68)
                elif is_focused:
                    border_color = (37, 99, 235)
                else:
                    border_color = (148, 163, 184)
                draw.rounded_rectangle(rect, radius=7, fill=fill_color, outline=border_color, width=2)

                raw_val = str(el.get("value") or "")
                if el_type == "password":
                    display_txt = ("•" * len(raw_val)) if raw_val else "🔒 密码输入字段 (需真人输入)"
                    txt_color = (185, 28, 28) if not raw_val else (15, 23, 42)
                elif raw_val:
                    display_txt = raw_val
                    txt_color = (15, 23, 42)
                else:
                    display_txt = str(el.get("placeholder") or el.get("text") or "输入内容...")
                    txt_color = (100, 116, 139)

                _safe_draw_text(draw, (bx + 42, by + 8), display_txt[:46], fill=txt_color, font=font_md)
                badge_bg = (220, 38, 38) if el_type == "password" else (15, 23, 42)
            elif tag == "button" or el_type in ("submit", "button"):
                fill_color = (37, 99, 235) if el_type == "submit" else (239, 246, 255)
                border_color = (29, 78, 216) if el_type == "submit" else (59, 130, 246)
                txt_color = (255, 255, 255) if el_type == "submit" else (30, 64, 175)
                draw.rounded_rectangle(rect, radius=7, fill=fill_color, outline=border_color, width=2)
                label = str(el.get("text") or el.get("value") or "Button")[:32]
                _safe_draw_text(draw, (bx + 40, by + 7), label, fill=txt_color, font=font_md)
                badge_bg = (30, 58, 138)
            else:
                # Link (`<a>`)
                fill_color = (241, 245, 249)
                border_color = (147, 197, 253) if not is_focused else (37, 99, 235)
                draw.rounded_rectangle(rect, radius=6, fill=fill_color, outline=border_color, width=1)
                label = str(el.get("text") or el.get("href") or "Link")[:36]
                _safe_draw_text(draw, (bx + 40, by + 7), label, fill=(29, 78, 216), font=font_md)
                badge_bg = (37, 99, 235)

            # High-contrast numbered badge `[1]`, `[2]` at top-left of bbox
            badge_str = f"[{el_id}]"
            badge_w = max(32, len(badge_str) * 8 + 8)
            badge_rect = [bx + 3, by + 4, bx + 3 + badge_w, by + bh - 4]
            draw.rounded_rectangle(badge_rect, radius=5, fill=badge_bg)
            _safe_draw_text(draw, (bx + 7, by + 7), badge_str, fill=(255, 255, 255), font=font_xs)

        # Empty state if about:blank and no blocks
        if not session.blocks and not session.elements:
            _safe_draw_text(
                draw,
                (36, CHROME_HEIGHT + 40),
                session.text_markdown or "空白页 (about:blank) — 等待输入网址或由 AI 导航",
                fill=(100, 116, 139),
                font=font_lg,
            )

        # 3. Scrollbar on right edge
        track_top = CHROME_HEIGHT + 6
        track_bottom = h - 6
        track_h = max(40, track_bottom - track_top)
        draw.rounded_rectangle([w - 10, track_top, w - 4, track_bottom], radius=3, fill=(226, 232, 240))
        total_h = max(h, session.content_height, session.scroll_y + h)
        thumb_h = max(28, int(track_h * (h / total_h)))
        max_scroll = max(1, total_h - h)
        thumb_y = track_top + int((track_h - thumb_h) * min(1.0, session.scroll_y / max_scroll))
        draw.rounded_rectangle([w - 10, thumb_y, w - 4, thumb_y + thumb_h], radius=3, fill=(100, 116, 139))

        # 4. Security Gate Warning Banner (if human_required)
        if session.human_required:
            draw.rectangle([0, CHROME_HEIGHT, w, CHROME_HEIGHT + 34], fill=(254, 242, 242))
            draw.line([(0, CHROME_HEIGHT + 34), (w, CHROME_HEIGHT + 34)], fill=(239, 68, 68), width=2)
            reason_txt = f"⚠ 需真人验证/接管: {session.human_reason or '检测到安全验证或敏感输入'}"
            _safe_draw_text(draw, (18, CHROME_HEIGHT + 7), reason_txt[:82], fill=(185, 28, 28), font=font_md)

        # 5. Top Browser Chrome Bar (drawn last so scrolled content clips cleanly beneath it)
        draw.rectangle([0, 0, w, CHROME_HEIGHT], fill=(15, 23, 42))
        draw.line([(0, CHROME_HEIGHT), (w, CHROME_HEIGHT)], fill=(51, 65, 85), width=1)

        # Traffic light dots
        draw.ellipse([16, 12, 28, 24], fill=(239, 68, 68))
        draw.ellipse([34, 12, 46, 24], fill=(245, 158, 11))
        draw.ellipse([52, 12, 64, 24], fill=(16, 185, 129))

        # Page Title
        title_display = (session.title or "Untitled")[:48]
        _safe_draw_text(draw, (78, 9), title_display, fill=(241, 245, 249), font=font_md)

        # Status Badge (AI 操作中 vs 真人接管 vs 需真人验证)
        if session.human_required:
            badge_label = "需真人验证"
            badge_fill = (220, 38, 38)
        elif session.control_owner == "human":
            badge_label = "真人接管"
            badge_fill = (217, 119, 6)
        else:
            badge_label = "AI 操作中"
            badge_fill = (37, 99, 235)

        draw.rounded_rectangle([w - 136, 7, w - 16, 31], radius=12, fill=badge_fill)
        _safe_draw_text(draw, (w - 122, 10), badge_label, fill=(255, 255, 255), font=font_sm)

        # URL Address Bar
        draw.rounded_rectangle([16, 38, w - 16, 68], radius=8, fill=(30, 41, 59), outline=(71, 85, 105), width=1)
        url_display = (session.url or "about:blank")[:78]
        _safe_draw_text(draw, (28, 44), url_display, fill=(226, 232, 240), font=font_sm)

        meta_str = f"#{len(session.elements)} els | Y:{session.scroll_y}px"
        _safe_draw_text(draw, (w - 175, 45), meta_str, fill=(148, 163, 184), font=font_xs)

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=80)
        jpeg_bytes = buf.getvalue()
        session.last_frame_bytes = jpeg_bytes
        session.last_frame_b64 = base64.b64encode(jpeg_bytes).decode("ascii")
        return jpeg_bytes

    def _try_render_edge_headless(self, url: str, width: int, height: int) -> bytes | None:
        edge_candidates = [
            shutil.which("msedge"),
            shutil.which("msedge.exe"),
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        ]
        edge_bin = next((c for c in edge_candidates if c and os.path.exists(c)), None)
        if not edge_bin:
            return None

        tmp_png = Path(tempfile.gettempdir()) / f"dsh_edge_{uuid.uuid4().hex[:8]}.png"
        try:
            cmd = [
                edge_bin,
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                f"--window-size={width},{height}",
                f"--screenshot={tmp_png}",
                url,
            ]
            subprocess.run(cmd, capture_output=True, timeout=8, check=False)
            if tmp_png.exists() and tmp_png.stat().st_size > 0:
                with Image.open(tmp_png) as im:
                    rgb = im.convert("RGB").resize((width, height))
                    out = io.BytesIO()
                    rgb.save(out, format="JPEG", quality=80)
                    return out.getvalue()
        except Exception:
            return None
        finally:
            try:
                tmp_png.unlink(missing_ok=True)
            except Exception:
                pass
        return None

    async def _fetch_page(self, url: str) -> tuple[int, str, str]:
        if self.http_fetcher is not None:
            result = self.http_fetcher(url)
            if inspect.isawaitable(result):
                result = await result
            if isinstance(result, tuple):
                if len(result) == 3:
                    return int(result[0]), str(result[1]), str(result[2])
                if len(result) == 2:
                    return int(result[0]), url, str(result[1])
            raise ValueError("Invalid response from http_fetcher")

        headers = {
            "User-Agent": DEFAULT_USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        }
        async with httpx.AsyncClient(follow_redirects=True, timeout=15.0, headers=headers) as client:
            resp = await client.get(url)
            return resp.status_code, str(resp.url), resp.text

    # ------------------------------------------------------------------
    # WebSocket Subscriber Broadcast Helpers
    # ------------------------------------------------------------------
    def subscribe(self, browser_id: str) -> asyncio.Queue[dict[str, Any]]:
        sess = self.create_or_get_session(browser_id=browser_id)
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=32)
        sess.subscribers.add(q)
        return q

    def unsubscribe(self, browser_id: str, q: asyncio.Queue[dict[str, Any]]) -> None:
        sess = self._sessions.get(browser_id)
        if sess is not None:
            sess.subscribers.discard(q)

    def _broadcast(self, sess: BrowserSession, event_type: str, extra: dict[str, Any] | None = None) -> None:
        if not sess.subscribers:
            return
        payload: dict[str, Any] = {
            "type": event_type,
            **self.snapshot(sess.browser_id, include_frame=True),
        }
        if extra:
            payload.update(extra)
        dead: list[asyncio.Queue[dict[str, Any]]] = []
        for q in list(sess.subscribers):
            try:
                if q.full():
                    try:
                        q.get_nowait()
                    except Exception:
                        pass
                q.put_nowait(payload)
            except Exception:
                dead.append(q)
        for q in dead:
            sess.subscribers.discard(q)

    # ------------------------------------------------------------------
    # Session Lifecycle Management
    # ------------------------------------------------------------------
    def create_or_get_session(
        self,
        browser_id: str | None = None,
        *,
        session_id: str = "global",
        workspace_profile_id: str = "ws_default",
    ) -> BrowserSession:
        with self._lock:
            if browser_id and browser_id in self._sessions:
                sess = self._sessions[browser_id]
                if session_id and session_id != "global":
                    sess.session_id = session_id
                if workspace_profile_id and workspace_profile_id != "ws_default":
                    sess.workspace_profile_id = workspace_profile_id
                return sess

            if not browser_id and session_id:
                for existing in self._sessions.values():
                    if existing.session_id == session_id:
                        return existing

            new_id = browser_id or ("br_" + uuid.uuid4().hex[:10])
            sess = BrowserSession(
                browser_id=new_id,
                session_id=session_id or "global",
                workspace_profile_id=workspace_profile_id or "ws_default",
                url="about:blank",
                title="空白页",
                text_markdown="# 空白页\n\n等待导航指令或输入网址。",
            )
            self._render_viewport_jpeg(sess)
            self._sessions[new_id] = sess
            return sess

    def get_session(self, browser_id: str) -> BrowserSession:
        with self._lock:
            if browser_id not in self._sessions:
                raise KeyError(f"Browser session not found: {browser_id}")
            return self._sessions[browser_id]

    def list_sessions(self, *, session_id: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            items: list[dict[str, Any]] = []
            for sess in self._sessions.values():
                if session_id and sess.session_id != session_id:
                    continue
                items.append(self.snapshot(sess.browser_id, include_frame=False))
            items.sort(key=lambda x: x.get("updated_at", ""), reverse=True)
            return items

    def close_session(self, browser_id: str) -> bool:
        with self._lock:
            sess = self._sessions.pop(browser_id, None)
            if sess is None:
                return False
            sess.subscribers.clear()
            return True

    # ------------------------------------------------------------------
    # Control Handoff & Actor Gate
    # ------------------------------------------------------------------
    def set_control(
        self,
        browser_id: str,
        owner: Literal["agent", "human"],
        reason: str = "",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        normalized_owner: Literal["agent", "human"] = "human" if owner == "human" else "agent"
        sess.control_owner = normalized_owner
        if normalized_owner == "agent":
            sess.human_required = False
            sess.human_reason = reason or ""
        else:
            sess.human_reason = reason or sess.human_reason or "真人已接管浏览器"
        sess.updated_at = _utc_now_iso()
        self._render_viewport_jpeg(sess)
        self._broadcast(
            sess,
            "control_changed",
            {"control_owner": sess.control_owner, "human_required": sess.human_required, "human_reason": sess.human_reason},
        )
        return {"ok": True, **self.snapshot(sess.browser_id, include_frame=True)}

    def _ensure_actor_allowed(
        self,
        sess: BrowserSession,
        actor: Literal["agent", "human"],
    ) -> dict[str, Any] | None:
        if actor == "human" and sess.control_owner != "human":
            sess.control_owner = "human"
            if not sess.human_reason:
                sess.human_reason = "真人点击/操作自动接管浏览器"
            sess.updated_at = _utc_now_iso()
            self._render_viewport_jpeg(sess)
            self._broadcast(
                sess,
                "control_changed",
                {
                    "event": "human_took_over",
                    "control_owner": "human",
                    "human_required": sess.human_required,
                    "human_reason": sess.human_reason,
                },
            )
            return None

        if actor == "agent" and sess.control_owner == "human":
            return {
                "ok": False,
                "browser_id": sess.browser_id,
                "session_id": sess.session_id,
                "url": sess.url,
                "title": sess.title,
                "paused_by_human": True,
                "control_owner": "human",
                "human_required": sess.human_required,
                "human_reason": sess.human_reason or "真人已接管浏览器，请等待交还控制权",
            }

        return None

    # ------------------------------------------------------------------
    # Browser Navigation & Interaction Actions
    # ------------------------------------------------------------------
    async def navigate(
        self,
        browser_id: str,
        url: str,
        *,
        actor: Literal["agent", "human"] = "agent",
        engine: str | None = None,
        record_history: bool = True,
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        raw_url = (url or "").strip() or "about:blank"
        if engine:
            sess.engine = engine

        # First check raw scheme before normalizing
        pre_check = self.check_url_allowed(raw_url)
        if not pre_check.allowed and any(raw_url.lower().startswith(f"{s}:") for s in DISALLOWED_SCHEMES):
            return {
                "ok": False,
                "blocked": True,
                "error": pre_check.reason,
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        target_url = raw_url
        if target_url.lower() != "about:blank" and "://" not in target_url:
            target_url = f"https://{target_url}"

        policy_check = self.check_url_allowed(target_url)
        if not policy_check.allowed:
            return {
                "ok": False,
                "blocked": True,
                "error": policy_check.reason,
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        if target_url.lower() == "about:blank":
            sess.url = "about:blank"
            sess.title = "空白页"
            sess.elements = []
            sess.blocks = []
            sess.text_markdown = "# 空白页\n\n等待导航指令或输入网址。"
            sess.scroll_y = 0
            sess.focused_element_id = None
            sess.last_status_code = 200
            sess.human_required = False
            if sess.control_owner == "agent":
                sess.human_reason = ""
            sess.updated_at = _utc_now_iso()
            self._render_viewport_jpeg(sess)
            self._broadcast(sess, "frame")
            return {"ok": True, **self.snapshot(sess.browser_id, include_frame=True)}

        try:
            status_code, final_url, html = await self._fetch_page(target_url)
        except Exception as exc:
            sess.last_status_code = 599
            sess.updated_at = _utc_now_iso()
            self._render_viewport_jpeg(sess)
            return {
                "ok": False,
                "error": f"页面加载失败: {exc}",
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        final_check = self.check_url_allowed(final_url)
        if not final_check.allowed:
            return {
                "ok": False,
                "blocked": True,
                "error": final_check.reason,
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        parsed = self._parse_html_page(final_url, html)
        sess.url = final_url
        sess.title = parsed["title"]
        sess.elements = parsed["elements"]
        sess.text_markdown = parsed["text_markdown"]
        sess.blocks = parsed["blocks"]
        sess.content_height = parsed["content_height"]
        sess.raw_html = html
        sess.scroll_y = 0
        sess.focused_element_id = None
        sess.last_status_code = status_code

        if record_history:
            if 0 <= sess.history_index < len(sess.history) - 1:
                sess.history = sess.history[: sess.history_index + 1]
            if not sess.history or sess.history[-1] != final_url:
                sess.history.append(final_url)
                sess.history_index = len(sess.history) - 1

        gate_hit, gate_reason = self._check_security_gate(final_url, sess.title, html, sess.elements)
        if gate_hit:
            sess.human_required = True
            sess.human_reason = gate_reason
            sess.control_owner = "human"
        else:
            sess.human_required = False
            if sess.control_owner == "agent":
                sess.human_reason = ""

        sess.updated_at = _utc_now_iso()
        self._render_viewport_jpeg(sess)
        if gate_hit:
            self._broadcast(
                sess,
                "security_gate",
                {
                    "control_owner": "human",
                    "human_required": True,
                    "human_reason": gate_reason,
                },
            )
        else:
            self._broadcast(sess, "frame")

        return {"ok": True, **self.snapshot(sess.browser_id, include_frame=True)}

    async def go_back(
        self,
        browser_id: str,
        *,
        actor: Literal["agent", "human"] = "agent",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        if sess.history_index <= 0 or not sess.history:
            return {
                "ok": False,
                "error": "没有可后退的历史记录",
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        sess.history_index -= 1
        target_url = sess.history[sess.history_index]
        return await self.navigate(browser_id, target_url, actor=actor, record_history=False)

    async def go_forward(
        self,
        browser_id: str,
        *,
        actor: Literal["agent", "human"] = "agent",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        if sess.history_index < 0 or sess.history_index >= len(sess.history) - 1:
            return {
                "ok": False,
                "error": "没有可前进的历史记录",
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        sess.history_index += 1
        target_url = sess.history[sess.history_index]
        return await self.navigate(browser_id, target_url, actor=actor, record_history=False)

    async def reload(
        self,
        browser_id: str,
        *,
        actor: Literal["agent", "human"] = "agent",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        if sess.url and sess.url.lower() != "about:blank":
            return await self.navigate(browser_id, sess.url, actor=actor, record_history=False)

        sess.updated_at = _utc_now_iso()
        self._render_viewport_jpeg(sess)
        self._broadcast(sess, "frame")
        return {"ok": True, **self.snapshot(sess.browser_id, include_frame=True)}

    def _find_element(
        self,
        sess: BrowserSession,
        *,
        element_id: int | None = None,
        x: int | None = None,
        y: int | None = None,
    ) -> dict[str, Any] | None:
        if element_id is not None:
            for el in sess.elements:
                if int(el.get("id", -1)) == int(element_id):
                    return el
            return None

        if x is not None and y is not None:
            px = int(x)
            py_doc = int(y) + sess.scroll_y
            for el in sess.elements:
                bbox = el.get("bbox") or []
                if len(bbox) == 4:
                    bx, by, bw, bh = int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])
                    if bx <= px <= bx + bw and by <= py_doc <= by + bh:
                        return el
            # Fallback direct bbox match if caller passed document coordinates
            if sess.scroll_y != 0:
                py_raw = int(y)
                for el in sess.elements:
                    bbox = el.get("bbox") or []
                    if len(bbox) == 4:
                        bx, by, bw, bh = int(bbox[0]), int(bbox[1]), int(bbox[2]), int(bbox[3])
                        if bx <= px <= bx + bw and by <= py_raw <= by + bh:
                            return el
        return None

    async def click(
        self,
        browser_id: str,
        *,
        element_id: int | None = None,
        x: int | None = None,
        y: int | None = None,
        actor: Literal["agent", "human"] = "agent",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        target = self._find_element(sess, element_id=element_id, x=x, y=y)
        if target is None:
            if element_id is not None:
                return {
                    "ok": False,
                    "error": f"未找到编号为 [{element_id}] 的交互元素",
                    **self.snapshot(sess.browser_id, include_frame=True),
                }
            # Coordinate click on non-element canvas area (still valid, e.g. human takeover click)
            sess.updated_at = _utc_now_iso()
            self._render_viewport_jpeg(sess)
            self._broadcast(sess, "frame")
            return {
                "ok": True,
                "clicked_element": None,
                "clicked_coords": [x, y] if x is not None and y is not None else None,
                **self.snapshot(sess.browser_id, include_frame=True),
            }

        sess.focused_element_id = int(target["id"])
        clicked_copy = copy.deepcopy(target)
        href = str(target.get("href") or "").strip()

        if href and not href.startswith(("#", "javascript:")):
            nav_res = await self.navigate(browser_id, href, actor=actor)
            nav_res["clicked_element"] = clicked_copy
            return nav_res

        form_action = str(target.get("form_action") or "").strip()
        if (target.get("type") == "submit" or target.get("tag") == "button") and form_action:
            params: dict[str, str] = {}
            for el in sess.elements:
                if el.get("tag") in ("input", "textarea", "select") and el.get("name"):
                    params[str(el["name"])] = str(el.get("value") or "")
            submit_url = form_action
            if params and str(target.get("form_method") or "GET").upper() == "GET":
                sep = "&" if "?" in submit_url else "?"
                submit_url = f"{submit_url}{sep}{urlencode(params)}"
            nav_res = await self.navigate(browser_id, submit_url, actor=actor)
            nav_res["clicked_element"] = clicked_copy
            return nav_res

        if target.get("type") == "checkbox":
            target["value"] = "" if target.get("value") == "checked" else "checked"

        sess.updated_at = _utc_now_iso()
        self._render_viewport_jpeg(sess)
        self._broadcast(sess, "frame")
        return {
            "ok": True,
            "clicked_element": copy.deepcopy(target),
            **self.snapshot(sess.browser_id, include_frame=True),
        }

    async def type_text(
        self,
        browser_id: str,
        *,
        text: str,
        element_id: int | None = None,
        submit: bool = False,
        actor: Literal["agent", "human"] = "agent",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        target: dict[str, Any] | None = None
        if element_id is not None:
            target = self._find_element(sess, element_id=element_id)
            if target is None:
                return {
                    "ok": False,
                    "error": f"未找到编号为 [{element_id}] 的输入元素",
                    **self.snapshot(sess.browser_id, include_frame=True),
                }
        elif sess.focused_element_id is not None:
            target = self._find_element(sess, element_id=sess.focused_element_id)

        if target is None:
            for el in sess.elements:
                if el.get("tag") in ("input", "textarea", "select"):
                    target = el
                    break
        if target is None and sess.elements:
            target = sess.elements[0]

        if target is not None:
            target["value"] = str(text)
            sess.focused_element_id = int(target["id"])
            # Update markdown line preview if applicable
            if f"[{target['id']}]" in sess.text_markdown and target.get("type") != "password":
                sess.text_markdown += f"\n\n> 输入 [{target['id']}]: {text}"

        if submit and target is not None:
            form_action = str(target.get("form_action") or "").strip()
            href = str(target.get("href") or "").strip()
            if form_action:
                field_name = str(target.get("name") or "q")
                sep = "&" if "?" in form_action else "?"
                submit_url = f"{form_action}{sep}{urlencode({field_name: str(text)})}"
                nav_res = await self.navigate(browser_id, submit_url, actor=actor)
                nav_res["typed_element"] = copy.deepcopy(target)
                return nav_res
            if href and not href.startswith(("#", "javascript:")):
                nav_res = await self.navigate(browser_id, href, actor=actor)
                nav_res["typed_element"] = copy.deepcopy(target)
                return nav_res

        sess.updated_at = _utc_now_iso()
        self._render_viewport_jpeg(sess)
        self._broadcast(sess, "frame")
        return {
            "ok": True,
            "typed_element": copy.deepcopy(target) if target else None,
            **self.snapshot(sess.browser_id, include_frame=True),
        }

    async def scroll(
        self,
        browser_id: str,
        *,
        delta_y: int = 360,
        actor: Literal["agent", "human"] = "agent",
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        blocked = self._ensure_actor_allowed(sess, actor)
        if blocked is not None:
            return blocked

        max_scroll = max(2400, sess.content_height - sess.viewport_height + 240)
        sess.scroll_y = max(0, min(sess.scroll_y + int(delta_y), max_scroll))
        sess.updated_at = _utc_now_iso()
        self._render_viewport_jpeg(sess)
        self._broadcast(sess, "frame")
        return {"ok": True, **self.snapshot(sess.browser_id, include_frame=True)}

    def snapshot(self, browser_id: str, *, include_frame: bool = True) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        if include_frame and not sess.last_frame_b64:
            self._render_viewport_jpeg(sess)

        data: dict[str, Any] = {
            "browser_id": sess.browser_id,
            "session_id": sess.session_id,
            "workspace_profile_id": sess.workspace_profile_id,
            "url": sess.url,
            "title": sess.title,
            "history": list(sess.history),
            "history_index": sess.history_index,
            "can_go_back": sess.history_index > 0,
            "can_go_forward": 0 <= sess.history_index < len(sess.history) - 1,
            "control_owner": sess.control_owner,
            "human_required": sess.human_required,
            "human_reason": sess.human_reason,
            "scroll_y": sess.scroll_y,
            "viewport_width": sess.viewport_width,
            "viewport_height": sess.viewport_height,
            "elements": copy.deepcopy(sess.elements),
            "text_markdown": sess.text_markdown,
            "last_status_code": sess.last_status_code,
            "updated_at": sess.updated_at,
        }
        if include_frame:
            data["frame_b64"] = sess.last_frame_b64
            data["last_frame_b64"] = sess.last_frame_b64
        return data

    def save_frame_as_attachment(
        self,
        browser_id: str,
        attachment_service: Any | None = None,
    ) -> dict[str, Any]:
        sess = self.create_or_get_session(browser_id=browser_id)
        frame_bytes = sess.last_frame_bytes or self._render_viewport_jpeg(sess)
        filename = f"browser_{sess.browser_id}_{int(time.time())}.jpg"
        svc = attachment_service or self.attachment_service

        if svc is not None and hasattr(svc, "save_image_bytes"):
            fn = svc.save_image_bytes
            try:
                sig = inspect.signature(fn)
                kwargs: dict[str, Any] = {}
                if "filename" in sig.parameters:
                    kwargs["filename"] = filename
                if "mime_type" in sig.parameters:
                    kwargs["mime_type"] = "image/jpeg"
                if "session_id" in sig.parameters:
                    kwargs["session_id"] = sess.session_id
                if "source" in sig.parameters:
                    kwargs["source"] = "browser"
                res = fn(frame_bytes, **kwargs)
                if isinstance(res, dict):
                    return {"ok": True, "browser_id": sess.browser_id, **res}
                if hasattr(res, "model_dump"):
                    return {"ok": True, "browser_id": sess.browser_id, **res.model_dump()}
                if hasattr(res, "to_dict"):
                    return {"ok": True, "browser_id": sess.browser_id, **res.to_dict()}
                return {"ok": True, "browser_id": sess.browser_id, "attachment": res}
            except TypeError:
                res = fn(frame_bytes)
                if isinstance(res, dict):
                    return {"ok": True, "browser_id": sess.browser_id, **res}
                return {"ok": True, "browser_id": sess.browser_id, "attachment": res}

        # Fallback local disk persistence if no attachment_service is wired
        att_id = "att_" + uuid.uuid4().hex[:12]
        att_dir = self.data_dir / "attachments"
        att_dir.mkdir(parents=True, exist_ok=True)
        dest = att_dir / f"{att_id}_{filename}"
        dest.write_bytes(frame_bytes)
        return {
            "ok": True,
            "browser_id": sess.browser_id,
            "attachment_id": att_id,
            "id": att_id,
            "filename": filename,
            "mime_type": "image/jpeg",
            "size": len(frame_bytes),
            "path": str(dest),
            "url": f"/api/attachments/{att_id}/raw",
        }
