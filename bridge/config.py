"""Configuration management for DeepSeek Mobile Bridge."""

from __future__ import annotations

import json
import os
import secrets
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

VERSION = "0.7.2"
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_DIR = Path(os.environ.get("PLUGIN_DATA") or (PROJECT_ROOT / "data"))


def _default_workspaces() -> list[str]:
    env_ws = os.environ.get("AGY_MOBILE_WORKSPACES", "").strip()
    if env_ws:
        sep = ";" if ";" in env_ws else ","
        items = [str(Path(p.strip()).resolve()) for p in env_ws.split(sep) if p.strip()]
        if items:
            return items
    result = [str(PROJECT_ROOT.resolve())]
    scratch_dir = Path.home() / ".gemini" / "antigravity" / "scratch"
    if scratch_dir.exists():
        scratch_resolved = str(scratch_dir.resolve())
        if scratch_resolved not in result:
            result.append(scratch_resolved)
    return result


class BridgeConfig(BaseModel):
    """Persisted configuration for the DeepSeek mobile bridge server."""

    model_config = ConfigDict(extra="ignore")

    host: str = "127.0.0.1"
    port: int = 8765
    auth_token: str = ""
    workspaces: list[str] = Field(default_factory=_default_workspaces)
    active_workspace: str = ""
    ai_access_mode: Literal["workspace_only", "workspace_read_all", "full_access"] = "workspace_only"
    default_approval_mode: Literal["ask_commands", "ask_writes", "auto"] = "ask_commands"
    bark_url: str = ""
    deepseek_base_url: str = "https://api.deepseek.com"
    model: str = "deepseek-chat"
    deepseek_api_key: str = ""
    enable_tunnel: bool = True
    cloudflared_token: str = ""
    public_url: str = ""

    def effective_api_key(self) -> str:
        return (
            self.deepseek_api_key.strip()
            or os.environ.get("DEEPSEEK_API_KEY", "").strip()
        )

    def effective_base_url(self) -> str:
        return (
            self.deepseek_base_url.strip()
            or os.environ.get("DEEPSEEK_BASE_URL", "").strip()
            or "https://api.deepseek.com"
        ).rstrip("/")

    def effective_active_workspace(self) -> str:
        if self.active_workspace and Path(self.active_workspace).exists():
            return str(Path(self.active_workspace).resolve())
        if self.workspaces:
            return str(Path(self.workspaces[0]).resolve())
        return str(PROJECT_ROOT.resolve())

    def to_public_dict(self) -> dict:
        return {
            "version": VERSION,
            "host": self.host,
            "port": self.port,
            "workspaces": self.workspaces,
            "active_workspace": self.effective_active_workspace(),
            "ai_access_mode": self.ai_access_mode,
            "default_approval_mode": self.default_approval_mode,
            "bark_url": self.bark_url,
            "deepseek_base_url": self.effective_base_url(),
            "model": self.model or "deepseek-chat",
            "has_api_key": bool(self.effective_api_key()),
            "enable_tunnel": self.enable_tunnel,
            "has_cloudflared_token": bool(self.cloudflared_token.strip()),
            "public_url": self.public_url,
        }


class ConfigStore:
    """Loads and atomically persists BridgeConfig on disk."""

    def __init__(self, data_dir: Path | None = None):
        self.data_dir = (data_dir or DEFAULT_DATA_DIR).resolve()
        self.config_path = self.data_dir / "config.json"
        self.config = self._load_or_init()

    def _load_or_init(self) -> BridgeConfig:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        raw: dict = {}
        if self.config_path.exists():
            try:
                raw = json.loads(self.config_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                raw = {}

        cfg = BridgeConfig(**raw)

        if env_host := os.environ.get("AGY_MOBILE_HOST", "").strip():
            cfg.host = env_host
        if env_port := os.environ.get("AGY_MOBILE_PORT", "").strip():
            cfg.port = int(env_port)
        if env_token := os.environ.get("AGY_MOBILE_TOKEN", "").strip():
            cfg.auth_token = env_token

        changed = not self.config_path.exists()
        if not cfg.auth_token:
            cfg.auth_token = secrets.token_urlsafe(24)
            changed = True

        if not cfg.model or cfg.model.startswith("gemini"):
            cfg.model = "deepseek-chat"
            changed = True

        normalized: list[str] = []
        for ws in cfg.workspaces:
            p = Path(ws)
            if p.exists() and p.is_dir():
                resolved = str(p.resolve())
                if resolved not in normalized:
                    normalized.append(resolved)
        if not normalized:
            normalized = _default_workspaces()
            changed = True
        cfg.workspaces = normalized

        if not cfg.active_workspace or not Path(cfg.active_workspace).exists():
            cfg.active_workspace = cfg.workspaces[0]
            changed = True

        if changed:
            self.save(cfg)
        return cfg

    def save(self, cfg: BridgeConfig | None = None) -> BridgeConfig:
        if cfg is not None:
            self.config = cfg
        self.data_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.config_path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(self.config.model_dump(), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        tmp.replace(self.config_path)
        return self.config
