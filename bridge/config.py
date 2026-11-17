"""Configuration management for DeepSeek Mobile Bridge."""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import secrets
import threading
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

VERSION = "0.8.1"
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_DIR = Path(os.environ.get("PLUGIN_DATA") or (PROJECT_ROOT / "data"))


def mask_secret(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""
    if len(raw) <= 8:
        return "•" * len(raw)
    return f"{raw[:4]}••••{raw[-4:]}"


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


def default_model_profiles() -> list[dict[str, Any]]:
    return [
        {
            "id": "deepseek-chat",
            "name": "DeepSeek Chat (V3)",
            "provider": "openai_compatible",
            "base_url": "https://api.deepseek.com",
            "api_key": "",
            "model": "deepseek-chat",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        },
        {
            "id": "deepseek-flash",
            "name": "DeepSeek Flash",
            "provider": "openai_compatible",
            "base_url": "https://api.deepseek.com",
            "api_key": "",
            "model": "deepseek-flash",
            "temperature": 0.6,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        },
        {
            "id": "deepseek-reasoner",
            "name": "DeepSeek Reasoner (R1)",
            "provider": "openai_compatible",
            "base_url": "https://api.deepseek.com",
            "api_key": "",
            "model": "deepseek-reasoner",
            "temperature": 0.6,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": True,
        },
        {
            "id": "openai-gpt4o",
            "name": "OpenAI GPT-4o",
            "provider": "openai_compatible",
            "base_url": "https://api.openai.com/v1",
            "api_key": "",
            "model": "gpt-4o",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        },
        {
            "id": "anthropic-claude",
            "name": "Anthropic Claude",
            "provider": "anthropic",
            "base_url": "https://api.anthropic.com",
            "api_key": "",
            "model": "claude-sonnet-4-5",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": True,
        },
        {
            "id": "openrouter",
            "name": "OpenRouter",
            "provider": "openai_compatible",
            "base_url": "https://openrouter.ai/api/v1",
            "api_key": "",
            "model": "deepseek/deepseek-chat-v3-0324",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        },
        {
            "id": "siliconflow",
            "name": "硅基流动 SiliconFlow",
            "provider": "openai_compatible",
            "base_url": "https://api.siliconflow.cn/v1",
            "api_key": "",
            "model": "deepseek-ai/DeepSeek-V3",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        },
        {
            "id": "moonshot-kimi",
            "name": "Kimi (Moonshot)",
            "provider": "openai_compatible",
            "base_url": "https://api.moonshot.cn/v1",
            "api_key": "",
            "model": "moonshot-v1-32k",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        },
    ]


def default_search_config() -> dict[str, Any]:
    return {
        "enabled": True,
        "provider": "duckduckgo",
        "api_key": "",
        "base_url": "",
        "max_results": 6,
        "timeout_sec": 12,
    }


def default_appearance_config() -> dict[str, Any]:
    return {
        "accent": "blue",
        "glass_intensity": 0.85,
        "font_scale": 1.0,
        "bubble_radius": 20.0,
        "compact_mode": False,
        "auto_hide_composer": True,
        "auto_hide_delay_sec": 4.0,
        "enable_dynamic_island": True,
        "enable_haptics": True,
    }


class BridgeConfig(BaseModel):
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

    # v0.8.0 extensions
    active_profile_id: str = ""
    model_profiles: list[dict[str, Any]] = Field(default_factory=default_model_profiles)
    search_config: dict[str, Any] = Field(default_factory=default_search_config)
    appearance_config: dict[str, Any] = Field(default_factory=default_appearance_config)
    dsh_profile_dir: str = ""

    def ensure_v8_defaults(self) -> bool:
        changed = False
        if not self.model_profiles:
            self.model_profiles = default_model_profiles()
            changed = True
        if not self.active_profile_id:
            # Try matching current model against profiles
            matched = next(
                (p.get("id") for p in self.model_profiles if p.get("model") == (self.model or "deepseek-chat")),
                "",
            )
            if not matched:
                matched = "deepseek-chat"
            self.active_profile_id = str(matched)
            changed = True
        if not isinstance(self.search_config, dict) or not self.search_config:
            self.search_config = default_search_config()
            changed = True
        else:
            for k, v in default_search_config().items():
                if k not in self.search_config:
                    self.search_config[k] = v
                    changed = True
        if not isinstance(self.appearance_config, dict) or not self.appearance_config:
            self.appearance_config = default_appearance_config()
            changed = True
        else:
            for k, v in default_appearance_config().items():
                if k not in self.appearance_config:
                    self.appearance_config[k] = v
                    changed = True
        if not self.dsh_profile_dir:
            self.dsh_profile_dir = str((Path.home() / ".dsh" / "profiles" / "desktop"))
            changed = True
        return changed

    def get_profile(self, profile_id: str | None = None, *, model_hint: str | None = None) -> dict[str, Any]:
        self.ensure_v8_defaults()
        if profile_id:
            for p in self.model_profiles:
                if p.get("id") == profile_id:
                    return p
        if model_hint:
            for p in self.model_profiles:
                if p.get("model") == model_hint or p.get("id") == model_hint:
                    return p
        for p in self.model_profiles:
            if p.get("id") == self.active_profile_id:
                return p
        return self.model_profiles[0] if self.model_profiles else {
            "id": "deepseek-chat",
            "name": "DeepSeek Chat",
            "provider": "openai_compatible",
            "base_url": self.deepseek_base_url or "https://api.deepseek.com",
            "api_key": self.deepseek_api_key,
            "model": self.model or "deepseek-chat",
            "temperature": 0.7,
            "max_tokens": 8192,
            "supports_tools": True,
            "supports_reasoning": False,
        }

    def get_active_profile(self) -> dict[str, Any]:
        return self.get_profile(self.active_profile_id)

    def apply_active_profile(self, profile_id: str) -> bool:
        for p in self.model_profiles:
            if p.get("id") == profile_id:
                self.active_profile_id = profile_id
                if p.get("model"):
                    self.model = str(p["model"])
                if p.get("base_url"):
                    self.deepseek_base_url = str(p["base_url"]).rstrip("/")
                if str(p.get("api_key") or "").strip():
                    self.deepseek_api_key = str(p["api_key"]).strip()
                return True
        return False

    def resolve_credentials(
        self, *, profile_id: str | None = None, model_override: str | None = None
    ) -> dict[str, Any]:
        prof = copy.deepcopy(self.get_profile(profile_id, model_hint=model_override))
        provider = str(prof.get("provider") or "openai_compatible")
        model = (model_override or prof.get("model") or self.model or "deepseek-chat").strip()
        prof_base = str(prof.get("base_url") or "").strip().rstrip("/")
        global_base = (self.deepseek_base_url or os.environ.get("DEEPSEEK_BASE_URL", "") or "https://api.deepseek.com").strip().rstrip("/")
        # Respect explicit top-level deepseek_base_url override when using DeepSeek profiles
        if profile_id is None and prof_base in ("", "https://api.deepseek.com") and global_base:
            base_url = global_base
        else:
            base_url = prof_base or global_base
        prof_key = str(prof.get("api_key") or "").strip()

        # Fall back to global deepseek_api_key when using DeepSeek endpoints and profile has no override
        global_key = self.deepseek_api_key.strip() or os.environ.get("DEEPSEEK_API_KEY", "").strip()
        if prof_key:
            api_key = prof_key
        elif "deepseek" in base_url.lower() or "deepseek" in model.lower() or not prof.get("id"):
            api_key = global_key
        else:
            api_key = os.environ.get(f"{provider.upper()}_API_KEY", "").strip() or global_key

        return {
            "profile_id": str(prof.get("id") or self.active_profile_id),
            "name": str(prof.get("name") or model),
            "provider": provider,
            "base_url": base_url,
            "api_key": api_key,
            "model": model,
            "temperature": float(prof.get("temperature") if prof.get("temperature") is not None else 0.7),
            "max_tokens": int(prof.get("max_tokens") or 8192),
            "supports_tools": bool(prof.get("supports_tools", True)),
            "supports_reasoning": bool(prof.get("supports_reasoning", False)),
            "extra_headers": dict(prof.get("extra_headers") or {}),
        }

    def effective_api_key(self) -> str:
        return self.resolve_credentials()["api_key"]

    def effective_base_url(self) -> str:
        return self.resolve_credentials()["base_url"]

    def effective_active_workspace(self) -> str:
        if self.active_workspace and Path(self.active_workspace).exists():
            return str(Path(self.active_workspace).resolve())
        if self.workspaces:
            return str(Path(self.workspaces[0]).resolve())
        return str(PROJECT_ROOT.resolve())

    def to_public_dict(self) -> dict:
        self.ensure_v8_defaults()
        masked_profiles: list[dict[str, Any]] = []
        global_key = self.deepseek_api_key.strip() or os.environ.get("DEEPSEEK_API_KEY", "").strip()
        for prof in self.model_profiles:
            raw_key = str(prof.get("api_key") or "").strip()
            inherits_global = not raw_key and ("deepseek" in str(prof.get("base_url") or "").lower()) and bool(global_key)
            eff_key = raw_key or (global_key if inherits_global else "")
            item = {
                "id": str(prof.get("id") or ""),
                "name": str(prof.get("name") or prof.get("model") or ""),
                "provider": str(prof.get("provider") or "openai_compatible"),
                "base_url": str(prof.get("base_url") or ""),
                "model": str(prof.get("model") or ""),
                "temperature": float(prof.get("temperature") if prof.get("temperature") is not None else 0.7),
                "max_tokens": int(prof.get("max_tokens") or 8192),
                "supports_tools": bool(prof.get("supports_tools", True)),
                "supports_reasoning": bool(prof.get("supports_reasoning", False)),
                "has_api_key": bool(eff_key),
                "api_key_masked": mask_secret(eff_key),
                "inherits_global_key": inherits_global,
            }
            masked_profiles.append(item)

        sc = dict(self.search_config or default_search_config())
        raw_sk = str(sc.get("api_key") or "").strip()
        sc_public = {
            "enabled": bool(sc.get("enabled", True)),
            "provider": str(sc.get("provider") or "duckduckgo"),
            "base_url": str(sc.get("base_url") or ""),
            "max_results": int(sc.get("max_results") or 6),
            "timeout_sec": int(sc.get("timeout_sec") or 12),
            "has_api_key": bool(raw_sk),
            "api_key_masked": mask_secret(raw_sk),
        }

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
            "active_profile_id": self.active_profile_id,
            "model_profiles": masked_profiles,
            "search_config": sc_public,
            "appearance_config": dict(self.appearance_config or default_appearance_config()),
            "dsh_profile_dir": self.dsh_profile_dir,
        }


class ConfigStore:
    """Loads and atomically persists BridgeConfig on disk."""

    def __init__(self, data_dir: Path | None = None):
        self._lock = threading.RLock()
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

        if cfg.ensure_v8_defaults():
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
        with self._lock:
            if cfg is not None:
                self.config = cfg
            self.config.ensure_v8_defaults()
            self.data_dir.mkdir(parents=True, exist_ok=True)
            tmp = self.config_path.with_suffix(f".json.tmp-{os.getpid()}-{threading.get_ident()}")
            tmp.write_text(
                json.dumps(self.config.model_dump(), indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            os.replace(tmp, self.config_path)
            return self.config
