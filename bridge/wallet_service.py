"""API Wallet, Token Usage Ledger, Balance Query & Auto-Downgrade Service for DeepSeek Mobile Bridge."""

from __future__ import annotations

import asyncio
from collections.abc import Callable
import copy
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import threading
import time
from typing import Any
from weakref import WeakKeyDictionary

import httpx

from bridge.utils import atomic_write_text

DEFAULT_MODEL_PRICING: dict[str, dict[str, Any]] = {
    "deepseek-chat": {
        "input_cache_hit": 0.5,
        "input_cache_miss": 2.0,
        "output": 8.0,
        "currency": "CNY",
    },
    "deepseek-flash": {
        "input_cache_hit": 0.25,
        "input_cache_miss": 1.0,
        "output": 4.0,
        "currency": "CNY",
    },
    "deepseek-reasoner": {
        "input_cache_hit": 1.0,
        "input_cache_miss": 4.0,
        "output": 16.0,
        "currency": "CNY",
    },
    "gpt-4o": {
        "input_cache_hit": 9.0,
        "input_cache_miss": 18.0,
        "output": 72.0,
        "currency": "CNY",
    },
    "claude-sonnet-4-5": {
        "input_cache_hit": 6.0,
        "input_cache_miss": 21.0,
        "output": 105.0,
        "currency": "CNY",
    },
}

DEFAULT_WALLET_RULES: dict[str, Any] = {
    "enabled": True,
    "balance_below": 5.0,
    "daily_spend_above": 20.0,
    "fallback_profile_id": "deepseek-flash",
    "notify_bark": True,
    "hysteresis": 1.0,
    "manual_balance": None,  # Optional float user override if provider has no balance API
    "currency": "CNY",
}


def default_model_pricing() -> dict[str, dict[str, Any]]:
    """Return a fresh copy of the default per-million-token pricing table."""
    return copy.deepcopy(DEFAULT_MODEL_PRICING)


def default_wallet_rules() -> dict[str, Any]:
    """Return a fresh copy of the default wallet auto-downgrade rules."""
    return copy.deepcopy(DEFAULT_WALLET_RULES)


class WalletService:
    """Manages token usage JSONL ledger, cost calculation, upstream balance queries, and auto-downgrade rules."""

    BALANCE_CACHE_TTL_SEC = 60.0

    def __init__(
        self,
        data_dir: Path,
        config_store: Any = None,
        http_client_factory: Callable[[], httpx.AsyncClient] | None = None,
    ) -> None:
        self._lock = threading.RLock()
        self.data_dir = Path(data_dir).resolve()
        self.config_store = config_store
        self.http_client_factory = http_client_factory
        self.usage_dir = self.data_dir / "usage"
        self.usage_dir.mkdir(parents=True, exist_ok=True)
        self.state_path = self.usage_dir / "wallet_state.json"
        self._state = self._load_state()
        self._fetch_locks: WeakKeyDictionary[asyncio.AbstractEventLoop, asyncio.Lock] = WeakKeyDictionary()

    # ------------------------------------------------------------------
    # State Persistence
    # ------------------------------------------------------------------

    def _default_state(self) -> dict[str, Any]:
        return {
            "downgrade_active": False,
            "downgrade_reason": "",
            "downgrade_triggered_at": "",
            "cached_balance": None,
            "cached_balance_ts": 0.0,
            "manual_balance_baseline_cost": 0.0,
            "pricing": {},
            "rules": {},
        }

    def _load_state(self) -> dict[str, Any]:
        with self._lock:
            state = self._default_state()
            if self.state_path.exists():
                try:
                    raw = json.loads(self.state_path.read_text(encoding="utf-8"))
                    if isinstance(raw, dict):
                        state.update(raw)
                except (OSError, json.JSONDecodeError):
                    pass
            return state

    def _save_state(self) -> None:
        with self._lock:
            self.usage_dir.mkdir(parents=True, exist_ok=True)
            atomic_write_text(
                self.state_path,
                json.dumps(self._state, indent=2, ensure_ascii=False),
            )

    # ------------------------------------------------------------------
    # Pricing & Rules Management
    # ------------------------------------------------------------------

    def get_pricing(self) -> dict[str, dict[str, Any]]:
        with self._lock:
            merged = copy.deepcopy(DEFAULT_MODEL_PRICING)
            cfg = getattr(self.config_store, "config", None) if self.config_store else None
            cfg_pricing = getattr(cfg, "model_pricing", None) if cfg else None
            if isinstance(cfg_pricing, dict):
                self._merge_pricing_dict(merged, cfg_pricing)
            state_pricing = self._state.get("pricing")
            if isinstance(state_pricing, dict):
                self._merge_pricing_dict(merged, state_pricing)
            return merged

    @staticmethod
    def _merge_pricing_dict(target: dict[str, dict[str, Any]], updates: dict[str, Any]) -> None:
        source = updates.get("pricing") if isinstance(updates.get("pricing"), dict) else updates
        if not isinstance(source, dict):
            return
        for model_key, p_val in source.items():
            if not isinstance(p_val, dict):
                continue
            key = str(model_key).strip()
            if not key:
                continue
            base = copy.deepcopy(
                target.get(
                    key,
                    {
                        "input_cache_hit": 0.5,
                        "input_cache_miss": 2.0,
                        "output": 8.0,
                        "currency": "CNY",
                    },
                )
            )
            for field in ("input_cache_hit", "input_cache_miss", "output"):
                if field in p_val and p_val[field] is not None:
                    try:
                        base[field] = max(0.0, float(p_val[field]))
                    except (TypeError, ValueError):
                        pass
            if "currency" in p_val and p_val["currency"]:
                base["currency"] = str(p_val["currency"]).strip().upper()
            target[key] = base

    def update_pricing(self, pricing_updates: dict[str, Any]) -> dict[str, dict[str, Any]]:
        with self._lock:
            current = self.get_pricing()
            if isinstance(pricing_updates, dict):
                self._merge_pricing_dict(current, pricing_updates)
            self._state["pricing"] = copy.deepcopy(current)
            self._save_state()

            cfg = getattr(self.config_store, "config", None) if self.config_store else None
            if cfg is not None and hasattr(cfg, "model_pricing"):
                try:
                    cfg.model_pricing = copy.deepcopy(current)
                    self.config_store.save(cfg)
                except Exception:
                    pass
            return copy.deepcopy(current)

    def get_rules(self) -> dict[str, Any]:
        with self._lock:
            rules = copy.deepcopy(DEFAULT_WALLET_RULES)
            cfg = getattr(self.config_store, "config", None) if self.config_store else None
            if cfg is not None:
                for attr in ("wallet_rules", "wallet_config"):
                    cfg_rules = getattr(cfg, attr, None)
                    if isinstance(cfg_rules, dict):
                        self._apply_rules_dict(rules, cfg_rules)
            state_rules = self._state.get("rules")
            if isinstance(state_rules, dict) and state_rules:
                self._apply_rules_dict(rules, state_rules)
            return rules

    @staticmethod
    def _apply_rules_dict(target: dict[str, Any], updates: dict[str, Any]) -> None:
        source = updates.get("rules") if isinstance(updates.get("rules"), dict) else updates
        if not isinstance(source, dict):
            return
        if "enabled" in source and source["enabled"] is not None:
            target["enabled"] = bool(source["enabled"])
        if "balance_below" in source and source["balance_below"] is not None:
            try:
                target["balance_below"] = max(0.0, float(source["balance_below"]))
            except (TypeError, ValueError):
                pass
        if "daily_spend_above" in source and source["daily_spend_above"] is not None:
            try:
                target["daily_spend_above"] = max(0.0, float(source["daily_spend_above"]))
            except (TypeError, ValueError):
                pass
        if "fallback_profile_id" in source and source["fallback_profile_id"] is not None:
            fb = str(source["fallback_profile_id"]).strip()
            if fb:
                target["fallback_profile_id"] = fb
        if "notify_bark" in source and source["notify_bark"] is not None:
            target["notify_bark"] = bool(source["notify_bark"])
        if "hysteresis" in source and source["hysteresis"] is not None:
            try:
                target["hysteresis"] = max(0.0, float(source["hysteresis"]))
            except (TypeError, ValueError):
                pass
        if "manual_balance" in source:
            val = source["manual_balance"]
            if val is None or (isinstance(val, str) and not val.strip()):
                target["manual_balance"] = None
            else:
                try:
                    target["manual_balance"] = float(val)
                except (TypeError, ValueError):
                    pass
        if "currency" in source and source["currency"]:
            target["currency"] = str(source["currency"]).strip().upper()

    def update_rules(self, rules_updates: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            rules = self.get_rules()
            if isinstance(rules_updates, dict):
                source = rules_updates.get("rules") if isinstance(rules_updates.get("rules"), dict) else rules_updates
                self._apply_rules_dict(rules, rules_updates)
                if isinstance(source, dict) and "manual_balance" in source:
                    if rules.get("manual_balance") is not None:
                        # Anchor baseline so historical spend before setting manual_balance isn't deducted twice
                        self._state["manual_balance_baseline_cost"] = self._get_all_time_cost()
                    else:
                        self._state["manual_balance_baseline_cost"] = 0.0
            self._state["rules"] = copy.deepcopy(rules)
            # Reset sticky downgrade flag when user updates rules
            self._state["downgrade_active"] = False
            self._state["downgrade_reason"] = ""
            self._state["downgrade_triggered_at"] = ""
            self._save_state()

            cfg = getattr(self.config_store, "config", None) if self.config_store else None
            if cfg is not None:
                saved = False
                for attr in ("wallet_rules", "wallet_config"):
                    if hasattr(cfg, attr):
                        setattr(cfg, attr, copy.deepcopy(rules))
                        saved = True
                if saved:
                    try:
                        self.config_store.save(cfg)
                    except Exception:
                        pass
            return copy.deepcopy(rules)

    def reset_downgrade(self) -> None:
        """Reset sticky auto-downgrade state (e.g. when user manually switches active model/profile)."""
        with self._lock:
            if self._state.get("downgrade_active"):
                self._state["downgrade_active"] = False
                self._state["downgrade_reason"] = ""
                self._state["downgrade_triggered_at"] = ""
                self._save_state()

    # ------------------------------------------------------------------
    # Cost Calculation & Usage Recording
    # ------------------------------------------------------------------

    def _resolve_model_pricing(self, model: str, profile_id: str) -> dict[str, Any]:
        pricing = self.get_pricing()
        prof_clean = (profile_id or "").strip()
        model_clean = (model or "").strip()

        if prof_clean and prof_clean in pricing:
            return pricing[prof_clean]
        if model_clean and model_clean in pricing:
            return pricing[model_clean]

        lower_map = {k.lower(): v for k, v in pricing.items()}
        if prof_clean.lower() in lower_map:
            return lower_map[prof_clean.lower()]
        if model_clean.lower() in lower_map:
            return lower_map[model_clean.lower()]

        combined = f"{prof_clean} {model_clean}".lower()
        # Check direct key substring matches first
        for key, val in pricing.items():
            if key.lower() in combined:
                return val

        if "reasoner" in combined or "deepseek-r1" in combined or "/r1" in combined:
            return pricing.get("deepseek-reasoner", DEFAULT_MODEL_PRICING["deepseek-reasoner"])
        if "flash" in combined:
            return pricing.get("deepseek-flash", DEFAULT_MODEL_PRICING["deepseek-flash"])
        if "gpt-4o" in combined or "gpt4o" in combined:
            return pricing.get("gpt-4o", DEFAULT_MODEL_PRICING["gpt-4o"])
        if "claude" in combined or "sonnet" in combined:
            return pricing.get("claude-sonnet-4-5", DEFAULT_MODEL_PRICING["claude-sonnet-4-5"])
        if "chat" in combined or "deepseek" in combined or "v3" in combined:
            return pricing.get("deepseek-chat", DEFAULT_MODEL_PRICING["deepseek-chat"])

        return pricing.get("deepseek-chat", DEFAULT_MODEL_PRICING["deepseek-chat"])

    def calculate_cost(
        self,
        model: str,
        profile_id: str = "",
        prompt_tokens: int = 0,
        cache_hit_tokens: int = 0,
        completion_tokens: int = 0,
    ) -> tuple[float, str]:
        p = self._resolve_model_pricing(model=model, profile_id=profile_id)
        p_tokens = max(0, int(prompt_tokens or 0))
        cache_hit = min(max(0, int(cache_hit_tokens or 0)), p_tokens)
        cache_miss = max(0, p_tokens - cache_hit)
        comp_tokens = max(0, int(completion_tokens or 0))

        cost = (
            cache_hit * float(p.get("input_cache_hit", 0.5))
            + cache_miss * float(p.get("input_cache_miss", 2.0))
            + comp_tokens * float(p.get("output", 8.0))
        ) / 1_000_000.0
        currency = str(p.get("currency") or "CNY")
        return (round(cost, 6), currency)

    def record_usage(
        self,
        *,
        session_id: str,
        turn_id: str,
        agent: str = "main",
        profile_id: str,
        model: str,
        prompt_tokens: int = 0,
        cache_hit_tokens: int = 0,
        completion_tokens: int = 0,
        reasoning_tokens: int = 0,
        estimated: bool = False,
        prompt_chars: int = 0,
        completion_chars: int = 0,
    ) -> dict[str, Any]:
        p_tokens = int(prompt_tokens or 0)
        c_hit_tokens = int(cache_hit_tokens or 0)
        comp_tokens = int(completion_tokens or 0)
        reas_tokens = int(reasoning_tokens or 0)
        p_chars = int(prompt_chars or 0)
        c_chars = int(completion_chars or 0)
        is_estimated = bool(estimated)

        if p_tokens <= 0 and comp_tokens <= 0 and (p_chars > 0 or c_chars > 0):
            p_tokens = max(1, p_chars // 3)
            comp_tokens = max(1, c_chars // 3)
            is_estimated = True

        p_tokens = max(0, p_tokens)
        comp_tokens = max(0, comp_tokens)
        c_hit_tokens = min(max(0, c_hit_tokens), p_tokens)
        reas_tokens = max(0, reas_tokens)

        cost, currency = self.calculate_cost(
            model=model,
            profile_id=profile_id,
            prompt_tokens=p_tokens,
            cache_hit_tokens=c_hit_tokens,
            completion_tokens=comp_tokens,
        )

        now = datetime.now().astimezone()
        iso_now = now.isoformat(timespec="seconds")
        date_str = now.strftime("%Y-%m-%d")
        hour_str = f"{now.strftime('%H')}:00"

        entry: dict[str, Any] = {
            "ts": iso_now,
            "date": date_str,
            "hour": hour_str,
            "session_id": str(session_id or ""),
            "turn_id": str(turn_id or ""),
            "agent": str(agent or "main"),
            "profile_id": str(profile_id or ""),
            "model": str(model or ""),
            "prompt_tokens": p_tokens,
            "cache_hit_tokens": c_hit_tokens,
            "completion_tokens": comp_tokens,
            "reasoning_tokens": reas_tokens,
            "total_tokens": p_tokens + comp_tokens,
            "cost": cost,
            "currency": currency,
            "estimated": is_estimated,
        }

        with self._lock:
            self.usage_dir.mkdir(parents=True, exist_ok=True)
            ledger_file = self.usage_dir / f"{date_str}.jsonl"
            with ledger_file.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

        return entry

    # ------------------------------------------------------------------
    # Ledger Reading Helpers
    # ------------------------------------------------------------------

    def _read_day_entries(self, date_str: str) -> list[dict[str, Any]]:
        ledger_file = self.usage_dir / f"{date_str}.jsonl"
        if not ledger_file.exists():
            return []
        entries: list[dict[str, Any]] = []
        with self._lock:
            try:
                lines = ledger_file.read_text(encoding="utf-8").splitlines()
            except OSError:
                return []
        for line in lines:
            raw = line.strip()
            if not raw:
                continue
            try:
                item = json.loads(raw)
                if isinstance(item, dict):
                    entries.append(item)
            except json.JSONDecodeError:
                continue
        return entries

    def _iter_all_entries(self, date_from: str = "", date_to: str = "") -> list[dict[str, Any]]:
        with self._lock:
            if not self.usage_dir.exists():
                return []
            files = sorted(self.usage_dir.glob("*.jsonl"))
        results: list[dict[str, Any]] = []
        for file_path in files:
            date_stem = file_path.stem
            if date_from and date_stem < date_from:
                continue
            if date_to and date_stem > date_to:
                continue
            results.extend(self._read_day_entries(date_stem))
        return results

    def _get_today_cost(self) -> float:
        today_str = datetime.now().astimezone().strftime("%Y-%m-%d")
        entries = self._read_day_entries(today_str)
        return round(sum(float(e.get("cost") or 0.0) for e in entries), 6)

    def _get_all_time_cost(self) -> float:
        entries = self._iter_all_entries()
        return round(sum(float(e.get("cost") or 0.0) for e in entries), 6)

    # ------------------------------------------------------------------
    # Upstream Balance & Fallback Estimation
    # ------------------------------------------------------------------

    def _compute_fallback_balance(self, rules: dict[str, Any]) -> dict[str, Any]:
        currency = str(rules.get("currency") or "CNY")
        manual_bal = rules.get("manual_balance")
        if manual_bal is not None:
            baseline = float(self._state.get("manual_balance_baseline_cost") or 0.0)
            cost_since = max(0.0, self._get_all_time_cost() - baseline)
            est_balance = round(float(manual_bal) - cost_since, 4)
            return {
                "available": True,
                "is_available": est_balance > 0,
                "source": "manual_estimated",
                "total_balance": est_balance,
                "granted_balance": 0.0,
                "topped_up_balance": round(float(manual_bal), 4),
                "currency": currency,
                "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                "stale": False,
            }

        with self._lock:
            cached = self._state.get("cached_balance")
            if isinstance(cached, dict) and cached.get("available"):
                stale_copy = copy.deepcopy(cached)
                stale_copy["stale"] = True
                return stale_copy

        return {
            "available": False,
            "is_available": False,
            "source": "unavailable",
            "total_balance": None,
            "granted_balance": None,
            "topped_up_balance": None,
            "currency": currency,
            "updated_at": None,
            "stale": False,
        }

    def _get_effective_balance(self) -> dict[str, Any]:
        rules = self.get_rules()
        with self._lock:
            cached = self._state.get("cached_balance")
            if (
                isinstance(cached, dict)
                and cached.get("available")
                and cached.get("source") == "api"
                and rules.get("manual_balance") is None
            ):
                return copy.deepcopy(cached)
        return self._compute_fallback_balance(rules)

    async def fetch_balance(self, *, force: bool = False) -> dict[str, Any]:
        loop = asyncio.get_running_loop()
        fetch_lock = self._fetch_locks.get(loop)
        if fetch_lock is None:
            fetch_lock = asyncio.Lock()
            self._fetch_locks[loop] = fetch_lock

        async with fetch_lock:
            return await self._fetch_balance_locked(force=force)

    async def _fetch_balance_locked(self, *, force: bool = False) -> dict[str, Any]:
        rules = self.get_rules()
        now_ts = time.time()

        with self._lock:
            cached = self._state.get("cached_balance")
            cached_ts = float(self._state.get("cached_balance_ts") or 0.0)
            if (
                not force
                and isinstance(cached, dict)
                and cached.get("available")
                and cached.get("source") == "api"
                and (now_ts - cached_ts) < self.BALANCE_CACHE_TTL_SEC
            ):
                return copy.deepcopy(cached)

        cfg = getattr(self.config_store, "config", None) if self.config_store else None
        creds: dict[str, Any] = {}
        if cfg is not None and hasattr(cfg, "resolve_credentials"):
            try:
                creds = cfg.resolve_credentials() or {}
                if not creds.get("api_key"):
                    creds = cfg.resolve_credentials(profile_id="deepseek-chat") or creds
            except Exception:
                creds = {}

        base_url = str(creds.get("base_url") or "https://api.deepseek.com").strip().rstrip("/")
        api_key = str(creds.get("api_key") or "").strip()

        if api_key and base_url:
            candidate_urls = [f"{base_url}/user/balance"]
            if base_url.endswith("/v1"):
                candidate_urls.append(f"{base_url[:-3]}/user/balance")

            headers = {
                "Authorization": f"Bearer {api_key}",
                "Accept": "application/json",
            }
            for url in candidate_urls:
                try:
                    if self.http_client_factory is not None:
                        async with self.http_client_factory() as client:
                            resp = await client.get(url, headers=headers)
                    else:
                        async with httpx.AsyncClient(timeout=10.0) as client:
                            resp = await client.get(url, headers=headers)

                    if resp.status_code == 200:
                        data = resp.json()
                        if isinstance(data, dict) and isinstance(data.get("balance_infos"), list) and data["balance_infos"]:
                            infos = data["balance_infos"]
                            pref_curr = str(rules.get("currency") or "CNY").upper()
                            chosen = next(
                                (
                                    item
                                    for item in infos
                                    if isinstance(item, dict)
                                    and str(item.get("currency") or "").upper() == pref_curr
                                ),
                                infos[0] if isinstance(infos[0], dict) else {},
                            )
                            total_balance = float(chosen.get("total_balance") or 0.0)
                            granted_balance = float(chosen.get("granted_balance") or 0.0)
                            topped_up_balance = float(chosen.get("topped_up_balance") or 0.0)
                            currency = str(chosen.get("currency") or pref_curr or "CNY")
                            is_available = bool(data.get("is_available", True))
                            updated_at = datetime.now().astimezone().isoformat(timespec="seconds")

                            bal_result: dict[str, Any] = {
                                "available": True,
                                "is_available": is_available,
                                "source": "api",
                                "total_balance": total_balance,
                                "granted_balance": granted_balance,
                                "topped_up_balance": topped_up_balance,
                                "currency": currency,
                                "updated_at": updated_at,
                                "stale": False,
                            }
                            with self._lock:
                                self._state["cached_balance"] = copy.deepcopy(bal_result)
                                self._state["cached_balance_ts"] = time.time()
                            await asyncio.to_thread(self._save_state)
                            return bal_result
                except Exception:
                    continue

        return await asyncio.to_thread(self._compute_fallback_balance, rules)

    # ------------------------------------------------------------------
    # Auto-Downgrade Evaluation
    # ------------------------------------------------------------------

    def evaluate_pre_turn_model(self, requested_profile_id: str, requested_model: str) -> dict[str, Any]:
        with self._lock:
            rules = self.get_rules()
            if not rules.get("enabled", True):
                return {
                    "switched": False,
                    "profile_id": requested_profile_id,
                    "model": requested_model,
                    "reason": "",
                }

            fallback_profile_id = str(rules.get("fallback_profile_id") or "deepseek-flash").strip()
            cfg = getattr(self.config_store, "config", None) if self.config_store else None
            fb_prof: dict[str, Any] = {}
            if cfg is not None and hasattr(cfg, "get_profile"):
                try:
                    fb_prof = cfg.get_profile(fallback_profile_id) or {}
                except Exception:
                    fb_prof = {}

            fb_id = str(fb_prof.get("id") or fallback_profile_id)
            fb_model = str(fb_prof.get("model") or fallback_profile_id)

            today_cost = self._get_today_cost()
            daily_spend_above = rules.get("daily_spend_above")
            balance_below = rules.get("balance_below")
            currency = str(rules.get("currency") or "CNY")

            balance_info = self._get_effective_balance()
            total_balance = balance_info.get("total_balance") if balance_info.get("available") else None

            triggered_reason = ""
            if balance_below is not None and total_balance is not None:
                if float(total_balance) < float(balance_below):
                    triggered_reason = (
                        f"balance_below ({float(total_balance):.2f} < {float(balance_below):.2f} {currency})"
                    )

            if not triggered_reason and daily_spend_above is not None:
                limit = float(daily_spend_above)
                if today_cost > limit or (limit > 0 and today_cost >= limit):
                    triggered_reason = (
                        f"daily_spend_above ({today_cost:.4f} >= {limit:.2f} {currency})"
                    )

            if triggered_reason:
                if not self._state.get("downgrade_active") or not self._state.get("downgrade_reason"):
                    self._state["downgrade_active"] = True
                    self._state["downgrade_reason"] = triggered_reason
                    self._state["downgrade_triggered_at"] = datetime.now().astimezone().isoformat(
                        timespec="seconds"
                    )
                    self._save_state()
            elif self._state.get("downgrade_active"):
                # Sticky downgrade: stay active until user manually resets or updates rules
                triggered_reason = str(self._state.get("downgrade_reason") or "sticky_downgrade")

            if triggered_reason and requested_profile_id != fb_id and requested_model != fb_model:
                return {
                    "switched": True,
                    "from_profile_id": requested_profile_id,
                    "from_model": requested_model,
                    "profile_id": fb_id,
                    "model": fb_model,
                    "reason": triggered_reason,
                }

            return {
                "switched": False,
                "profile_id": requested_profile_id,
                "model": requested_model,
                "reason": triggered_reason,
            }

    # ------------------------------------------------------------------
    # Aggregation & Reporting
    # ------------------------------------------------------------------

    def get_summary(self) -> dict[str, Any]:
        now = datetime.now().astimezone()
        today_str = now.strftime("%Y-%m-%d")
        current_hour_str = f"{now.strftime('%H')}:00"

        today_entries = self._read_day_entries(today_str)

        prompt_tokens = 0
        cache_hit_tokens = 0
        completion_tokens = 0
        reasoning_tokens = 0
        total_tokens = 0
        total_cost = 0.0
        by_model_map: dict[str, dict[str, Any]] = {}

        hourly_buckets: dict[str, dict[str, Any]] = {
            f"{h:02d}:00": {"hour": f"{h:02d}:00", "tokens": 0, "total_tokens": 0, "cost": 0.0, "turns": 0}
            for h in range(24)
        }

        for entry in today_entries:
            p_tok = int(entry.get("prompt_tokens") or 0)
            c_hit = int(entry.get("cache_hit_tokens") or 0)
            comp_tok = int(entry.get("completion_tokens") or 0)
            reas_tok = int(entry.get("reasoning_tokens") or 0)
            tot_tok = int(entry.get("total_tokens") or (p_tok + comp_tok))
            cost = float(entry.get("cost") or 0.0)
            model_key = str(entry.get("model") or entry.get("profile_id") or "unknown")
            hour_key = str(entry.get("hour") or "00:00")

            prompt_tokens += p_tok
            cache_hit_tokens += c_hit
            completion_tokens += comp_tok
            reasoning_tokens += reas_tok
            total_tokens += tot_tok
            total_cost += cost

            if model_key not in by_model_map:
                by_model_map[model_key] = {
                    "model": model_key,
                    "profile_id": str(entry.get("profile_id") or model_key),
                    "prompt_tokens": 0,
                    "cache_hit_tokens": 0,
                    "completion_tokens": 0,
                    "reasoning_tokens": 0,
                    "total_tokens": 0,
                    "cost": 0.0,
                    "turns": 0,
                }
            m_bucket = by_model_map[model_key]
            m_bucket["prompt_tokens"] += p_tok
            m_bucket["cache_hit_tokens"] += c_hit
            m_bucket["completion_tokens"] += comp_tok
            m_bucket["reasoning_tokens"] += reas_tok
            m_bucket["total_tokens"] += tot_tok
            m_bucket["cost"] = round(m_bucket["cost"] + cost, 6)
            m_bucket["turns"] += 1

            if hour_key not in hourly_buckets:
                hourly_buckets[hour_key] = {
                    "hour": hour_key,
                    "tokens": 0,
                    "total_tokens": 0,
                    "cost": 0.0,
                    "turns": 0,
                }
            h_bucket = hourly_buckets[hour_key]
            h_bucket["tokens"] += tot_tok
            h_bucket["total_tokens"] += tot_tok
            h_bucket["cost"] = round(h_bucket["cost"] + cost, 6)
            h_bucket["turns"] += 1

        by_model_list = sorted(by_model_map.values(), key=lambda x: x["cost"], reverse=True)
        hourly_today = [hourly_buckets[f"{h:02d}:00"] for h in range(24)]
        cur_hour_bucket = hourly_buckets.get(
            current_hour_str,
            {"hour": current_hour_str, "tokens": 0, "total_tokens": 0, "cost": 0.0, "turns": 0},
        )

        last_7_days: list[dict[str, Any]] = []
        for delta in range(6, -1, -1):
            day_dt = now - timedelta(days=delta)
            d_str = day_dt.strftime("%Y-%m-%d")
            d_entries = today_entries if d_str == today_str else self._read_day_entries(d_str)
            d_tokens = sum(
                int(e.get("total_tokens") or (int(e.get("prompt_tokens") or 0) + int(e.get("completion_tokens") or 0)))
                for e in d_entries
            )
            d_cost = round(sum(float(e.get("cost") or 0.0) for e in d_entries), 6)
            last_7_days.append(
                {
                    "date": d_str,
                    "tokens": d_tokens,
                    "total_tokens": d_tokens,
                    "cost": d_cost,
                    "turns": len(d_entries),
                }
            )

        with self._lock:
            downgrade_active = bool(self._state.get("downgrade_active", False))
            downgrade_reason = str(self._state.get("downgrade_reason") or "")

        return {
            "balance": self._get_effective_balance(),
            "today": {
                "date": today_str,
                "prompt_tokens": prompt_tokens,
                "cache_hit_tokens": cache_hit_tokens,
                "completion_tokens": completion_tokens,
                "reasoning_tokens": reasoning_tokens,
                "total_tokens": total_tokens,
                "cost": round(total_cost, 6),
                "turns": len(today_entries),
                "by_model": by_model_list,
            },
            "current_hour": {
                "hour": current_hour_str,
                "total_tokens": cur_hour_bucket["total_tokens"],
                "cost": round(float(cur_hour_bucket["cost"]), 6),
                "turns": cur_hour_bucket["turns"],
            },
            "hourly_today": hourly_today,
            "last_7_days": last_7_days,
            "rules": self.get_rules(),
            "pricing": self.get_pricing(),
            "downgrade_active": downgrade_active,
            "downgrade_reason": downgrade_reason,
        }

    def query_usage(
        self,
        *,
        date_from: str = "",
        date_to: str = "",
        group_by: str = "model",
    ) -> dict[str, Any]:
        valid_groups = ("model", "session", "hour", "day")
        grp = group_by if group_by in valid_groups else "model"
        entries = self._iter_all_entries(date_from=date_from.strip(), date_to=date_to.strip())

        buckets: dict[str, dict[str, Any]] = {}
        tot_prompt = 0
        tot_cache_hit = 0
        tot_completion = 0
        tot_reasoning = 0
        tot_tokens = 0
        tot_cost = 0.0
        currency = str(self.get_rules().get("currency") or "CNY")

        for entry in entries:
            if grp == "model":
                key = str(entry.get("model") or entry.get("profile_id") or "unknown")
            elif grp == "session":
                key = str(entry.get("session_id") or "unknown")
            elif grp == "hour":
                key = str(entry.get("hour") or "00:00")
            else:  # "day"
                key = str(entry.get("date") or "unknown")

            p_tok = int(entry.get("prompt_tokens") or 0)
            c_hit = int(entry.get("cache_hit_tokens") or 0)
            comp_tok = int(entry.get("completion_tokens") or 0)
            reas_tok = int(entry.get("reasoning_tokens") or 0)
            t_tok = int(entry.get("total_tokens") or (p_tok + comp_tok))
            cost = float(entry.get("cost") or 0.0)
            entry_curr = str(entry.get("currency") or currency)

            tot_prompt += p_tok
            tot_cache_hit += c_hit
            tot_completion += comp_tok
            tot_reasoning += reas_tok
            tot_tokens += t_tok
            tot_cost += cost

            if key not in buckets:
                bucket: dict[str, Any] = {
                    "key": key,
                    grp: key,
                    "prompt_tokens": 0,
                    "cache_hit_tokens": 0,
                    "completion_tokens": 0,
                    "reasoning_tokens": 0,
                    "total_tokens": 0,
                    "cost": 0.0,
                    "turns": 0,
                    "currency": entry_curr,
                }
                if grp == "session":
                    bucket["session_id"] = key
                elif grp == "day":
                    bucket["date"] = key
                buckets[key] = bucket

            b = buckets[key]
            b["prompt_tokens"] += p_tok
            b["cache_hit_tokens"] += c_hit
            b["completion_tokens"] += comp_tok
            b["reasoning_tokens"] += reas_tok
            b["total_tokens"] += t_tok
            b["cost"] = round(b["cost"] + cost, 6)
            b["turns"] += 1

        if grp in ("hour", "day"):
            items = [buckets[k] for k in sorted(buckets.keys())]
        else:
            items = sorted(buckets.values(), key=lambda x: x["cost"], reverse=True)

        return {
            "group_by": grp,
            "date_from": date_from,
            "date_to": date_to,
            "items": items,
            "totals": {
                "prompt_tokens": tot_prompt,
                "cache_hit_tokens": tot_cache_hit,
                "completion_tokens": tot_completion,
                "reasoning_tokens": tot_reasoning,
                "total_tokens": tot_tokens,
                "cost": round(tot_cost, 6),
                "turns": len(entries),
                "currency": currency,
            },
        }
