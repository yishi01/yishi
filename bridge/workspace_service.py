"""Workspace Profiles & Cross-Session Reading Service for DeepSeek Mobile Bridge v0.9.0."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import threading
from typing import Any, Callable
import uuid

from bridge.config import PROJECT_ROOT

VALID_APPROVAL_MODES = {"ask_commands", "ask_writes", "auto"}
DEFAULT_PROFILE_ID = "ws_default"
DEFAULT_PROFILE_ICON = "folder.fill"
DEFAULT_PROFILE_COLOR = "blue"


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _normalize_path_str(raw_path: str) -> str:
    clean = (raw_path or "").strip()
    if not clean:
        return ""
    try:
        return str(Path(clean).expanduser().resolve())
    except OSError:
        return str(Path(clean).expanduser())


class WorkspaceService:
    """Manages isolated Workspace Profiles and strictly-scoped cross-session reading."""

    def __init__(
        self,
        data_dir: Path,
        config_store: Any,
        session_manager_getter: Callable[[], Any] | None = None,
    ) -> None:
        self._lock = threading.RLock()
        self.data_dir = Path(data_dir).resolve()
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.config_store = config_store
        self.session_manager_getter = session_manager_getter
        self.storage_path = self.data_dir / "workspaces.json"
        self._profiles: dict[str, dict[str, Any]] = {}

        self._backup_v09_config_once()
        self._load_or_bootstrap()

    def set_session_manager_getter(self, getter: Callable[[], Any] | None) -> None:
        self.session_manager_getter = getter

    # ------------------------------------------------------------------
    # Initialization, Backup & Persistence
    # ------------------------------------------------------------------
    def _backup_v09_config_once(self) -> None:
        src_cfg = self.data_dir / "config.json"
        backup_dir = self.data_dir / "backup-v09"
        dst_cfg = backup_dir / "config.json"
        if src_cfg.exists() and not dst_cfg.exists():
            try:
                backup_dir.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_cfg, dst_cfg)
            except OSError:
                pass

    def _cfg_workspaces(self) -> list[str]:
        if self.config_store is not None and hasattr(self.config_store, "config"):
            raw = getattr(self.config_store.config, "workspaces", None) or []
            normalized = [_normalize_path_str(str(p)) for p in raw if str(p).strip()]
            normalized = [p for p in normalized if p]
            if normalized:
                return list(dict.fromkeys(normalized))
        return [str(PROJECT_ROOT.resolve())]

    def _cfg_default_model_profile_id(self) -> str:
        if self.config_store is not None and hasattr(self.config_store, "config"):
            val = str(getattr(self.config_store.config, "active_profile_id", "") or "").strip()
            if val:
                return val
        return "deepseek-flash"

    def _cfg_default_approval_mode(self) -> str:
        if self.config_store is not None and hasattr(self.config_store, "config"):
            val = str(getattr(self.config_store.config, "default_approval_mode", "") or "").strip()
            if val in VALID_APPROVAL_MODES:
                return val
        return "ask_commands"

    def _sync_paths_to_config(self, paths: list[str]) -> None:
        if self.config_store is None or not hasattr(self.config_store, "config"):
            return
        cfg = self.config_store.config
        current_ws = list(getattr(cfg, "workspaces", None) or [])
        changed = False
        for raw_p in paths:
            norm = _normalize_path_str(raw_p)
            if not norm:
                continue
            try:
                p = Path(norm)
                if p.exists() and p.is_dir():
                    resolved_str = str(p.resolve())
                    if resolved_str not in current_ws:
                        current_ws.append(resolved_str)
                        changed = True
            except OSError:
                continue
        if changed:
            cfg.workspaces = current_ws
            if hasattr(self.config_store, "save"):
                try:
                    self.config_store.save(cfg)
                except Exception:
                    pass

    def _normalize_profile_dict(
        self,
        raw: dict[str, Any],
        *,
        fallback_id: str | None = None,
        now_iso: str | None = None,
    ) -> dict[str, Any]:
        now = now_iso or _utc_now()
        pid = str(raw.get("id") or fallback_id or f"ws_{uuid.uuid4().hex[:8]}").strip()
        name = str(raw.get("name") or ("默认工作区" if pid == DEFAULT_PROFILE_ID else pid)).strip()[:60]
        if not name:
            name = "默认工作区" if pid == DEFAULT_PROFILE_ID else pid[:60]

        icon = str(raw.get("icon") or DEFAULT_PROFILE_ICON).strip() or DEFAULT_PROFILE_ICON
        color = str(raw.get("color") or DEFAULT_PROFILE_COLOR).strip() or DEFAULT_PROFILE_COLOR

        raw_paths = raw.get("root_paths")
        if isinstance(raw_paths, str):
            raw_paths = [raw_paths]
        elif not isinstance(raw_paths, list):
            single = raw.get("root_path") or raw.get("workspace")
            raw_paths = [single] if isinstance(single, str) and single.strip() else []

        root_paths: list[str] = []
        for p in raw_paths:
            norm = _normalize_path_str(str(p))
            if norm and norm not in root_paths:
                root_paths.append(norm)
        if not root_paths:
            root_paths = self._cfg_workspaces()

        default_profile_id = (
            str(raw.get("default_profile_id") or "").strip() or self._cfg_default_model_profile_id()
        )
        approval_mode = str(raw.get("default_approval_mode") or "").strip()
        if approval_mode not in VALID_APPROVAL_MODES:
            approval_mode = self._cfg_default_approval_mode()

        shared_notes = str(raw.get("shared_notes") if raw.get("shared_notes") is not None else "")
        cross_session_read = bool(raw.get("cross_session_read", True))
        created_at = str(raw.get("created_at") or now)
        updated_at = str(raw.get("updated_at") or created_at)

        return {
            "id": pid,
            "name": name,
            "icon": icon,
            "color": color,
            "root_paths": root_paths,
            "default_profile_id": default_profile_id,
            "default_approval_mode": approval_mode,
            "shared_notes": shared_notes,
            "cross_session_read": cross_session_read,
            "created_at": created_at,
            "updated_at": updated_at,
        }

    def _build_default_profile(self, now_iso: str | None = None) -> dict[str, Any]:
        now = now_iso or _utc_now()
        return {
            "id": DEFAULT_PROFILE_ID,
            "name": "默认工作区",
            "icon": DEFAULT_PROFILE_ICON,
            "color": DEFAULT_PROFILE_COLOR,
            "root_paths": self._cfg_workspaces(),
            "default_profile_id": self._cfg_default_model_profile_id(),
            "default_approval_mode": self._cfg_default_approval_mode(),
            "shared_notes": "",
            "cross_session_read": True,
            "created_at": now,
            "updated_at": now,
        }

    def _load_or_bootstrap(self) -> None:
        with self._lock:
            loaded_items: list[dict[str, Any]] = []
            if self.storage_path.exists():
                try:
                    raw = json.loads(self.storage_path.read_text(encoding="utf-8"))
                    if isinstance(raw, list):
                        loaded_items = [x for x in raw if isinstance(x, dict)]
                    elif isinstance(raw, dict) and isinstance(raw.get("profiles"), list):
                        loaded_items = [x for x in raw["profiles"] if isinstance(x, dict)]
                except (OSError, json.JSONDecodeError):
                    loaded_items = []

            now = _utc_now()
            had_existing_profiles = bool(loaded_items)
            profiles_map: dict[str, dict[str, Any]] = {}

            for item in loaded_items:
                norm = self._normalize_profile_dict(item, now_iso=now)
                profiles_map[norm["id"]] = norm

            if DEFAULT_PROFILE_ID not in profiles_map:
                default_prof = self._build_default_profile(now_iso=now)
                # Ensure ws_default is placed first
                profiles_map = {DEFAULT_PROFILE_ID: default_prof, **profiles_map}
            else:
                # Keep ws_default first in ordering
                default_prof = profiles_map.pop(DEFAULT_PROFILE_ID)
                profiles_map = {DEFAULT_PROFILE_ID: default_prof, **profiles_map}

            if not had_existing_profiles:
                cfg_ws = self._cfg_workspaces()
                if len(cfg_ws) > 1:
                    palette = ["indigo", "emerald", "amber", "rose", "purple", "cyan"]
                    for idx, extra_path in enumerate(cfg_ws[1:]):
                        folder_name = (Path(extra_path).name or extra_path)[:60]
                        extra_id = f"ws_{uuid.uuid4().hex[:8]}"
                        profiles_map[extra_id] = {
                            "id": extra_id,
                            "name": folder_name,
                            "icon": DEFAULT_PROFILE_ICON,
                            "color": palette[idx % len(palette)],
                            "root_paths": [extra_path],
                            "default_profile_id": self._cfg_default_model_profile_id(),
                            "default_approval_mode": self._cfg_default_approval_mode(),
                            "shared_notes": "",
                            "cross_session_read": True,
                            "created_at": now,
                            "updated_at": now,
                        }

            self._profiles = profiles_map
            all_paths: list[str] = []
            for prof in self._profiles.values():
                for p in prof.get("root_paths", []):
                    if p not in all_paths:
                        all_paths.append(p)
            self._sync_paths_to_config(all_paths)
            self._save_to_disk()

    def _save_to_disk(self) -> None:
        with self._lock:
            self.data_dir.mkdir(parents=True, exist_ok=True)
            payload = {
                "version": "0.9.0",
                "profiles": list(self._profiles.values()),
            }
            tmp = self.storage_path.with_suffix(
                f".json.tmp-{os.getpid()}-{threading.get_ident()}"
            )
            tmp.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            os.replace(tmp, self.storage_path)

    # ------------------------------------------------------------------
    # Session Manager & Profile Resolution Helpers
    # ------------------------------------------------------------------
    def _get_session_manager(self, caller_session: Any | None = None) -> Any | None:
        if self.session_manager_getter is not None:
            try:
                sm = self.session_manager_getter()
                if sm is not None:
                    return sm
            except Exception:
                pass
        if caller_session is not None:
            sm = getattr(caller_session, "session_manager", None)
            if sm is not None:
                return sm
        return None

    def _iter_all_sessions(self, caller_session: Any | None = None) -> list[Any]:
        sm = self._get_session_manager(caller_session)
        if sm is None:
            return []
        sessions_attr = getattr(sm, "sessions", None)
        if isinstance(sessions_attr, dict):
            return list(sessions_attr.values())
        if isinstance(sessions_attr, list):
            return list(sessions_attr)
        return []

    def resolve_profile_for_workspace_path(self, workspace_path: str) -> str:
        """Match a session's workspace path to a profile whose root_paths contains or equals it."""
        norm_target = _normalize_path_str(workspace_path)
        if not norm_target:
            return DEFAULT_PROFILE_ID

        target_normcase = os.path.normcase(norm_target)
        try:
            target_path = Path(norm_target).resolve()
        except OSError:
            target_path = Path(norm_target)

        with self._lock:
            # Prefer non-default profiles over ws_default when both contain the path
            ordered_profiles = [
                p for pid, p in self._profiles.items() if pid != DEFAULT_PROFILE_ID
            ]
            if DEFAULT_PROFILE_ID in self._profiles:
                ordered_profiles.append(self._profiles[DEFAULT_PROFILE_ID])

            # Pass 1: exact root_path match
            for prof in ordered_profiles:
                for rp in prof.get("root_paths") or []:
                    rp_norm = _normalize_path_str(rp)
                    if rp_norm and os.path.normcase(rp_norm) == target_normcase:
                        return str(prof["id"])

            # Pass 2: subpath containment match (longest matching root wins)
            best_profile_id: str | None = None
            best_len = -1
            for prof in ordered_profiles:
                for rp in prof.get("root_paths") or []:
                    rp_norm = _normalize_path_str(rp)
                    if not rp_norm:
                        continue
                    try:
                        rp_path = Path(rp_norm).resolve()
                        is_sub = target_path == rp_path or target_path.is_relative_to(rp_path)
                    except (OSError, ValueError):
                        rp_prefix = os.path.normcase(rp_norm).rstrip("\\/") + os.sep
                        is_sub = target_normcase.startswith(rp_prefix)
                    if is_sub and len(rp_norm) > best_len:
                        best_len = len(rp_norm)
                        best_profile_id = str(prof["id"])

            return best_profile_id or DEFAULT_PROFILE_ID

    def _resolve_session_profile_id(self, session: Any) -> str:
        if session is None:
            return DEFAULT_PROFILE_ID
        if isinstance(session, dict):
            explicit_id = str(session.get("workspace_profile_id") or "").strip()
            ws_path = str(session.get("workspace") or "").strip()
        else:
            explicit_id = str(getattr(session, "workspace_profile_id", "") or "").strip()
            ws_path = str(getattr(session, "workspace", "") or "").strip()

        if explicit_id:
            return explicit_id
        if ws_path:
            return self.resolve_profile_for_workspace_path(ws_path)
        return DEFAULT_PROFILE_ID

    def _compute_session_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {pid: 0 for pid in self._profiles}
        for s in self._iter_all_sessions():
            if getattr(s, "parent_session_id", None):
                continue
            pid = self._resolve_session_profile_id(s)
            if pid not in counts:
                pid = DEFAULT_PROFILE_ID
            counts[pid] = counts.get(pid, 0) + 1
        return counts

    def _enrich_profile(
        self,
        profile: dict[str, Any],
        session_counts: dict[str, int] | None = None,
    ) -> dict[str, Any]:
        out = copy.deepcopy(profile)
        if session_counts is None:
            session_counts = self._compute_session_counts()
        out["session_count"] = int(session_counts.get(out["id"], 0))
        return out

    # ------------------------------------------------------------------
    # CRUD Operations on Workspace Profiles
    # ------------------------------------------------------------------
    def list_profiles(self) -> list[dict[str, Any]]:
        with self._lock:
            counts = self._compute_session_counts()
            return [self._enrich_profile(p, counts) for p in self._profiles.values()]

    def get_profile(self, profile_id: str) -> dict[str, Any]:
        pid = (profile_id or "").strip()
        with self._lock:
            if pid not in self._profiles:
                raise KeyError(f"Workspace profile not found: {profile_id}")
            return self._enrich_profile(self._profiles[pid])

    def get_or_default_profile(self, profile_id: str | None) -> dict[str, Any]:
        pid = (profile_id or "").strip()
        with self._lock:
            if pid and pid in self._profiles:
                return self._enrich_profile(self._profiles[pid])
            if DEFAULT_PROFILE_ID not in self._profiles:
                self._profiles[DEFAULT_PROFILE_ID] = self._build_default_profile()
                self._save_to_disk()
            return self._enrich_profile(self._profiles[DEFAULT_PROFILE_ID])

    def create_profile(self, payload: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(payload, dict):
            raise ValueError("Payload must be a dict")

        raw_name = str(payload.get("name") or "").strip()
        if not raw_name:
            raise ValueError("Workspace profile name is required")
        name = raw_name[:60]

        approval_mode = str(
            payload.get("default_approval_mode") or self._cfg_default_approval_mode()
        ).strip()
        if approval_mode not in VALID_APPROVAL_MODES:
            raise ValueError(f"Invalid default_approval_mode: {approval_mode}")

        with self._lock:
            requested_id = str(payload.get("id") or "").strip()
            if requested_id:
                if requested_id in self._profiles:
                    raise ValueError(f"Workspace profile already exists: {requested_id}")
                pid = requested_id
            else:
                pid = f"ws_{uuid.uuid4().hex[:8]}"
                while pid in self._profiles:
                    pid = f"ws_{uuid.uuid4().hex[:8]}"

            now = _utc_now()
            prof = self._normalize_profile_dict(
                {
                    **payload,
                    "id": pid,
                    "name": name,
                    "default_approval_mode": approval_mode,
                    "created_at": now,
                    "updated_at": now,
                },
                fallback_id=pid,
                now_iso=now,
            )
            self._profiles[pid] = prof
            self._sync_paths_to_config(prof["root_paths"])
            self._save_to_disk()
            return self._enrich_profile(prof)

    def update_profile(self, profile_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(payload, dict):
            raise ValueError("Payload must be a dict")
        pid = (profile_id or "").strip()
        with self._lock:
            if pid not in self._profiles:
                raise KeyError(f"Workspace profile not found: {profile_id}")

            existing = copy.deepcopy(self._profiles[pid])

            if "name" in payload and payload["name"] is not None:
                new_name = str(payload["name"]).strip()
                if not new_name:
                    raise ValueError("Workspace profile name cannot be empty")
                existing["name"] = new_name[:60]

            if "icon" in payload and payload["icon"] is not None:
                existing["icon"] = str(payload["icon"]).strip() or DEFAULT_PROFILE_ICON

            if "color" in payload and payload["color"] is not None:
                existing["color"] = str(payload["color"]).strip() or DEFAULT_PROFILE_COLOR

            if "root_paths" in payload and payload["root_paths"] is not None:
                raw_paths = payload["root_paths"]
                if isinstance(raw_paths, str):
                    raw_paths = [raw_paths]
                if not isinstance(raw_paths, list):
                    raise ValueError("root_paths must be a list of strings")
                cleaned_paths: list[str] = []
                for p in raw_paths:
                    norm = _normalize_path_str(str(p))
                    if norm and norm not in cleaned_paths:
                        cleaned_paths.append(norm)
                if not cleaned_paths:
                    raise ValueError("root_paths cannot be empty")
                existing["root_paths"] = cleaned_paths
                self._sync_paths_to_config(cleaned_paths)

            if "default_profile_id" in payload and payload["default_profile_id"] is not None:
                val = str(payload["default_profile_id"]).strip()
                if val:
                    existing["default_profile_id"] = val

            if "default_approval_mode" in payload and payload["default_approval_mode"] is not None:
                mode = str(payload["default_approval_mode"]).strip()
                if mode not in VALID_APPROVAL_MODES:
                    raise ValueError(f"Invalid default_approval_mode: {mode}")
                existing["default_approval_mode"] = mode

            if "shared_notes" in payload and payload["shared_notes"] is not None:
                existing["shared_notes"] = str(payload["shared_notes"])

            if "cross_session_read" in payload and payload["cross_session_read"] is not None:
                existing["cross_session_read"] = bool(payload["cross_session_read"])

            existing["updated_at"] = _utc_now()
            self._profiles[pid] = existing
            self._save_to_disk()
            return self._enrich_profile(existing)

    def delete_profile(self, profile_id: str, *, delete_sessions: bool = False) -> dict[str, Any]:
        pid = (profile_id or "").strip()
        if pid == DEFAULT_PROFILE_ID:
            raise ValueError("Cannot delete default workspace profile")

        with self._lock:
            if pid not in self._profiles:
                raise KeyError(f"Workspace profile not found: {profile_id}")

            removed = self._profiles.pop(pid)
            self._save_to_disk()

            deleted_sessions: list[str] = []
            reassigned_sessions: list[str] = []
            sm = self._get_session_manager()
            if sm is not None:
                sessions_dict = getattr(sm, "sessions", None)
                for s in list(self._iter_all_sessions()):
                    s_pid = self._resolve_session_profile_id(s)
                    if s_pid != pid:
                        continue
                    sid = str(getattr(s, "session_id", "") or "")
                    if delete_sessions:
                        if isinstance(sessions_dict, dict) and sid:
                            sessions_dict.pop(sid, None)
                        active_task = getattr(s, "_active_task", None)
                        if active_task is not None and hasattr(active_task, "cancel"):
                            try:
                                active_task.cancel()
                            except Exception:
                                pass
                        storage_p = getattr(s, "storage_path", None)
                        if isinstance(storage_p, Path) and storage_p.exists():
                            try:
                                storage_p.unlink()
                            except OSError:
                                pass
                        if sid:
                            deleted_sessions.append(sid)
                    else:
                        try:
                            setattr(s, "workspace_profile_id", DEFAULT_PROFILE_ID)
                        except Exception:
                            if isinstance(s, dict):
                                s["workspace_profile_id"] = DEFAULT_PROFILE_ID
                        if hasattr(s, "save_to_disk"):
                            try:
                                s.save_to_disk()
                            except Exception:
                                pass
                        if sid:
                            reassigned_sessions.append(sid)

            return {
                "deleted": True,
                "profile_id": pid,
                "profile": removed,
                "deleted_sessions": deleted_sessions,
                "reassigned_sessions": reassigned_sessions,
            }

    # ------------------------------------------------------------------
    # Cross-Session Reading (Strictly Scoped to Same workspace_profile_id)
    # ------------------------------------------------------------------
    def _check_cross_read_allowed(self, caller_session: Any) -> dict[str, Any]:
        wp_id = self._resolve_session_profile_id(caller_session)
        with self._lock:
            profile = self._profiles.get(wp_id) or self._profiles.get(DEFAULT_PROFILE_ID)
            if profile is None:
                profile = self._build_default_profile()
                self._profiles[DEFAULT_PROFILE_ID] = profile
            prof_copy = copy.deepcopy(profile)
            # Preserve caller's resolved wp_id if it was explicitly assigned
            prof_copy["id"] = wp_id if wp_id in self._profiles else prof_copy["id"]

        if not prof_copy.get("cross_session_read", True):
            raise PermissionError("当前工作区档案已关闭跨对话读取权限 (cross_session_read=False)")
        return prof_copy

    @staticmethod
    def _extract_dialogue_turns(session: Any) -> list[dict[str, Any]]:
        raw_messages = (
            session.get("messages", [])
            if isinstance(session, dict)
            else getattr(session, "messages", None) or []
        )
        turns: list[dict[str, Any]] = []
        idx = 0

        if raw_messages:
            for msg in raw_messages:
                if not isinstance(msg, dict):
                    continue
                role = str(msg.get("role") or "")
                if role not in ("user", "assistant"):
                    # Skip raw tool output blobs and system messages
                    continue
                content = str(msg.get("content") or "").strip()
                tool_calls = msg.get("tool_calls") or []
                if not content and tool_calls and role == "assistant":
                    tool_names = [
                        str((tc.get("function") or {}).get("name") or "")
                        for tc in tool_calls
                        if isinstance(tc, dict)
                    ]
                    tool_names = [n for n in tool_names if n]
                    if tool_names:
                        content = f"[调用工具: {', '.join(tool_names)}]"
                if not content:
                    continue
                turns.append(
                    {
                        "index": idx,
                        "role": role,
                        "content": content,
                    }
                )
                idx += 1
            return turns

        raw_events = (
            session.get("events", [])
            if isinstance(session, dict)
            else getattr(session, "events", None) or []
        )
        for ev in raw_events:
            if not isinstance(ev, dict):
                continue
            etype = ev.get("type")
            data = ev.get("data") or {}
            if etype == "user_message":
                text = str(data.get("text") or "").strip()
                if text:
                    turns.append({"index": idx, "role": "user", "content": text})
                    idx += 1
            elif etype == "text_delta":
                text = str(data.get("full_text") or data.get("text") or "").strip()
                if text:
                    turns.append({"index": idx, "role": "assistant", "content": text})
                    idx += 1
        return turns

    def list_workspace_sessions(
        self,
        caller_session: Any,
        *,
        query: str = "",
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        profile = self._check_cross_read_allowed(caller_session)
        caller_wp_id = profile["id"]
        caller_sid = str(
            caller_session.get("session_id", "")
            if isinstance(caller_session, dict)
            else getattr(caller_session, "session_id", "")
        )
        q_lower = (query or "").strip().lower()
        max_items = max(1, int(limit or 20))

        results: list[dict[str, Any]] = []
        for s in self._iter_all_sessions(caller_session):
            sid = str(
                s.get("session_id", "")
                if isinstance(s, dict)
                else getattr(s, "session_id", "")
            )
            if not sid or sid == caller_sid:
                continue
            parent_sid = (
                s.get("parent_session_id")
                if isinstance(s, dict)
                else getattr(s, "parent_session_id", None)
            )
            if parent_sid:
                continue

            s_wp_id = self._resolve_session_profile_id(s)
            if s_wp_id != caller_wp_id:
                continue

            title = str(
                s.get("title", "Session")
                if isinstance(s, dict)
                else getattr(s, "title", "Session")
            )
            updated_at = str(
                s.get("updated_at", "")
                if isinstance(s, dict)
                else getattr(s, "updated_at", "")
            )
            model = str(
                s.get("model", "")
                if isinstance(s, dict)
                else getattr(s, "model", "")
            )

            turns = self._extract_dialogue_turns(s)
            if q_lower:
                title_match = q_lower in title.lower()
                msg_match = any(q_lower in t["content"].lower() for t in turns)
                if not title_match and not msg_match:
                    continue

            preview = turns[-1]["content"][:200] if turns else ""
            results.append(
                {
                    "session_id": sid,
                    "title": title,
                    "workspace_profile_id": s_wp_id,
                    "updated_at": updated_at,
                    "model": model,
                    "turn_count": len(turns),
                    "preview": preview,
                }
            )

        results.sort(key=lambda item: item.get("updated_at") or "", reverse=True)
        return results[:max_items]

    def _find_target_session(self, caller_session: Any, target_session_id: str) -> Any:
        sm = self._get_session_manager(caller_session)
        if sm is not None:
            if hasattr(sm, "get_session"):
                try:
                    return sm.get_session(target_session_id)
                except KeyError:
                    pass
            sessions_attr = getattr(sm, "sessions", None)
            if isinstance(sessions_attr, dict) and target_session_id in sessions_attr:
                return sessions_attr[target_session_id]
        for s in self._iter_all_sessions(caller_session):
            sid = str(
                s.get("session_id", "")
                if isinstance(s, dict)
                else getattr(s, "session_id", "")
            )
            if sid == target_session_id:
                return s
        raise KeyError(f"Session not found: {target_session_id}")

    def read_session_transcript(
        self,
        caller_session: Any,
        target_session_id: str,
        *,
        turn_range: list[int] | None = None,
        search: str = "",
        max_chars: int = 12000,
    ) -> dict[str, Any]:
        caller_sid = str(
            caller_session.get("session_id", "")
            if isinstance(caller_session, dict)
            else getattr(caller_session, "session_id", "")
        )
        if target_session_id == caller_sid:
            raise ValueError("Cannot read own session via cross-session tool")

        profile = self._check_cross_read_allowed(caller_session)
        caller_wp_id = profile["id"]

        target = self._find_target_session(caller_session, target_session_id)
        target_wp_id = self._resolve_session_profile_id(target)
        if target_wp_id != caller_wp_id:
            raise PermissionError("Forbidden: 跨工作区档案读取被拒绝")

        turns = self._extract_dialogue_turns(target)

        if turn_range and len(turn_range) >= 1:
            start_idx = max(0, int(turn_range[0]))
            end_idx = int(turn_range[1]) if len(turn_range) >= 2 else (len(turns) - 1)
            turns = [t for t in turns if start_idx <= t["index"] <= end_idx]

        q_lower = (search or "").strip().lower()
        if q_lower:
            turns = [t for t in turns if q_lower in t["content"].lower()]

        budget = min(max(1, int(max_chars or 12000)), 40000)
        selected_turns: list[dict[str, Any]] = []
        char_count = 0
        truncated = False

        for t in turns:
            text = t["content"]
            remaining = budget - char_count
            if remaining <= 0:
                truncated = True
                break
            if len(text) > remaining:
                selected_turns.append(
                    {
                        **t,
                        "content": text[:remaining] + "...[truncated]",
                    }
                )
                char_count += remaining
                truncated = True
                break
            selected_turns.append(dict(t))
            char_count += len(text)

        title = str(
            target.get("title", "Session")
            if isinstance(target, dict)
            else getattr(target, "title", "Session")
        )
        return {
            "session_id": target_session_id,
            "title": title,
            "workspace_profile_id": target_wp_id,
            "turns": selected_turns,
            "truncated": truncated,
            "char_count": char_count,
        }

    def list_session_artifacts(
        self,
        caller_session: Any,
        target_session_id: str,
    ) -> dict[str, Any]:
        profile = self._check_cross_read_allowed(caller_session)
        caller_wp_id = profile["id"]

        target = self._find_target_session(caller_session, target_session_id)
        target_wp_id = self._resolve_session_profile_id(target)
        if target_wp_id != caller_wp_id:
            raise PermissionError("Forbidden: 跨工作区档案读取被拒绝")

        raw_events = (
            target.get("events", [])
            if isinstance(target, dict)
            else getattr(target, "events", None) or []
        )
        raw_messages = (
            target.get("messages", [])
            if isinstance(target, dict)
            else getattr(target, "messages", None) or []
        )

        artifacts: list[dict[str, Any]] = []
        touched_files: list[str] = []

        def _add_touched(path_val: Any) -> None:
            p = str(path_val or "").strip()
            if p and p not in touched_files:
                touched_files.append(p)

        for ev in raw_events:
            if not isinstance(ev, dict):
                continue
            etype = ev.get("type")
            data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
            if etype == "file_artifact":
                art_copy = dict(data)
                artifacts.append(art_copy)
                _add_touched(art_copy.get("path") or art_copy.get("rel_path"))
            elif etype in ("tool_call", "write_file", "edit_file", "present_file"):
                tool_name = etype if etype != "tool_call" else str(data.get("name") or ev.get("name") or "")
                if tool_name in ("write_file", "edit_file", "present_file"):
                    args = data.get("args") if isinstance(data.get("args"), dict) else data
                    _add_touched(args.get("path"))

        for msg in raw_messages:
            if not isinstance(msg, dict) or msg.get("role") != "assistant":
                continue
            for tc in msg.get("tool_calls") or []:
                if not isinstance(tc, dict):
                    continue
                fn = tc.get("function") or {}
                fn_name = str(fn.get("name") or "")
                if fn_name in ("write_file", "edit_file", "present_file"):
                    raw_args = fn.get("arguments")
                    parsed_args: dict[str, Any] = {}
                    if isinstance(raw_args, dict):
                        parsed_args = raw_args
                    elif isinstance(raw_args, str) and raw_args.strip():
                        try:
                            loaded = json.loads(raw_args)
                            if isinstance(loaded, dict):
                                parsed_args = loaded
                        except json.JSONDecodeError:
                            pass
                    _add_touched(parsed_args.get("path"))

        title = str(
            target.get("title", "Session")
            if isinstance(target, dict)
            else getattr(target, "title", "Session")
        )
        return {
            "session_id": target_session_id,
            "title": title,
            "workspace_profile_id": target_wp_id,
            "artifacts": artifacts,
            "touched_files": touched_files,
        }

    def build_system_prompt_appendix(self, caller_session: Any) -> str:
        wp_id = self._resolve_session_profile_id(caller_session)
        profile = self.get_or_default_profile(wp_id)
        caller_sid = str(
            caller_session.get("session_id", "")
            if isinstance(caller_session, dict)
            else getattr(caller_session, "session_id", "")
        )

        sibling_count = 0
        for s in self._iter_all_sessions(caller_session):
            sid = str(
                s.get("session_id", "")
                if isinstance(s, dict)
                else getattr(s, "session_id", "")
            )
            if not sid or sid == caller_sid:
                continue
            parent_sid = (
                s.get("parent_session_id")
                if isinstance(s, dict)
                else getattr(s, "parent_session_id", None)
            )
            if parent_sid:
                continue
            if self._resolve_session_profile_id(s) == profile["id"]:
                sibling_count += 1

        root_paths_str = ", ".join(profile.get("root_paths") or [])
        lines = [
            "\n\nWorkspace Profile Context:",
            f"- Active Workspace Profile: {profile['name']} (id: {profile['id']})",
            f"- Profile Root Paths: {root_paths_str}",
        ]
        shared_notes = str(profile.get("shared_notes") or "").strip()
        if shared_notes:
            lines.append(f"- Workspace Shared Notes:\n{shared_notes}")

        if profile.get("cross_session_read", True):
            lines.append(
                f"- Cross-Session Collaboration: Enabled ({sibling_count} sibling session(s) in this workspace profile). "
                "You may inspect sibling sessions in the same workspace profile using "
                "`list_workspace_sessions`, `read_session_transcript`, and `list_session_artifacts`."
            )
        else:
            lines.append(
                "- Cross-Session Collaboration: Disabled (cross_session_read=False for this workspace profile)."
            )
        return "\n".join(lines) + "\n"
