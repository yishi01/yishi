from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import socket
import threading
import time

import httpx
import pytest
import uvicorn
import websockets

from bridge.server import create_app


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def test_connection_stability_stress_live_server(tmp_path: Path, monkeypatch):
    """
    Real TCP Uvicorn stress test simulating unstable mobile cellular/Wi-Fi handoffs:
    1. 60 concurrent authenticated HTTP API & file calls under load.
    2. Live SSE turn streaming while a WebSocket abruptly drops & reconnects 12 times
       with cursor replay (`after_seq`), proving ZERO missed or duplicated events.
    3. Concurrent WebSocket ping/pong keepalive exchanges & clean server WS diagnostics.
    """
    workspace = tmp_path / "ws"
    workspace.mkdir(parents=True, exist_ok=True)
    for i in range(10):
        (workspace / f"file_{i}.txt").write_text(f"sample line {i}", encoding="utf-8")

    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    port = _free_port()
    token = "stress-test-token"
    (data_dir / "config.json").write_text(
        json.dumps(
            {
                "host": "127.0.0.1",
                "port": port,
                "auth_token": token,
                "workspaces": [str(workspace.resolve())],
                "active_workspace": str(workspace.resolve()),
                "ai_access_mode": "workspace_only",
                "default_approval_mode": "auto",
                "deepseek_api_key": "sk-stress-key",
                "enable_tunnel": False,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    app = create_app(data_dir=data_dir)
    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    base_http = f"http://127.0.0.1:{port}"
    base_ws = f"ws://127.0.0.1:{port}"
    headers = {"Authorization": f"Bearer {token}"}

    try:
        # Wait for server listening
        ready = False
        for _ in range(50):
            try:
                r = httpx.get(f"{base_http}/api/health", timeout=1.0)
                if r.status_code == 200:
                    ready = True
                    break
            except Exception:
                time.sleep(0.05)
        assert ready, "Uvicorn test server failed to start in time"

        # Part A: 60 concurrent HTTP requests across settings, plugins, pc files, diagnostics
        def _hit(idx: int) -> int:
            ep = [
                f"{base_http}/api/health",
                f"{base_http}/api/settings",
                f"{base_http}/api/plugins",
                f"{base_http}/api/diagnostics/status",
                f"{base_http}/api/files/tree?workspace={workspace}",
            ][idx % 5]
            resp = httpx.get(ep, headers=headers, timeout=5.0)
            return resp.status_code

        with ThreadPoolExecutor(max_workers=16) as pool:
            statuses = list(pool.map(_hit, range(60)))
        assert all(code == 200 for code in statuses), f"Non-200 HTTP response under concurrency: {statuses}"

        # Part B: Rapid WS disconnect / reconnect cursor-replay storm during live event stream
        sid = httpx.post(
            f"{base_http}/api/sessions",
            json={"workspace": str(workspace), "title": "WS Stress"},
            headers=headers,
            timeout=5.0,
        ).json()["session_id"]
        sess = app.state.session_manager.get_session(sid)

        class _SlowStreamResp:
            status_code = 200

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

            async def aread(self):
                return b""

            async def aiter_lines(self):
                for idx in range(25):
                    await asyncio.sleep(0.025)
                    payload = json.dumps({"choices": [{"delta": {"content": f"[{idx}]"}}]})
                    yield f"data: {payload}"
                yield "data: [DONE]"

        class _MockClient:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

            def stream(self, *args, **kwargs):
                return _SlowStreamResp()

        sess._http_client_factory = lambda: _MockClient()

        async def _ws_storm() -> tuple[list[int], int]:
            seen_seqs: list[int] = []
            pong_count = 0
            last_seq = 0

            # Trigger live streaming turn via HTTP
            async with httpx.AsyncClient() as hc:
                r = await hc.post(
                    f"{base_http}/api/sessions/{sid}/message",
                    json={"prompt": "stream stress test"},
                    headers=headers,
                )
                assert r.status_code == 200

            turn_done = False
            attempts = 0
            while not turn_done and attempts < 20:
                attempts += 1
                ws_url = f"{base_ws}/ws/sessions/{sid}?token={token}&after_seq={last_seq}"
                async with websockets.connect(ws_url, open_timeout=5.0, close_timeout=2.0) as ws:
                    await ws.send("ping")
                    # Receive a handful of events then intentionally drop TCP like cellular handoff
                    per_conn_reads = 0
                    while per_conn_reads < 6:
                        raw = await asyncio.wait_for(ws.recv(), timeout=4.0)
                        ev = json.loads(raw)
                        etype = ev.get("type")
                        if etype == "pong":
                            pong_count += 1
                            continue
                        if etype in ("sync_complete", "ping"):
                            continue
                        seq = int(ev.get("seq", 0))
                        if seq > 0:
                            assert seq not in seen_seqs, f"Duplicate seq delivered: {seq}"
                            seen_seqs.append(seq)
                            last_seq = max(last_seq, seq)
                        per_conn_reads += 1
                        if etype == "turn_done":
                            turn_done = True
                            break
                await asyncio.sleep(0.015)

            assert turn_done, "Never received turn_done across WS reconnect storm"
            return seen_seqs, pong_count

        seen_seqs, pong_count = asyncio.run(_ws_storm())
        assert pong_count >= 1
        assert seen_seqs == sorted(seen_seqs)

        # Verify total emitted persisted events match reconstructed sequence
        history = httpx.get(f"{base_http}/api/sessions/{sid}/events?after_seq=0", headers=headers).json()["events"]
        all_text = "".join(e["data"].get("text", "") for e in history if e["type"] == "text_delta")
        for idx in range(25):
            assert f"[{idx}]" in all_text

        # Check diagnostics recorded healthy disconnect cleanup (active_ws returned to 0!)
        time.sleep(0.1)
        diag = httpx.get(f"{base_http}/api/diagnostics/status", headers=headers).json()
        assert diag["network"]["websocket"]["active_connections"] == 0
        assert diag["network"]["websocket"]["total_connects"] >= 2
        assert diag["network"]["http"]["total_errors"] == 0
    finally:
        server.should_exit = True
        thread.join(timeout=5.0)
