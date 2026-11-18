"""Streaming LLM completion adapters for OpenAI-compatible and Anthropic APIs."""

from __future__ import annotations

import asyncio
import json
import ssl
import uuid
from collections.abc import Callable
from typing import Any

import httpx

from bridge.agent.history import _format_exception
from bridge.agent.tools_schema import RETRYABLE_STATUS_CODES


def _assemble_assistant_message(
    *,
    content_parts: list[str],
    reasoning_parts: list[str],
    tool_calls_acc: dict[int, dict[str, Any]],
    usage_acc: dict[str, Any],
    normalize_empty_args: bool = False,
) -> dict[str, Any]:
    assistant_msg: dict[str, Any] = {
        "role": "assistant",
        "content": "".join(content_parts) if content_parts else None,
    }
    if reasoning_parts:
        assistant_msg["reasoning_content"] = "".join(reasoning_parts)
    if tool_calls_acc:
        if normalize_empty_args:
            for tc in tool_calls_acc.values():
                if not tc["function"]["arguments"].strip():
                    tc["function"]["arguments"] = "{}"
        assistant_msg["tool_calls"] = [tool_calls_acc[k] for k in sorted(tool_calls_acc.keys())]
    comp_chars = (
        sum(len(p) for p in content_parts)
        + sum(len(p) for p in reasoning_parts)
        + sum(len(tc["function"]["arguments"]) for tc in tool_calls_acc.values())
    )
    assistant_msg["_usage"] = usage_acc
    assistant_msg["_completion_chars"] = comp_chars
    return assistant_msg


async def stream_openai_completion(
    client: httpx.AsyncClient,
    api_key: str,
    base_url: str,
    model: str,
    *,
    api_msgs: list[dict[str, Any]],
    tool_schemas: list[dict[str, Any]],
    emit_event: Callable[..., dict[str, Any]],
    temperature: float = 0.7,
    max_tokens: int = 8192,
    supports_tools: bool = True,
    extra_headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    url = f"{base_url}/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        **(extra_headers or {}),
    }
    body: dict[str, Any] = {
        "model": model,
        "messages": api_msgs,
        "stream": True,
    }
    if supports_tools:
        body["tools"] = tool_schemas
    if "reasoner" not in model.lower():
        body["temperature"] = temperature
        if max_tokens > 0:
            body["max_tokens"] = max_tokens

    last_exc: BaseException | None = None
    for attempt in range(1, 4):
        content_parts: list[str] = []
        reasoning_parts: list[str] = []
        tool_calls_acc: dict[int, dict[str, Any]] = {}
        usage_acc: dict[str, Any] = {}
        emitted_any = False

        try:
            async with client.stream("POST", url, headers=headers, json=body) as resp:
                if resp.status_code in RETRYABLE_STATUS_CODES and attempt < 3:
                    await resp.aread()
                    await asyncio.sleep(0.8 * attempt)
                    continue

                if resp.status_code >= 400:
                    err_raw = await resp.aread()
                    err_text = err_raw.decode("utf-8", errors="replace").strip()
                    try:
                        err_json = json.loads(err_text)
                        msg = (
                            err_json.get("error", {}).get("message")
                            if isinstance(err_json.get("error"), dict)
                            else err_text
                        ) or err_text
                    except json.JSONDecodeError:
                        msg = err_text
                    raise RuntimeError(f"Model API ({resp.status_code}): {msg or '请求被拒绝'}")

                async for raw_line in resp.aiter_lines():
                    line = raw_line.strip()
                    if not line or not line.startswith("data:"):
                        continue
                    payload_str = line[5:].strip()
                    if payload_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload_str)
                    except json.JSONDecodeError:
                        continue

                    if isinstance(chunk.get("usage"), dict):
                        usage_acc = dict(chunk["usage"])

                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    delta = choices[0].get("delta") or {}

                    if r_delta := delta.get("reasoning_content"):
                        emitted_any = True
                        reasoning_parts.append(r_delta)
                        emit_event("thought_delta", {"text": r_delta}, persist=False)

                    if c_delta := delta.get("content"):
                        emitted_any = True
                        content_parts.append(c_delta)
                        emit_event("text_delta", {"text": c_delta}, persist=False)

                    for tc in delta.get("tool_calls") or []:
                        emitted_any = True
                        idx = int(tc.get("index", 0))
                        acc = tool_calls_acc.setdefault(
                            idx,
                            {
                                "id": tc.get("id") or f"call_{uuid.uuid4().hex[:8]}",
                                "type": "function",
                                "function": {"name": "", "arguments": ""},
                            },
                        )
                        if tc.get("id"):
                            acc["id"] = tc["id"]
                        fn = tc.get("function") or {}
                        if fn.get("name"):
                            acc["function"]["name"] += fn["name"]
                        if fn.get("arguments"):
                            acc["function"]["arguments"] += fn["arguments"]

            return _assemble_assistant_message(
                content_parts=content_parts,
                reasoning_parts=reasoning_parts,
                tool_calls_acc=tool_calls_acc,
                usage_acc=usage_acc,
            )

        except (httpx.TransportError, httpx.TimeoutException, ssl.SSLError, OSError) as exc:
            last_exc = exc
            if attempt < 3 and not tool_calls_acc and not emitted_any:
                await asyncio.sleep(0.8 * attempt)
                continue
            if attempt < 2 and not tool_calls_acc:
                await asyncio.sleep(1.0)
                continue
            raise RuntimeError(_format_exception(exc)) from exc

    raise RuntimeError(_format_exception(last_exc or RuntimeError("模型请求失败")))


async def stream_anthropic_completion(
    client: httpx.AsyncClient,
    api_key: str,
    base_url: str,
    model: str,
    *,
    raw_msgs: list[dict[str, Any]],
    tool_schemas: list[dict[str, Any]],
    emit_event: Callable[..., dict[str, Any]],
    temperature: float = 0.7,
    max_tokens: int = 8192,
    supports_tools: bool = True,
    extra_headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Stream Anthropic Messages API (/v1/messages) into uniform internal OpenAI-shaped message."""
    base = base_url.rstrip("/")
    url = f"{base}/messages" if base.endswith("/v1") else f"{base}/v1/messages"
    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
        **(extra_headers or {}),
    }

    sys_parts: list[str] = []
    anth_msgs: list[dict[str, Any]] = []
    for m in raw_msgs:
        role = m.get("role")
        if role == "system":
            if m.get("content"):
                sys_parts.append(str(m["content"]))
        elif role == "user":
            mc = m.get("content")
            if isinstance(mc, list):
                anth_msgs.append({"role": "user", "content": list(mc)})
            else:
                anth_msgs.append({"role": "user", "content": str(mc or "")})
        elif role == "assistant":
            blocks: list[dict[str, Any]] = []
            if m.get("content"):
                blocks.append({"type": "text", "text": str(m["content"])})
            for tc in m.get("tool_calls") or []:
                try:
                    parsed_in = json.loads(tc["function"]["arguments"] or "{}")
                    if not isinstance(parsed_in, dict):
                        parsed_in = {"input": parsed_in}
                except Exception:
                    parsed_in = {}
                blocks.append(
                    {
                        "type": "tool_use",
                        "id": tc.get("id") or f"toolu_{uuid.uuid4().hex[:8]}",
                        "name": tc["function"]["name"],
                        "input": parsed_in,
                    }
                )
            if blocks:
                anth_msgs.append({"role": "assistant", "content": blocks})
        elif role == "tool":
            tr_block = {
                "type": "tool_result",
                "tool_use_id": str(m.get("tool_call_id") or ""),
                "content": str(m.get("content") or ""),
            }
            if anth_msgs and anth_msgs[-1]["role"] == "user" and isinstance(anth_msgs[-1]["content"], list):
                anth_msgs[-1]["content"].append(tr_block)
            else:
                anth_msgs.append({"role": "user", "content": [tr_block]})

    anth_tools = [
        {
            "name": t["function"]["name"],
            "description": t["function"].get("description", ""),
            "input_schema": t["function"].get("parameters", {"type": "object", "properties": {}}),
        }
        for t in tool_schemas
    ]

    body: dict[str, Any] = {
        "model": model,
        "system": "\n\n".join(sys_parts),
        "messages": anth_msgs,
        "max_tokens": max(256, int(max_tokens or 4096)),
        "temperature": temperature,
        "stream": True,
    }
    if supports_tools:
        body["tools"] = anth_tools

    last_exc: BaseException | None = None
    for attempt in range(1, 3):
        content_parts: list[str] = []
        reasoning_parts: list[str] = []
        tool_calls_acc: dict[int, dict[str, Any]] = {}
        usage_acc: dict[str, Any] = {}
        emitted_any = False
        try:
            async with client.stream("POST", url, headers=headers, json=body) as resp:
                if resp.status_code in RETRYABLE_STATUS_CODES and attempt < 2:
                    await resp.aread()
                    await asyncio.sleep(0.8)
                    continue
                if resp.status_code >= 400:
                    err_text = (await resp.aread()).decode("utf-8", errors="replace").strip()
                    raise RuntimeError(f"Anthropic API ({resp.status_code}): {err_text or '请求被拒绝'}")

                async for raw_line in resp.aiter_lines():
                    line = raw_line.strip()
                    if not line or not line.startswith("data:"):
                        continue
                    payload_str = line[5:].strip()
                    if not payload_str or payload_str == "[DONE]":
                        continue
                    try:
                        ev = json.loads(payload_str)
                    except json.JSONDecodeError:
                        continue

                    etype = ev.get("type")
                    if etype == "message_start":
                        msg_u = (ev.get("message") or {}).get("usage")
                        if isinstance(msg_u, dict):
                            usage_acc.update(msg_u)
                    elif etype == "message_delta":
                        delta_u = ev.get("usage")
                        if isinstance(delta_u, dict):
                            usage_acc.update(delta_u)

                    idx = int(ev.get("index", 0))
                    if etype == "content_block_start":
                        blk = ev.get("content_block") or {}
                        if blk.get("type") == "tool_use":
                            emitted_any = True
                            tool_calls_acc[idx] = {
                                "id": blk.get("id") or f"toolu_{uuid.uuid4().hex[:8]}",
                                "type": "function",
                                "function": {
                                    "name": str(blk.get("name") or ""),
                                    "arguments": "",
                                },
                            }
                    elif etype == "content_block_delta":
                        delta = ev.get("delta") or {}
                        dtype = delta.get("type")
                        if dtype == "text_delta" and delta.get("text"):
                            emitted_any = True
                            txt = str(delta["text"])
                            content_parts.append(txt)
                            emit_event("text_delta", {"text": txt}, persist=False)
                        elif dtype == "thinking_delta" and delta.get("thinking"):
                            emitted_any = True
                            th = str(delta["thinking"])
                            reasoning_parts.append(th)
                            emit_event("thought_delta", {"text": th}, persist=False)
                        elif dtype == "input_json_delta" and "partial_json" in delta:
                            if idx in tool_calls_acc:
                                tool_calls_acc[idx]["function"]["arguments"] += str(delta["partial_json"])
                    elif etype == "message_stop":
                        break

            return _assemble_assistant_message(
                content_parts=content_parts,
                reasoning_parts=reasoning_parts,
                tool_calls_acc=tool_calls_acc,
                usage_acc=usage_acc,
                normalize_empty_args=True,
            )
        except (httpx.TransportError, httpx.TimeoutException, ssl.SSLError, OSError) as exc:
            last_exc = exc
            if attempt < 2 and not tool_calls_acc and not emitted_any:
                await asyncio.sleep(0.8)
                continue
            raise RuntimeError(_format_exception(exc)) from exc
    raise RuntimeError(_format_exception(last_exc or RuntimeError("Anthropic 请求失败")))
