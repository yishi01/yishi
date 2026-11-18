"""Tool execution, approval gating, interaction requests, and artifact builder mixin."""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from bridge.agent.history import _format_exception, _strip_browser_frame_for_llm, _utc_now
from bridge.agent.tools_schema import (
    COMMAND_TOOLS,
    SUBAGENT_ORCHESTRATION_TOOLS,
    TOOL_SCHEMAS,
    WRITE_TOOLS,
)
from bridge.config import PROJECT_ROOT
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
from bridge.sandbox_runner import audit_untrusted_code
from bridge.search_service import execute_web_search


@dataclass
class PendingRequest:
    request_id: str
    kind: str  # "approval" | "interaction"
    payload: dict[str, Any]
    future: asyncio.Future[Any]
    created_at: str = field(default_factory=_utc_now)


class ToolExecutorMixin:
    """Provides HITL approval/interaction helpers and async tool dispatch for DeepSeekSession."""

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
        if self.parent_session_id and self.agent_id:
            payload["subagent_id"] = self.agent_id
            payload["subagent_role"] = self.agent_role or self.agent_id
        req = PendingRequest(
            request_id=req_id,
            kind="approval",
            payload=payload,
            future=fut,
        )
        self.pending_approvals[req_id] = req
        return req

    def _emit_to_self_and_parent(
        self,
        event_type: str,
        data: dict[str, Any],
        *,
        persist: bool = True,
        include_session: bool = False,
    ) -> dict[str, Any]:
        ev = self.emit_event(event_type, data, persist=persist, include_session=include_session)
        if self.parent_session is not None:
            parent_data = dict(data)
            parent_data["turn_id"] = self.parent_session._current_turn_id or parent_data.get("turn_id") or ""
            self.parent_session.emit_event(
                event_type,
                parent_data,
                persist=persist,
                include_session=include_session,
            )
        return ev

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
        self._emit_to_self_and_parent(
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
        payload: dict[str, Any] = {"questions": questions_data}
        if self.parent_session_id and self.agent_id:
            payload["subagent_id"] = self.agent_id
            payload["subagent_role"] = self.agent_role or self.agent_id
        self.pending_interactions[req_id] = PendingRequest(
            request_id=req_id,
            kind="interaction",
            payload=payload,
            future=fut,
        )
        self.status = "waiting_input"
        self._emit_to_self_and_parent(
            "interaction_request",
            {"request_id": req_id, **payload},
            include_session=True,
        )
        notify_target = self.parent_session or self
        asyncio.create_task(notify_target._send_bark("DeepSeek 需要你的回答", question))
        try:
            answer = await fut
        finally:
            self.pending_interactions.pop(req_id, None)
            if not self.pending_approvals and not self.pending_interactions:
                if self._active_task and not self._active_task.done():
                    self.status = "running"

        cancelled = bool(answer.get("cancelled", False))
        self._emit_to_self_and_parent(
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
            self._emit_to_self_and_parent(
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

        async def _build_and_emit_artifact(
            target_path: Path,
            *,
            title: str = "",
            summary: str = "",
            mode: str = "review",
            att_meta: dict[str, Any] | None = None,
        ) -> dict[str, Any]:
            def _prepare() -> dict[str, Any]:
                st = target_path.stat()
                ext_lower = target_path.suffix.lower()
                is_img = ext_lower in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
                preview_text = ""
                is_text = False
                local_att = att_meta
                if is_img and local_att is None and self.attachment_service and st.st_size <= 15_000_000:
                    try:
                        local_att = self.attachment_service.save_image_bytes(
                            target_path.read_bytes(),
                            filename=target_path.name,
                            session_id=self.session_id,
                            source="artifact",
                        )
                    except Exception:
                        local_att = None
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
                return {
                    "id": (local_att or {}).get("att_id") or uuid.uuid4().hex[:10],
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
                    "is_image": bool(is_img or local_att is not None),
                    "att_id": str((local_att or {}).get("att_id") or ""),
                    "image_url": str((local_att or {}).get("url") or ""),
                    "thumb_url": str((local_att or {}).get("thumb_url") or ""),
                    "width": int((local_att or {}).get("width") or 0),
                    "height": int((local_att or {}).get("height") or 0),
                }

            artifact_info = await asyncio.to_thread(_prepare)
            self.emit_event("file_artifact", artifact_info)
            return artifact_info

        try:
            if name == "list_directory":
                res = await asyncio.to_thread(
                    list_directory,
                    root,
                    str(args.get("path", "")),
                    allowed_workspaces=allowed_ws,
                    ai_access_mode=ai_mode,
                )
                return json.dumps(res, ensure_ascii=False)

            if name == "read_file":
                data = await asyncio.to_thread(
                    read_file_content,
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
                res = await asyncio.to_thread(
                    write_file_content,
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
                    await _build_and_emit_artifact(
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
                data = await asyncio.to_thread(
                    read_file_content,
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
                res = await asyncio.to_thread(
                    write_file_content,
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
                    await _build_and_emit_artifact(
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
                art = await _build_and_emit_artifact(
                    target_file,
                    title=str(args.get("title") or target_file.name),
                    summary=str(args.get("summary") or "AI 已为你发送该文件，点击即可审查内容或下载到手机本地"),
                    mode=str(args.get("mode") or "download"),
                )
                return json.dumps({"presented": True, "artifact": art}, ensure_ascii=False)

            if name == "search_files":
                res = await asyncio.to_thread(search_workspace, root, str(args.get("query", "")))
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
                res = await asyncio.to_thread(self.plugin_service.list_all)
                return json.dumps(res, ensure_ascii=False)

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
                    art = await _build_and_emit_artifact(
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

                def _emit_browser_result(payload: dict[str, Any]) -> str:
                    self.emit_event("browser_state", payload)
                    return json.dumps(_strip_browser_frame_for_llm(payload), ensure_ascii=False)

                if name == "browser_open":
                    return _emit_browser_result(
                        await self.browser_service.navigate(
                            browser_id,
                            str(args.get("url") or ""),
                            actor="agent",
                        )
                    )

                if name == "browser_snapshot":
                    return _emit_browser_result(
                        await self.browser_service.remote_snapshot(browser_id, actor="agent")
                    )

                if name == "browser_click":
                    el_id = int(args["element_id"]) if args.get("element_id") is not None else None
                    x_val = int(args["x"]) if args.get("x") is not None else None
                    y_val = int(args["y"]) if args.get("y") is not None else None
                    return _emit_browser_result(
                        await self.browser_service.click(
                            browser_id,
                            element_id=el_id,
                            x=x_val,
                            y=y_val,
                            actor="agent",
                        )
                    )

                if name == "browser_type":
                    el_id = int(args["element_id"]) if args.get("element_id") is not None else None
                    return _emit_browser_result(
                        await self.browser_service.type_text(
                            browser_id,
                            text=str(args.get("text") or ""),
                            element_id=el_id,
                            submit=bool(args.get("submit", False)),
                            actor="agent",
                        )
                    )

                if name == "browser_scroll":
                    return _emit_browser_result(
                        await self.browser_service.scroll(
                            browser_id,
                            delta_y=int(args.get("delta_y", 360)),
                            actor="agent",
                        )
                    )

                if name == "browser_back":
                    return _emit_browser_result(
                        await self.browser_service.go_back(browser_id, actor="agent")
                    )

                if name == "browser_extract":
                    snap = await self.browser_service.remote_snapshot(browser_id, actor="agent")
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
                    att_res = await self.browser_service.remote_screenshot(
                        browser_id,
                        self.attachment_service,
                        actor="agent",
                    )
                    snap = self.browser_service.snapshot(
                        browser_id,
                        include_frame=(att_res.get("mode") != "mobile_wkwebview"),
                    )
                    self.emit_event("browser_state", snap)
                    att_id = str(att_res.get("att_id") or "")
                    if att_id and self.attachment_service:
                        try:
                            img_path, _ = self.attachment_service.get_file_path(att_id, thumb=False)
                            await _build_and_emit_artifact(
                                img_path,
                                title=f"网页截图 · {snap.get('title') or snap.get('url') or '浏览器'}",
                                summary="点击卡片内图片可全屏缩放预览或保存",
                                mode="review",
                                att_meta=att_res,
                            )
                        except Exception:
                            self.emit_event("image_attachment", att_res)
                    else:
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
                session_cls = type(self)
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
                    raw_ag_id = str(spec.get("agent_id") or "").strip()
                    safe_ag_id = re.sub(r"[^a-zA-Z0-9_-]+", "_", raw_ag_id).strip("_-")[:40]
                    ag_id = safe_ag_id or f"ag_{uuid.uuid4().hex[:8]}"

                    all_tool_names = [t["function"]["name"] for t in TOOL_SCHEMAS]
                    child_tools = [
                        tn
                        for tn in all_tool_names
                        if tn not in SUBAGENT_ORCHESTRATION_TOOLS
                        and (allow_writes or tn not in WRITE_TOOLS)
                    ]

                    child = session_cls(
                        session_id=f"{self.session_id}_{ag_id}",
                        title=f"[{role}] {task[:36]}",
                        workspace=self.workspace,
                        workspace_profile_id=self.workspace_profile_id,
                        parent_session_id=self.session_id,
                        parent_session=self,
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
                    if self.browser_service is not None:
                        self.browser_service.alias_mobile_executor(child.session_id, self.session_id)
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
