"""DeepSeek streaming agent runtime with resilient retries, message sanitization, and batch approvals."""

from __future__ import annotations

import asyncio
import json
import os
import ssl
import subprocess
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx

from bridge.config import PROJECT_ROOT, ConfigStore
from bridge.fs_service import (
    WorkspaceSecurityError,
    git_status_and_diff,
    list_directory,
    read_file_content,
    resolve_ai_path,
    search_workspace,
    to_rel_posix,
    write_file_content,
)

WRITE_TOOLS = {"write_file", "edit_file", "run_command"}
COMMAND_TOOLS = {"run_command"}
MAX_TOOL_ROUNDS = 24
RETRYABLE_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}

SYSTEM_PROMPT = """You are a skilled AI coding assistant running inside the user's Windows workspace via DeepSeek Mobile Bridge.
You have tools to inspect directories, read files, search code, write/edit files, present files to the user for download/review (Claude Artifact style), inspect git status/diff, run shell commands, and ask the user questions.

Environment Facts:
- Bridge HTTP/WebSocket server: http://127.0.0.1:8765 (health checks: http://127.0.0.1:8765/health and http://127.0.0.1:8765/api/health)
- Project Python virtualenv: .venv\\Scripts\\python.exe (automatically prepended to PATH in run_command)
- Frontend in `web/` is zero-build native ES Modules (no Node.js / npm required)
- Active workspace root: {workspace}
- AI Access Isolation Mode: {ai_access_mode} (Allowed workspaces: {allowed_workspaces})

Guidelines:
- Always inspect relevant files before editing them.
- Prefer `edit_file` for targeted changes to existing files and `write_file` for creating new files.
- Whenever the user asks you to send/share/provide a file for download, OR asks to review a newly created or modified file, call `present_file` so a Claude-style interactive File Artifact & Download card is pushed directly to their phone screen.
- Keep responses concise and clear for mobile reading.
"""

TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "list_directory",
            "description": "List files and subdirectories inside the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative path from workspace root (empty string for root).",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a text file inside the workspace with optional line range.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path to the file."},
                    "start_line": {"type": "integer", "description": "1-based start line (optional)."},
                    "end_line": {"type": "integer", "description": "1-based inclusive end line (optional)."},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Create or overwrite a text file inside the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path to the file."},
                    "content": {"type": "string", "description": "Full file contents."},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "edit_file",
            "description": "Replace an exact target text block inside an existing workspace file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Relative path to the file."},
                    "target": {"type": "string", "description": "Exact existing text to replace."},
                    "replacement": {"type": "string", "description": "New replacement text."},
                },
                "required": ["path", "target", "replacement"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_files",
            "description": "Search filenames and text contents in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query string."},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "git_status_diff",
            "description": "Show git branch, modified files, and unified diff in the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Optional relative file path filter."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Execute a PowerShell command in the workspace directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "PowerShell command to execute."},
                    "timeout": {"type": "integer", "description": "Timeout in seconds (default 60)."},
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "present_file",
            "description": "Send or present a file to the user on their mobile screen as a Claude-style File Artifact card for immediate review, preview, or local download.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative or absolute path to the file on the PC.",
                    },
                    "title": {
                        "type": "string",
                        "description": "Display title for the file card (optional).",
                    },
                    "summary": {
                        "type": "string",
                        "description": "Brief summary of what this file contains or what was changed (optional).",
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["review", "download"],
                        "description": "'review' for newly created/modified files to inspect, or 'download' when the user asked to download a file.",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "ask_user",
            "description": "Ask the user a clarifying question on their mobile screen and wait for their answer.",
            "parameters": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The question to ask."},
                    "options": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional list of quick-reply options.",
                    },
                },
                "required": ["question"],
            },
        },
    },
]


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _format_exception(exc: BaseException) -> str:
    msg = str(exc).strip()
    cls_name = type(exc).__name__
    if isinstance(exc, (httpx.TimeoutException, asyncio.TimeoutError)):
        return f"请求超时 ({cls_name}): {msg or '连接 DeepSeek 服务器超时，请重试'}"
    if isinstance(exc, (httpx.TransportError, ssl.SSLError, OSError)):
        return f"网络连接中断 ({cls_name}): {msg or '与 DeepSeek 的连接被重置或代理中断，请重试'}"
    if msg:
        return msg
    return f"运行异常 ({cls_name})"


def sanitize_conversation_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Repair any corrupted/interrupted message history so DeepSeek API never rejects it."""
    cleaned: list[dict[str, Any]] = []
    i = 0
    n = len(messages)
    while i < n:
        msg = dict(messages[i])
        role = msg.get("role")

        if role == "user":
            # If the previous message in `cleaned` is also a `user` message (from a failed turn),
            # replace the dangling user message with the latest one.
            if cleaned and cleaned[-1].get("role") == "user":
                cleaned[-1] = msg
            else:
                cleaned.append(msg)
            i += 1
            continue

        if role == "assistant":
            tool_calls = msg.get("tool_calls") or []
            if not tool_calls:
                if msg.get("content") or msg.get("reasoning_content"):
                    cleaned.append(msg)
                i += 1
                continue

            # Collect subsequent `tool` messages matching this assistant's tool_calls
            expected_ids = [tc.get("id") for tc in tool_calls if tc.get("id")]
            j = i + 1
            found_tools: dict[str, dict[str, Any]] = {}
            while j < n and messages[j].get("role") == "tool":
                tmsg = dict(messages[j])
                tc_id = tmsg.get("tool_call_id")
                if tc_id:
                    found_tools[tc_id] = tmsg
                j += 1

            cleaned.append(msg)
            for tc_id in expected_ids:
                if tc_id in found_tools:
                    cleaned.append(found_tools[tc_id])
                else:
                    cleaned.append(
                        {
                            "role": "tool",
                            "tool_call_id": tc_id,
                            "content": json.dumps(
                                {"error": "Tool execution was interrupted in a previous turn."},
                                ensure_ascii=False,
                            ),
                        }
                    )
            i = j
            continue

        # Skip orphan `tool` messages not preceded by an `assistant` with `tool_calls`
        i += 1

    return cleaned


def compact_event_stream(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Coalesce contiguous thought_delta / text_delta events and drop transient status events."""
    compacted: list[dict[str, Any]] = []
    for ev in events:
        etype = ev.get("type")
        if etype == "status":
            continue
        data = dict(ev.get("data") or {})
        if etype == "error" and not str(data.get("message") or "").strip():
            data["message"] = "网络连接中断 (历史回合未完成)"

        if etype in ("thought_delta", "text_delta"):
            piece = str(data.get("full_text") or data.get("text") or "")
            if compacted and compacted[-1].get("type") == etype:
                prev_data = compacted[-1]["data"]
                # If `full_text` was already stored, use it if longer; otherwise append `text`
                if "full_text" in data:
                    merged = piece
                else:
                    merged = str(prev_data.get("full_text") or prev_data.get("text") or "") + piece
                compacted[-1] = {
                    "seq": ev["seq"],
                    "type": etype,
                    "ts": ev.get("ts") or _utc_now(),
                    "data": {"text": merged, "full_text": merged},
                }
            else:
                compacted.append(
                    {
                        "seq": ev["seq"],
                        "type": etype,
                        "ts": ev.get("ts") or _utc_now(),
                        "data": {"text": piece, "full_text": piece},
                    }
                )
        else:
            compacted.append({**ev, "data": data})
    return compacted


@dataclass
class PendingRequest:
    request_id: str
    kind: str  # "approval" | "interaction"
    payload: dict[str, Any]
    future: asyncio.Future[Any]
    created_at: str = field(default_factory=_utc_now)


class DeepSeekSession:
    """Persistent conversation session powered by DeepSeek chat/reasoner API."""

    def __init__(
        self,
        *,
        session_id: str,
        title: str,
        workspace: str,
        approval_mode: str,
        config_store: ConfigStore,
        sessions_dir: Path,
        model: str | None = None,
        messages: list[dict[str, Any]] | None = None,
        events: list[dict[str, Any]] | None = None,
    ):
        self.session_id = session_id
        self.title = title
        self.workspace = str(Path(workspace).resolve())
        self.approval_mode = approval_mode
        self.model = model or config_store.config.model or "deepseek-chat"
        self.config_store = config_store
        self.sessions_dir = sessions_dir
        self.created_at = _utc_now()
        self.updated_at = self.created_at
        self.messages: list[dict[str, Any]] = sanitize_conversation_messages(messages or [])
        self.events: list[dict[str, Any]] = compact_event_stream(events or [])
        self.next_seq = (self.events[-1]["seq"] + 1) if self.events else 1

        self.status: str = "idle"
        self.subscribers: set[asyncio.Queue[dict[str, Any]]] = set()
        self.pending_approvals: dict[str, PendingRequest] = {}
        self.pending_interactions: dict[str, PendingRequest] = {}

        self._lock = asyncio.Lock()
        self._active_task: asyncio.Task[None] | None = None
        self._http_client_factory = lambda: httpx.AsyncClient(
            http2=False,
            timeout=httpx.Timeout(120.0, connect=15.0, read=90.0),
        )

    @property
    def storage_path(self) -> Path:
        return self.sessions_dir / f"{self.session_id}.json"

    def summary(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "title": self.title,
            "workspace": self.workspace,
            "approval_mode": self.approval_mode,
            "model": self.model,
            "status": self.status,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "last_seq": self.next_seq - 1,
            "pending_approvals": [
                {
                    "request_id": req.request_id,
                    "created_at": req.created_at,
                    **req.payload,
                }
                for req in self.pending_approvals.values()
            ],
            "pending_interactions": [
                {
                    "request_id": req.request_id,
                    "created_at": req.created_at,
                    **req.payload,
                }
                for req in self.pending_interactions.values()
            ],
        }

    def save_to_disk(self) -> None:
        self.sessions_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "session_id": self.session_id,
            "title": self.title,
            "workspace": self.workspace,
            "approval_mode": self.approval_mode,
            "model": self.model,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "messages": self.messages[-120:],
            "events": self.events[-600:],
        }
        tmp = self.storage_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.storage_path)

    def emit_event(
        self,
        event_type: str,
        data: dict[str, Any],
        *,
        persist: bool = True,
        include_session: bool = False,
    ) -> dict[str, Any]:
        seq = self.next_seq
        self.next_seq += 1
        now = _utc_now()
        self.updated_at = now

        # Coalesce contiguous thought_delta and text_delta in stored history
        if event_type in ("thought_delta", "text_delta"):
            delta_text = str(data.get("text") or "")
            if self.events and self.events[-1]["type"] == event_type:
                prev_full = str(self.events[-1]["data"].get("full_text") or self.events[-1]["data"].get("text") or "")
                full_text = prev_full + delta_text
                stored_event = {
                    "seq": seq,
                    "type": event_type,
                    "ts": now,
                    "data": {"text": full_text, "full_text": full_text},
                }
                self.events[-1] = stored_event
            else:
                full_text = delta_text
                stored_event = {
                    "seq": seq,
                    "type": event_type,
                    "ts": now,
                    "data": {"text": full_text, "full_text": full_text},
                }
                self.events.append(stored_event)

            wire_event: dict[str, Any] = {
                "seq": seq,
                "type": event_type,
                "ts": now,
                "data": {"text": delta_text, "full_text": full_text},
            }
        else:
            wire_data = dict(data)
            if include_session:
                wire_data["session"] = self.summary()
            wire_event = {
                "seq": seq,
                "type": event_type,
                "ts": now,
                "data": wire_data,
            }
            if event_type != "status":
                self.events.append(wire_event)
                if len(self.events) > 800:
                    self.events = self.events[-600:]

        for queue in list(self.subscribers):
            queue.put_nowait(wire_event)

        if persist:
            self.save_to_disk()
        return wire_event

    def get_events_after(self, after_seq: int = 0) -> list[dict[str, Any]]:
        if after_seq <= 0:
            return list(self.events)
        return [ev for ev in self.events if ev["seq"] > after_seq]

    def subscribe(self) -> asyncio.Queue[dict[str, Any]]:
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[dict[str, Any]]) -> None:
        self.subscribers.discard(q)

    async def _send_bark(self, title: str, body: str) -> None:
        bark_url = self.config_store.config.bark_url.strip().rstrip("/")
        if not bark_url:
            return

        def _post() -> None:
            encoded_title = urllib.parse.quote(title, safe="")
            encoded_body = urllib.parse.quote(body[:200], safe="")
            url = f"{bark_url}/{encoded_title}/{encoded_body}?group=deepseek"
            try:
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=4):
                    pass
            except Exception:
                pass

        await asyncio.to_thread(_post)

    def _needs_approval(self, tool_name: str) -> bool:
        if self.approval_mode == "auto":
            return False
        if self.approval_mode == "ask_writes":
            return tool_name in WRITE_TOOLS
        return tool_name in COMMAND_TOOLS

    def _register_approval(self, tool_name: str, args: dict[str, Any]) -> PendingRequest:
        loop = asyncio.get_running_loop()
        req_id = uuid.uuid4().hex[:10]
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        payload = {"tool_name": tool_name, "args": args}
        req = PendingRequest(
            request_id=req_id,
            kind="approval",
            payload=payload,
            future=fut,
        )
        self.pending_approvals[req_id] = req
        return req

    async def _await_approval(self, req: PendingRequest) -> tuple[bool, str]:
        try:
            decision = await req.future
        finally:
            self.pending_approvals.pop(req.request_id, None)
            if not self.pending_approvals and not self.pending_interactions:
                if self._active_task and not self._active_task.done():
                    self.status = "running"

        allow = bool(decision.get("allow", False))
        reason = str(decision.get("reason") or ("Approved on mobile" if allow else "Denied on mobile"))
        self.emit_event(
            "approval_resolved",
            {"request_id": req.request_id, "allow": allow, "reason": reason},
            include_session=True,
        )
        return allow, reason

    async def _request_interaction(self, question: str, options: list[str]) -> dict[str, Any]:
        loop = asyncio.get_running_loop()
        req_id = uuid.uuid4().hex[:10]
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        questions_data = [
            {
                "question": question,
                "is_multi_select": False,
                "options": [{"id": str(i), "text": opt} for i, opt in enumerate(options)],
            }
        ]
        payload = {"questions": questions_data}
        self.pending_interactions[req_id] = PendingRequest(
            request_id=req_id,
            kind="interaction",
            payload=payload,
            future=fut,
        )
        self.status = "waiting_input"
        self.emit_event(
            "interaction_request",
            {"request_id": req_id, **payload},
            include_session=True,
        )
        asyncio.create_task(self._send_bark("DeepSeek 需要你的回答", question))
        try:
            answer = await fut
        finally:
            self.pending_interactions.pop(req_id, None)
            if not self.pending_approvals and not self.pending_interactions:
                if self._active_task and not self._active_task.done():
                    self.status = "running"

        cancelled = bool(answer.get("cancelled", False))
        self.emit_event(
            "interaction_resolved",
            {"request_id": req_id, "cancelled": cancelled},
            include_session=True,
        )
        return answer

    async def _execute_tool(
        self,
        name: str,
        raw_args: str,
        pre_req: PendingRequest | None = None,
    ) -> str:
        try:
            args = json.loads(raw_args) if raw_args.strip() else {}
        except json.JSONDecodeError as exc:
            if pre_req:
                self.pending_approvals.pop(pre_req.request_id, None)
            return json.dumps({"error": f"Invalid JSON arguments: {exc}"}, ensure_ascii=False)

        if not isinstance(args, dict):
            if pre_req:
                self.pending_approvals.pop(pre_req.request_id, None)
            return json.dumps({"error": "Tool arguments must be a JSON object"}, ensure_ascii=False)

        if pre_req is not None:
            allow, reason = await self._await_approval(pre_req)
            if not allow:
                return json.dumps({"error": f"Denied by user: {reason}"}, ensure_ascii=False)
        elif self._needs_approval(name):
            req = self._register_approval(name, args)
            self.status = "waiting_input"
            self.emit_event(
                "approval_request",
                {"request_id": req.request_id, **req.payload},
                include_session=True,
            )
            allow, reason = await self._await_approval(req)
            if not allow:
                return json.dumps({"error": f"Denied by user: {reason}"}, ensure_ascii=False)

        root = Path(self.workspace)
        cfg = self.config_store.config
        allowed_ws = cfg.workspaces
        ai_mode = cfg.ai_access_mode

        def _build_and_emit_artifact(
            target_path: Path,
            *,
            title: str = "",
            summary: str = "",
            mode: str = "review",
        ) -> dict[str, Any]:
            st = target_path.stat()
            preview_text = ""
            is_text = False
            if st.st_size <= 1_000_000:
                try:
                    raw_b = target_path.read_bytes()
                    if b"\x00" not in raw_b[:4096]:
                        decoded = raw_b.decode("utf-8", errors="replace")
                        is_text = True
                        preview_text = "\n".join(decoded.splitlines()[:120])[:6000]
                except OSError:
                    pass
            artifact_info = {
                "id": uuid.uuid4().hex[:10],
                "name": target_path.name,
                "path": str(target_path.resolve()),
                "rel_path": to_rel_posix(root, target_path),
                "title": title or target_path.name,
                "summary": summary or ("已为你准备好文件，可直接预览审查或下载到手机" if mode == "review" else "点击下方按钮可将该文件下载到手机本地"),
                "size": st.st_size,
                "mtime": st.st_mtime,
                "ext": target_path.suffix.lower(),
                "mode": mode,
                "is_text": is_text,
                "preview": preview_text,
            }
            self.emit_event("file_artifact", artifact_info)
            return artifact_info

        try:
            if name == "list_directory":
                res = list_directory(
                    root,
                    str(args.get("path", "")),
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                )
                return json.dumps(res, ensure_ascii=False)

            if name == "read_file":
                data = read_file_content(
                    root,
                    str(args["path"]),
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                )
                if data.get("is_binary") or data.get("too_large"):
                    return json.dumps(data, ensure_ascii=False)
                lines = data["content"].splitlines()
                start = max(1, int(args.get("start_line") or 1))
                end = min(len(lines), int(args.get("end_line") or len(lines)))
                snippet = "\n".join(
                    f"{idx}: {lines[idx - 1]}" for idx in range(start, end + 1)
                )
                return json.dumps(
                    {
                        "path": data["path"],
                        "abs_path": data.get("abs_path", ""),
                        "total_lines": len(lines),
                        "start_line": start,
                        "end_line": end,
                        "content": snippet[:20000],
                    },
                    ensure_ascii=False,
                )

            if name == "write_file":
                res = write_file_content(
                    root,
                    str(args["path"]),
                    str(args["content"]),
                    force=True,
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                )
                target_file = resolve_ai_path(
                    root,
                    str(args["path"]),
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                    is_write=True,
                )
                if target_file.exists() and target_file.is_file():
                    _build_and_emit_artifact(
                        target_file,
                        title=f"已写入文件 · {target_file.name}",
                        summary="AI 已创建或更新此文件，点击可全屏审查代码或下载到手机",
                        mode="review",
                    )
                return json.dumps(res, ensure_ascii=False)

            if name == "edit_file":
                rel = str(args["path"])
                target = str(args["target"])
                replacement = str(args["replacement"])
                data = read_file_content(
                    root,
                    rel,
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                )
                if data.get("is_binary"):
                    return json.dumps({"error": "Cannot edit binary file"}, ensure_ascii=False)
                text = data["content"]
                count = text.count(target)
                if count == 0:
                    return json.dumps({"error": "Target text not found in file"}, ensure_ascii=False)
                if count > 1:
                    return json.dumps(
                        {"error": f"Target text matched {count} times; provide more context"},
                        ensure_ascii=False,
                    )
                updated = text.replace(target, replacement, 1)
                res = write_file_content(
                    root,
                    rel,
                    updated,
                    force=True,
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                )
                target_file = resolve_ai_path(
                    root,
                    rel,
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                    is_write=True,
                )
                if target_file.exists() and target_file.is_file():
                    _build_and_emit_artifact(
                        target_file,
                        title=f"已修改文件 · {target_file.name}",
                        summary="AI 已修改此文件，点击可审查最新内容或下载到手机",
                        mode="review",
                    )
                return json.dumps({"edited": True, **res}, ensure_ascii=False)

            if name == "present_file":
                raw_p = str(args["path"])
                target_file = resolve_ai_path(
                    root,
                    raw_p,
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                    is_write=False,
                )
                if not target_file.exists():
                    return json.dumps({"error": f"File not found: {raw_p}"}, ensure_ascii=False)
                if target_file.is_dir():
                    return json.dumps({"error": f"Path is a directory, not a file: {raw_p}"}, ensure_ascii=False)
                art = _build_and_emit_artifact(
                    target_file,
                    title=str(args.get("title") or target_file.name),
                    summary=str(args.get("summary") or "AI 已为你发送该文件，点击即可审查内容或下载到手机本地"),
                    mode=str(args.get("mode") or "download"),
                )
                return json.dumps({"presented": True, "artifact": art}, ensure_ascii=False)

            if name == "search_files":
                res = search_workspace(root, str(args.get("query", "")))
                return json.dumps(res, ensure_ascii=False)

            if name == "git_status_diff":
                rel = args.get("path")
                res = await git_status_and_diff(root, str(rel) if rel else None)
                return json.dumps(res, ensure_ascii=False)

            if name == "run_command":
                cmd = str(args["command"])
                timeout = min(300, max(5, int(args.get("timeout") or 60)))

                def _run() -> dict[str, Any]:
                    env = os.environ.copy()
                    venv_scripts = PROJECT_ROOT / ".venv" / "Scripts"
                    if venv_scripts.exists():
                        env["PATH"] = f"{venv_scripts};{env.get('PATH', '')}"
                        env["VIRTUAL_ENV"] = str(PROJECT_ROOT / ".venv")
                    env["PYTHONIOENCODING"] = "utf-8"
                    try:
                        proc = subprocess.run(
                            ["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd],
                            cwd=str(root),
                            env=env,
                            stdin=subprocess.DEVNULL,
                            capture_output=True,
                            text=True,
                            encoding="utf-8",
                            errors="replace",
                            timeout=timeout,
                        )
                        return {
                            "exit_code": proc.returncode,
                            "stdout": proc.stdout[-12000:],
                            "stderr": proc.stderr[-6000:],
                        }
                    except subprocess.TimeoutExpired as tex:
                        out = (tex.stdout or "") if isinstance(tex.stdout, str) else ""
                        err = (tex.stderr or "") if isinstance(tex.stderr, str) else ""
                        return {
                            "error": f"Command timed out after {timeout}s",
                            "exit_code": -1,
                            "stdout": out[-6000:],
                            "stderr": err[-4000:],
                        }

                res = await asyncio.to_thread(_run)
                return json.dumps(res, ensure_ascii=False)

            if name == "ask_user":
                question = str(args.get("question", ""))
                options = [str(o) for o in (args.get("options") or [])]
                ans = await self._request_interaction(question, options)
                return json.dumps(ans, ensure_ascii=False)

            return json.dumps({"error": f"Unknown tool: {name}"}, ensure_ascii=False)
        except WorkspaceSecurityError as exc:
            return json.dumps({"error": f"Security error: {exc}"}, ensure_ascii=False)
        except Exception as exc:
            return json.dumps({"error": _format_exception(exc)}, ensure_ascii=False)

    def _build_api_messages(self) -> list[dict[str, Any]]:
        self.messages = sanitize_conversation_messages(self.messages)
        cfg = self.config_store.config
        api_msgs: list[dict[str, Any]] = [
            {
                "role": "system",
                "content": SYSTEM_PROMPT.format(
                    workspace=self.workspace,
                    ai_access_mode=cfg.ai_access_mode,
                    allowed_workspaces=", ".join(cfg.workspaces),
                ),
            }
        ]
        last_user_idx = -1
        for i, msg in enumerate(self.messages):
            if msg.get("role") == "user":
                last_user_idx = i

        for i, msg in enumerate(self.messages):
            copied = dict(msg)
            if i < last_user_idx and "reasoning_content" in copied:
                copied.pop("reasoning_content", None)
            api_msgs.append(copied)
        return api_msgs

    async def _stream_completion(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        base_url: str,
        model: str,
    ) -> dict[str, Any]:
        url = f"{base_url}/chat/completions"
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
        body: dict[str, Any] = {
            "model": model,
            "messages": self._build_api_messages(),
            "tools": TOOL_SCHEMAS,
            "stream": True,
        }

        last_exc: BaseException | None = None
        for attempt in range(1, 4):
            content_parts: list[str] = []
            reasoning_parts: list[str] = []
            tool_calls_acc: dict[int, dict[str, Any]] = {}
            emitted_any = False

            try:
                async with client.stream("POST", url, headers=headers, json=body) as resp:
                    if resp.status_code in RETRYABLE_STATUS_CODES and attempt < 3:
                        await resp.aread()
                        await asyncio.sleep(0.8 * attempt)
                        continue

                    if resp.status_code >= 400:
                        err_raw = await resp.aread()
                        err_text = err_raw.decode("utf-8", errors="replace").strip()
                        try:
                            err_json = json.loads(err_text)
                            msg = (
                                err_json.get("error", {}).get("message")
                                if isinstance(err_json.get("error"), dict)
                                else err_text
                            ) or err_text
                        except json.JSONDecodeError:
                            msg = err_text
                        raise RuntimeError(f"DeepSeek API ({resp.status_code}): {msg or '请求被拒绝'}")

                    async for raw_line in resp.aiter_lines():
                        line = raw_line.strip()
                        if not line or not line.startswith("data:"):
                            continue
                        payload_str = line[5:].strip()
                        if payload_str == "[DONE]":
                            break
                        try:
                            chunk = json.loads(payload_str)
                        except json.JSONDecodeError:
                            continue

                        choices = chunk.get("choices") or []
                        if not choices:
                            continue
                        delta = choices[0].get("delta") or {}

                        if r_delta := delta.get("reasoning_content"):
                            emitted_any = True
                            reasoning_parts.append(r_delta)
                            self.emit_event("thought_delta", {"text": r_delta}, persist=False)

                        if c_delta := delta.get("content"):
                            emitted_any = True
                            content_parts.append(c_delta)
                            self.emit_event("text_delta", {"text": c_delta}, persist=False)

                        for tc in delta.get("tool_calls") or []:
                            emitted_any = True
                            idx = int(tc.get("index", 0))
                            acc = tool_calls_acc.setdefault(
                                idx,
                                {
                                    "id": tc.get("id") or f"call_{uuid.uuid4().hex[:8]}",
                                    "type": "function",
                                    "function": {"name": "", "arguments": ""},
                                },
                            )
                            if tc.get("id"):
                                acc["id"] = tc["id"]
                            fn = tc.get("function") or {}
                            if fn.get("name"):
                                acc["function"]["name"] += fn["name"]
                            if fn.get("arguments"):
                                acc["function"]["arguments"] += fn["arguments"]

                assistant_msg: dict[str, Any] = {
                    "role": "assistant",
                    "content": "".join(content_parts) if content_parts else None,
                }
                if reasoning_parts:
                    assistant_msg["reasoning_content"] = "".join(reasoning_parts)
                if tool_calls_acc:
                    assistant_msg["tool_calls"] = [
                        tool_calls_acc[k] for k in sorted(tool_calls_acc.keys())
                    ]
                return assistant_msg

            except (httpx.TransportError, httpx.TimeoutException, ssl.SSLError, OSError) as exc:
                last_exc = exc
                # Retry if stream broke before any tokens or if partial stream had no tool calls yet
                if attempt < 3 and not tool_calls_acc and not emitted_any:
                    await asyncio.sleep(0.8 * attempt)
                    continue
                # If partial text/thoughts already streamed, still retry only if we haven't mutated tools
                if attempt < 2 and not tool_calls_acc:
                    await asyncio.sleep(1.0)
                    continue
                raise RuntimeError(_format_exception(exc)) from exc

        raise RuntimeError(_format_exception(last_exc or RuntimeError("DeepSeek 请求失败")))

    async def send_prompt(self, prompt: str, *, model: str | None = None) -> dict[str, Any]:
        clean = prompt.strip()
        if not clean:
            raise ValueError("Prompt cannot be empty")
        if self._active_task and not self._active_task.done():
            raise RuntimeError("当前会话正在执行任务，请先点击「停止」或处理待审批项。")

        if model and model.strip():
            self.model = model.strip()

        if self.title in ("New Session", "DeepSeek Session") and len(self.events) == 0:
            self.title = clean[:40] + ("..." if len(clean) > 40 else "")

        user_event = self.emit_event("user_message", {"text": clean})
        self.status = "running"
        self.emit_event("status", {"status": "running"}, persist=False, include_session=True)
        self._active_task = asyncio.create_task(self._run_turn(clean))
        return user_event

    async def _run_turn(self, prompt: str) -> None:
        try:
            async with self._lock:
                cfg = self.config_store.config
                api_key = cfg.effective_api_key()
                if not api_key:
                    raise RuntimeError(
                        "请先在「Diff/设置」Tab 填入你的 DeepSeek API Key（或配置环境变量 DEEPSEEK_API_KEY）。"
                    )
                base_url = cfg.effective_base_url()
                model = self.model or cfg.model or "deepseek-flash"

                self.messages = sanitize_conversation_messages(self.messages)
                self.messages.append({"role": "user", "content": prompt})

                async with self._http_client_factory() as client:
                    for _ in range(MAX_TOOL_ROUNDS):
                        assistant_msg = await self._stream_completion(
                            client, api_key, base_url, model
                        )
                        self.messages.append(assistant_msg)

                        tool_calls = assistant_msg.get("tool_calls") or []
                        if not tool_calls:
                            break

                        # Pre-parse and pre-register all approvals in this batch so the mobile UI
                        # receives all pending approvals at once (avoiding sequential button flash/lag).
                        batch_items: list[tuple[dict[str, Any], dict[str, Any], PendingRequest | None]] = []
                        for tc in tool_calls:
                            fn_name = tc["function"]["name"]
                            raw_args = tc["function"]["arguments"]
                            try:
                                parsed_args = json.loads(raw_args) if raw_args.strip() else {}
                                if not isinstance(parsed_args, dict):
                                    parsed_args = {"raw": raw_args}
                            except json.JSONDecodeError:
                                parsed_args = {"raw": raw_args}

                            self.emit_event(
                                "tool_call",
                                {"id": tc["id"], "name": fn_name, "args": parsed_args},
                                persist=False,
                            )
                            pre_req: PendingRequest | None = None
                            if self._needs_approval(fn_name):
                                pre_req = self._register_approval(fn_name, parsed_args)
                            batch_items.append((tc, parsed_args, pre_req))

                        if self.pending_approvals:
                            self.status = "waiting_input"
                            first_req = next(iter(self.pending_approvals.values()))
                            self.emit_event(
                                "approval_request",
                                {
                                    "request_id": first_req.request_id,
                                    "batch_count": len(self.pending_approvals),
                                    **first_req.payload,
                                },
                                include_session=True,
                            )
                            asyncio.create_task(
                                self._send_bark(
                                    f"DeepSeek 待审批 ({len(self.pending_approvals)} 项)",
                                    json.dumps(first_req.payload.get("args", {}), ensure_ascii=False),
                                )
                            )

                        for tc, _parsed_args, pre_req in batch_items:
                            tc_id = tc["id"]
                            fn_name = tc["function"]["name"]
                            raw_args = tc["function"]["arguments"]

                            result_str = await self._execute_tool(fn_name, raw_args, pre_req=pre_req)
                            display_res = (
                                result_str[:8000] + "\n...[truncated]"
                                if len(result_str) > 8000
                                else result_str
                            )
                            err_val = None
                            try:
                                parsed_res = json.loads(result_str)
                                if isinstance(parsed_res, dict) and parsed_res.get("error"):
                                    err_val = str(parsed_res["error"])
                            except json.JSONDecodeError:
                                pass

                            self.emit_event(
                                "tool_result",
                                {
                                    "id": tc_id,
                                    "name": fn_name,
                                    "result": display_res,
                                    "error": err_val,
                                },
                                persist=False,
                            )
                            self.messages.append(
                                {
                                    "role": "tool",
                                    "tool_call_id": tc_id,
                                    "content": result_str,
                                }
                            )

                self.status = "idle"
                self.emit_event("turn_done", {"stop_reason": "done"}, include_session=True)
                asyncio.create_task(self._send_bark("DeepSeek 任务完成", self.title))
        except asyncio.CancelledError:
            self.status = "idle"
            self.messages = sanitize_conversation_messages(self.messages)
            self.emit_event("turn_done", {"stop_reason": "cancelled"}, include_session=True)
        except Exception as exc:
            self.status = "error"
            self.messages = sanitize_conversation_messages(self.messages)
            err_msg = _format_exception(exc)
            self.emit_event("error", {"message": err_msg}, include_session=True)
            asyncio.create_task(self._send_bark("DeepSeek 执行出错", err_msg))
        finally:
            self.save_to_disk()

    async def cancel_turn(self) -> None:
        for req in list(self.pending_approvals.values()):
            if not req.future.done():
                req.future.set_result({"allow": False, "reason": "Turn cancelled"})
        for req in list(self.pending_interactions.values()):
            if not req.future.done():
                req.future.set_result({"cancelled": True, "responses": []})

        if self._active_task and not self._active_task.done():
            self._active_task.cancel()
            try:
                await self._active_task
            except Exception:
                pass
        self.status = "idle"

    def resolve_approval(
        self,
        request_id: str,
        *,
        allow: bool,
        reason: str = "",
        set_approval_mode: str | None = None,
    ) -> bool:
        if set_approval_mode in {"ask_commands", "ask_writes", "auto"}:
            self.approval_mode = set_approval_mode

        if request_id == "all":
            resolved_any = False
            for req in list(self.pending_approvals.values()):
                if not req.future.done():
                    req.future.set_result({"allow": allow, "reason": reason})
                    resolved_any = True
            return resolved_any

        req = self.pending_approvals.get(request_id)
        if not req or req.future.done():
            return False
        req.future.set_result({"allow": allow, "reason": reason})

        # If user switched session to auto mode, auto-approve remaining pending items in this batch
        if allow and self.approval_mode == "auto":
            for other in list(self.pending_approvals.values()):
                if not other.future.done():
                    other.future.set_result({"allow": True, "reason": "Auto-approved"})
        return True

    def resolve_interaction(
        self,
        request_id: str,
        *,
        responses: list[dict[str, Any]] | None = None,
        cancelled: bool = False,
    ) -> bool:
        req = self.pending_interactions.get(request_id)
        if not req or req.future.done():
            return False
        req.future.set_result({"responses": responses or [], "cancelled": cancelled})
        return True


class SessionManager:
    """Manages multiple DeepSeekSessions backed by disk storage."""

    def __init__(self, config_store: ConfigStore):
        self.config_store = config_store
        self.sessions_dir = config_store.data_dir / "sessions"
        self.sessions: dict[str, DeepSeekSession] = {}
        self._load_existing()

    def _load_existing(self) -> None:
        if not self.sessions_dir.exists():
            return
        for path in sorted(self.sessions_dir.glob("*.json")):
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
                sid = raw["session_id"]
                raw_events = raw.get("events", [])
                raw_msgs = raw.get("messages", [])
                sess = DeepSeekSession(
                    session_id=sid,
                    title=raw.get("title", "Session"),
                    workspace=raw.get("workspace") or self.config_store.config.workspaces[0],
                    approval_mode=raw.get(
                        "approval_mode", self.config_store.config.default_approval_mode
                    ),
                    model=raw.get("model") or self.config_store.config.model,
                    config_store=self.config_store,
                    sessions_dir=self.sessions_dir,
                    messages=raw_msgs,
                    events=raw_events,
                )
                sess.created_at = raw.get("created_at", sess.created_at)
                sess.updated_at = raw.get("updated_at", sess.updated_at)
                # Persist compacted events and sanitized messages back to disk if shrunk
                if len(sess.events) < len(raw_events) or len(sess.messages) != len(raw_msgs):
                    sess.save_to_disk()
                self.sessions[sid] = sess
            except Exception:
                continue

    def list_sessions(self) -> list[dict[str, Any]]:
        items = [s.summary() for s in self.sessions.values()]
        items.sort(key=lambda s: s["updated_at"], reverse=True)
        return items

    def create_session(
        self,
        *,
        workspace: str | None = None,
        title: str = "New Session",
        approval_mode: str | None = None,
        model: str | None = None,
    ) -> DeepSeekSession:
        ws = workspace or self.config_store.config.workspaces[0]
        sid = uuid.uuid4().hex[:12]
        sess = DeepSeekSession(
            session_id=sid,
            title=title,
            workspace=ws,
            approval_mode=approval_mode or self.config_store.config.default_approval_mode,
            model=model or self.config_store.config.model,
            config_store=self.config_store,
            sessions_dir=self.sessions_dir,
        )
        sess.save_to_disk()
        self.sessions[sid] = sess
        return sess

    def get_session(self, session_id: str) -> DeepSeekSession:
        if session_id not in self.sessions:
            raise KeyError(f"Session not found: {session_id}")
        return self.sessions[session_id]

    async def delete_session(self, session_id: str) -> None:
        sess = self.sessions.pop(session_id, None)
        if sess is None:
            raise KeyError(f"Session not found: {session_id}")
        await sess.cancel_turn()
        if sess.storage_path.exists():
            sess.storage_path.unlink()

    async def shutdown(self) -> None:
        for sess in list(self.sessions.values()):
            await sess.cancel_turn()
