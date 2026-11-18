"""Message history sanitization, turn-ID backfill, and event compaction helpers."""

from __future__ import annotations

import asyncio
import json
import ssl
from datetime import datetime, timezone
from typing import Any

import httpx


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
