"""API Wallet, Token Usage Ledger, and Auto-Downgrade rules routes (Module E)."""

from __future__ import annotations

import asyncio
from typing import Any

from fastapi import APIRouter, Body, Depends, Query, Request

from bridge.deps import require_auth

router = APIRouter()


@router.get("/api/wallet/summary", dependencies=[Depends(require_auth)])
async def api_wallet_summary(request: Request, force_balance: bool = Query(default=False)) -> dict[str, Any]:
    wallet_service = request.app.state.wallet_service
    if force_balance:
        await wallet_service.fetch_balance(force=True)
    return await asyncio.to_thread(wallet_service.get_summary)


@router.get("/api/wallet/usage", dependencies=[Depends(require_auth)])
def api_wallet_usage(
    request: Request,
    date_from: str = Query(default=""),
    date_to: str = Query(default=""),
    group_by: str = Query(default="model"),
) -> dict[str, Any]:
    return request.app.state.wallet_service.query_usage(
        date_from=date_from,
        date_to=date_to,
        group_by=group_by,
    )


@router.put("/api/wallet/rules", dependencies=[Depends(require_auth)])
def api_update_wallet_rules(request: Request, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    ws = request.app.state.wallet_service
    rules = ws.update_rules(payload)
    return {"ok": True, "rules": rules, **ws.get_summary()}


@router.put("/api/wallet/pricing", dependencies=[Depends(require_auth)])
def api_update_wallet_pricing(request: Request, payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    ws = request.app.state.wallet_service
    pricing = ws.update_pricing(payload)
    return {"ok": True, "pricing": pricing, **ws.get_summary()}
