"""Encrypted fixed-endpoint rendezvous publisher (zero-dependency stdlib crypto)."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import struct
import subprocess
import time
import urllib.error
import urllib.request
from typing import Any

logger = logging.getLogger("bridge.rendezvous")


def _derive_key(auth_token: str) -> bytes:
    return hashlib.sha256(f"ds-route-v1:{auth_token.strip()}".encode("utf-8")).digest()


def _keystream(key: bytes, nonce: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        block = hashlib.sha256(key + nonce + struct.pack(">I", counter)).digest()
        out.extend(block)
        counter += 1
    return bytes(out[:length])


def encrypt_route_payload(payload: dict[str, Any], auth_token: str) -> str:
    """Encrypt route JSON using SHA256-CTR + HMAC-SHA256 authenticated with auth_token."""
    if not auth_token.strip():
        raise ValueError("auth_token is required")
    key = _derive_key(auth_token)
    nonce = secrets.token_bytes(16)
    plaintext = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ks = _keystream(key, nonce, len(plaintext))
    ct = bytes(a ^ b for a, b in zip(plaintext, ks))
    tag = hmac.new(key, nonce + ct, hashlib.sha256).digest()
    envelope = {
        "v": 1,
        "n": base64.b64encode(nonce).decode("ascii"),
        "c": base64.b64encode(ct).decode("ascii"),
        "m": base64.b64encode(tag).decode("ascii"),
        "ts": int(time.time()),
    }
    return json.dumps(envelope, separators=(",", ":"))


def decrypt_route_payload(envelope_str: str, auth_token: str) -> dict[str, Any]:
    """Verify HMAC-SHA256 and decrypt route envelope."""
    env = json.loads(envelope_str)
    if env.get("v") != 1:
        raise ValueError("Unsupported envelope version")
    key = _derive_key(auth_token)
    nonce = base64.b64decode(env["n"])
    ct = base64.b64decode(env["c"])
    tag = base64.b64decode(env["m"])
    expected = hmac.new(key, nonce + ct, hashlib.sha256).digest()
    if not hmac.compare_digest(tag, expected):
        raise ValueError("Route envelope HMAC verification failed")
    ks = _keystream(key, nonce, len(ct))
    pt = bytes(a ^ b for a, b in zip(ct, ks))
    return json.loads(pt.decode("utf-8"))


def _get_git_github_token() -> str:
    env_tok = os.environ.get("GITHUB_GIST_TOKEN", "").strip()
    if env_tok:
        return env_tok
    try:
        proc = subprocess.run(
            ["git", "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in proc.stdout.splitlines():
            if line.startswith("password="):
                return line.split("=", 1)[1].strip()
    except Exception:
        pass
    return ""


def publish_route_to_gist(
    *,
    gist_id: str,
    auth_token: str,
    public_url: str,
    lan_urls: list[str],
    tailscale_urls: list[str],
) -> str:
    """Create or update a Secret GitHub Gist holding encrypted route endpoints. Returns gist_id."""
    token = _get_git_github_token()
    if not token:
        raise RuntimeError("No GitHub credential available on PC to publish rendezvous gist")

    payload = {
        "public_url": public_url,
        "lan_urls": lan_urls,
        "tailscale_urls": tailscale_urls,
        "updated_at": int(time.time()),
    }
    encrypted = encrypt_route_payload(payload, auth_token)
    body = json.dumps(
        {
            "description": "DeepSeek Mobile Bridge Encrypted Rendezvous Endpoint",
            "public": False,
            "files": {"endpoint.enc": {"content": encrypted}},
        }
    ).encode("utf-8")

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": "DeepSeekMobileBridge",
    }

    if gist_id.strip():
        req = urllib.request.Request(
            f"https://api.github.com/gists/{gist_id.strip()}",
            data=body,
            headers=headers,
            method="PATCH",
        )
        with urllib.request.urlopen(req, timeout=12) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return str(data["id"])

    req = urllib.request.Request(
        "https://api.github.com/gists",
        data=body,
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=12) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        return str(data["id"])
