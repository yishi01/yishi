"""Persistent conversation session lifecycle and multi-round agent turn loop."""

from __future__ import annotations

import asyncio
import json
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import httpx

from bridge.agent.history import (
    _backfill_turn_ids_on_events,
    _backfill_turn_ids_on_messages,
    _format_exception,
    _utc_now,
    compact_event_stream,
    sanitize_conversation_messages,
)
from bridge.agent.providers import stream_anthropic_completion, stream_openai_completion
from bridge.agent.tool_executor import PendingRequest, ToolExecutorMixin
from bridge.agent.tools_schema import (
    MAX_TOOL_ROUNDS,
    META_EVENT_TYPES,
    SUBAGENT_ORCHESTRATION_TOOLS,
    SYSTEM_PROMPT,
    TOOL_SCHEMAS,
)
from bridge.config import ConfigStore
from bridge.sandbox_runner import SandboxRunner
from bridge.utils import atomic_write_text


class DeepSeekSession(ToolExecutorMixin):
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
        parent_session: DeepSeekSession | None = None,
        agent_id: str | None = None,
        agent_role: str = "",
        max_tool_rounds: int = MAX_TOOL_ROUNDS,
        allowed_tools: list[str] | None = None,
        last_usage: dict[str, Any] | None = None,
    ):
        self.session_id = session_id
        self.title = title
        self.workspace = str(Path(workspace).resolve())
        self.approval_mode = approval_mode
        self.profile_id = (profile_id if profile_id is not None else config_store.config.active_profile_id) or ""
        if model and str(model).strip():
            self.model = str(model).strip()
        elif profile_id and str(profile_id).strip():
            prof = config_store.config.get_profile(str(profile_id).strip())
            self.model = str(prof.get("model") or config_store.config.model or "deepseek-chat")
        else:
            self.model = config_store.config.model or "deepseek-chat"
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
        self.parent_session: DeepSeekSession | None = parent_session
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
        self.last_usage: dict[str, Any] = dict(last_usage or {})

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

    def _collect_pending_items(self, attr: str) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for req in getattr(self, attr).values():
            out.append({"request_id": req.request_id, "created_at": req.created_at, **req.payload})
        for ag_id, sub in self.subagents.items():
            for req in getattr(sub, attr).values():
                item = {
                    "request_id": req.request_id,
                    "created_at": req.created_at,
                    **req.payload,
                }
                item.setdefault("subagent_id", ag_id)
                item.setdefault("subagent_role", sub.agent_role or ag_id)
                out.append(item)
        return out

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
            "pending_approvals": self._collect_pending_items("pending_approvals"),
            "pending_interactions": self._collect_pending_items("pending_interactions"),
        }

    def save_to_disk(self) -> None:
        self.sessions_dir.mkdir(parents=True, exist_ok=True)
        ev_slice = self.events[-600:]
        if len(self.messages) > 240:
            self.messages = sanitize_conversation_messages(self.messages[-160:])
        msg_slice = self.messages[-120:]
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
            "last_usage": self.last_usage,
            "messages": msg_slice,
            "events": ev_slice,
            "message_queue": self.message_queue[-50:],
        }
        atomic_write_text(
            self.storage_path,
            json.dumps(payload, ensure_ascii=False, indent=2),
        )

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
        api_msgs = await asyncio.to_thread(self._build_api_messages, provider=provider)
        schemas = self._get_active_tool_schemas()
        if provider == "anthropic":
            return await stream_anthropic_completion(
                client,
                api_key,
                base_url,
                model,
                raw_msgs=api_msgs,
                tool_schemas=schemas,
                emit_event=self.emit_event,
                temperature=temperature,
                max_tokens=max_tokens,
                supports_tools=supports_tools,
                extra_headers=extra_headers,
            )
        return await stream_openai_completion(
            client,
            api_key,
            base_url,
            model,
            api_msgs=api_msgs,
            tool_schemas=schemas,
            emit_event=self.emit_event,
            temperature=temperature,
            max_tokens=max_tokens,
            supports_tools=supports_tools,
            extra_headers=extra_headers,
        )

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

    def _start_turn_task(self, clean_prompt: str, att_ids: list[str]) -> dict[str, Any]:
        if self.title in ("New Session", "DeepSeek Session") and len(self.events) == 0:
            self.title = clean_prompt[:40] + ("..." if len(clean_prompt) > 40 else "")

        turn_id = "turn_" + uuid.uuid4().hex[:10]
        self._current_turn_id = turn_id
        att_metas = self._resolve_attachment_metas(att_ids)
        user_payload: dict[str, Any] = {"text": clean_prompt, "turn_id": turn_id}
        if att_metas:
            user_payload["attachments"] = att_metas
        user_event = self.emit_event("user_message", user_payload)
        self._cancel_requested = False
        self.status = "running"
        self.emit_event("status", {"status": "running", "turn_id": turn_id}, persist=False, include_session=True)
        self._active_task = asyncio.create_task(
            self._run_turn(clean_prompt, turn_id=turn_id, attachment_ids=att_ids)
        )
        return {**user_event, "turn_id": turn_id, "queued": False}

    def _apply_model_selection(self, *, model: str | None = None, profile_id: str | None = None) -> None:
        if profile_id is not None and profile_id.strip():
            pid = profile_id.strip()
            self.profile_id = pid
            if not (model and model.strip()):
                prof = self.config_store.config.get_profile(pid)
                if prof.get("model"):
                    self.model = str(prof["model"]).strip()
        if model and model.strip():
            self.model = model.strip()

    def _extract_turn_attachments(self, target_tid: str, fallback_msg_idx: int | None = None) -> list[str]:
        for ev in self.events:
            if ev.get("type") == "user_message" and (ev.get("data") or {}).get("turn_id") == target_tid:
                raw_atts = (ev.get("data") or {}).get("attachments") or []
                return [
                    str(a.get("att_id") if isinstance(a, dict) else a)
                    for a in raw_atts
                    if (a.get("att_id") if isinstance(a, dict) else a)
                ]
        if fallback_msg_idx is not None and 0 <= fallback_msg_idx < len(self.messages):
            return list(self.messages[fallback_msg_idx].get("_attachments") or [])
        for m in self.messages:
            if m.get("role") == "user" and m.get("_turn_id") == target_tid:
                return list(m.get("_attachments") or [])
        return []

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

        self._apply_model_selection(model=model, profile_id=profile_id)
        return self._start_turn_task(clean, att_ids)

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

        async with self._lock:
            has_ev = any(
                ev.get("type") not in META_EVENT_TYPES and (ev.get("data") or {}).get("turn_id") == target_tid
                for ev in self.events
            )
            has_msg = any(m.get("_turn_id") == target_tid for m in self.messages)
            if not has_ev and not has_msg:
                raise KeyError(f"Turn not found: {target_tid}")

            self.events = [
                ev
                for ev in self.events
                if ev.get("type") in META_EVENT_TYPES or (ev.get("data") or {}).get("turn_id") != target_tid
            ]
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

        async with self._lock:
            first_ev_idx = next(
                (
                    idx
                    for idx, ev in enumerate(self.events)
                    if ev.get("type") not in META_EVENT_TYPES
                    and (ev.get("data") or {}).get("turn_id") == target_tid
                ),
                None,
            )
            first_msg_idx = next(
                (idx for idx, m in enumerate(self.messages) if m.get("_turn_id") == target_tid),
                None,
            )
            if first_ev_idx is None and first_msg_idx is None:
                raise KeyError(f"Turn not found: {target_tid}")

            resolved_atts = (
                [str(a).strip() for a in attachments if str(a).strip()]
                if attachments is not None
                else self._extract_turn_attachments(target_tid, first_msg_idx)
            )
            clean_new = (new_text or "").strip()
            if not clean_new and resolved_atts:
                clean_new = "请查看图片"
            if not clean_new and not resolved_atts:
                raise ValueError("Prompt cannot be empty")

            removed_turn_ids: list[str] = []
            if first_ev_idx is not None:
                for ev in self.events[first_ev_idx:]:
                    if ev.get("type") in META_EVENT_TYPES:
                        continue
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
            self._apply_model_selection(model=model, profile_id=profile_id)
            return self._start_turn_task(clean_new, resolved_atts)

    async def regenerate_turn(
        self,
        turn_id: str,
        *,
        model: str | None = None,
        profile_id: str | None = None,
    ) -> dict[str, Any]:
        target_tid = (turn_id or "").strip()
        orig_text = ""
        for ev in self.events:
            if ev.get("type") == "user_message" and (ev.get("data") or {}).get("turn_id") == target_tid:
                orig_text = str((ev.get("data") or {}).get("text") or "")
                break
        if not orig_text:
            for m in self.messages:
                if m.get("role") == "user" and m.get("_turn_id") == target_tid:
                    orig_text = str(m.get("content") or "")
                    break
        orig_att_ids = self._extract_turn_attachments(target_tid)
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
        usage_recorded = False
        tot_prompt_tokens = 0
        tot_cache_hit_tokens = 0
        tot_completion_tokens = 0
        tot_reasoning_tokens = 0
        tot_prompt_chars = 0
        tot_completion_chars = 0
        any_exact_usage = False
        creds: dict[str, Any] = {"profile_id": self.profile_id or ""}
        model = self.model or "deepseek-chat"

        def _flush_usage() -> dict[str, Any] | None:
            nonlocal usage_recorded
            if usage_recorded or self.wallet_service is None:
                return None
            if tot_prompt_tokens <= 0 and tot_completion_tokens <= 0 and tot_completion_chars <= 0:
                return None
            usage_recorded = True
            try:
                entry = self.wallet_service.record_usage(
                    session_id=self.parent_session_id or self.session_id,
                    turn_id=tid,
                    agent=self.agent_role or self.agent_id or "main",
                    profile_id=str(creds.get("profile_id") or self.profile_id or ""),
                    model=model,
                    prompt_tokens=tot_prompt_tokens,
                    cache_hit_tokens=tot_cache_hit_tokens,
                    completion_tokens=tot_completion_tokens,
                    reasoning_tokens=tot_reasoning_tokens,
                    estimated=not any_exact_usage,
                    prompt_chars=max(1, tot_prompt_chars),
                    completion_chars=max(1, tot_completion_chars),
                )
                self.last_usage = entry
                return entry
            except Exception:
                return None

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
                            self._emit_to_self_and_parent(
                                "approval_request",
                                {
                                    "request_id": first_req.request_id,
                                    "batch_count": len(self.pending_approvals),
                                    "turn_id": tid,
                                    **first_req.payload,
                                },
                                include_session=True,
                            )
                            notify_target = self.parent_session or self
                            asyncio.create_task(
                                notify_target._send_bark(
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

                usage_entry = await asyncio.to_thread(_flush_usage)

                self.status = "idle"
                done_payload: dict[str, Any] = {"stop_reason": "done", "turn_id": tid}
                if usage_entry is not None:
                    done_payload["usage"] = usage_entry
                self.emit_event("turn_done", done_payload, include_session=True)
                if self.parent_session_id is None:
                    asyncio.create_task(self._send_bark("DeepSeek 任务完成", self.title))
        except asyncio.CancelledError:
            was_cancelled = True
            _flush_usage()
            self.status = "idle"
            self.messages = sanitize_conversation_messages(self.messages)
            self.emit_event("turn_done", {"stop_reason": "cancelled", "turn_id": tid}, include_session=True)
        except Exception as exc:
            _flush_usage()
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
                self._apply_model_selection(
                    model=str(next_item.get("model") or "") or None,
                    profile_id=str(next_item.get("profile_id") or "") or None,
                )
                self._start_turn_task(next_prompt or "请查看图片", next_atts)

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
            for sub in self.subagents.values():
                sub.approval_mode = set_approval_mode

        if request_id == "all":
            resolved_any = False
            for req in list(self.pending_approvals.values()):
                if not req.future.done():
                    req.future.set_result({"allow": allow, "reason": reason})
                    resolved_any = True
            for sub in self.subagents.values():
                if sub.resolve_approval("all", allow=allow, reason=reason, set_approval_mode=set_approval_mode):
                    resolved_any = True
            return resolved_any

        req = self.pending_approvals.get(request_id)
        if req is None or req.future.done():
            for sub in self.subagents.values():
                if sub.resolve_approval(request_id, allow=allow, reason=reason, set_approval_mode=set_approval_mode):
                    return True
            return False
        req.future.set_result({"allow": allow, "reason": reason})

        if allow and self.approval_mode == "auto":
            for other in list(self.pending_approvals.values()):
                if not other.future.done():
                    other.future.set_result({"allow": True, "reason": "Auto-approved"})
            for sub in self.subagents.values():
                sub.resolve_approval("all", allow=True, reason="Auto-approved", set_approval_mode="auto")
        return True

    def resolve_interaction(
        self,
        request_id: str,
        *,
        responses: list[dict[str, Any]] | None = None,
        cancelled: bool = False,
    ) -> bool:
        req = self.pending_interactions.get(request_id)
        if req is None or req.future.done():
            for sub in self.subagents.values():
                if sub.resolve_interaction(request_id, responses=responses, cancelled=cancelled):
                    return True
            return False
        req.future.set_result({"responses": responses or [], "cancelled": cancelled})
        return True
