"""Regression tests for v0.9.0 full-stack audit fixes, security gates, and architecture hygiene."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

from fastapi.testclient import TestClient
import pytest

from bridge.agent.manager import SessionManager
from bridge.agent.session import DeepSeekSession
from bridge.browser_service import BrowserService
from bridge.config import BridgeConfig, ConfigStore, VERSION
from bridge.fs_service import WorkspaceSecurityError, rename_or_move_pc_entry, resolve_ai_path
from bridge.log_service import get_log_handler, install_log_capture
from bridge.plugin_service import PluginService
from bridge.sandbox_runner import SandboxRunner
from bridge.search_service import _DuckDuckGoHTMLParser
from bridge.server import create_app
from bridge.wallet_service import WalletService

AUTH_TOKEN = "audit-test-secret-token"


def _headers(token: str = AUTH_TOKEN) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def audit_app_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    ws = tmp_path / "workspace"
    ws.mkdir(parents=True, exist_ok=True)
    (ws / "hello.txt").write_text("hello world\n", encoding="utf-8")

    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    cfg_path = data_dir / "config.json"
    cfg_path.write_text(
        json.dumps(
            {
                "host": "127.0.0.1",
                "port": 8765,
                "auth_token": AUTH_TOKEN,
                "workspaces": [str(ws.resolve())],
                "active_workspace": str(ws.resolve()),
                "ai_access_mode": "workspace_only",
                "default_approval_mode": "ask_writes",
                "deepseek_api_key": "sk-deepseek-primary",
                "deepseek_base_url": "https://api.deepseek.com",
                "model": "deepseek-flash",
                "active_profile_id": "deepseek-flash",
                "enable_tunnel": False,
                "model_profiles": [
                    {
                        "id": "deepseek-flash",
                        "name": "DeepSeek Flash",
                        "provider": "deepseek",
                        "base_url": "https://api.deepseek.com",
                        "model": "deepseek-chat",
                        "api_key": "",
                        "inherits_global_key": True,
                        "supports_tools": True,
                        "supports_reasoning": False,
                        "supports_vision": True,
                    },
                    {
                        "id": "third-party-claude",
                        "name": "Third Party",
                        "provider": "anthropic",
                        "base_url": "https://api.example.com",
                        "model": "claude-sonnet",
                        "api_key": "",
                        "inherits_global_key": False,
                        "supports_tools": True,
                        "supports_reasoning": True,
                        "supports_vision": True,
                    },
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    async def _noop(self):
        return None

    monkeypatch.setattr("bridge.tunnel_manager.TunnelManager.start", _noop)
    monkeypatch.setattr("bridge.tunnel_manager.TunnelManager.stop", _noop)

    app = create_app(data_dir=data_dir)
    with TestClient(app) as client:
        yield app, client, ws, data_dir, cfg_path


def test_config_persistence_and_credential_isolation(tmp_path: Path):
    data_dir = tmp_path / "cfgdata"
    data_dir.mkdir(parents=True, exist_ok=True)
    cfg = BridgeConfig(
        deepseek_api_key="sk-ds-secret",
        model_profiles=[
            {
                "id": "third-party-openai",
                "name": "Custom OpenAI",
                "provider": "openai_compatible",
                "base_url": "https://api.other.example/v1",
                "model": "gpt-4o",
                "api_key": "",
                "inherits_global_key": False,
            }
        ],
        browser_policy={"blocked_domains": ["evil.example"], "require_human_for_login": True},
        wallet_rules={"auto_downgrade_enabled": True, "balance_below": 3.5},
        model_pricing={"custom-model": {"input": 1.0, "output": 2.0, "cached": 0.5}},
    )
    store = ConfigStore(data_dir)
    store.save(cfg)

    reloaded = ConfigStore(data_dir).config
    assert reloaded.browser_policy.get("blocked_domains") == ["evil.example"]
    assert reloaded.wallet_rules.get("balance_below") == 3.5
    assert "custom-model" in reloaded.model_pricing

    resolved = reloaded.resolve_credentials(profile_id="third-party-openai")
    assert resolved["api_key"] == ""
    assert resolved["provider"] == "openai_compatible"


def test_wallet_manual_balance_baseline_not_double_charged(tmp_path: Path):
    ws = WalletService(data_dir=tmp_path)
    ws.record_usage(
        session_id="s1",
        turn_id="t1",
        profile_id="deepseek-chat",
        model="deepseek-chat",
        prompt_tokens=500_000,
        completion_tokens=100_000,
    )
    before_cost = ws._get_all_time_cost()
    assert before_cost > 0

    ws.update_rules({"manual_balance": 10.0})
    after_topup = ws.get_summary()
    assert after_topup["balance"]["total_balance"] == pytest.approx(10.0, abs=0.01)

    entry = ws.record_usage(
        session_id="s1",
        turn_id="t2",
        profile_id="deepseek-chat",
        model="deepseek-chat",
        prompt_tokens=1_000_000,
        completion_tokens=0,
    )
    after_spend = ws.get_summary()
    assert after_spend["balance"]["total_balance"] == pytest.approx(round(10.0 - entry["cost"], 4), abs=0.01)


def test_turn_delete_twice_and_empty_edit_validation(audit_app_env):
    app, client, _, _, _ = audit_app_env
    create_resp = client.post("/api/sessions", headers=_headers(), json={"title": "Turn Ops"})
    assert create_resp.status_code == 200
    sid = create_resp.json()["session_id"]

    session = app.state.session_manager.get_session(sid)
    assert session is not None
    session.messages.extend(
        [
            {"role": "user", "content": "turn one", "_turn_id": "t_1"},
            {"role": "assistant", "content": "reply one", "_turn_id": "t_1"},
            {"role": "user", "content": "turn two", "_turn_id": "t_2"},
            {"role": "assistant", "content": "reply two", "_turn_id": "t_2"},
        ]
    )
    session.events.extend(
        [
            {"seq": 1, "type": "user_message", "data": {"text": "turn one", "turn_id": "t_1"}},
            {"seq": 2, "type": "text_delta", "data": {"full_text": "reply one", "turn_id": "t_1"}},
            {"seq": 3, "type": "user_message", "data": {"text": "turn two", "turn_id": "t_2"}},
            {"seq": 4, "type": "text_delta", "data": {"full_text": "reply two", "turn_id": "t_2"}},
        ]
    )
    session._next_seq = 5

    # Empty edit must fail 400 WITHOUT truncating turns
    bad_edit = client.post(
        f"/api/sessions/{sid}/turns/t_1/edit",
        headers=_headers(),
        json={"text": "   "},
    )
    assert bad_edit.status_code == 400
    assert len(session.messages) == 4

    # Deleting t_1 once succeeds, second delete returns 404 (not leaving/corrupting t_2)
    del_1 = client.delete(f"/api/sessions/{sid}/turns/t_1", headers=_headers())
    assert del_1.status_code == 200
    assert [m["_turn_id"] for m in session.messages] == ["t_2", "t_2"]

    del_2 = client.delete(f"/api/sessions/{sid}/turns/t_1", headers=_headers())
    assert del_2.status_code == 404
    assert [m["_turn_id"] for m in session.messages] == ["t_2", "t_2"]


def test_subagent_approval_bubbling_reload_and_cleanup(tmp_path: Path):
    ws = tmp_path / "ws"
    ws.mkdir(parents=True, exist_ok=True)
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    cfg_path = data_dir / "config.json"
    cfg_path.write_text(
        json.dumps(
            {
                "auth_token": AUTH_TOKEN,
                "workspaces": [str(ws.resolve())],
                "active_workspace": str(ws.resolve()),
                "model": "deepseek-flash",
                "active_profile_id": "deepseek-flash",
                "model_profiles": [
                    {
                        "id": "reasoner-prof",
                        "name": "Reasoner",
                        "provider": "deepseek",
                        "base_url": "https://api.deepseek.com",
                        "model": "deepseek-reasoner",
                        "inherits_global_key": True,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    store = ConfigStore(data_dir)
    sandbox = SandboxRunner(base_dir=data_dir / "sandbox")
    mgr = SessionManager(store, sandbox_runner=sandbox)

    parent = mgr.create_session(workspace=str(ws), title="Parent")
    child = DeepSeekSession(
        session_id=f"{parent.session_id}_ag_worker_test",
        title="Worker",
        workspace=str(ws),
        approval_mode="ask_writes",
        config_store=store,
        sessions_dir=data_dir / "sessions" / "subagents",
        sandbox_runner=sandbox,
        parent_session_id=parent.session_id,
        parent_session=parent,
        agent_id="ag_worker_test",
        agent_role="auditor",
        profile_id="reasoner-prof",
    )
    assert child.model == "deepseek-reasoner"
    parent.subagents["ag_worker_test"] = child
    child.save_to_disk()
    parent.save_to_disk()
    child_disk_path = child.storage_path
    assert child_disk_path.exists()

    async def _exercise_bubbling():
        req = child._register_approval("run_command", {"command": "echo hi"})
        child._emit_to_self_and_parent("approval_required", {"request_id": req.request_id, **req.payload})
        await_task = asyncio.create_task(child._await_approval(req))
        # Parent summary & events should expose bubbled approval
        assert any(a["request_id"] == req.request_id for a in parent.summary()["pending_approvals"])
        assert any(
            ev["type"] == "approval_required" and ev["data"].get("subagent_id") == "ag_worker_test"
            for ev in parent.events
        )
        assert parent.resolve_approval(req.request_id, allow=True) is True
        allow, _ = await await_task
        assert allow is True

        inter_task = asyncio.create_task(child._request_interaction("Need confirmation", ["yes", "no"]))
        await asyncio.sleep(0)
        inter_list = parent.summary()["pending_interactions"]
        assert inter_list
        inter_id = inter_list[0]["request_id"]
        assert parent.resolve_interaction(inter_id, responses=[{"question": "Need confirmation", "selected_option_ids": ["0"]}]) is True
        ans = await inter_task
        assert ans["responses"][0]["selected_option_ids"] == ["0"]

    asyncio.run(_exercise_bubbling())

    # Reload from disk into a fresh SessionManager and verify subagent restores + cleanup works
    mgr2 = SessionManager(store, sandbox_runner=sandbox)
    reloaded_parent = mgr2.get_session(parent.session_id)
    assert reloaded_parent is not None
    assert "ag_worker_test" in reloaded_parent.subagents

    asyncio.run(mgr2.delete_session(parent.session_id))
    assert not child_disk_path.exists()


def test_security_boundaries_plugins_fs_browser_and_server(audit_app_env):
    app, client, ws, data_dir, cfg_path = audit_app_env
    store = app.state.config_store

    # 1. Plugin directory traversal guard
    ps = PluginService(plugins_dir=data_dir / "plugins", dsh_profile_dir=data_dir / "dsh")
    with pytest.raises(ValueError):
        ps._resolve_plugin_dir("../../evil")

    # 2. FS drive-relative block + non-empty directory rename_or_move_pc_entry
    cfg = store.config
    with pytest.raises(WorkspaceSecurityError):
        resolve_ai_path(ws, "C:relative.txt", allowed_workspaces=cfg.workspaces, ai_access_mode=cfg.ai_access_mode)

    src_dir = ws / "src_folder"
    src_dir.mkdir()
    (src_dir / "a.txt").write_text("alpha", encoding="utf-8")
    dest_parent = ws / "dest_parent"
    dest_parent.mkdir()
    moved = rename_or_move_pc_entry(src_dir, dest_parent / "src_folder", overwrite=False)
    assert Path(moved["path"]).exists()
    assert (Path(moved["path"]) / "a.txt").read_text(encoding="utf-8") == "alpha"
    assert not src_dir.exists()

    # 3. Browser SSRF private/loopback/metadata blocking
    bs = BrowserService(data_dir=data_dir, attachment_service=app.state.attachment_service)
    assert bs.check_url_allowed("http://127.0.0.1:8765/api/settings").allowed is False
    assert bs.check_url_allowed("http://169.254.169.254/latest/meta-data").allowed is False
    assert bs.check_url_allowed("https://example.com/docs").allowed is True

    # 4. .mobileconfig XML escaping + invalid scheme handling
    bad_cfg = client.get(
        "/install.mobileconfig",
        params={"url": "javascript:alert(1)<xml>"},
    )
    assert bad_cfg.status_code == 400

    good_cfg = client.get(
        "/install.mobileconfig",
        params={"url": "https://dsh-pc.tail.ts.net/?a=1&b=<tag>"},
    )
    assert good_cfg.status_code == 200
    ET.fromstring(good_cfg.text)

    # 5. /api/pc/upload traversal stripping, invalid filename, and invalid base64 guard
    up_sanitized = client.post(
        "/api/pc/upload",
        headers=_headers(),
        json={
            "dir_path": str(ws),
            "filename": "../../inside_only.txt",
            "base64_data": base64.b64encode(b"ok").decode("ascii"),
        },
    )
    assert up_sanitized.status_code == 200
    assert Path(up_sanitized.json()["path"]).resolve() == (ws / "inside_only.txt").resolve()

    up_dotdot = client.post(
        "/api/pc/upload",
        headers=_headers(),
        json={
            "dir_path": str(ws),
            "filename": "..",
            "base64_data": base64.b64encode(b"bad").decode("ascii"),
        },
    )
    assert up_dotdot.status_code == 400

    up_bad_b64 = client.post(
        "/api/pc/upload",
        headers=_headers(),
        json={
            "dir_path": str(ws),
            "filename": "good.txt",
            "base64_data": "!!!not_base64!!!",
        },
    )
    assert up_bad_b64.status_code == 400


def test_log_dedup_and_search_nested_snippet(tmp_path: Path):
    install_log_capture()
    handler = get_log_handler()

    test_logger = logging.getLogger("bridge.audit_dedup_probe")
    test_logger.setLevel(logging.INFO)
    test_logger.propagate = True
    test_logger.info("unique_audit_marker_xyz")

    matches = [e for e in handler.query(search="unique_audit_marker_xyz") if e.get("message") == "unique_audit_marker_xyz"]
    assert len(matches) == 1

    # Nested tag inside DDG result__snippet must not truncate snippet
    html = (
        '<div class="result">'
        '<a class="result__a" href="https://example.com/a">Title</a>'
        '<a class="result__snippet">Hello <span class="hi">world</span> after span!</a>'
        "</div>"
    )
    parser = _DuckDuckGoHTMLParser()
    parser.feed(html)
    parser.close()
    assert len(parser.results) == 1
    assert "world" in parser.results[0]["snippet"]
    assert "after span!" in parser.results[0]["snippet"]


def test_web_and_repo_hygiene_consistency():
    repo = Path(__file__).resolve().parent.parent

    index_html = (repo / "web" / "index.html").read_text(encoding="utf-8")
    assert "與" not in index_html

    app_js = (repo / "web" / "app.js").read_text(encoding="utf-8")
    assert '&quot;' in app_js and "&#39;" in app_js
    assert "?force_balance=true" in app_js and "/api/wallet/summary" in app_js
    assert "/activate" not in app_js
    assert "/api/browser/sessions/${encodeURIComponent(browserId)}/${action}" in app_js

    sw_js = (repo / "web" / "sw.js").read_text(encoding="utf-8")
    assert "cache.put" in sw_js

    assert not (repo / "ios-native" / "DeepSeekMobile" / "Views" / "V9FeaturesView.swift").exists()
    assert not (repo / "ios-native" / "DeepSeekMobile" / "Views" / "ChatView.swift").exists()
    assert (repo / "ios-native" / "DeepSeekMobile" / "Views" / "Chat" / "ChatView.swift").exists()
    assert (repo / "ios-native" / "DeepSeekMobile" / "Services" / "BridgeClient+WebSocket.swift").exists()
    assert not (repo / "window_capture.png").exists()
    assert not (repo / "start_bridge.bat").exists()
    assert (repo / "tools" / "cloudflared.exe").exists()

    assert VERSION == "0.9.0"
    assert 'version = "0.9.0"' in (repo / "pyproject.toml").read_text(encoding="utf-8")
    assert "0.9.0" in (repo / "ios-native" / "DeepSeekMobile" / "Info.plist").read_text(encoding="utf-8")
    assert "18" in (repo / "ios-native" / "DeepSeekMobile" / "Info.plist").read_text(encoding="utf-8")
