from __future__ import annotations

import asyncio
import base64
import io
import json
from pathlib import Path
import time
import zipfile

import httpx
import pytest
from fastapi.testclient import TestClient

from bridge.config import VERSION
from bridge.server import create_app


def _headers(token: str = "test-v8-token") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def v8_env(tmp_path: Path, monkeypatch):
    workspace = tmp_path / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "hello.txt").write_text("hello", encoding="utf-8")

    dsh_dir = tmp_path / "dsh_desktop_profile"
    dsh_dir.mkdir(parents=True, exist_ok=True)
    (dsh_dir / "package.json").write_text(
        json.dumps(
            {
                "name": "dsh-profile-desktop",
                "dependencies": {"@xiazhi88/dshgo": "^2.0.5"},
                "dsh": {"profile": {"bundles": ["@deepseek-ai/dsh-base", "@xiazhi88/dshgo"]}},
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    (dsh_dir / "cordis.patch.yml").write_text(
        "- id: agent-default-model\n  name: '@deepseek-ai/dsh-agent-default-model'\n  config:\n    model: deepseek-flash\n- id: ui-settings\n  disabled: false\n",
        encoding="utf-8",
    )

    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    (data_dir / "config.json").write_text(
        json.dumps(
            {
                "host": "127.0.0.1",
                "port": 8765,
                "auth_token": "test-v8-token",
                "workspaces": [str(workspace.resolve())],
                "active_workspace": str(workspace.resolve()),
                "ai_access_mode": "workspace_only",
                "default_approval_mode": "auto",
                "deepseek_api_key": "sk-test-global-secret",
                "deepseek_base_url": "https://api.deepseek.com",
                "model": "deepseek-chat",
                "enable_tunnel": False,
                "dsh_profile_dir": str(dsh_dir.resolve()),
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    app = create_app(data_dir=data_dir)
    with TestClient(app) as client:
        yield client, workspace, data_dir, dsh_dir


def test_dsh_plugins_install_configure_and_run_on_pc(v8_env):
    client, workspace, _data_dir, dsh_dir = v8_env

    # 1. Install inline PC plugin with SKILL.md and Python script
    r_inline = client.post(
        "/api/plugins/install",
        json={
            "source_type": "inline",
            "name": "pc-greeter",
            "description": "Greets from PC with plugin config",
            "skill_markdown": "---\nname: pc-greeter\n---\nAlways greet politely.",
            "script_code": (
                "import json, os, sys\n"
                "cfg = json.loads(os.environ.get('DSH_PLUGIN_CONFIG', '{}'))\n"
                "print('GREET:' + cfg.get('prefix', 'hi') + ':' + ' '.join(sys.argv[1:]))\n"
            ),
            "script_language": "python",
            "config": {"prefix": "你好"},
        },
        headers=_headers(),
    )
    assert r_inline.status_code == 200
    assert r_inline.json()["ok"] is True

    # 2. Upload zip bundle plugin from "mobile"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("mybundle/plugin.json", json.dumps({"name": "zip-helper", "version": "1.2.0"}))
        zf.writestr("mybundle/tools/check.py", "print('ZIP_PLUGIN_OK')")
    b64_zip = base64.b64encode(buf.getvalue()).decode("ascii")
    r_zip = client.post(
        "/api/plugins/install",
        json={"source_type": "upload", "filename": "zip-helper.zip", "content_base64": b64_zip},
        headers=_headers(),
    )
    assert r_zip.status_code == 200

    # 3. Verify list + toggle + config update + PC execution
    lst = client.get("/api/plugins", headers=_headers()).json()
    ids = [p["id"] for p in lst["plugins"]]
    assert "pc-greeter" in ids
    assert "zip-helper" in ids
    assert lst["dsh_profile"]["exists"] is True
    assert len(lst["dsh_profile"]["bundles"]) >= 2

    run_res = client.post(
        "/api/plugins/pc-greeter/run",
        json={"args": ["world"]},
        headers=_headers(),
    )
    assert run_res.status_code == 200
    assert run_res.json()["executed_on"] == "PC"
    assert "GREET:你好:world" in run_res.json()["stdout"]

    # Update plugin config & toggle off -> execution blocked while disabled
    client.put("/api/plugins/pc-greeter/config", json={"config": {"prefix": "早安"}}, headers=_headers())
    run_res2 = client.post("/api/plugins/pc-greeter/run", json={"args": ["DSH"]}, headers=_headers())
    assert "GREET:早安:DSH" in run_res2.json()["stdout"]

    client.post("/api/plugins/pc-greeter/toggle", json={"enabled": False}, headers=_headers())
    blocked = client.post("/api/plugins/pc-greeter/run", json={}, headers=_headers())
    assert blocked.status_code == 409

    # 4. Toggle native DSH desktop profile bundle & patch entry
    t_bundle = client.post(
        "/api/plugins/dsh/toggle",
        json={"kind": "bundle", "id": "@xiazhi88/dshgo", "enabled": False},
        headers=_headers(),
    )
    assert t_bundle.status_code == 200
    pkg_after = json.loads((dsh_dir / "package.json").read_text(encoding="utf-8"))
    assert "@xiazhi88/dshgo" not in pkg_after["dsh"]["profile"]["bundles"]

    t_patch = client.put(
        "/api/plugins/dsh/config",
        json={"entry_id": "ui-settings", "enabled": False, "config": {"theme": "glass"}},
        headers=_headers(),
    )
    assert t_patch.status_code == 200
    patch_text = (dsh_dir / "cordis.patch.yml").read_text(encoding="utf-8")
    assert "disabled: true" in patch_text
    assert "glass" in patch_text


def test_sandbox_untrusted_code_self_check_and_secret_isolation(v8_env, monkeypatch):
    client, _workspace, _data_dir, _dsh_dir = v8_env
    monkeypatch.setenv("DEEPSEEK_API_KEY", "sk-must-not-leak")
    monkeypatch.setenv("BRIDGE_SECRET_TOKEN", "top-secret-value")

    # 1. Dangerous script caught by AST/regex self-check
    risky_py = (
        "import os, subprocess\n"
        "print(os.environ.get('DEEPSEEK_API_KEY', 'MISSING'))\n"
        "subprocess.run(['whoami'])\n"
    )
    audit = client.post(
        "/api/sandbox/audit",
        json={"code": risky_py, "language": "python"},
        headers=_headers(),
    ).json()
    assert audit["ok"] is True
    assert audit["risk_level"] in ("high", "critical")
    assert audit["safe_to_auto_run"] is False
    assert any("subprocess" in f["message"] for f in audit["findings"])

    # 2. Even if simulated in PC sandbox, host secrets MUST be scrubbed from os.environ
    probe_py = (
        "import os, socket\n"
        "print('KEY=' + os.environ.get('DEEPSEEK_API_KEY', 'STRIPPED'))\n"
        "print('TOK=' + os.environ.get('BRIDGE_SECRET_TOKEN', 'STRIPPED'))\n"
        "print('SANDBOX=' + os.environ.get('DSH_SANDBOX', '0'))\n"
        "try:\n"
        "    socket.create_connection(('example.com', 80), timeout=1)\n"
        "    print('NET=ALLOWED')\n"
        "except Exception as e:\n"
        "    print('NET=BLOCKED')\n"
    )
    sim = client.post(
        "/api/sandbox/run",
        json={"code": probe_py, "language": "python", "allow_network": False},
        headers=_headers(),
    ).json()
    assert sim["ok"] is True
    assert "KEY=STRIPPED" in sim["stdout"]
    assert "TOK=STRIPPED" in sim["stdout"]
    assert "SANDBOX=1" in sim["stdout"]
    assert "NET=BLOCKED" in sim["stdout"]

    # 3. HTML self-check + preview passthrough
    html_res = client.post(
        "/api/sandbox/run",
        json={"code": "<html><body><h1>Hi</h1><script>fetch('https://evil.example')</script></body></html>", "language": "html"},
        headers=_headers(),
    ).json()
    assert html_res["ok"] is True
    assert html_res["audit"]["risk_level"] == "high"
    assert "<h1>Hi</h1>" in html_res["preview_html"]


def test_settings_secret_preservation_multi_provider_anthropic_and_queue(v8_env, monkeypatch):
    client, workspace, _data_dir, _dsh_dir = v8_env
    cfg = client.app.state.config_store.config

    # Configure Anthropic profile + test key preservation when updating non-secret fields
    profiles = cfg.model_profiles
    for p in profiles:
        if p["id"] == "anthropic-claude":
            p["api_key"] = "sk-ant-real-key"
    upd1 = client.put(
        "/api/settings",
        json={
            "active_profile_id": "anthropic-claude",
            "model_profiles": profiles,
            "search_config": {"enabled": True, "provider": "tavily", "api_key": "tvly-secret-123", "max_results": 4},
        },
        headers=_headers(),
    )
    assert upd1.status_code == 200
    pub1 = upd1.json()
    ant_pub = next(p for p in pub1["model_profiles"] if p["id"] == "anthropic-claude")
    assert ant_pub["has_api_key"] is True
    assert "sk-ant-real-key" not in json.dumps(pub1)
    assert pub1["search_config"]["has_api_key"] is True
    assert "tvly-secret-123" not in json.dumps(pub1)

    # Re-submit settings with empty api_key (simulating UI save) -> secrets MUST NOT be erased!
    pub1["search_config"]["max_results"] = 8
    pub1["search_config"]["api_key"] = ""
    upd2 = client.put(
        "/api/settings",
        json={
            "model_profiles": [{**p, "temperature": 0.4} for p in pub1["model_profiles"]],
            "search_config": pub1["search_config"],
        },
        headers=_headers(),
    ).json()
    ant_after = next(p for p in upd2["model_profiles"] if p["id"] == "anthropic-claude")
    assert ant_after["has_api_key"] is True
    assert ant_after["temperature"] == 0.4
    assert upd2["search_config"]["has_api_key"] is True
    assert upd2["search_config"]["max_results"] == 8

    # Verify Anthropic SSE streaming + FIFO Message Queue execution in order
    captured_requests: list[tuple[str, dict]] = []

    class _MockAnthResp:
        status_code = 200

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def aread(self):
            return b""

        async def aiter_lines(self):
            await asyncio.sleep(0.08)  # Keep turn active long enough to enqueue second message
            prompt_num = len(captured_requests)
            lines = [
                'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
                f'data: {{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"Reply #{prompt_num}"}}}}',
                'data: {"type":"message_stop"}',
            ]
            for ln in lines:
                yield ln

    class _MockAsyncClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        def stream(self, method, url, headers=None, json=None):
            captured_requests.append((url, json or {}))
            return _MockAnthResp()

    sid = client.post("/api/sessions", json={"workspace": str(workspace), "title": "Queue & Claude"}, headers=_headers()).json()["session_id"]
    sess = client.app.state.session_manager.get_session(sid)
    sess._http_client_factory = lambda: _MockAsyncClient()

    # Send #1 (runs immediately), immediately send #2 & #3 -> should queue and auto-drain in FIFO order!
    r1 = client.post(f"/api/sessions/{sid}/message", json={"prompt": "First prompt", "profile_id": "anthropic-claude"}, headers=_headers()).json()
    assert r1["queued"] is False
    r2 = client.post(f"/api/sessions/{sid}/message", json={"prompt": "Second queued prompt"}, headers=_headers()).json()
    assert r2["queued"] is True
    r3 = client.post(f"/api/sessions/{sid}/message", json={"prompt": "Third queued prompt"}, headers=_headers()).json()
    assert r3["queued"] is True

    # Delete #2 before it starts so only #1 then #3 execute!
    q_id_2 = r2["queue_item"]["id"]
    del_res = client.delete(f"/api/sessions/{sid}/queue/{q_id_2}", headers=_headers())
    assert del_res.status_code == 200

    deadline = time.time() + 5.0
    while time.time() < deadline:
        evs = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()
        txt = "".join(e["data"].get("text", "") for e in evs["events"] if e["type"] == "text_delta")
        if "Reply #1" in txt and "Reply #2" in txt and evs["session"]["status"] == "idle":
            break
        time.sleep(0.05)

    assert len(captured_requests) == 2
    assert captured_requests[0][0].endswith("/v1/messages")
    assert len(sess.list_queue()) == 0
    evs = client.get(f"/api/sessions/{sid}/events", headers=_headers()).json()["events"]
    user_texts = [e["data"]["text"] for e in evs if e["type"] == "user_message"]
    assert user_texts == ["First prompt", "Third queued prompt"]


def test_diagnostics_logs_and_selfcheck(v8_env):
    client, _workspace, _data_dir, _dsh_dir = v8_env
    st = client.get("/api/diagnostics/status", headers=_headers())
    assert st.status_code == 200
    body = st.json()
    assert body["version"] == VERSION
    assert body["model"]["api_key_configured"] is True

    sc = client.post("/api/diagnostics/selfcheck", headers=_headers())
    assert sc.status_code == 200
    sc_body = sc.json()
    assert sc_body["ok"] is True
    assert any(c["key"] == "sandbox" and c["status"] == "ok" for c in sc_body["checks"])

    logs = client.get("/api/diagnostics/logs?limit=50", headers=_headers())
    assert logs.status_code == 200
    assert isinstance(logs.json()["logs"], list)
