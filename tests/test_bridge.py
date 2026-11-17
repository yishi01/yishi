"""Comprehensive automated tests for DeepSeek Mobile Bridge (covering SELFCHECK_ISSUES)."""

from __future__ import annotations

import json
import re
import subprocess
import time
from pathlib import Path
from unittest.mock import patch

import httpx
import pytest
from fastapi.testclient import TestClient

from bridge.config import VERSION, BridgeConfig, ConfigStore
from bridge.deepseek_agent import compact_event_stream, sanitize_conversation_messages
from bridge.server import create_app


@pytest.fixture()
def bridge_env(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    (workspace / "hello.py").write_text("print('hello')\n", encoding="utf-8")
    (workspace / "sub").mkdir()
    (workspace / "sub" / "notes.md").write_text("# Notes\nTODO: test mobile\n", encoding="utf-8")
    (workspace / "binary.bin").write_bytes(b"\x00\x01\x02\x03")

    data_dir = tmp_path / "data"
    store = ConfigStore(data_dir=data_dir)
    store.save(
        BridgeConfig(
            auth_token="test-secret-token",
            workspaces=[str(workspace.resolve())],
            deepseek_api_key="sk-test-deepseek-key",
        )
    )
    app = create_app(data_dir=data_dir)
    with TestClient(app) as client:
        yield client, workspace, data_dir


def _headers(token: str = "test-secret-token") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_auth_and_health_endpoints(bridge_env):
    client, _, _ = bridge_env
    for ep in ("/health", "/api/health"):
        r = client.get(ep)
        assert r.status_code == 200
        assert r.json()["status"] == "ok"
        assert r.json()["version"] == VERSION

    assert client.get("/api/settings").status_code == 401
    assert client.get("/api/settings", headers=_headers("wrong")).status_code == 401

    verify_ok = client.post("/api/auth/verify", json={"token": "test-secret-token"})
    assert verify_ok.status_code == 200
    assert verify_ok.json()["ok"] is True

    settings = client.get("/api/settings", headers=_headers()).json()
    assert "auth_token" not in settings
    assert "deepseek_api_key" not in settings
    assert settings["has_api_key"] is True
    assert settings["deepseek_base_url"] == "https://api.deepseek.com"
    assert settings["model"] == "deepseek-chat"

    upd = client.put(
        "/api/settings",
        json={
            "model": "deepseek-reasoner",
            "deepseek_base_url": "https://api.deepseek.com/v1",
            "default_approval_mode": "ask_writes",
        },
        headers=_headers(),
    )
    assert upd.status_code == 200
    assert upd.json()["model"] == "deepseek-reasoner"
    assert upd.json()["deepseek_base_url"] == "https://api.deepseek.com/v1"


def test_file_sandbox_and_crud(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    res = client.get("/api/files/tree", params={"workspace": ws}, headers=_headers())
    assert res.status_code == 200
    names = [e["name"] for e in res.json()["entries"]]
    assert "sub" in names and "hello.py" in names

    assert (
        client.get(
            "/api/files/read",
            params={"workspace": ws, "path": "../data/config.json"},
            headers=_headers(),
        ).status_code
        == 403
    )
    assert (
        client.get(
            "/api/files/read",
            params={"workspace": ws, "path": "C:/Windows/win.ini"},
            headers=_headers(),
        ).status_code
        == 403
    )

    bin_res = client.get(
        "/api/files/read",
        params={"workspace": ws, "path": "binary.bin"},
        headers=_headers(),
    )
    assert bin_res.status_code == 200
    assert bin_res.json()["is_binary"] is True

    read_res = client.get(
        "/api/files/read",
        params={"workspace": ws, "path": "hello.py"},
        headers=_headers(),
    ).json()
    mtime = read_res["mtime"]

    time.sleep(0.03)
    (workspace / "hello.py").write_text("print('external')\n", encoding="utf-8")

    conflict = client.put(
        "/api/files/write",
        json={
            "workspace": ws,
            "path": "hello.py",
            "content": "print('mobile')\n",
            "expected_mtime": mtime,
            "force": False,
        },
        headers=_headers(),
    )
    assert conflict.status_code == 409

    forced = client.put(
        "/api/files/write",
        json={
            "workspace": ws,
            "path": "hello.py",
            "content": "print('mobile')\n",
            "expected_mtime": mtime,
            "force": True,
        },
        headers=_headers(),
    )
    assert forced.status_code == 200
    assert (workspace / "hello.py").read_text(encoding="utf-8") == "print('mobile')\n"

    # Create / rename / delete
    assert (
        client.post(
            "/api/files/create",
            json={"workspace": ws, "path": "dir1/a.txt", "content": "123"},
            headers=_headers(),
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/files/rename",
            json={"workspace": ws, "old_path": "dir1/a.txt", "new_path": "dir1/b.txt"},
            headers=_headers(),
        ).status_code
        == 200
    )
    assert (
        client.delete(
            "/api/files/delete",
            params={"workspace": ws, "path": "dir1"},
            headers=_headers(),
        ).status_code
        == 200
    )

    search = client.get(
        "/api/files/search",
        params={"workspace": ws, "q": "TODO"},
        headers=_headers(),
    )
    assert search.status_code == 200
    assert any(m["path"] == "sub/notes.md" for m in search.json()["matches"])


def test_git_diff_and_non_repo_reason(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    # Before git init: structured reason=not_a_repo
    non_git = client.get("/api/git/status", params={"workspace": ws}, headers=_headers())
    assert non_git.status_code == 200
    assert non_git.json()["is_git_repo"] is False
    assert non_git.json()["reason"] == "not_a_repo"

    subprocess.run(["git", "-C", ws, "init"], check=True, capture_output=True)
    subprocess.run(["git", "-C", ws, "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", ws, "config", "user.name", "Test"], check=True)
    subprocess.run(["git", "-C", ws, "add", "hello.py"], check=True)
    subprocess.run(["git", "-C", ws, "commit", "-m", "init"], check=True, capture_output=True)

    (workspace / "hello.py").write_text("print('changed on mobile')\n", encoding="utf-8")

    git_res = client.get("/api/git/status", params={"workspace": ws}, headers=_headers())
    assert git_res.status_code == 200
    payload = git_res.json()
    assert payload["is_git_repo"] is True
    assert any(f["path"] == "hello.py" for f in payload["files"])
    assert "changed on mobile" in payload["diff"]


def test_deepseek_streaming_and_tool_execution(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    created = client.post(
        "/api/sessions",
        json={"workspace": ws, "title": "DeepSeek Tool Test", "model": "deepseek-reasoner"},
        headers=_headers(),
    )
    assert created.status_code == 200
    sid = created.json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)

    call_count = 0

    def mock_handler(request: httpx.Request) -> httpx.Response:
        nonlocal call_count
        call_count += 1
        assert request.headers["Authorization"] == "Bearer sk-test-deepseek-key"
        body = json.loads(request.content.decode("utf-8"))
        assert body["model"] == "deepseek-reasoner"

        if call_count == 1:
            chunks = [
                {"choices": [{"delta": {"reasoning_content": "Let me read hello.py first."}}]},
                {
                    "choices": [
                        {
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_1",
                                        "type": "function",
                                        "function": {
                                            "name": "read_file",
                                            "arguments": '{"path": "hello.py"}',
                                        },
                                    }
                                ]
                            }
                        }
                    ]
                },
            ]
        else:
            assert any(m.get("role") == "tool" and "hello" in m.get("content", "") for m in body["messages"])
            chunks = [
                {"choices": [{"delta": {"content": "hello.py prints hello."}}]},
            ]

        sse = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
        return httpx.Response(200, text=sse)

    sess._http_client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(mock_handler)
    )

    msg_res = client.post(
        f"/api/sessions/{sid}/message",
        json={"prompt": "Read hello.py"},
        headers=_headers(),
    )
    assert msg_res.status_code == 200

    for _ in range(40):
        ev_res = client.get(
            f"/api/sessions/{sid}/events",
            params={"after_seq": 0},
            headers=_headers(),
        ).json()
        if any(e["type"] == "turn_done" for e in ev_res["events"]):
            break
        time.sleep(0.05)

    types_seen = [e["type"] for e in ev_res["events"]]
    assert "thought_delta" in types_seen, f"Events were: {ev_res['events']}"
    assert "tool_call" in types_seen
    assert "tool_result" in types_seen
    assert "text_delta" in types_seen
    assert "turn_done" in types_seen


def test_approval_and_ask_user_roundtrip_and_bark(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    client.put(
        "/api/settings",
        json={"bark_url": "https://api.day.app/testkey"},
        headers=_headers(),
    )

    sid = client.post(
        "/api/sessions",
        json={"workspace": ws, "title": "HITL Test", "approval_mode": "ask_commands"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)

    step = 0

    def mock_handler(request: httpx.Request) -> httpx.Response:
        nonlocal step
        step += 1
        if step == 1:
            chunks = [
                {
                    "choices": [
                        {
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_cmd",
                                        "type": "function",
                                        "function": {
                                            "name": "run_command",
                                            "arguments": '{"command": "python -m pytest --version"}',
                                        },
                                    }
                                ]
                            }
                        }
                    ]
                }
            ]
        elif step == 2:
            chunks = [
                {
                    "choices": [
                        {
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "call_ask",
                                        "type": "function",
                                        "function": {
                                            "name": "ask_user",
                                            "arguments": '{"question": "Choose env", "options": ["dev", "prod"]}',
                                        },
                                    }
                                ]
                            }
                        }
                    ]
                }
            ]
        else:
            chunks = [{"choices": [{"delta": {"content": "All interactive steps completed."}}]}]
        sse = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
        return httpx.Response(200, text=sse)

    sess._http_client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(mock_handler)
    )

    bark_urls: list[str] = []

    def fake_urlopen(req, timeout=4):
        bark_urls.append(req.full_url)

        class _Dummy:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

        return _Dummy()

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        client.post(
            f"/api/sessions/{sid}/message",
            json={"prompt": "Run command and ask me"},
            headers=_headers(),
        )

        # 1. Wait for pending approval on run_command
        req_id = None
        for _ in range(40):
            s_info = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()["session"]
            if s_info["pending_approvals"]:
                req_id = s_info["pending_approvals"][0]["request_id"]
                break
            time.sleep(0.05)
        assert req_id is not None

        # Approve command execution
        app_res = client.post(
            f"/api/sessions/{sid}/approvals/{req_id}",
            json={"allow": True},
            headers=_headers(),
        )
        assert app_res.status_code == 200

        # 2. Wait for pending interaction on ask_user
        inter_id = None
        for _ in range(60):
            s_info = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()["session"]
            if s_info["pending_interactions"]:
                inter_id = s_info["pending_interactions"][0]["request_id"]
                break
            time.sleep(0.05)
        assert inter_id is not None

        int_res = client.post(
            f"/api/sessions/{sid}/interactions/{inter_id}",
            json={"responses": [{"selected_option_ids": ["0"], "freeform_response": "dev"}]},
            headers=_headers(),
        )
        assert int_res.status_code == 200

        # 3. Wait for turn_done
        for _ in range(60):
            ev_res = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()
            if any(e["type"] == "turn_done" for e in ev_res["events"]):
                break
            time.sleep(0.05)

    events = ev_res["events"]
    assert any(e["type"] == "approval_resolved" and e["data"]["allow"] is True for e in events)
    assert any(e["type"] == "interaction_resolved" for e in events)
    assert any("pytest" in str(e["data"].get("result", "")) for e in events if e["type"] == "tool_result")
    assert len(bark_urls) >= 1


def test_websocket_cursor_replay_pwa_and_version_consistency(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    sid = client.post(
        "/api/sessions",
        json={"workspace": ws, "title": "WS Replay"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)
    sess.emit_event("user_message", {"text": "hi"})
    sess.emit_event("text_delta", {"text": "world"})
    sess.emit_event("turn_done", {"stop_reason": "done"})

    with client.websocket_connect(f"/ws/sessions/{sid}?token=test-secret-token&after_seq=1") as ws_conn:
        m1 = ws_conn.receive_json()
        m2 = ws_conn.receive_json()
        m3 = ws_conn.receive_json()
        assert m1["seq"] == 2
        assert m2["seq"] == 3
        assert m3["type"] == "sync_complete"

    # PWA & Version consistency checks
    root = Path(__file__).resolve().parents[1]
    plugin = json.loads((root / "plugin.json").read_text(encoding="utf-8"))
    assert plugin["version"] == VERSION

    sw_text = (root / "web" / "sw.js").read_text(encoding="utf-8")
    assert f"v{VERSION}" in sw_text

    html_text = (root / "web" / "index.html").read_text(encoding="utf-8")
    app_js = (root / "web" / "app.js").read_text(encoding="utf-8")
    html_ids = set(re.findall(r'id="([^"]+)"', html_text))
    referenced_ids = set(re.findall(r'\$\("([^"]+)"\)', app_js))
    missing_ids = referenced_ids - html_ids
    assert not missing_ids, f"Missing DOM IDs in index.html: {missing_ids}"


def test_transient_network_retry_and_non_empty_error(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    sid = client.post(
        "/api/sessions",
        json={"workspace": ws, "title": "Retry Test"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)

    attempts = 0

    def flaky_handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            # Exact empty-string ReadError that previously caused '未知错误'
            raise httpx.ReadError("")
        chunks = [{"choices": [{"delta": {"content": "Recovered after retry!"}}]}]
        sse = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
        return httpx.Response(200, text=sse)

    sess._http_client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(flaky_handler)
    )

    client.post(f"/api/sessions/{sid}/message", json={"prompt": "test retry"}, headers=_headers())
    for _ in range(50):
        ev_res = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()
        if any(e["type"] == "turn_done" for e in ev_res["events"]):
            break
        time.sleep(0.05)

    assert attempts == 2
    assert any(
        e["type"] == "text_delta" and "Recovered after retry!" in e["data"].get("full_text", "")
        for e in ev_res["events"]
    )


def test_message_sanitization_and_event_coalescing(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    # 1. Verify broken history (duplicate user + unclosed tool_calls) is repaired
    broken = [
        {"role": "user", "content": "first failed attempt"},
        {"role": "user", "content": "second attempt"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {"id": "tc_1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
                {"id": "tc_2", "type": "function", "function": {"name": "list_directory", "arguments": "{}"}},
            ],
        },
        {"role": "tool", "tool_call_id": "tc_1", "content": '{"ok": true}'},
        # tc_2 is missing because previous turn crashed mid-batch!
        {"role": "user", "content": "new question"},
    ]
    repaired = sanitize_conversation_messages(broken)
    assert [m["role"] for m in repaired] == ["user", "assistant", "tool", "tool", "user"]
    assert repaired[0]["content"] == "second attempt"
    assert repaired[3]["tool_call_id"] == "tc_2"

    # 2. Verify 50 streaming deltas coalesce into 1 stored event
    sid = client.post(
        "/api/sessions",
        json={"workspace": ws, "title": "Coalesce Test"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)
    for i in range(50):
        sess.emit_event("thought_delta", {"text": f"t{i} "}, persist=False)
    for i in range(50):
        sess.emit_event("text_delta", {"text": f"w{i} "}, persist=False)

    assert len(sess.events) == 2
    assert sess.events[0]["type"] == "thought_delta"
    assert sess.events[0]["data"]["full_text"].startswith("t0 t1 ")
    assert sess.events[1]["type"] == "text_delta"
    assert sess.events[1]["data"]["full_text"].startswith("w0 w1 ")


def test_batch_multi_tool_approvals(bridge_env):
    client, workspace, _ = bridge_env
    ws = str(workspace.resolve())

    sid = client.post(
        "/api/sessions",
        json={"workspace": ws, "title": "Batch Approval Test", "approval_mode": "ask_commands"},
        headers=_headers(),
    ).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)

    step = 0

    def mock_handler(request: httpx.Request) -> httpx.Response:
        nonlocal step
        step += 1
        if step == 1:
            chunks = [
                {
                    "choices": [
                        {
                            "delta": {
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": "cmd_1",
                                        "type": "function",
                                        "function": {
                                            "name": "run_command",
                                            "arguments": '{"command": "Write-Output one"}',
                                        },
                                    },
                                    {
                                        "index": 1,
                                        "id": "cmd_2",
                                        "type": "function",
                                        "function": {
                                            "name": "run_command",
                                            "arguments": '{"command": "Write-Output two"}',
                                        },
                                    },
                                ]
                            }
                        }
                    ]
                }
            ]
        else:
            chunks = [{"choices": [{"delta": {"content": "Both commands ran."}}]}]
        sse = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
        return httpx.Response(200, text=sse)

    sess._http_client_factory = lambda: httpx.AsyncClient(
        transport=httpx.MockTransport(mock_handler)
    )

    client.post(f"/api/sessions/{sid}/message", json={"prompt": "Run two commands"}, headers=_headers())

    # Both approvals should be registered upfront in the batch
    pending = []
    for _ in range(40):
        s_info = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()["session"]
        pending = s_info["pending_approvals"]
        if len(pending) == 2:
            break
        time.sleep(0.05)
    assert len(pending) == 2

    # Approve all in one click
    res = client.post(
        f"/api/sessions/{sid}/approvals/all",
        json={"allow": True},
        headers=_headers(),
    )
    assert res.status_code == 200

    for _ in range(60):
        ev_res = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()
        if any(e["type"] == "turn_done" for e in ev_res["events"]):
            break
        time.sleep(0.05)

    assert any(
        e["type"] == "text_delta" and "Both commands ran." in e["data"].get("full_text", "")
        for e in ev_res["events"]
    )
