"""DeepSeek streaming agent runtime with resilient retries, message sanitization, multimodal vision, wallet metering, collaborative browser, and subagent orchestration."""

from __future__ import annotations

import asyncio
import json
import os
import ssl
import subprocess
import threading
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
from bridge.sandbox_runner import SandboxRunner, audit_untrusted_code
from bridge.search_service import execute_web_search

WRITE_TOOLS = {"write_file", "edit_file", "run_command", "run_plugin"}
COMMAND_TOOLS = {"run_command", "run_plugin"}
SUBAGENT_ORCHESTRATION_TOOLS = {"spawn_agents", "wait_agents", "message_agent", "cancel_agent"}
MAX_TOOL_ROUNDS = 24
RETRYABLE_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}

SYSTEM_PROMPT = """You are a skilled AI coding assistant running inside the user's Windows workspace via DeepSeek Mobile Bridge.
You have tools to inspect directories, read files, search code, write/edit files, present files to the user for download/review (Claude Artifact style), inspect git status/diff, run shell commands, capture PC screenshots, browse web pages collaboratively, read sibling workspace sessions, spawn parallel sub-agents, and ask the user questions.

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
- Whenever the user asks to take a screenshot, see the PC screen/desktop/window, or check what is on the computer screen, immediately call `take_screenshot` (target='full', 'window', or 'region'). It will automatically push an interactive Image Artifact Card with live image preview & download to their phone screen.
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
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the public web using the configured search provider (DuckDuckGo, Tavily, Brave, Serper, Bocha, or Custom).",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query keywords."},
                    "max_results": {"type": "integer", "description": "Max search results (1-10)."},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_plugins",
            "description": "List installed PC DSH plugins, enabled skills, and executable plugin tools.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_plugin",
            "description": "Execute a tool provided by an enabled PC DSH plugin on the host PC.",
            "parameters": {
                "type": "object",
                "properties": {
                    "plugin_id": {"type": "string", "description": "Plugin ID from list_plugins."},
                    "tool_name": {"type": "string", "description": "Tool name inside the plugin (optional if default)."},
                    "args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "CLI arguments to pass to the PC plugin script.",
                    },
                    "stdin_text": {"type": "string", "description": "Optional stdin string."},
                },
                "required": ["plugin_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sandbox_audit_run",
            "description": "Perform static security self-check and optionally run untrusted code in an isolated PC sandbox without host secrets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "code": {"type": "string", "description": "Source code to inspect or simulate."},
                    "language": {
                        "type": "string",
                        "enum": ["python", "javascript", "powershell", "bash", "html"],
                        "description": "Script language.",
                    },
                    "execute": {
                        "type": "boolean",
                        "description": "True to execute inside isolated PC sandbox after audit; false for static security audit only.",
                    },
                    "allow_network": {
                        "type": "boolean",
                        "description": "Allow outbound network in simulator (default false).",
                    },
                },
                "required": ["code", "language"],
            },
        },
    },
    # Module A: Cross-Session Reading Tools
    {
        "type": "function",
        "function": {
            "name": "list_workspace_sessions",
            "description": "List other conversation sessions in the SAME Workspace Profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Optional keyword filter for session title or messages."},
                    "limit": {"type": "integer", "description": "Max sessions to return (default 20)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_session_transcript",
            "description": "Read user and assistant dialogue turns from another session in the SAME Workspace Profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Target session_id to read."},
                    "turn_range": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "Optional [start_idx, end_idx] turn range.",
                    },
                    "search": {"type": "string", "description": "Optional keyword filter within turns."},
                    "max_chars": {"type": "integer", "description": "Max characters to return (default 12000)."},
                },
                "required": ["session_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_session_artifacts",
            "description": "List file artifacts and touched file paths from another session in the SAME Workspace Profile.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {"type": "string", "description": "Target session_id to inspect."},
                },
                "required": ["session_id"],
            },
        },
    },
    # Module B: Native PC Screenshot Tool
    {
        "type": "function",
        "function": {
            "name": "take_screenshot",
            "description": "Capture a screenshot of the host PC screen, a specific window, or a screen region.",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "enum": ["full", "window", "region"],
                        "description": "Capture target mode: 'full', 'window', or 'region'.",
                    },
                    "window_title": {
                        "type": "string",
                        "description": "Window title substring when target='window'.",
                    },
                    "region": {
                        "type": "array",
                        "items": {"type": "integer"},
                        "description": "[x, y, width, height] when target='region'.",
                    },
                },
                "required": [],
            },
        },
    },
    # Module F: Collaborative Browser Tools
    {
        "type": "function",
        "function": {
            "name": "browser_open",
            "description": "Open a URL in the collaborative session browser and render an interactive viewport card in chat.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "Target HTTP/HTTPS URL to open."},
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_snapshot",
            "description": "Get the current browser page title, URL, numbered interactive elements, and viewport snapshot.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_click",
            "description": "Click an interactive element by its numbered badge [element_id] or viewport coordinates (x, y).",
            "parameters": {
                "type": "object",
                "properties": {
                    "element_id": {"type": "integer", "description": "Numbered element ID from browser snapshot."},
                    "x": {"type": "integer", "description": "Viewport X coordinate (optional)."},
                    "y": {"type": "integer", "description": "Viewport Y coordinate (optional)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_type",
            "description": "Type text into an input/textarea element in the collaborative browser.",
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to type."},
                    "element_id": {"type": "integer", "description": "Target input element ID (optional)."},
                    "submit": {"type": "boolean", "description": "True to submit the form after typing."},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_scroll",
            "description": "Scroll the collaborative browser viewport vertically.",
            "parameters": {
                "type": "object",
                "properties": {
                    "delta_y": {"type": "integer", "description": "Vertical scroll delta in pixels (positive=down, negative=up)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_back",
            "description": "Navigate back to the previous page in the collaborative browser history.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_extract",
            "description": "Extract clean Markdown text and interactive elements list from the current browser page.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "browser_screenshot",
            "description": "Save the current browser viewport frame as an image attachment.",
            "parameters": {
                "type": "object",
                "properties": {},
            },
        },
    },
    # Module D: Sub-Agent Team Orchestration Tools
    {
        "type": "function",
        "function": {
            "name": "spawn_agents",
            "description": "Spawn up to 4 parallel sub-agents to execute subtasks concurrently.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agents": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "role": {"type": "string", "description": "Sub-agent role title."},
                                "task": {"type": "string", "description": "Detailed task instructions for the sub-agent."},
                                "profile_id": {"type": "string", "description": "Optional model profile ID."},
                                "max_rounds": {"type": "integer", "description": "Max tool rounds (default 8)."},
                                "allow_writes": {"type": "boolean", "description": "Allow write/command tools (default false)."},
                            },
                            "required": ["role", "task"],
                        },
                        "description": "List of sub-agent specifications to spawn (max 4).",
                    }
                },
                "required": ["agents"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "wait_agents",
            "description": "Wait for spawned sub-agents to complete and collect their findings.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Agent IDs to wait for (empty for all active sub-agents).",
                    },
                    "timeout_sec": {"type": "integer", "description": "Timeout in seconds (default 90)."},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "message_agent",
            "description": "Send a follow-up instruction to an existing sub-agent.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string", "description": "Target sub-agent ID."},
                    "text": {"type": "string", "description": "Follow-up instruction text."},
                },
                "required": ["agent_id", "text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "cancel_agent",
            "description": "Cancel a running sub-agent.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string", "description": "Target sub-agent ID to cancel."},
                },
                "required": ["agent_id"],
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
                    synth: dict[str, Any] = {
                        "role": "tool",
                        "tool_call_id": tc_id,
                        "content": json.dumps(
                            {"error": "Tool execution was interrupted in a previous turn."},
                            ensure_ascii=False,
                        ),
                    }
                    if msg.get("_turn_id"):
                        synth["_turn_id"] = msg["_turn_id"]
                    cleaned.append(synth)
            i = j
            continue

        # Skip orphan `tool` messages not preceded by an `assistant` with `tool_calls`
        i += 1

    return cleaned


def _backfill_turn_ids_on_events(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Ensure every historical event in `events` has a stable `turn_id` inside `data`."""
    cur_tid = ""
    out: list[dict[str, Any]] = []
    for ev in events:
        if not isinstance(ev, dict):
            continue
        ev_copy = dict(ev)
        data = dict(ev_copy.get("data") or {})
        etype = ev_copy.get("type")
        if etype == "user_message":
            existing = str(data.get("turn_id") or "").strip()
            if existing:
                cur_tid = existing
            else:
                cur_tid = f"turn_{ev_copy.get('seq', 1)}"
                data["turn_id"] = cur_tid
        elif cur_tid and not data.get("turn_id"):
            data["turn_id"] = cur_tid
        ev_copy["data"] = data
        out.append(ev_copy)
    return out


def compact_event_stream(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Coalesce contiguous thought_delta / text_delta events (within the same turn_id) and drop transient status events."""
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
            cur_tid = str(data.get("turn_id") or "")
            prev_tid = str(compacted[-1]["data"].get("turn_id") or "") if compacted else ""
            if compacted and compacted[-1].get("type") == etype and prev_tid == cur_tid:
                prev_data = compacted[-1]["data"]
                # If `full_text` was already stored, use it if longer; otherwise append `text`
                if "full_text" in data:
                    merged = piece
                else:
                    merged = str(prev_data.get("full_text") or prev_data.get("text") or "") + piece
                merged_data: dict[str, Any] = {"text": merged, "full_text": merged}
                if cur_tid:
                    merged_data["turn_id"] = cur_tid
                compacted[-1] = {
                    "seq": ev["seq"],
                    "type": etype,
                    "ts": ev.get("ts") or _utc_now(),
                    "data": merged_data,
                }
            else:
                new_data: dict[str, Any] = {"text": piece, "full_text": piece}
                if cur_tid:
                    new_data["turn_id"] = cur_tid
                compacted.append(
                    {
                        "seq": ev["seq"],
                        "type": etype,
                        "ts": ev.get("ts") or _utc_now(),
                        "data": new_data,
                    }
                )
        else:
            compacted.append({**ev, "data": data})
    return compacted


def _backfill_turn_ids_on_messages(
    messages: list[dict[str, Any]],
    events: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Backfill `_turn_id` on historical messages by aligning user messages with `user_message` events."""
    user_turn_ids: list[str] = []
    for ev in events:
        if ev.get("type") == "user_message":
            tid = str((ev.get("data") or {}).get("turn_id") or "").strip()
            if tid:
                user_turn_ids.append(tid)

    user_idx = 0
    cur_tid = ""
    out: list[dict[str, Any]] = []
    for m in messages:
        mc = dict(m)
        if mc.get("role") == "user":
            if mc.get("_turn_id"):
                cur_tid = str(mc["_turn_id"])
            elif user_idx < len(user_turn_ids):
                cur_tid = user_turn_ids[user_idx]
                mc["_turn_id"] = cur_tid
            else:
                cur_tid = f"turn_m{user_idx + 1}"
                mc["_turn_id"] = cur_tid
            user_idx += 1
        elif cur_tid and not mc.get("_turn_id"):
            mc["_turn_id"] = cur_tid
        out.append(mc)
    return out


def _strip_browser_frame_for_llm(snap: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of a browser snapshot without large base64 JPEG strings to keep LLM context compact."""
    out = dict(snap)
    out.pop("frame_b64", None)
    out.pop("last_frame_b64", None)
    return out


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
        profile_id: str | None = None,
        messages: list[dict[str, Any]] | None = None,
        events: list[dict[str, Any]] | None = None,
        message_queue: list[dict[str, Any]] | None = None,
        plugin_service: Any | None = None,
        sandbox_runner: SandboxRunner | None = None,
        workspace_service: Any | None = None,
        attachment_service: Any | None = None,
        wallet_service: Any | None = None,
        browser_service: Any | None = None,
        workspace_profile_id: str = "",
        parent_session_id: str | None = None,
        agent_id: str | None = None,
        agent_role: str = "",
        max_tool_rounds: int = MAX_TOOL_ROUNDS,
        allowed_tools: list[str] | None = None,
    ):
        self.session_id = session_id
        self.title = title
        self.workspace = str(Path(workspace).resolve())
        self.approval_mode = approval_mode
        self.model = model or config_store.config.model or "deepseek-chat"
        self.profile_id = profile_id or config_store.config.active_profile_id or ""
        self.config_store = config_store
        self.sessions_dir = sessions_dir
        self.plugin_service = plugin_service
        self.sandbox_runner = sandbox_runner
        self.workspace_service = workspace_service
        self.attachment_service = attachment_service
        self.wallet_service = wallet_service
        self.browser_service = browser_service

        clean_wp_id = (workspace_profile_id or "").strip()
        if not clean_wp_id:
            if workspace_service is not None and hasattr(workspace_service, "resolve_profile_for_workspace_path"):
                clean_wp_id = workspace_service.resolve_profile_for_workspace_path(self.workspace)
            else:
                clean_wp_id = "ws_default"
        self.workspace_profile_id: str = clean_wp_id
        self.parent_session_id: str | None = parent_session_id
        self.agent_id: str | None = agent_id
        self.agent_role: str = agent_role
        self.max_tool_rounds: int = max(1, int(max_tool_rounds or MAX_TOOL_ROUNDS))
        self.allowed_tools: list[str] | None = list(allowed_tools) if allowed_tools is not None else None

        self.created_at = _utc_now()
        self.updated_at = self.created_at
        self._current_turn_id: str = ""

        backfilled_events = _backfill_turn_ids_on_events(events or [])
        self.events: list[dict[str, Any]] = compact_event_stream(backfilled_events)
        sanitized_msgs = sanitize_conversation_messages(messages or [])
        self.messages: list[dict[str, Any]] = _backfill_turn_ids_on_messages(sanitized_msgs, self.events)
        self.next_seq = (self.events[-1]["seq"] + 1) if self.events else 1
        self.message_queue: list[dict[str, Any]] = list(message_queue or [])

        self.status: str = "idle"
        self.subscribers: set[asyncio.Queue[dict[str, Any]]] = set()
        self.pending_approvals: dict[str, PendingRequest] = {}
        self.pending_interactions: dict[str, PendingRequest] = {}
        self.subagents: dict[str, DeepSeekSession] = {}
        self.last_usage: dict[str, Any] = {}

        self._lock = asyncio.Lock()
        self._active_task: asyncio.Task[None] | None = None
        self._cancel_requested: bool = False
        self._http_client_factory = lambda: httpx.AsyncClient(
            http2=False,
            timeout=httpx.Timeout(120.0, connect=15.0, read=90.0),
        )

    @property
    def storage_path(self) -> Path:
        return self.sessions_dir / f"{self.session_id}.json"

    def list_subagents(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for ag_id, sub in self.subagents.items():
            last_text = ""
            for m in reversed(sub.messages):
                if m.get("role") == "assistant" and m.get("content"):
                    last_text = str(m["content"])
                    break
            items.append(
                {
                    "agent_id": ag_id,
                    "session_id": sub.session_id,
                    "parent_session_id": self.session_id,
                    "role": sub.agent_role or ag_id,
                    "title": sub.title,
                    "status": sub.status,
                    "model": sub.model,
                    "profile_id": sub.profile_id,
                    "updated_at": sub.updated_at,
                    "summary_text": last_text[:500],
                    "usage": sub.last_usage,
                }
            )
        return items

    def summary(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "title": self.title,
            "workspace": self.workspace,
            "workspace_profile_id": self.workspace_profile_id,
            "parent_session_id": self.parent_session_id,
            "agent_id": self.agent_id,
            "agent_role": self.agent_role,
            "approval_mode": self.approval_mode,
            "model": self.model,
            "profile_id": self.profile_id,
            "status": self.status,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "last_seq": self.next_seq - 1,
            "queued_count": len(self.message_queue),
            "queued_messages": list(self.message_queue),
            "team": self.list_subagents(),
            "active_browsers": (
                self.browser_service.list_sessions(session_id=self.session_id)
                if self.browser_service is not None
                else []
            ),
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
            "workspace_profile_id": self.workspace_profile_id,
            "parent_session_id": self.parent_session_id,
            "agent_id": self.agent_id,
            "agent_role": self.agent_role,
            "approval_mode": self.approval_mode,
            "model": self.model,
            "profile_id": self.profile_id,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "messages": self.messages[-120:],
            "events": self.events[-600:],
            "message_queue": self.message_queue[-50:],
        }
        tmp = self.storage_path.with_suffix(f".json.tmp-{os.getpid()}-{threading.get_ident()}")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, self.storage_path)

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
        eff_tid = str(data.get("turn_id") or self._current_turn_id or "")

        # Coalesce contiguous thought_delta and text_delta (within the same turn_id) in stored history
        if event_type in ("thought_delta", "text_delta"):
            delta_text = str(data.get("text") or "")
            prev_tid = str(self.events[-1]["data"].get("turn_id") or "") if self.events else ""
            if self.events and self.events[-1]["type"] == event_type and prev_tid == eff_tid:
                prev_full = str(self.events[-1]["data"].get("full_text") or self.events[-1]["data"].get("text") or "")
                full_text = prev_full + delta_text
                stored_data: dict[str, Any] = {"text": full_text, "full_text": full_text}
                if eff_tid:
                    stored_data["turn_id"] = eff_tid
                stored_event = {
                    "seq": seq,
                    "type": event_type,
                    "ts": now,
                    "data": stored_data,
                }
                self.events[-1] = stored_event
            else:
                full_text = delta_text
                stored_data = {"text": full_text, "full_text": full_text}
                if eff_tid:
                    stored_data["turn_id"] = eff_tid
                stored_event = {
                    "seq": seq,
                    "type": event_type,
                    "ts": now,
                    "data": stored_data,
                }
                self.events.append(stored_event)

            wire_delta_data: dict[str, Any] = {"text": delta_text, "full_text": full_text}
            if eff_tid:
                wire_delta_data["turn_id"] = eff_tid
            wire_event: dict[str, Any] = {
                "seq": seq,
                "type": event_type,
                "ts": now,
                "data": wire_delta_data,
            }
        else:
            wire_data = dict(data)
            if eff_tid and "turn_id" not in wire_data:
                wire_data["turn_id"] = eff_tid
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
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(wire_event)
            except asyncio.QueueFull:
                pass

        if persist:
            self.save_to_disk()
        return wire_event

    def get_events_after(self, after_seq: int = 0) -> list[dict[str, Any]]:
        if after_seq <= 0:
            return list(self.events)
        return [ev for ev in self.events if ev["seq"] > after_seq]

    def subscribe(self) -> asyncio.Queue[dict[str, Any]]:
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=2048)
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
        payload: dict[str, Any] = {"tool_name": tool_name, "args": args}
        if tool_name == "run_command" and args.get("command"):
            audit = audit_untrusted_code(str(args["command"]), language="powershell")
            payload["risk_level"] = audit["risk_level"]
            payload["review_summary"] = audit["summary"]
            payload["review_score"] = audit["score"]
        elif tool_name == "write_file" and args.get("content"):
            audit = audit_untrusted_code(
                str(args["content"]),
                language="",
                filename=str(args.get("path") or "file.py"),
            )
            payload["risk_level"] = audit["risk_level"]
            payload["review_summary"] = audit["summary"]
            payload["review_score"] = audit["score"]
        elif tool_name == "run_plugin":
            payload["risk_level"] = "medium"
            payload["review_summary"] = f"将在 PC 端执行插件 `{args.get('plugin_id', '')}`"
            payload["review_score"] = 25
        elif tool_name == "take_screenshot":
            payload["risk_level"] = "medium"
            payload["review_summary"] = f"将截取 PC 屏幕 ({args.get('target', 'full')})"
            payload["review_score"] = 20
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
        allowed_ws = list(cfg.workspaces)
        if self.workspace_service is not None:
            try:
                wp = self.workspace_service.get_or_default_profile(self.workspace_profile_id)
                for rp in wp.get("root_paths") or []:
                    if rp not in allowed_ws:
                        allowed_ws.append(rp)
            except Exception:
                pass
        ai_mode = cfg.ai_access_mode

        def _build_and_emit_artifact(
            target_path: Path,
            *,
            title: str = "",
            summary: str = "",
            mode: str = "review",
            att_meta: dict[str, Any] | None = None,
        ) -> dict[str, Any]:
            st = target_path.stat()
            ext_lower = target_path.suffix.lower()
            is_img = ext_lower in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
            preview_text = ""
            is_text = False
            if is_img and att_meta is None and self.attachment_service and st.st_size <= 15_000_000:
                try:
                    att_meta = self.attachment_service.save_image_bytes(
                        target_path.read_bytes(),
                        filename=target_path.name,
                        session_id=self.session_id,
                        source="artifact",
                    )
                except Exception:
                    att_meta = None
            elif not is_img and st.st_size <= 1_000_000:
                try:
                    raw_b = target_path.read_bytes()
                    if b"\x00" not in raw_b[:4096]:
                        decoded = raw_b.decode("utf-8", errors="replace")
                        is_text = True
                        preview_text = "\n".join(decoded.splitlines()[:120])[:6000]
                except OSError:
                    pass
            try:
                rel_p = to_rel_posix(root, target_path)
            except Exception:
                rel_p = target_path.name
            artifact_info = {
                "id": (att_meta or {}).get("att_id") or uuid.uuid4().hex[:10],
                "name": target_path.name,
                "path": str(target_path.resolve()),
                "rel_path": rel_p,
                "title": title or target_path.name,
                "summary": summary or (
                    "点击卡片图片可全屏缩放预览或保存下载到手机"
                    if is_img
                    else ("已为你准备好文件，可直接预览审查或下载到手机" if mode == "review" else "点击下方按钮可将该文件下载到手机本地")
                ),
                "size": st.st_size,
                "mtime": st.st_mtime,
                "ext": ext_lower,
                "mode": mode,
                "is_text": is_text,
                "preview": preview_text,
                "is_image": bool(is_img or att_meta is not None),
                "att_id": str((att_meta or {}).get("att_id") or ""),
                "image_url": str((att_meta or {}).get("url") or ""),
                "thumb_url": str((att_meta or {}).get("thumb_url") or ""),
                "width": int((att_meta or {}).get("width") or 0),
                "height": int((att_meta or {}).get("height") or 0),
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

            if name == "web_search":
                query = str(args.get("query") or "").strip()
                max_res = int(args.get("max_results") or 6)
                res = await execute_web_search(query, cfg.search_config, max_results=max_res)
                return json.dumps(res, ensure_ascii=False)

            if name == "list_plugins":
                if not self.plugin_service:
                    return json.dumps({"plugins": [], "dsh_profile": {"exists": False}}, ensure_ascii=False)
                return json.dumps(self.plugin_service.list_all(), ensure_ascii=False)

            if name == "run_plugin":
                if not self.plugin_service:
                    return json.dumps({"error": "Plugin service is unavailable"}, ensure_ascii=False)
                res = await asyncio.to_thread(
                    self.plugin_service.run_plugin_tool,
                    str(args["plugin_id"]),
                    tool_name=str(args.get("tool_name") or ""),
                    args=[str(a) for a in (args.get("args") or [])],
                    stdin_text=str(args.get("stdin_text") or ""),
                    workspace_cwd=str(root),
                )
                return json.dumps(res, ensure_ascii=False)

            if name == "sandbox_audit_run":
                code = str(args.get("code") or "")
                lang = str(args.get("language") or "python")
                do_exec = bool(args.get("execute", False))
                allow_net = bool(args.get("allow_network", False))
                if not do_exec or not self.sandbox_runner:
                    return json.dumps(audit_untrusted_code(code, language=lang), ensure_ascii=False)
                res = await asyncio.to_thread(
                    self.sandbox_runner.run_sandbox_script,
                    code,
                    lang,
                    allow_network=allow_net,
                )
                return json.dumps(res, ensure_ascii=False)

            # --- Module A: Cross-Session Reading Tools ---
            if name == "list_workspace_sessions":
                if not self.workspace_service:
                    return json.dumps({"error": "Workspace service is unavailable"}, ensure_ascii=False)
                sessions_list = self.workspace_service.list_workspace_sessions(
                    self,
                    query=str(args.get("query") or ""),
                    limit=int(args.get("limit") or 20),
                )
                return json.dumps({"sessions": sessions_list}, ensure_ascii=False)

            if name == "read_session_transcript":
                if not self.workspace_service:
                    return json.dumps({"error": "Workspace service is unavailable"}, ensure_ascii=False)
                target_sid = str(args.get("session_id") or args.get("target_session_id") or "").strip()
                tr_raw = args.get("turn_range")
                tr_list = [int(x) for x in tr_raw] if isinstance(tr_raw, list) else None
                res = self.workspace_service.read_session_transcript(
                    self,
                    target_sid,
                    turn_range=tr_list,
                    search=str(args.get("search") or ""),
                    max_chars=int(args.get("max_chars") or 12000),
                )
                return json.dumps(res, ensure_ascii=False)

            if name == "list_session_artifacts":
                if not self.workspace_service:
                    return json.dumps({"error": "Workspace service is unavailable"}, ensure_ascii=False)
                target_sid = str(args.get("session_id") or args.get("target_session_id") or "").strip()
                res = self.workspace_service.list_session_artifacts(self, target_sid)
                return json.dumps(res, ensure_ascii=False)

            # --- Module B: Native PC Screenshot Tool ---
            if name == "take_screenshot":
                if not self.attachment_service:
                    return json.dumps({"error": "Attachment service is unavailable"}, ensure_ascii=False)
                target_mode = str(args.get("target") or "full")
                win_title = str(args.get("window_title") or "")
                reg = args.get("region")
                reg_list = [int(x) for x in reg] if isinstance(reg, list) else None
                meta = await asyncio.to_thread(
                    self.attachment_service.take_pc_screenshot,
                    target=target_mode,
                    window_title=win_title,
                    region=reg_list,
                    session_id=self.session_id,
                )
                try:
                    img_path, _ = self.attachment_service.get_file_path(meta["att_id"], thumb=False)
                    art = _build_and_emit_artifact(
                        img_path,
                        title=f"电脑屏幕截图 · {meta.get('width', 0)}×{meta.get('height', 0)}",
                        summary="AI 已执行截图工具，点击卡片内图片可全屏缩放预览或保存到手机相册",
                        mode="review",
                        att_meta=meta,
                    )
                except Exception:
                    art = None
                return json.dumps({"ok": True, "attachment": meta, "artifact": art}, ensure_ascii=False)

            # --- Module F: Collaborative Browser Tools ---
            if name.startswith("browser_"):
                if not self.browser_service:
                    return json.dumps({"error": "Browser service is unavailable"}, ensure_ascii=False)
                browser_id = str(args.get("browser_id") or f"br_{self.session_id}")
                self.browser_service.create_or_get_session(
                    browser_id=browser_id,
                    session_id=self.session_id,
                    workspace_profile_id=self.workspace_profile_id,
                )

                if name == "browser_open":
                    res = await self.browser_service.navigate(
                        browser_id,
                        str(args.get("url") or ""),
                        actor="agent",
                    )
                    self.emit_event("browser_state", res)
                    return json.dumps(_strip_browser_frame_for_llm(res), ensure_ascii=False)

                if name == "browser_snapshot":
                    snap = self.browser_service.snapshot(browser_id, include_frame=True)
                    self.emit_event("browser_state", snap)
                    return json.dumps(_strip_browser_frame_for_llm(snap), ensure_ascii=False)

                if name == "browser_click":
                    el_id = int(args["element_id"]) if args.get("element_id") is not None else None
                    x_val = int(args["x"]) if args.get("x") is not None else None
                    y_val = int(args["y"]) if args.get("y") is not None else None
                    res = await self.browser_service.click(
                        browser_id,
                        element_id=el_id,
                        x=x_val,
                        y=y_val,
                        actor="agent",
                    )
                    self.emit_event("browser_state", res)
                    return json.dumps(_strip_browser_frame_for_llm(res), ensure_ascii=False)

                if name == "browser_type":
                    el_id = int(args["element_id"]) if args.get("element_id") is not None else None
                    res = await self.browser_service.type_text(
                        browser_id,
                        text=str(args.get("text") or ""),
                        element_id=el_id,
                        submit=bool(args.get("submit", False)),
                        actor="agent",
                    )
                    self.emit_event("browser_state", res)
                    return json.dumps(_strip_browser_frame_for_llm(res), ensure_ascii=False)

                if name == "browser_scroll":
                    res = await self.browser_service.scroll(
                        browser_id,
                        delta_y=int(args.get("delta_y", 360)),
                        actor="agent",
                    )
                    self.emit_event("browser_state", res)
                    return json.dumps(_strip_browser_frame_for_llm(res), ensure_ascii=False)

                if name == "browser_back":
                    res = await self.browser_service.go_back(browser_id, actor="agent")
                    self.emit_event("browser_state", res)
                    return json.dumps(_strip_browser_frame_for_llm(res), ensure_ascii=False)

                if name == "browser_extract":
                    snap = self.browser_service.snapshot(browser_id, include_frame=True)
                    self.emit_event("browser_state", snap)
                    return json.dumps(
                        {
                            "ok": True,
                            "browser_id": browser_id,
                            "url": snap["url"],
                            "title": snap["title"],
                            "text_markdown": snap["text_markdown"],
                            "elements": snap["elements"],
                        },
                        ensure_ascii=False,
                    )

                if name == "browser_screenshot":
                    att_res = self.browser_service.save_frame_as_attachment(
                        browser_id,
                        self.attachment_service,
                    )
                    snap = self.browser_service.snapshot(browser_id, include_frame=True)
                    self.emit_event("browser_state", snap)
                    self.emit_event("image_attachment", att_res)
                    return json.dumps(att_res, ensure_ascii=False)

            # --- Module D: Sub-Agent Team Orchestration Tools ---
            if name == "spawn_agents":
                if self.parent_session_id is not None:
                    return json.dumps(
                        {"error": "Sub-agents cannot spawn nested sub-agents (max depth = 1)"},
                        ensure_ascii=False,
                    )
                raw_specs = args.get("agents") or []
                if not isinstance(raw_specs, list) or not raw_specs:
                    return json.dumps({"error": "agents list is required"}, ensure_ascii=False)

                spawned_ids: list[str] = []
                for spec in raw_specs[:4]:
                    if not isinstance(spec, dict):
                        continue
                    role = str(spec.get("role") or "SubAgent").strip()[:60]
                    task = str(spec.get("task") or spec.get("prompt") or "").strip()
                    if not task:
                        continue
                    prof_id = str(spec.get("profile_id") or self.profile_id or "deepseek-flash").strip()
                    max_rounds = min(16, max(1, int(spec.get("max_rounds") or 8)))
                    allow_writes = bool(spec.get("allow_writes", False))
                    ag_id = str(spec.get("agent_id") or f"ag_{uuid.uuid4().hex[:8]}").strip()

                    all_tool_names = [t["function"]["name"] for t in TOOL_SCHEMAS]
                    child_tools = [
                        tn
                        for tn in all_tool_names
                        if tn not in SUBAGENT_ORCHESTRATION_TOOLS
                        and (allow_writes or tn not in WRITE_TOOLS)
                    ]

                    child = DeepSeekSession(
                        session_id=f"{self.session_id}_{ag_id}",
                        title=f"[{role}] {task[:36]}",
                        workspace=self.workspace,
                        workspace_profile_id=self.workspace_profile_id,
                        parent_session_id=self.session_id,
                        agent_id=ag_id,
                        agent_role=role,
                        approval_mode=self.approval_mode,
                        profile_id=prof_id,
                        config_store=self.config_store,
                        sessions_dir=self.sessions_dir / "subagents",
                        plugin_service=self.plugin_service,
                        sandbox_runner=self.sandbox_runner,
                        workspace_service=self.workspace_service,
                        attachment_service=self.attachment_service,
                        wallet_service=self.wallet_service,
                        browser_service=self.browser_service,
                        max_tool_rounds=max_rounds,
                        allowed_tools=child_tools,
                    )
                    child._http_client_factory = self._http_client_factory
                    self.subagents[ag_id] = child
                    spawned_ids.append(ag_id)
                    await child.send_prompt(task, profile_id=prof_id, queue_if_busy=True)

                team_snapshot = self.list_subagents()
                self.emit_event(
                    "agent_team_update",
                    {"turn_id": self._current_turn_id, "agents": team_snapshot},
                )
                return json.dumps(
                    {"ok": True, "spawned": spawned_ids, "agents": team_snapshot},
                    ensure_ascii=False,
                )

            if name == "wait_agents":
                req_ids = [
                    str(x).strip()
                    for x in (args.get("agent_ids") or [])
                    if str(x).strip()
                ]
                target_ids = req_ids if req_ids else list(self.subagents.keys())
                timeout_sec = min(300, max(1, int(args.get("timeout_sec") or 90)))
                tasks = [
                    self.subagents[aid]._active_task
                    for aid in target_ids
                    if aid in self.subagents
                    and self.subagents[aid]._active_task is not None
                    and not self.subagents[aid]._active_task.done()
                ]
                if tasks:
                    await asyncio.wait(tasks, timeout=float(timeout_sec))
                team_snapshot = self.list_subagents()
                self.emit_event(
                    "agent_team_update",
                    {"turn_id": self._current_turn_id, "agents": team_snapshot},
                )
                filtered = [a for a in team_snapshot if a["agent_id"] in target_ids]
                return json.dumps({"ok": True, "agents": filtered}, ensure_ascii=False)

            if name == "message_agent":
                ag_id = str(args.get("agent_id") or "").strip()
                text = str(args.get("text") or "").strip()
                sub = self.subagents.get(ag_id)
                if sub is None:
                    return json.dumps({"error": f"Sub-agent not found: {ag_id}"}, ensure_ascii=False)
                await sub.send_prompt(text, queue_if_busy=True)
                team_snapshot = self.list_subagents()
                self.emit_event(
                    "agent_team_update",
                    {"turn_id": self._current_turn_id, "agents": team_snapshot},
                )
                agent_info = next((a for a in team_snapshot if a["agent_id"] == ag_id), {})
                return json.dumps({"ok": True, "agent": agent_info}, ensure_ascii=False)

            if name == "cancel_agent":
                ag_id = str(args.get("agent_id") or "").strip()
                sub = self.subagents.get(ag_id)
                if sub is None:
                    return json.dumps({"error": f"Sub-agent not found: {ag_id}"}, ensure_ascii=False)
                await sub.cancel_turn()
                team_snapshot = self.list_subagents()
                self.emit_event(
                    "agent_team_update",
                    {"turn_id": self._current_turn_id, "agents": team_snapshot},
                )
                return json.dumps(
                    {"ok": True, "agent_id": ag_id, "status": sub.status},
                    ensure_ascii=False,
                )

            return json.dumps({"error": f"Unknown tool: {name}"}, ensure_ascii=False)
        except WorkspaceSecurityError as exc:
            return json.dumps({"error": f"Security error: {exc}"}, ensure_ascii=False)
        except Exception as exc:
            return json.dumps({"error": _format_exception(exc)}, ensure_ascii=False)

    def _get_active_tool_schemas(self) -> list[dict[str, Any]]:
        schemas = TOOL_SCHEMAS
        if self.parent_session_id is not None:
            schemas = [
                t for t in schemas if t["function"]["name"] not in SUBAGENT_ORCHESTRATION_TOOLS
            ]
        if self.allowed_tools is not None:
            allowed_set = set(self.allowed_tools)
            schemas = [t for t in schemas if t["function"]["name"] in allowed_set]
        return schemas

    def _build_api_messages(self, *, provider: str = "openai_compatible") -> list[dict[str, Any]]:
        self.messages = sanitize_conversation_messages(self.messages)
        cfg = self.config_store.config
        sys_text = SYSTEM_PROMPT.format(
            workspace=self.workspace,
            ai_access_mode=cfg.ai_access_mode,
            allowed_workspaces=", ".join(cfg.workspaces),
        )
        if self.agent_role:
            sys_text += (
                f"\n\nSub-Agent Role: {self.agent_role}\n"
                "You are running as a specialized sub-agent. Focus on completing your assigned task concisely."
            )
        if self.workspace_service is not None and hasattr(self.workspace_service, "build_system_prompt_appendix"):
            try:
                ws_appendix = self.workspace_service.build_system_prompt_appendix(self)
                if ws_appendix:
                    sys_text += ws_appendix
            except Exception:
                pass
        if self.plugin_service:
            plugin_appendix = self.plugin_service.get_agent_prompt_appendix()
            if plugin_appendix:
                sys_text += plugin_appendix

        api_msgs: list[dict[str, Any]] = [{"role": "system", "content": sys_text}]
        last_user_idx = -1
        multimodal_user_indices: list[int] = []
        for i, msg in enumerate(self.messages):
            if msg.get("role") == "user":
                last_user_idx = i
                if msg.get("_attachments"):
                    multimodal_user_indices.append(i)

        recent_mm_set = set(multimodal_user_indices[-3:])

        for i, msg in enumerate(self.messages):
            copied = {k: v for k, v in msg.items() if not str(k).startswith("_")}
            if i < last_user_idx and "reasoning_content" in copied:
                copied.pop("reasoning_content", None)
            if (
                msg.get("role") == "user"
                and msg.get("_attachments")
                and self.attachment_service is not None
            ):
                att_ids = [str(a) for a in (msg.get("_attachments") or []) if str(a).strip()]
                if att_ids:
                    try:
                        copied["content"] = self.attachment_service.build_multimodal_content(
                            str(msg.get("content") or ""),
                            att_ids,
                            provider=provider,
                            include_binary=(i in recent_mm_set),
                        )
                    except Exception:
                        pass
            api_msgs.append(copied)
        return api_msgs

    async def _stream_completion(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        base_url: str,
        model: str,
        *,
        provider: str = "openai_compatible",
        temperature: float = 0.7,
        max_tokens: int = 8192,
        supports_tools: bool = True,
        extra_headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        if provider == "anthropic":
            return await self._stream_anthropic_completion(
                client,
                api_key,
                base_url,
                model,
                temperature=temperature,
                max_tokens=max_tokens,
                supports_tools=supports_tools,
                extra_headers=extra_headers,
            )

        url = f"{base_url}/chat/completions"
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            **(extra_headers or {}),
        }
        body: dict[str, Any] = {
            "model": model,
            "messages": self._build_api_messages(provider=provider),
            "stream": True,
        }
        if supports_tools:
            body["tools"] = self._get_active_tool_schemas()
        if "reasoner" not in model.lower():
            body["temperature"] = temperature
            if max_tokens > 0:
                body["max_tokens"] = max_tokens

        last_exc: BaseException | None = None
        for attempt in range(1, 4):
            content_parts: list[str] = []
            reasoning_parts: list[str] = []
            tool_calls_acc: dict[int, dict[str, Any]] = {}
            usage_acc: dict[str, Any] = {}
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
                        raise RuntimeError(f"Model API ({resp.status_code}): {msg or '请求被拒绝'}")

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

                        if isinstance(chunk.get("usage"), dict):
                            usage_acc = dict(chunk["usage"])

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
                comp_chars = (
                    sum(len(p) for p in content_parts)
                    + sum(len(p) for p in reasoning_parts)
                    + sum(len(tc["function"]["arguments"]) for tc in tool_calls_acc.values())
                )
                assistant_msg["_usage"] = usage_acc
                assistant_msg["_completion_chars"] = comp_chars
                return assistant_msg

            except (httpx.TransportError, httpx.TimeoutException, ssl.SSLError, OSError) as exc:
                last_exc = exc
                if attempt < 3 and not tool_calls_acc and not emitted_any:
                    await asyncio.sleep(0.8 * attempt)
                    continue
                if attempt < 2 and not tool_calls_acc:
                    await asyncio.sleep(1.0)
                    continue
                raise RuntimeError(_format_exception(exc)) from exc

        raise RuntimeError(_format_exception(last_exc or RuntimeError("模型请求失败")))

    async def _stream_anthropic_completion(
        self,
        client: httpx.AsyncClient,
        api_key: str,
        base_url: str,
        model: str,
        *,
        temperature: float = 0.7,
        max_tokens: int = 8192,
        supports_tools: bool = True,
        extra_headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Stream Anthropic Messages API (/v1/messages) into uniform internal OpenAI-shaped message."""
        base = base_url.rstrip("/")
        url = f"{base}/messages" if base.endswith("/v1") else f"{base}/v1/messages"
        headers = {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
            **(extra_headers or {}),
        }

        raw_msgs = self._build_api_messages(provider="anthropic")
        sys_parts: list[str] = []
        anth_msgs: list[dict[str, Any]] = []
        for m in raw_msgs:
            role = m.get("role")
            if role == "system":
                if m.get("content"):
                    sys_parts.append(str(m["content"]))
            elif role == "user":
                mc = m.get("content")
                if isinstance(mc, list):
                    anth_msgs.append({"role": "user", "content": list(mc)})
                else:
                    anth_msgs.append({"role": "user", "content": str(mc or "")})
            elif role == "assistant":
                blocks: list[dict[str, Any]] = []
                if m.get("content"):
                    blocks.append({"type": "text", "text": str(m["content"])})
                for tc in m.get("tool_calls") or []:
                    try:
                        parsed_in = json.loads(tc["function"]["arguments"] or "{}")
                        if not isinstance(parsed_in, dict):
                            parsed_in = {"input": parsed_in}
                    except Exception:
                        parsed_in = {}
                    blocks.append(
                        {
                            "type": "tool_use",
                            "id": tc.get("id") or f"toolu_{uuid.uuid4().hex[:8]}",
                            "name": tc["function"]["name"],
                            "input": parsed_in,
                        }
                    )
                if blocks:
                    anth_msgs.append({"role": "assistant", "content": blocks})
            elif role == "tool":
                tr_block = {
                    "type": "tool_result",
                    "tool_use_id": str(m.get("tool_call_id") or ""),
                    "content": str(m.get("content") or ""),
                }
                if anth_msgs and anth_msgs[-1]["role"] == "user" and isinstance(anth_msgs[-1]["content"], list):
                    anth_msgs[-1]["content"].append(tr_block)
                else:
                    anth_msgs.append({"role": "user", "content": [tr_block]})

        active_schemas = self._get_active_tool_schemas()
        anth_tools = [
            {
                "name": t["function"]["name"],
                "description": t["function"].get("description", ""),
                "input_schema": t["function"].get("parameters", {"type": "object", "properties": {}}),
            }
            for t in active_schemas
        ]

        body: dict[str, Any] = {
            "model": model,
            "system": "\n\n".join(sys_parts),
            "messages": anth_msgs,
            "max_tokens": max(256, int(max_tokens or 4096)),
            "temperature": temperature,
            "stream": True,
        }
        if supports_tools:
            body["tools"] = anth_tools

        last_exc: BaseException | None = None
        for attempt in range(1, 3):
            content_parts: list[str] = []
            reasoning_parts: list[str] = []
            tool_calls_acc: dict[int, dict[str, Any]] = {}
            usage_acc: dict[str, Any] = {}
            emitted_any = False
            try:
                async with client.stream("POST", url, headers=headers, json=body) as resp:
                    if resp.status_code in RETRYABLE_STATUS_CODES and attempt < 2:
                        await resp.aread()
                        await asyncio.sleep(0.8)
                        continue
                    if resp.status_code >= 400:
                        err_text = (await resp.aread()).decode("utf-8", errors="replace").strip()
                        raise RuntimeError(f"Anthropic API ({resp.status_code}): {err_text or '请求被拒绝'}")

                    async for raw_line in resp.aiter_lines():
                        line = raw_line.strip()
                        if not line or not line.startswith("data:"):
                            continue
                        payload_str = line[5:].strip()
                        if not payload_str or payload_str == "[DONE]":
                            continue
                        try:
                            ev = json.loads(payload_str)
                        except json.JSONDecodeError:
                            continue

                        etype = ev.get("type")
                        if etype == "message_start":
                            msg_u = (ev.get("message") or {}).get("usage")
                            if isinstance(msg_u, dict):
                                usage_acc.update(msg_u)
                        elif etype == "message_delta":
                            delta_u = ev.get("usage")
                            if isinstance(delta_u, dict):
                                usage_acc.update(delta_u)

                        idx = int(ev.get("index", 0))
                        if etype == "content_block_start":
                            blk = ev.get("content_block") or {}
                            if blk.get("type") == "tool_use":
                                emitted_any = True
                                tool_calls_acc[idx] = {
                                    "id": blk.get("id") or f"toolu_{uuid.uuid4().hex[:8]}",
                                    "type": "function",
                                    "function": {
                                        "name": str(blk.get("name") or ""),
                                        "arguments": "",
                                    },
                                }
                        elif etype == "content_block_delta":
                            delta = ev.get("delta") or {}
                            dtype = delta.get("type")
                            if dtype == "text_delta" and delta.get("text"):
                                emitted_any = True
                                txt = str(delta["text"])
                                content_parts.append(txt)
                                self.emit_event("text_delta", {"text": txt}, persist=False)
                            elif dtype == "thinking_delta" and delta.get("thinking"):
                                emitted_any = True
                                th = str(delta["thinking"])
                                reasoning_parts.append(th)
                                self.emit_event("thought_delta", {"text": th}, persist=False)
                            elif dtype == "input_json_delta" and "partial_json" in delta:
                                if idx in tool_calls_acc:
                                    tool_calls_acc[idx]["function"]["arguments"] += str(delta["partial_json"])
                        elif etype == "message_stop":
                            break

                assistant_msg: dict[str, Any] = {
                    "role": "assistant",
                    "content": "".join(content_parts) if content_parts else None,
                }
                if reasoning_parts:
                    assistant_msg["reasoning_content"] = "".join(reasoning_parts)
                if tool_calls_acc:
                    for tc in tool_calls_acc.values():
                        if not tc["function"]["arguments"].strip():
                            tc["function"]["arguments"] = "{}"
                    assistant_msg["tool_calls"] = [tool_calls_acc[k] for k in sorted(tool_calls_acc.keys())]
                comp_chars = (
                    sum(len(p) for p in content_parts)
                    + sum(len(p) for p in reasoning_parts)
                    + sum(len(tc["function"]["arguments"]) for tc in tool_calls_acc.values())
                )
                assistant_msg["_usage"] = usage_acc
                assistant_msg["_completion_chars"] = comp_chars
                return assistant_msg
            except (httpx.TransportError, httpx.TimeoutException, ssl.SSLError, OSError) as exc:
                last_exc = exc
                if attempt < 2 and not tool_calls_acc and not emitted_any:
                    await asyncio.sleep(0.8)
                    continue
                raise RuntimeError(_format_exception(exc)) from exc
        raise RuntimeError(_format_exception(last_exc or RuntimeError("Anthropic 请求失败")))

    def _resolve_attachment_metas(self, attachment_ids: list[str]) -> list[dict[str, Any]]:
        metas: list[dict[str, Any]] = []
        for aid in attachment_ids:
            if self.attachment_service is not None:
                try:
                    metas.append(self.attachment_service.get_metadata(aid))
                    continue
                except Exception:
                    pass
            metas.append(
                {
                    "att_id": aid,
                    "url": f"/api/attachments/{aid}",
                    "thumb_url": f"/api/attachments/{aid}/thumb",
                }
            )
        return metas

    async def send_prompt(
        self,
        prompt: str,
        *,
        model: str | None = None,
        profile_id: str | None = None,
        attachments: list[str] | None = None,
        queue_if_busy: bool = True,
    ) -> dict[str, Any]:
        att_ids = [str(a).strip() for a in (attachments or []) if str(a).strip()]
        clean = (prompt or "").strip()
        if not clean and att_ids:
            clean = "请查看图片"
        if not clean and not att_ids:
            raise ValueError("Prompt cannot be empty")

        if self._active_task and not self._active_task.done():
            if not queue_if_busy:
                raise RuntimeError("当前会话正在执行任务，请先点击「停止」或处理待审批项。")
            item = {
                "id": uuid.uuid4().hex[:10],
                "prompt": clean,
                "model": (model or "").strip() or self.model,
                "profile_id": (profile_id or "").strip() or self.profile_id,
                "attachments": att_ids,
                "created_at": _utc_now(),
            }
            self.message_queue.append(item)
            ev = self.emit_event(
                "queue_updated",
                {
                    "queued_messages": list(self.message_queue),
                    "queued_count": len(self.message_queue),
                    "enqueued": item,
                },
                include_session=True,
            )
            return {**ev, "queued": True, "queue_item": item}

        if model and model.strip():
            self.model = model.strip()
        if profile_id is not None and profile_id.strip():
            self.profile_id = profile_id.strip()

        if self.title in ("New Session", "DeepSeek Session") and len(self.events) == 0:
            self.title = clean[:40] + ("..." if len(clean) > 40 else "")

        turn_id = "turn_" + uuid.uuid4().hex[:10]
        self._current_turn_id = turn_id
        att_metas = self._resolve_attachment_metas(att_ids)
        user_payload: dict[str, Any] = {"text": clean, "turn_id": turn_id}
        if att_metas:
            user_payload["attachments"] = att_metas
        user_event = self.emit_event("user_message", user_payload)
        self._cancel_requested = False
        self.status = "running"
        self.emit_event("status", {"status": "running", "turn_id": turn_id}, persist=False, include_session=True)
        self._active_task = asyncio.create_task(
            self._run_turn(clean, turn_id=turn_id, attachment_ids=att_ids)
        )
        return {**user_event, "turn_id": turn_id, "queued": False}

    # --- Module C: Session Rename & Turn Manipulation ---

    def rename(self, title: str) -> dict[str, Any]:
        clean_title = (title or "").strip()[:80]
        if clean_title:
            self.title = clean_title
        self.updated_at = _utc_now()
        self.save_to_disk()
        self.emit_event("session_updated", {"title": self.title}, include_session=True)
        return self.summary()

    async def delete_turn(self, turn_id: str) -> dict[str, Any]:
        target_tid = (turn_id or "").strip()
        if not target_tid:
            raise KeyError("turn_id is required")
        if self._active_task and not self._active_task.done():
            await self.cancel_turn()

        has_ev = any((ev.get("data") or {}).get("turn_id") == target_tid for ev in self.events)
        has_msg = any(m.get("_turn_id") == target_tid for m in self.messages)
        if not has_ev and not has_msg:
            raise KeyError(f"Turn not found: {target_tid}")

        self.events = [ev for ev in self.events if (ev.get("data") or {}).get("turn_id") != target_tid]
        self.messages = [m for m in self.messages if m.get("_turn_id") != target_tid]
        self.messages = sanitize_conversation_messages(self.messages)
        self._current_turn_id = ""
        self.emit_event("turn_deleted", {"turn_id": target_tid}, include_session=True)
        return self.summary()

    async def edit_turn(
        self,
        turn_id: str,
        new_text: str,
        *,
        model: str | None = None,
        profile_id: str | None = None,
        attachments: list[str] | None = None,
    ) -> dict[str, Any]:
        target_tid = (turn_id or "").strip()
        if not target_tid:
            raise KeyError("turn_id is required")
        if self._active_task and not self._active_task.done():
            await self.cancel_turn()

        first_ev_idx = next(
            (idx for idx, ev in enumerate(self.events) if (ev.get("data") or {}).get("turn_id") == target_tid),
            None,
        )
        first_msg_idx = next(
            (idx for idx, m in enumerate(self.messages) if m.get("_turn_id") == target_tid),
            None,
        )
        if first_ev_idx is None and first_msg_idx is None:
            raise KeyError(f"Turn not found: {target_tid}")

        if attachments is None:
            for ev in self.events:
                if ev.get("type") == "user_message" and (ev.get("data") or {}).get("turn_id") == target_tid:
                    raw_atts = (ev.get("data") or {}).get("attachments") or []
                    attachments = [
                        str(a.get("att_id") if isinstance(a, dict) else a)
                        for a in raw_atts
                        if (a.get("att_id") if isinstance(a, dict) else a)
                    ]
                    break
            if attachments is None and first_msg_idx is not None:
                attachments = list(self.messages[first_msg_idx].get("_attachments") or [])

        removed_turn_ids: list[str] = []
        if first_ev_idx is not None:
            for ev in self.events[first_ev_idx:]:
                tid = str((ev.get("data") or {}).get("turn_id") or "").strip()
                if tid and tid not in removed_turn_ids:
                    removed_turn_ids.append(tid)
            self.events = self.events[:first_ev_idx]
        if target_tid not in removed_turn_ids:
            removed_turn_ids.insert(0, target_tid)

        if first_msg_idx is not None:
            for m in self.messages[first_msg_idx:]:
                tid = str(m.get("_turn_id") or "").strip()
                if tid and tid not in removed_turn_ids:
                    removed_turn_ids.append(tid)
            self.messages = self.messages[:first_msg_idx]
        else:
            removed_set = set(removed_turn_ids)
            self.messages = [m for m in self.messages if m.get("_turn_id") not in removed_set]

        self.messages = sanitize_conversation_messages(self.messages)
        self._current_turn_id = ""
        self.emit_event(
            "turns_truncated",
            {"from_turn_id": target_tid, "removed_turn_ids": removed_turn_ids},
            include_session=True,
        )
        return await self.send_prompt(
            new_text,
            model=model,
            profile_id=profile_id,
            attachments=attachments,
            queue_if_busy=False,
        )

    async def regenerate_turn(
        self,
        turn_id: str,
        *,
        model: str | None = None,
        profile_id: str | None = None,
    ) -> dict[str, Any]:
        target_tid = (turn_id or "").strip()
        orig_text = ""
        orig_att_ids: list[str] | None = None
        for ev in self.events:
            if ev.get("type") == "user_message" and (ev.get("data") or {}).get("turn_id") == target_tid:
                orig_text = str((ev.get("data") or {}).get("text") or "")
                raw_atts = (ev.get("data") or {}).get("attachments") or []
                orig_att_ids = [
                    str(a.get("att_id") if isinstance(a, dict) else a)
                    for a in raw_atts
                    if (a.get("att_id") if isinstance(a, dict) else a)
                ]
                break
        if not orig_text:
            for m in self.messages:
                if m.get("role") == "user" and m.get("_turn_id") == target_tid:
                    orig_text = str(m.get("content") or "")
                    orig_att_ids = list(m.get("_attachments") or [])
                    break
        if not orig_text and not orig_att_ids:
            raise KeyError(f"User turn not found: {target_tid}")
        return await self.edit_turn(
            target_tid,
            orig_text,
            model=model,
            profile_id=profile_id,
            attachments=orig_att_ids,
        )

    def list_queue(self) -> list[dict[str, Any]]:
        return list(self.message_queue)

    def remove_queued_item(self, item_id: str) -> bool:
        before = len(self.message_queue)
        self.message_queue = [m for m in self.message_queue if m.get("id") != item_id]
        if len(self.message_queue) == before:
            return False
        self.emit_event(
            "queue_updated",
            {"queued_messages": list(self.message_queue), "queued_count": len(self.message_queue)},
            include_session=True,
        )
        return True

    def clear_queue(self) -> int:
        n = len(self.message_queue)
        self.message_queue.clear()
        self.emit_event(
            "queue_updated",
            {"queued_messages": [], "queued_count": 0},
            include_session=True,
        )
        return n

    async def send_queued_now(self, item_id: str) -> dict[str, Any]:
        target = next((m for m in self.message_queue if m.get("id") == item_id), None)
        if not target:
            raise KeyError(f"Queue item not found: {item_id}")
        self.message_queue = [m for m in self.message_queue if m.get("id") != item_id]
        if self._active_task and not self._active_task.done():
            # Promote to front of queue so it runs immediately after current turn
            self.message_queue.insert(0, target)
            ev = self.emit_event(
                "queue_updated",
                {"queued_messages": list(self.message_queue), "queued_count": len(self.message_queue)},
                include_session=True,
            )
            return {**ev, "promoted": True}
        self.emit_event(
            "queue_updated",
            {"queued_messages": list(self.message_queue), "queued_count": len(self.message_queue)},
            include_session=True,
        )
        return await self.send_prompt(
            str(target.get("prompt") or ""),
            model=str(target.get("model") or "") or None,
            profile_id=str(target.get("profile_id") or "") or None,
            attachments=list(target.get("attachments") or []),
            queue_if_busy=False,
        )

    async def _run_turn(
        self,
        prompt: str,
        *,
        turn_id: str = "",
        attachment_ids: list[str] | None = None,
    ) -> None:
        was_cancelled = False
        tid = turn_id or self._current_turn_id or ("turn_" + uuid.uuid4().hex[:10])
        self._current_turn_id = tid
        att_ids = list(attachment_ids or [])

        try:
            async with self._lock:
                cfg = self.config_store.config
                creds = cfg.resolve_credentials(
                    profile_id=self.profile_id or None,
                    model_override=self.model or None,
                )

                # 1. Wallet Pre-Turn Evaluation (Auto-Downgrade)
                if self.wallet_service is not None:
                    eval_res = self.wallet_service.evaluate_pre_turn_model(
                        creds["profile_id"],
                        creds["model"],
                    )
                    if eval_res.get("switched"):
                        from_model = eval_res.get("from_model") or creds["model"]
                        creds = cfg.resolve_credentials(
                            profile_id=eval_res["profile_id"],
                            model_override=eval_res["model"],
                        )
                        self.profile_id = creds["profile_id"]
                        self.model = creds["model"]
                        self.emit_event(
                            "model_auto_switched",
                            {
                                "turn_id": tid,
                                "from_model": from_model,
                                "to_model": creds["model"],
                                "reason": eval_res.get("reason") or "已触发费用与余额自动降级策略",
                            },
                            include_session=True,
                        )

                # 2. Vision Auto-Switch (Decision Q2 ★A)
                has_vision_input = bool(att_ids) or any(
                    bool(m.get("_attachments"))
                    for m in self.messages[-6:]
                    if m.get("role") == "user"
                )
                if has_vision_input and not creds.get("supports_vision", False):
                    vision_creds = cfg.resolve_credentials(profile_id="deepseek-flash")
                    if not vision_creds.get("api_key"):
                        for mp in cfg.model_profiles:
                            cand = cfg.resolve_credentials(profile_id=mp.get("id"))
                            if cand.get("supports_vision") and cand.get("api_key"):
                                vision_creds = cand
                                break
                    if vision_creds.get("api_key") and vision_creds.get("supports_vision", True):
                        orig_model = creds["model"]
                        creds = vision_creds
                        self.emit_event(
                            "model_auto_switched",
                            {
                                "turn_id": tid,
                                "from_model": orig_model,
                                "to_model": creds["model"],
                                "reason": f"当前模型不支持图片输入，本轮已自动切换至多模态模型 {creds['model']}",
                            },
                            include_session=True,
                        )

                api_key = creds["api_key"]
                if not api_key:
                    raise RuntimeError(
                        f"请先在「设置 -> 模型配置」填入 {creds['name']} 的 API Key。"
                    )
                base_url = creds["base_url"]
                model = creds["model"]

                self.messages = sanitize_conversation_messages(self.messages)
                user_msg_entry: dict[str, Any] = {
                    "role": "user",
                    "content": prompt,
                    "_turn_id": tid,
                }
                if att_ids:
                    user_msg_entry["_attachments"] = att_ids
                self.messages.append(user_msg_entry)

                tot_prompt_tokens = 0
                tot_cache_hit_tokens = 0
                tot_completion_tokens = 0
                tot_reasoning_tokens = 0
                tot_prompt_chars = 0
                tot_completion_chars = 0
                any_exact_usage = False

                async with self._http_client_factory() as client:
                    for _ in range(self.max_tool_rounds):
                        assistant_msg = await self._stream_completion(
                            client,
                            api_key,
                            base_url,
                            model,
                            provider=creds["provider"],
                            temperature=creds["temperature"],
                            max_tokens=creds["max_tokens"],
                            supports_tools=creds["supports_tools"],
                            extra_headers=creds["extra_headers"],
                        )
                        assistant_msg["_turn_id"] = tid

                        u = assistant_msg.pop("_usage", None) or {}
                        c_chars = int(assistant_msg.pop("_completion_chars", 0) or 0)
                        p_tok = int(u.get("prompt_tokens") or u.get("input_tokens") or 0)
                        c_hit = int(
                            u.get("prompt_cache_hit_tokens")
                            or (u.get("prompt_tokens_details") or {}).get("cached_tokens")
                            or u.get("cache_read_input_tokens")
                            or 0
                        )
                        comp_tok = int(u.get("completion_tokens") or u.get("output_tokens") or 0)
                        reas_tok = int(
                            ((u.get("completion_tokens_details") or {}).get("reasoning_tokens"))
                            or 0
                        )
                        if p_tok > 0 or comp_tok > 0:
                            any_exact_usage = True
                            tot_prompt_tokens += p_tok
                            tot_cache_hit_tokens += c_hit
                            tot_completion_tokens += comp_tok
                            tot_reasoning_tokens += reas_tok
                        tot_prompt_chars += max(
                            len(prompt),
                            sum(len(str(m.get("content") or "")) for m in self.messages[-6:]),
                        )
                        tot_completion_chars += max(
                            1,
                            c_chars
                            or (
                                len(str(assistant_msg.get("content") or ""))
                                + len(str(assistant_msg.get("reasoning_content") or ""))
                            ),
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
                                {"id": tc["id"], "name": fn_name, "args": parsed_args, "turn_id": tid},
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
                                    "turn_id": tid,
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
                                    "turn_id": tid,
                                },
                                persist=False,
                            )
                            self.messages.append(
                                {
                                    "role": "tool",
                                    "tool_call_id": tc_id,
                                    "content": result_str,
                                    "_turn_id": tid,
                                }
                            )

                usage_entry: dict[str, Any] | None = None
                if self.wallet_service is not None:
                    try:
                        usage_entry = self.wallet_service.record_usage(
                            session_id=self.parent_session_id or self.session_id,
                            turn_id=tid,
                            agent=self.agent_role or self.agent_id or "main",
                            profile_id=creds["profile_id"],
                            model=model,
                            prompt_tokens=tot_prompt_tokens,
                            cache_hit_tokens=tot_cache_hit_tokens,
                            completion_tokens=tot_completion_tokens,
                            reasoning_tokens=tot_reasoning_tokens,
                            estimated=not any_exact_usage,
                            prompt_chars=max(1, tot_prompt_chars),
                            completion_chars=max(1, tot_completion_chars),
                        )
                        self.last_usage = usage_entry
                    except Exception:
                        usage_entry = None

                self.status = "idle"
                done_payload: dict[str, Any] = {"stop_reason": "done", "turn_id": tid}
                if usage_entry is not None:
                    done_payload["usage"] = usage_entry
                self.emit_event("turn_done", done_payload, include_session=True)
                if self.parent_session_id is None:
                    asyncio.create_task(self._send_bark("DeepSeek 任务完成", self.title))
        except asyncio.CancelledError:
            was_cancelled = True
            self.status = "idle"
            self.messages = sanitize_conversation_messages(self.messages)
            self.emit_event("turn_done", {"stop_reason": "cancelled", "turn_id": tid}, include_session=True)
        except Exception as exc:
            self.status = "error"
            self.messages = sanitize_conversation_messages(self.messages)
            err_msg = _format_exception(exc)
            self.emit_event("error", {"message": err_msg, "turn_id": tid}, include_session=True)
            if self.parent_session_id is None:
                asyncio.create_task(self._send_bark("DeepSeek 执行出错", err_msg))
        finally:
            self._current_turn_id = ""
            self.save_to_disk()

        # Auto-dequeue next message only after cleanly releasing self._lock
        if not was_cancelled and not self._cancel_requested and self.message_queue:
            next_item = self.message_queue.pop(0)
            self.emit_event(
                "queue_updated",
                {"queued_messages": list(self.message_queue), "queued_count": len(self.message_queue)},
                include_session=True,
            )
            next_prompt = str(next_item.get("prompt") or "").strip()
            next_atts = [str(a).strip() for a in (next_item.get("attachments") or []) if str(a).strip()]
            if next_prompt or next_atts:
                if next_item.get("model"):
                    self.model = str(next_item["model"]).strip()
                if next_item.get("profile_id"):
                    self.profile_id = str(next_item["profile_id"]).strip()
                next_tid = "turn_" + uuid.uuid4().hex[:10]
                self._current_turn_id = next_tid
                att_metas = self._resolve_attachment_metas(next_atts)
                u_payload: dict[str, Any] = {"text": next_prompt or "请查看图片", "turn_id": next_tid}
                if att_metas:
                    u_payload["attachments"] = att_metas
                self.emit_event("user_message", u_payload)
                self.status = "running"
                self.emit_event("status", {"status": "running", "turn_id": next_tid}, persist=False, include_session=True)
                self._active_task = asyncio.create_task(
                    self._run_turn(next_prompt or "请查看图片", turn_id=next_tid, attachment_ids=next_atts)
                )

    async def cancel_turn(self) -> None:
        self._cancel_requested = True
        for req in list(self.pending_approvals.values()):
            if not req.future.done():
                req.future.set_result({"allow": False, "reason": "Turn cancelled"})
        for req in list(self.pending_interactions.values()):
            if not req.future.done():
                req.future.set_result({"cancelled": True, "responses": []})

        for sub in list(self.subagents.values()):
            try:
                await sub.cancel_turn()
            except Exception:
                pass

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

    def __init__(
        self,
        config_store: ConfigStore,
        *,
        plugin_service: Any | None = None,
        sandbox_runner: SandboxRunner | None = None,
        workspace_service: Any | None = None,
        attachment_service: Any | None = None,
        wallet_service: Any | None = None,
        browser_service: Any | None = None,
    ):
        self.config_store = config_store
        self.plugin_service = plugin_service
        self.sandbox_runner = sandbox_runner
        self.workspace_service = workspace_service
        self.attachment_service = attachment_service
        self.wallet_service = wallet_service
        self.browser_service = browser_service
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
                if raw.get("parent_session_id"):
                    continue
                raw_events = raw.get("events", [])
                raw_msgs = raw.get("messages", [])
                raw_queue = raw.get("message_queue", [])
                ws_path = raw.get("workspace") or self.config_store.config.workspaces[0]
                wp_id = str(raw.get("workspace_profile_id") or "").strip()
                if not wp_id and self.workspace_service is not None:
                    wp_id = self.workspace_service.resolve_profile_for_workspace_path(ws_path)
                sess = DeepSeekSession(
                    session_id=sid,
                    title=raw.get("title", "Session"),
                    workspace=ws_path,
                    workspace_profile_id=wp_id or "ws_default",
                    parent_session_id=raw.get("parent_session_id"),
                    agent_id=raw.get("agent_id"),
                    agent_role=str(raw.get("agent_role") or ""),
                    approval_mode=raw.get(
                        "approval_mode", self.config_store.config.default_approval_mode
                    ),
                    model=raw.get("model") or self.config_store.config.model,
                    profile_id=raw.get("profile_id") or "",
                    config_store=self.config_store,
                    sessions_dir=self.sessions_dir,
                    messages=raw_msgs,
                    events=raw_events,
                    message_queue=raw_queue if isinstance(raw_queue, list) else [],
                    plugin_service=self.plugin_service,
                    sandbox_runner=self.sandbox_runner,
                    workspace_service=self.workspace_service,
                    attachment_service=self.attachment_service,
                    wallet_service=self.wallet_service,
                    browser_service=self.browser_service,
                )
                sess.created_at = raw.get("created_at", sess.created_at)
                sess.updated_at = raw.get("updated_at", sess.updated_at)
                if (
                    len(sess.events) < len(raw_events)
                    or len(sess.messages) != len(raw_msgs)
                    or not raw.get("workspace_profile_id")
                ):
                    sess.save_to_disk()
                self.sessions[sid] = sess
            except Exception:
                continue

    def list_sessions(self, *, workspace_profile_id: str | None = None) -> list[dict[str, Any]]:
        wp_filter = (workspace_profile_id or "").strip()
        items: list[dict[str, Any]] = []
        for s in self.sessions.values():
            if s.parent_session_id:
                continue
            if wp_filter and s.workspace_profile_id != wp_filter:
                continue
            items.append(s.summary())
        items.sort(key=lambda s: s["updated_at"], reverse=True)
        return items

    def create_session(
        self,
        *,
        workspace: str | None = None,
        workspace_profile_id: str | None = None,
        title: str = "New Session",
        approval_mode: str | None = None,
        model: str | None = None,
        profile_id: str | None = None,
    ) -> DeepSeekSession:
        wp_id = (workspace_profile_id or "").strip()
        wp_dict: dict[str, Any] = {}
        if self.workspace_service is not None:
            if wp_id:
                wp_dict = self.workspace_service.get_or_default_profile(wp_id)
                wp_id = wp_dict["id"]
            elif workspace:
                wp_id = self.workspace_service.resolve_profile_for_workspace_path(workspace)
                wp_dict = self.workspace_service.get_or_default_profile(wp_id)
            else:
                wp_dict = self.workspace_service.get_or_default_profile("ws_default")
                wp_id = wp_dict["id"]

        ws = (
            workspace
            or ((wp_dict.get("root_paths") or [None])[0])
            or self.config_store.config.workspaces[0]
        )
        eff_approval = (
            approval_mode
            or wp_dict.get("default_approval_mode")
            or self.config_store.config.default_approval_mode
        )
        eff_profile_id = (
            profile_id
            or wp_dict.get("default_profile_id")
            or self.config_store.config.active_profile_id
        )
        sid = uuid.uuid4().hex[:12]
        sess = DeepSeekSession(
            session_id=sid,
            title=title,
            workspace=ws,
            workspace_profile_id=wp_id or "ws_default",
            approval_mode=eff_approval,
            model=model or self.config_store.config.model,
            profile_id=eff_profile_id,
            config_store=self.config_store,
            sessions_dir=self.sessions_dir,
            plugin_service=self.plugin_service,
            sandbox_runner=self.sandbox_runner,
            workspace_service=self.workspace_service,
            attachment_service=self.attachment_service,
            wallet_service=self.wallet_service,
            browser_service=self.browser_service,
        )
        sess.save_to_disk()
        self.sessions[sid] = sess
        return sess

    def get_session(self, session_id: str) -> DeepSeekSession:
        if session_id not in self.sessions:
            raise KeyError(f"Session not found: {session_id}")
        return self.sessions[session_id]

    def move_session(self, session_id: str, workspace_profile_id: str) -> DeepSeekSession:
        sess = self.get_session(session_id)
        if self.workspace_service is not None:
            prof = self.workspace_service.get_profile(workspace_profile_id)
            sess.workspace_profile_id = prof["id"]
            root_paths = prof.get("root_paths") or []
            if root_paths and sess.workspace not in root_paths:
                sess.workspace = root_paths[0]
        else:
            sess.workspace_profile_id = workspace_profile_id.strip() or "ws_default"
        sess.updated_at = _utc_now()
        sess.save_to_disk()
        sess.emit_event(
            "session_updated",
            {"workspace_profile_id": sess.workspace_profile_id, "workspace": sess.workspace},
            include_session=True,
        )
        return sess

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
