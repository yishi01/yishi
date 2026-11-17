"""DeepSeek streaming agent runtime with workspace tools, mobile approvals, and event replay."""

from __future__ import annotations

import asyncio
import json
import os
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
    resolve_workspace_path,
    search_workspace,
    write_file_content,
)

WRITE_TOOLS = {"write_file", "edit_file", "run_command"}
COMMAND_TOOLS = {"run_command"}
MAX_TOOL_ROUNDS = 24

SYSTEM_PROMPT = """You are a skilled AI coding assistant running inside the user's Windows workspace via DeepSeek Mobile Bridge.
You have tools to inspect directories, read files, search code, write/edit files, inspect git status/diff, run shell commands, and ask the user questions.

Environment Facts:
- Bridge HTTP/WebSocket server: http://127.0.0.1:8765 (health checks: http://127.0.0.1:8765/health and http://127.0.0.1:8765/api/health)
- Project Python virtualenv: .venv\\Scripts\\python.exe (automatically prepended to PATH in run_command)
- Frontend in `web/` is zero-build native ES Modules (no Node.js / npm required)
- Active workspace root: {workspace}

Guidelines:
- Always inspect relevant files before editing them.
- Prefer `edit_file` for targeted changes to existing files and `write_file` for creating new files.
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
        self.messages: list[dict[str, Any]] = messages or []
        self.events: list[dict[str, Any]] = events or []
        self.next_seq = (self.events[-1]["seq"] + 1) if self.events else 1

        self.status: str = "idle"
        self.subscribers: set[asyncio.Queue[dict[str, Any]]] = set()
        self.pending_approvals: dict[str, PendingRequest] = {}
        self.pending_interactions: dict[str, PendingRequest] = {}

        self._lock = asyncio.Lock()
        self._active_task: asyncio.Task[None] | None = None
        self._http_client_factory = lambda: httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=20.0))

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
            "events": self.events[-2000:],
        }
        tmp = self.storage_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.storage_path)

    def emit_event(self, event_type: str, data: dict[str, Any], *, persist: bool = True) -> dict[str, Any]:
        event = {
            "seq": self.next_seq,
            "type": event_type,
            "ts": _utc_now(),
            "data": data,
        }
        self.next_seq += 1
        self.updated_at = event["ts"]
        self.events.append(event)
        if len(self.events) > 3000:
            self.events = self.events[-2500:]

        for queue in list(self.subscribers):
            queue.put_nowait(event)

        if persist:
            self.save_to_disk()
        return event

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

    async def _request_approval(self, tool_name: str, args: dict[str, Any]) -> tuple[bool, str]:
        if not self._needs_approval(tool_name):
            return True, ""

        loop = asyncio.get_running_loop()
        req_id = uuid.uuid4().hex[:10]
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        payload = {"tool_name": tool_name, "args": args}
        self.pending_approvals[req_id] = PendingRequest(
            request_id=req_id,
            kind="approval",
            payload=payload,
            future=fut,
        )
        self.status = "waiting_input"
        self.emit_event("approval_request", {"request_id": req_id, **payload})
        asyncio.create_task(
            self._send_bark(
                f"DeepSeek 审批: {tool_name}",
                json.dumps(args, ensure_ascii=False),
            )
        )
        try:
            decision = await fut
        finally:
            self.pending_approvals.pop(req_id, None)
            if self._active_task and not self._active_task.done():
                self.status = "running"

        allow = bool(decision.get("allow", False))
        reason = str(decision.get("reason") or ("Approved on mobile" if allow else "Denied on mobile"))
        self.emit_event(
            "approval_resolved",
            {"request_id": req_id, "allow": allow, "reason": reason},
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
        self.emit_event("interaction_request", {"request_id": req_id, **payload})
        asyncio.create_task(self._send_bark("DeepSeek 需要你的回答", question))
        try:
            answer = await fut
        finally:
            self.pending_interactions.pop(req_id, None)
            if self._active_task and not self._active_task.done():
                self.status = "running"

        cancelled = bool(answer.get("cancelled", False))
        self.emit_event(
            "interaction_resolved",
            {"request_id": req_id, "cancelled": cancelled},
        )
        return answer

    async def _execute_tool(self, name: str, raw_args: str) -> str:
        try:
            args = json.loads(raw_args) if raw_args.strip() else {}
        except json.JSONDecodeError as exc:
            return json.dumps({"error": f"Invalid JSON arguments: {exc}"}, ensure_ascii=False)

        if not isinstance(args, dict):
            return json.dumps({"error": "Tool arguments must be a JSON object"}, ensure_ascii=False)

        allow, reason = await self._request_approval(name, args)
        if not allow:
            return json.dumps({"error": f"Denied by user: {reason}"}, ensure_ascii=False)

        root = Path(self.workspace)
        try:
            if name == "list_directory":
                res = list_directory(root, str(args.get("path", "")))
                return json.dumps(res, ensure_ascii=False)

            if name == "read_file":
                data = read_file_content(root, str(args["path"]))
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
                )
                return json.dumps(res, ensure_ascii=False)

            if name == "edit_file":
                rel = str(args["path"])
                target = str(args["target"])
                replacement = str(args["replacement"])
                data = read_file_content(root, rel)
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
                res = write_file_content(root, rel, updated, force=True)
                return json.dumps({"edited": True, **res}, ensure_ascii=False)

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
                    proc = subprocess.run(
                        ["powershell", "-NoProfile", "-Command", cmd],
                        cwd=str(root),
                        env=env,
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
            return json.dumps({"error": str(exc)}, ensure_ascii=False)

    def _build_api_messages(self) -> list[dict[str, Any]]:
        api_msgs: list[dict[str, Any]] = [
            {"role": "system", "content": SYSTEM_PROMPT.format(workspace=self.workspace)}
        ]
        # Find last user message index so prior-turn reasoning_content can be omitted cleanly
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

        content_parts: list[str] = []
        reasoning_parts: list[str] = []
        tool_calls_acc: dict[int, dict[str, Any]] = {}

        async with client.stream("POST", url, headers=headers, json=body) as resp:
            if resp.status_code >= 400:
                err_raw = await resp.aread()
                err_text = err_raw.decode("utf-8", errors="replace")
                try:
                    err_json = json.loads(err_text)
                    msg = err_json.get("error", {}).get("message") or err_text
                except json.JSONDecodeError:
                    msg = err_text
                raise RuntimeError(f"DeepSeek API ({resp.status_code}): {msg}")

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
                    reasoning_parts.append(r_delta)
                    self.emit_event("thought_delta", {"text": r_delta}, persist=False)

                if c_delta := delta.get("content"):
                    content_parts.append(c_delta)
                    self.emit_event("text_delta", {"text": c_delta}, persist=False)

                for tc in delta.get("tool_calls") or []:
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

    async def send_prompt(self, prompt: str, *, model: str | None = None) -> dict[str, Any]:
        clean = prompt.strip()
        if not clean:
            raise ValueError("Prompt cannot be empty")
        if self._active_task and not self._active_task.done():
            raise RuntimeError("Session is already executing a turn; stop it first.")

        if model and model.strip():
            self.model = model.strip()

        if self.title == "New Session" and len(self.events) == 0:
            self.title = clean[:40] + ("..." if len(clean) > 40 else "")

        user_event = self.emit_event("user_message", {"text": clean})
        self.status = "running"
        self.emit_event("status", {"status": "running"}, persist=False)
        self._active_task = asyncio.create_task(self._run_turn(clean))
        return user_event

    async def _run_turn(self, prompt: str) -> None:
        try:
            async with self._lock:
                cfg = self.config_store.config
                api_key = cfg.effective_api_key()
                if not api_key:
                    raise RuntimeError(
                        "请先在「设置」Tab 填入你的 DeepSeek API Key（或设置环境变量 DEEPSEEK_API_KEY）。"
                    )
                base_url = cfg.effective_base_url()
                model = self.model or cfg.model or "deepseek-chat"

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

                        for tc in tool_calls:
                            tc_id = tc["id"]
                            fn_name = tc["function"]["name"]
                            raw_args = tc["function"]["arguments"]
                            try:
                                parsed_args = json.loads(raw_args) if raw_args.strip() else {}
                            except json.JSONDecodeError:
                                parsed_args = {"raw": raw_args}

                            self.emit_event(
                                "tool_call",
                                {"id": tc_id, "name": fn_name, "args": parsed_args},
                            )
                            result_str = await self._execute_tool(fn_name, raw_args)
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
                            )
                            self.messages.append(
                                {
                                    "role": "tool",
                                    "tool_call_id": tc_id,
                                    "content": result_str,
                                }
                            )

                self.status = "idle"
                self.emit_event("turn_done", {"stop_reason": "done"})
                asyncio.create_task(self._send_bark("DeepSeek 任务完成", self.title))
        except asyncio.CancelledError:
            self.status = "idle"
            self.emit_event("turn_done", {"stop_reason": "cancelled"})
        except Exception as exc:
            self.status = "error"
            self.emit_event("error", {"message": str(exc)})
            asyncio.create_task(self._send_bark("DeepSeek 执行出错", str(exc)))
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

    def resolve_approval(self, request_id: str, *, allow: bool, reason: str = "") -> bool:
        req = self.pending_approvals.get(request_id)
        if not req or req.future.done():
            return False
        req.future.set_result({"allow": allow, "reason": reason})
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
                    messages=raw.get("messages", []),
                    events=raw.get("events", []),
                )
                sess.created_at = raw.get("created_at", sess.created_at)
                sess.updated_at = raw.get("updated_at", sess.updated_at)
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
