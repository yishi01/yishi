"""Comprehensive automated tests for DeepSeek Mobile Bridge v0.9.0 (Modules A–F)."""

from __future__ import annotations

import asyncio
import base64
import io
import json
from pathlib import Path
import time
from typing import Any

from fastapi.testclient import TestClient
from PIL import Image
import pytest

from bridge.server import create_app

AUTH_TOKEN = "test-v9-secret-token"


def _headers(token: str = AUTH_TOKEN) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _wait_session_idle(client: TestClient, session_id: str, timeout: float = 6.0) -> dict[str, Any]:
    deadline = time.time() + timeout
    last_data: dict[str, Any] = {}
    while time.time() < deadline:
        resp = client.get(f"/api/sessions/{session_id}/events", headers=_headers())
        assert resp.status_code == 200
        last_data = resp.json()
        if last_data["session"]["status"] == "idle":
            return last_data
        time.sleep(0.03)
    return last_data


class _MockSSEStream:
    """Deterministic OpenAI-compatible SSE stream response."""

    status_code = 200

    def __init__(self, chunks: list[dict[str, Any]], delay_sec: float = 0.0) -> None:
        self._chunks = chunks
        self._delay_sec = delay_sec

    async def __aenter__(self) -> "_MockSSEStream":
        return self

    async def __aexit__(self, *args: Any) -> bool:
        return False

    async def aread(self) -> bytes:
        return b""

    async def aiter_lines(self):
        if self._delay_sec > 0:
            await asyncio.sleep(self._delay_sec)
        for ch in self._chunks:
            yield f"data: {json.dumps(ch, ensure_ascii=False)}"
        yield "data: [DONE]"


@pytest.fixture()
def v9_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    ws_a = tmp_path / "workspace_a"
    ws_b = tmp_path / "workspace_b"
    ws_a.mkdir(parents=True, exist_ok=True)
    ws_b.mkdir(parents=True, exist_ok=True)
    (ws_a / "readme_a.md").write_text("# Project Alpha\nAlpha architecture notes.\n", encoding="utf-8")
    (ws_b / "readme_b.md").write_text("# Project Beta\nBeta secret specs.\n", encoding="utf-8")

    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / "config.json").write_text(
        json.dumps(
            {
                "host": "127.0.0.1",
                "port": 8765,
                "auth_token": AUTH_TOKEN,
                "workspaces": [str(ws_a.resolve()), str(ws_b.resolve())],
                "active_workspace": str(ws_a.resolve()),
                "ai_access_mode": "workspace_only",
                "default_approval_mode": "auto",
                "deepseek_api_key": "sk-test-v9-key",
                "deepseek_base_url": "https://api.deepseek.com",
                "model": "deepseek-flash",
                "active_profile_id": "deepseek-flash",
                "enable_tunnel": False,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    app = create_app(data_dir=data_dir)
    with TestClient(app) as client:
        yield client, ws_a, ws_b, data_dir


# =============================================================================
# 1. Module A: Workspace Profiles & Strictly-Scoped Cross-Session Reading
# =============================================================================
def test_module_a_workspace_profiles_and_cross_session_reading(v9_env):
    client, ws_a, ws_b, _data_dir = v9_env

    # 1. Default profile exists on bootstrap
    r_list = client.get("/api/workspace-profiles", headers=_headers())
    assert r_list.status_code == 200
    initial_profiles = r_list.json()["profiles"]
    assert any(p["id"] == "ws_default" for p in initial_profiles)

    # 2. Create Profile A and Profile B
    r_pa = client.post(
        "/api/workspace-profiles",
        json={
            "id": "ws_alpha",
            "name": "Alpha Workspace",
            "icon": "cpu.fill",
            "color": "blue",
            "root_paths": [str(ws_a.resolve())],
            "default_profile_id": "deepseek-flash",
            "default_approval_mode": "auto",
            "shared_notes": "Always follow Alpha conventions.",
            "cross_session_read": True,
        },
        headers=_headers(),
    )
    assert r_pa.status_code == 200
    assert r_pa.json()["profile"]["id"] == "ws_alpha"

    r_pb = client.post(
        "/api/workspace-profiles",
        json={
            "id": "ws_beta",
            "name": "Beta Workspace",
            "icon": "lock.fill",
            "color": "rose",
            "root_paths": [str(ws_b.resolve())],
            "default_profile_id": "deepseek-chat",
            "default_approval_mode": "auto",
            "shared_notes": "Beta isolated project.",
            "cross_session_read": True,
        },
        headers=_headers(),
    )
    assert r_pb.status_code == 200
    assert r_pb.json()["profile"]["id"] == "ws_beta"

    # 3. Create 2 sessions in Profile A (s_a1, s_a2) and 1 session in Profile B (s_b1)
    s_a1 = client.post(
        "/api/sessions",
        json={"workspace_profile_id": "ws_alpha", "title": "Alpha Session 1"},
        headers=_headers(),
    ).json()["session_id"]
    s_a2 = client.post(
        "/api/sessions",
        json={"workspace_profile_id": "ws_alpha", "title": "Alpha Design Spec"},
        headers=_headers(),
    ).json()["session_id"]
    s_b1 = client.post(
        "/api/sessions",
        json={"workspace_profile_id": "ws_beta", "title": "Beta Secret Chat"},
        headers=_headers(),
    ).json()["session_id"]

    # Populate Session A2 with dialogue & a file artifact, and Session B1 with secret dialogue
    sess_a2 = client.app.state.session_manager.get_session(s_a2)
    sess_a2.messages = [
        {"role": "user", "content": "What is the Alpha port number?"},
        {"role": "assistant", "content": "The Alpha port number is 9091."},
    ]
    sess_a2.emit_event(
        "file_artifact",
        {
            "id": "art_alpha_1",
            "name": "readme_a.md",
            "path": str((ws_a / "readme_a.md").resolve()),
            "title": "Alpha Readme",
            "summary": "Architecture doc",
            "size": 36,
            "ext": ".md",
            "mode": "review",
            "is_text": True,
            "preview": "# Project Alpha",
        },
    )
    sess_a2.save_to_disk()

    sess_b1 = client.app.state.session_manager.get_session(s_b1)
    sess_b1.messages = [
        {"role": "user", "content": "Beta launch code"},
        {"role": "assistant", "content": "BETA-SECRET-999"},
    ]
    sess_b1.save_to_disk()

    # 4. Agent in Session A1 calls list_workspace_sessions, read_session_transcript, list_session_artifacts
    sess_a1 = client.app.state.session_manager.get_session(s_a1)

    list_res = json.loads(
        asyncio.run(sess_a1._execute_tool("list_workspace_sessions", json.dumps({"query": "Alpha"})))
    )
    listed_ids = [item["session_id"] for item in list_res["sessions"]]
    assert s_a2 in listed_ids
    assert s_b1 not in listed_ids

    read_a2 = json.loads(
        asyncio.run(sess_a1._execute_tool("read_session_transcript", json.dumps({"session_id": s_a2})))
    )
    assert read_a2["session_id"] == s_a2
    assert any("9091" in t["content"] for t in read_a2["turns"])

    arts_a2 = json.loads(
        asyncio.run(sess_a1._execute_tool("list_session_artifacts", json.dumps({"session_id": s_a2})))
    )
    assert any(a["name"] == "readme_a.md" for a in arts_a2["artifacts"])

    # 5. Attempting to read Session B1 (in Profile B) from Session A1 is strictly forbidden
    read_b1 = json.loads(
        asyncio.run(sess_a1._execute_tool("read_session_transcript", json.dumps({"session_id": s_b1})))
    )
    assert "error" in read_b1
    assert "BETA-SECRET-999" not in json.dumps(read_b1)

    # 6. Disabling cross_session_read on Profile A blocks cross-session reading
    upd_pa = client.put(
        "/api/workspace-profiles/ws_alpha",
        json={"cross_session_read": False},
        headers=_headers(),
    )
    assert upd_pa.status_code == 200
    assert upd_pa.json()["profile"]["cross_session_read"] is False

    blocked_res = json.loads(
        asyncio.run(sess_a1._execute_tool("read_session_transcript", json.dumps({"session_id": s_a2})))
    )
    assert "error" in blocked_res

    # 7. Move Session B1 to ws_alpha and verify /api/sessions?workspace_profile_id=ws_alpha
    mv = client.post(
        f"/api/sessions/{s_b1}/move",
        json={"workspace_profile_id": "ws_alpha"},
        headers=_headers(),
    )
    assert mv.status_code == 200
    assert mv.json()["workspace_profile_id"] == "ws_alpha"
    alpha_sessions = client.get(
        "/api/sessions",
        params={"workspace_profile_id": "ws_alpha"},
        headers=_headers(),
    ).json()["sessions"]
    assert any(s["session_id"] == s_b1 for s in alpha_sessions)


# =============================================================================
# 2. Module B: Image Attachments, Native PC Screenshot & DeepSeek Vision Switch
# =============================================================================
def test_module_b_attachments_screenshot_and_deepseek_vision(v9_env):
    client, ws_a, _ws_b, _data_dir = v9_env

    # 1. Upload a real PNG image via POST /api/attachments
    img = Image.new("RGB", (320, 240), color=(37, 99, 235))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    b64_png = base64.b64encode(buf.getvalue()).decode("ascii")

    r_up = client.post(
        "/api/attachments",
        json={"filename": "diagram.png", "base64_data": b64_png, "session_id": "global"},
        headers=_headers(),
    )
    assert r_up.status_code == 200
    att_meta = r_up.json()["attachment"]
    att_id = att_meta["att_id"]
    assert att_id.startswith("att_")
    assert att_meta["width"] == 320
    assert att_meta["height"] == 240

    # Verify GET /api/attachments/{att_id} and /thumb
    r_raw = client.get(f"/api/attachments/{att_id}", headers=_headers())
    assert r_raw.status_code == 200
    assert len(r_raw.content) > 50

    r_thumb = client.get(f"/api/attachments/{att_id}/thumb", headers=_headers())
    assert r_thumb.status_code == 200
    assert r_thumb.headers["content-type"] == "image/jpeg"

    # 2. Test POST /api/pc/screenshot
    r_shot = client.post(
        "/api/pc/screenshot",
        json={"target": "full", "session_id": "global"},
        headers=_headers(),
    )
    assert r_shot.status_code == 200
    shot_meta = r_shot.json()["attachment"]
    assert shot_meta["att_id"].startswith("att_")
    assert shot_meta["source"] == "pc_screenshot"

    # 3. Send message with attachment on non-vision profile (deepseek-reasoner) ->
    #    verifies auto-switch to deepseek-flash (Decision Q2 ★A) & multimodal image_url payload!
    captured_bodies: list[dict[str, Any]] = []

    class _MockVisionClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        def stream(self, method: str, url: str, headers: Any = None, json: dict[str, Any] | None = None):
            captured_bodies.append(json or {})
            return _MockSSEStream(
                [
                    {"choices": [{"delta": {"content": "I see a blue 320x240 diagram."}}]},
                    {"choices": [], "usage": {"prompt_tokens": 120, "completion_tokens": 12}},
                ]
            )

    sid = client.post(
        "/api/sessions",
        json={
            "workspace": str(ws_a),
            "title": "Vision Test",
            "profile_id": "deepseek-reasoner",
            "model": "deepseek-reasoner",
        },
        headers=_headers(),
    ).json()["session_id"]

    sess = client.app.state.session_manager.get_session(sid)
    sess._http_client_factory = lambda: _MockVisionClient()

    r_msg = client.post(
        f"/api/sessions/{sid}/message",
        json={
            "prompt": "Describe this diagram",
            "profile_id": "deepseek-reasoner",
            "model": "deepseek-reasoner",
            "attachments": [att_id],
        },
        headers=_headers(),
    )
    assert r_msg.status_code == 200
    evs_payload = _wait_session_idle(client, sid)
    events = evs_payload["events"]

    # Verify model_auto_switched event was emitted
    switched_evs = [e for e in events if e["type"] == "model_auto_switched"]
    assert len(switched_evs) >= 1
    assert switched_evs[0]["data"]["to_model"] == "deepseek-flash"

    # Verify upstream received OpenAI-compatible multimodal content list with image_url
    assert len(captured_bodies) == 1
    sent_body = captured_bodies[0]
    assert sent_body["model"] == "deepseek-flash"
    user_msgs = [m for m in sent_body["messages"] if m["role"] == "user"]
    assert isinstance(user_msgs[-1]["content"], list)
    block_types = [b["type"] for b in user_msgs[-1]["content"]]
    assert "text" in block_types
    assert "image_url" in block_types


# =============================================================================
# 3. Module C: Session Rename & Turn Operations (Delete, Edit, Regenerate)
# =============================================================================
def test_module_c_turn_operations_rename_delete_edit_regenerate(v9_env):
    client, ws_a, _ws_b, _data_dir = v9_env

    call_counter = 0

    class _MockTurnClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        def stream(self, method: str, url: str, headers: Any = None, json: dict[str, Any] | None = None):
            nonlocal call_counter
            call_counter += 1
            last_user = [m for m in (json or {}).get("messages", []) if m.get("role") == "user"][-1]["content"]
            return _MockSSEStream(
                [
                    {"choices": [{"delta": {"content": f"Resp#{call_counter}({last_user})"}}]},
                ]
            )

    sid = client.post(
        "/api/sessions",
        json={"workspace": str(ws_a), "title": "Initial Title"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)
    sess._http_client_factory = lambda: _MockTurnClient()

    # 1. PATCH /api/sessions/{sid} rename
    r_ren = client.patch(
        f"/api/sessions/{sid}",
        json={"title": "Renamed Session Title"},
        headers=_headers(),
    )
    assert r_ren.status_code == 200
    assert r_ren.json()["title"] == "Renamed Session Title"

    # 2. Run Turn 1 and Turn 2
    t1_resp = client.post(
        f"/api/sessions/{sid}/message",
        json={"prompt": "TurnOne"},
        headers=_headers(),
    ).json()
    turn_id_1 = t1_resp["turn_id"]
    assert turn_id_1.startswith("turn_")
    _wait_session_idle(client, sid)

    t2_resp = client.post(
        f"/api/sessions/{sid}/message",
        json={"prompt": "TurnTwo"},
        headers=_headers(),
    ).json()
    turn_id_2 = t2_resp["turn_id"]
    assert turn_id_2.startswith("turn_")
    _wait_session_idle(client, sid)

    # 3. Regenerate Turn 2 -> replaces Turn 2 response with a fresh call
    r_regen = client.post(
        f"/api/sessions/{sid}/turns/{turn_id_2}/regenerate",
        json={},
        headers=_headers(),
    )
    assert r_regen.status_code == 200
    turn_id_2_new = r_regen.json()["turn_id"]
    evs_after_regen = _wait_session_idle(client, sid)["events"]
    assert any(e["type"] == "turns_truncated" for e in evs_after_regen)
    text_deltas = [e["data"].get("text", "") for e in evs_after_regen if e["type"] == "text_delta"]
    assert any("Resp#3(TurnTwo)" in t for t in text_deltas)

    # 4. Edit Turn 1 -> truncates Turn 1 & Turn 2 and re-runs from Turn 1 with edited text
    r_edit = client.post(
        f"/api/sessions/{sid}/turns/{turn_id_1}/edit",
        json={"text": "TurnOneEdited"},
        headers=_headers(),
    )
    assert r_edit.status_code == 200
    turn_id_1_edited = r_edit.json()["turn_id"]
    evs_after_edit = _wait_session_idle(client, sid)["events"]
    user_msgs = [e for e in evs_after_edit if e["type"] == "user_message"]
    assert len(user_msgs) == 1
    assert user_msgs[0]["data"]["text"] == "TurnOneEdited"
    assert turn_id_2_new not in [m.get("_turn_id") for m in sess.messages]

    # 5. Delete Turn 1 Edited
    r_del = client.delete(
        f"/api/sessions/{sid}/turns/{turn_id_1_edited}",
        headers=_headers(),
    )
    assert r_del.status_code == 200
    assert len(sess.messages) == 0


# =============================================================================
# 4. Module D: Multi-Agent Team (`spawn_agents`, `wait_agents`, `/agents`)
# =============================================================================
def test_module_d_agent_team_spawn_wait_and_cancel(v9_env):
    client, ws_a, _ws_b, _data_dir = v9_env

    main_round = 0

    class _MockTeamClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        def stream(self, method: str, url: str, headers: Any = None, json: dict[str, Any] | None = None):
            nonlocal main_round
            body = json or {}
            sys_prompt = body.get("messages", [{}])[0].get("content", "")

            # Sub-agent execution path
            if "Sub-Agent Role:" in sys_prompt:
                role_line = [ln for ln in sys_prompt.splitlines() if ln.startswith("Sub-Agent Role:")][0]
                role_name = role_line.split(":", 1)[1].strip()
                return _MockSSEStream(
                    [
                        {"choices": [{"delta": {"content": f"[{role_name}] Completed analysis successfully."}}]},
                        {"choices": [], "usage": {"prompt_tokens": 60, "completion_tokens": 15}},
                    ]
                )

            # Main coordinator agent path
            main_round += 1
            if main_round == 1:
                tc_args = json_dumps_compact(
                    {
                        "agents": [
                            {"agent_id": "ag_res", "role": "Researcher", "task": "Inspect readme_a.md"},
                            {"agent_id": "ag_rev", "role": "Reviewer", "task": "Audit architecture"},
                        ]
                    }
                )
                return _MockSSEStream(
                    [
                        {
                            "choices": [
                                {
                                    "delta": {
                                        "tool_calls": [
                                            {
                                                "index": 0,
                                                "id": "call_spawn_1",
                                                "type": "function",
                                                "function": {"name": "spawn_agents", "arguments": tc_args},
                                            }
                                        ]
                                    }
                                }
                            ]
                        }
                    ]
                )
            if main_round == 2:
                wait_args = json_dumps_compact({"agent_ids": ["ag_res", "ag_rev"], "timeout_sec": 10})
                return _MockSSEStream(
                    [
                        {
                            "choices": [
                                {
                                    "delta": {
                                        "tool_calls": [
                                            {
                                                "index": 0,
                                                "id": "call_wait_1",
                                                "type": "function",
                                                "function": {"name": "wait_agents", "arguments": wait_args},
                                            }
                                        ]
                                    }
                                }
                            ]
                        }
                    ]
                )
            return _MockSSEStream(
                [
                    {"choices": [{"delta": {"content": "Both Researcher and Reviewer finished!"}}]},
                ]
            )

    def json_dumps_compact(obj: Any) -> str:
        return json.dumps(obj, ensure_ascii=False)

    sid = client.post(
        "/api/sessions",
        json={"workspace": str(ws_a), "title": "Team Session"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)
    sess._http_client_factory = lambda: _MockTeamClient()

    client.post(
        f"/api/sessions/{sid}/message",
        json={"prompt": "Run parallel subagents"},
        headers=_headers(),
    )
    evs_payload = _wait_session_idle(client, sid)
    events = evs_payload["events"]

    team_evs = [e for e in events if e["type"] == "agent_team_update"]
    assert len(team_evs) >= 2

    # Check GET /api/sessions/{sid}/agents
    r_agents = client.get(f"/api/sessions/{sid}/agents", headers=_headers())
    assert r_agents.status_code == 200
    agents_list = r_agents.json()["agents"]
    assert len(agents_list) == 2
    roles = {a["agent_id"]: a for a in agents_list}
    assert roles["ag_res"]["status"] in ("done", "idle")
    assert "Researcher" in roles["ag_res"]["summary_text"]
    assert roles["ag_rev"]["status"] in ("done", "idle")
    assert "Reviewer" in roles["ag_rev"]["summary_text"]

    # Also verify POST /api/sessions/{sid}/agents/{agent_id}/cancel endpoint
    r_cancel = client.post(f"/api/sessions/{sid}/agents/ag_res/cancel", headers=_headers())
    assert r_cancel.status_code == 200
    assert r_cancel.json()["ok"] is True


# =============================================================================
# 5. Module E: API Wallet, Token Usage Ledger & Auto-Downgrade
# =============================================================================
def test_module_e_wallet_usage_ledger_and_auto_downgrade(v9_env):
    client, ws_a, _ws_b, _data_dir = v9_env

    captured_models: list[str] = []

    class _MockWalletClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        def stream(self, method: str, url: str, headers: Any = None, json: dict[str, Any] | None = None):
            body = json or {}
            captured_models.append(body.get("model", ""))
            return _MockSSEStream(
                [
                    {"choices": [{"delta": {"content": "Ledger recorded response."}}]},
                    {
                        "choices": [],
                        "usage": {
                            "prompt_tokens": 1000,
                            "prompt_cache_hit_tokens": 400,
                            "completion_tokens": 500,
                        },
                    },
                ]
            )

    sid = client.post(
        "/api/sessions",
        json={
            "workspace": str(ws_a),
            "title": "Wallet Session",
            "profile_id": "deepseek-reasoner",
            "model": "deepseek-reasoner",
        },
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)
    sess._http_client_factory = lambda: _MockWalletClient()

    # 1. Run a turn on deepseek-reasoner and verify turn_done carries exact usage & cost
    client.post(
        f"/api/sessions/{sid}/message",
        json={"prompt": "Calculate tokens", "profile_id": "deepseek-reasoner", "model": "deepseek-reasoner"},
        headers=_headers(),
    )
    evs = _wait_session_idle(client, sid)["events"]
    turn_done_ev = [e for e in evs if e["type"] == "turn_done"][-1]
    usage_info = turn_done_ev["data"]["usage"]
    assert usage_info["prompt_tokens"] == 1000
    assert usage_info["cache_hit_tokens"] == 400
    assert usage_info["completion_tokens"] == 500
    assert usage_info["cost"] > 0

    # 2. Verify GET /api/wallet/summary and GET /api/wallet/usage
    summary = client.get("/api/wallet/summary", headers=_headers()).json()
    assert summary["today"]["prompt_tokens"] >= 1000
    assert summary["today"]["completion_tokens"] >= 500
    assert summary["today"]["cost"] > 0

    usage_q = client.get("/api/wallet/usage?group_by=model", headers=_headers()).json()
    assert any(item["key"] == "deepseek-reasoner" for item in usage_q["items"])

    # 3. Configure low manual_balance below threshold -> triggers auto-downgrade to deepseek-flash
    r_rules = client.put(
        "/api/wallet/rules",
        json={
            "enabled": True,
            "balance_below": 10.0,
            "daily_spend_above": 50.0,
            "fallback_profile_id": "deepseek-flash",
            "manual_balance": 2.0,
            "notify_bark": False,
        },
        headers=_headers(),
    )
    assert r_rules.status_code == 200

    client.post(
        f"/api/sessions/{sid}/message",
        json={"prompt": "Second turn with low balance", "profile_id": "deepseek-reasoner", "model": "deepseek-reasoner"},
        headers=_headers(),
    )
    evs2 = _wait_session_idle(client, sid)["events"]
    assert any(e["type"] == "model_auto_switched" for e in evs2)
    assert captured_models[-1] == "deepseek-flash"


# =============================================================================
# 6. Module F: Built-in Collaborative Browser & Security Gate
# =============================================================================
def test_module_f_collaborative_browser_and_security_gate(v9_env):
    client, ws_a, _ws_b, _data_dir = v9_env

    mock_pages = {
        "https://example.com": (
            200,
            "https://example.com",
            "<html><head><title>Example Home</title></head><body>"
            "<h1>Welcome to Example</h1>"
            "<p>Interactive collaborative browser test.</p>"
            "<a href='/docs'>Documentation</a>"
            "<form action='/search' method='GET'>"
            "<input type='text' name='q' placeholder='Search query' />"
            "<button type='submit'>Go</button>"
            "</form></body></html>",
        ),
        "https://example.com/docs": (
            200,
            "https://example.com/docs",
            "<html><head><title>Docs Portal</title></head><body><h1>Docs</h1><p>API Reference</p></body></html>",
        ),
        "https://example.com/login": (
            200,
            "https://example.com/login",
            "<html><head><title>Login</title></head><body>"
            "<input type='text' name='username' />"
            "<input type='password' name='password' />"
            "</body></html>",
        ),
    }

    async def mock_fetcher(url: str) -> tuple[int, str, str]:
        base = url.split("?")[0]
        return mock_pages.get(
            base,
            (200, url, f"<html><head><title>Search</title></head><body><h1>URL: {url}</h1></body></html>"),
        )

    browser_svc = client.app.state.browser_service
    browser_svc.http_fetcher = mock_fetcher

    sid = client.post(
        "/api/sessions",
        json={"workspace": str(ws_a), "title": "Browser Session"},
        headers=_headers(),
    ).json()["session_id"]

    # 1. Create browser session & navigate
    r_create = client.post(
        "/api/browser/sessions",
        json={"session_id": sid, "url": "https://example.com"},
        headers=_headers(),
    )
    assert r_create.status_code == 200
    snap = r_create.json()
    bid = snap["browser_id"]
    assert snap["title"] == "Example Home"
    assert len(snap["elements"]) == 3
    assert base64.b64decode(snap["frame_b64"])[:2] == b"\xff\xd8"

    # 2. Switch control to agent, then perform human click -> auto-takes over control_owner="human"
    client.post(f"/api/browser/sessions/{bid}/control", json={"owner": "agent"}, headers=_headers())
    input_el = snap["elements"][1]
    bx, by, bw, bh = input_el["bbox"]
    r_click = client.post(
        f"/api/browser/sessions/{bid}/input",
        json={"action": "click", "x": bx + bw // 2, "y": by + bh // 2, "actor": "human"},
        headers=_headers(),
    )
    assert r_click.status_code == 200
    assert r_click.json()["control_owner"] == "human"

    # Agent action while human owns control must return paused_by_human=True without mutating page
    r_agent_blocked = client.post(
        f"/api/browser/sessions/{bid}/navigate",
        json={"url": "https://example.com/docs", "actor": "agent"},
        headers=_headers(),
    )
    assert r_agent_blocked.status_code == 200
    assert r_agent_blocked.json()["ok"] is False
    assert r_agent_blocked.json()["paused_by_human"] is True
    assert client.get(f"/api/browser/sessions/{bid}", headers=_headers()).json()["url"] == "https://example.com"

    # Hand control back to agent -> agent clicks link [1] -> navigates to /docs
    client.post(f"/api/browser/sessions/{bid}/control", json={"owner": "agent"}, headers=_headers())
    r_agent_click = client.post(
        f"/api/browser/sessions/{bid}/input",
        json={"action": "click", "element_id": 1, "actor": "agent"},
        headers=_headers(),
    )
    assert r_agent_click.status_code == 200
    assert r_agent_click.json()["url"] == "https://example.com/docs"

    # 3. Navigate to /login with password field -> triggers security gate (human_required=True, control_owner="human")
    r_login = client.post(
        f"/api/browser/sessions/{bid}/navigate",
        json={"url": "https://example.com/login", "actor": "agent"},
        headers=_headers(),
    ).json()
    assert r_login["human_required"] is True
    assert r_login["control_owner"] == "human"
    assert "password" in r_login["human_reason"].lower() or "密码" in r_login["human_reason"]

    # 4. Save browser viewport frame as chat attachment & verify /ws/browser/{browser_id}
    r_shot = client.post(f"/api/browser/sessions/{bid}/screenshot", headers=_headers())
    assert r_shot.status_code == 200
    assert r_shot.json()["att_id"].startswith("att_")

    with client.websocket_connect(f"/ws/browser/{bid}?token={AUTH_TOKEN}") as ws:
        first_frame = ws.receive_json()
        assert first_frame["type"] == "frame"
        assert first_frame["browser_id"] == bid
        ws.send_text("ping")
        pong = ws.receive_json()
        assert pong["type"] == "pong"
