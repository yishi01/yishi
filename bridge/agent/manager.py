"""Session manager handling disk persistence, subagent reattachment, and cleanup."""

from __future__ import annotations

import json
import uuid
from typing import Any

from bridge.agent.history import _utc_now
from bridge.agent.session import DeepSeekSession
from bridge.agent.tools_schema import MAX_TOOL_ROUNDS
from bridge.config import ConfigStore
from bridge.sandbox_runner import SandboxRunner
from bridge.utils import cleanup_subagent_files


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
                    max_tool_rounds=MAX_TOOL_ROUNDS,
                    last_usage=raw.get("last_usage") if isinstance(raw.get("last_usage"), dict) else None,
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

        # Reload persisted subagent transcripts and attach them to parent sessions
        sub_dir = self.sessions_dir / "subagents"
        if sub_dir.exists():
            for path in sorted(sub_dir.glob("*.json")):
                try:
                    raw = json.loads(path.read_text(encoding="utf-8"))
                    parent_sid = str(raw.get("parent_session_id") or "").strip()
                    ag_id = str(raw.get("agent_id") or "").strip()
                    parent = self.sessions.get(parent_sid)
                    if not parent or not ag_id:
                        continue
                    child = DeepSeekSession(
                        session_id=str(raw.get("session_id") or f"{parent_sid}_{ag_id}"),
                        title=raw.get("title", f"[{ag_id}]"),
                        workspace=raw.get("workspace") or parent.workspace,
                        workspace_profile_id=str(raw.get("workspace_profile_id") or parent.workspace_profile_id),
                        parent_session_id=parent_sid,
                        parent_session=parent,
                        agent_id=ag_id,
                        agent_role=str(raw.get("agent_role") or ag_id),
                        approval_mode=raw.get("approval_mode", parent.approval_mode),
                        model=raw.get("model") or parent.model,
                        profile_id=raw.get("profile_id") or parent.profile_id,
                        config_store=self.config_store,
                        sessions_dir=sub_dir,
                        messages=raw.get("messages", []),
                        events=raw.get("events", []),
                        message_queue=raw.get("message_queue", []),
                        last_usage=raw.get("last_usage") if isinstance(raw.get("last_usage"), dict) else None,
                        plugin_service=self.plugin_service,
                        sandbox_runner=self.sandbox_runner,
                        workspace_service=self.workspace_service,
                        attachment_service=self.attachment_service,
                        wallet_service=self.wallet_service,
                        browser_service=self.browser_service,
                    )
                    child.created_at = raw.get("created_at", child.created_at)
                    child.updated_at = raw.get("updated_at", child.updated_at)
                    if self.browser_service is not None:
                        self.browser_service.alias_mobile_executor(child.session_id, parent_sid)
                    parent.subagents[ag_id] = child
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
        cleanup_subagent_files(self.sessions_dir, session_id)
        if self.attachment_service is not None and hasattr(self.attachment_service, "delete_session_attachments"):
            try:
                self.attachment_service.delete_session_attachments(session_id)
            except Exception:
                pass
        if self.browser_service is not None and hasattr(self.browser_service, "close_sessions_for_chat"):
            try:
                self.browser_service.close_sessions_for_chat(session_id)
            except Exception:
                pass

    async def shutdown(self) -> None:
        for sess in list(self.sessions.values()):
            await sess.cancel_turn()
