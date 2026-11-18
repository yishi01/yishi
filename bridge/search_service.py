from __future__ import annotations

from html.parser import HTMLParser
import time
from typing import Any
from urllib.parse import parse_qs, quote_plus, unquote, urlparse

import httpx


class _DuckDuckGoHTMLParser(HTMLParser):
    """Minimal dependency-free parser for DuckDuckGo HTML results."""

    def __init__(self, limit: int = 8) -> None:
        super().__init__()
        self.limit = limit
        self.results: list[dict[str, str]] = []
        self._in_title = False
        self._snippet_tag: str = ""
        self._snippet_depth: int = 0
        self._cur_title: list[str] = []
        self._cur_href: str = ""
        self._cur_snippet: list[str] = []

    def _flush_current(self) -> None:
        title = " ".join("".join(self._cur_title).split()).strip()
        snippet = " ".join("".join(self._cur_snippet).split()).strip()
        href = _clean_ddg_href(self._cur_href)
        if title and href and len(self.results) < self.limit:
            self.results.append({"title": title, "url": href, "snippet": snippet})
        self._cur_title = []
        self._cur_href = ""
        self._cur_snippet = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = dict(attrs)
        cls = attr_map.get("class") or ""
        if tag == "a" and "result__a" in cls:
            if self._cur_title and self._cur_href:
                self._flush_current()
            self._in_title = True
            self._cur_title = []
            self._cur_href = attr_map.get("href") or ""
            self._cur_snippet = []
            self._snippet_tag = ""
            self._snippet_depth = 0
        elif self._snippet_depth > 0:
            if tag == self._snippet_tag:
                self._snippet_depth += 1
        elif tag in ("a", "div", "span") and "result__snippet" in cls:
            self._snippet_tag = tag
            self._snippet_depth = 1

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._in_title:
            self._in_title = False
        elif self._snippet_depth > 0 and tag == self._snippet_tag:
            self._snippet_depth -= 1
            if self._snippet_depth == 0:
                self._snippet_tag = ""
                self._flush_current()

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._cur_title.append(data)
        elif self._snippet_depth > 0:
            self._cur_snippet.append(data)

    def close(self) -> None:
        super().close()
        if self._cur_title and self._cur_href:
            self._flush_current()


def _clean_ddg_href(raw_href: str) -> str:
    if raw_href.startswith("//"):
        raw_href = "https:" + raw_href
    parsed = urlparse(raw_href)
    if "duckduckgo.com" in parsed.netloc and parsed.path.startswith("/l/"):
        qs = parse_qs(parsed.query)
        if "uddg" in qs and qs["uddg"]:
            return unquote(qs["uddg"][0])
    return raw_href


async def _search_duckduckgo(query: str, max_results: int, timeout_sec: float) -> list[dict[str, str]]:
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    }
    async with httpx.AsyncClient(timeout=timeout_sec, follow_redirects=True) as client:
        resp = await client.post(
            "https://html.duckduckgo.com/html/",
            data={"q": query},
            headers=headers,
        )
        if resp.status_code == 200 and "result__a" in resp.text:
            parser = _DuckDuckGoHTMLParser(limit=max_results)
            parser.feed(resp.text)
            if parser.results:
                return parser.results

        # Fallback: Instant Answer JSON API
        api_resp = await client.get(
            "https://api.duckduckgo.com/",
            params={"q": query, "format": "json", "no_html": "1", "skip_disambig": "1"},
            headers=headers,
        )
        api_resp.raise_for_status()
        data = api_resp.json()
        results: list[dict[str, str]] = []
        if data.get("AbstractText"):
            results.append(
                {
                    "title": data.get("Heading") or query,
                    "url": data.get("AbstractURL") or "https://duckduckgo.com",
                    "snippet": str(data.get("AbstractText") or ""),
                }
            )
        for topic in data.get("RelatedTopics", []):
            if isinstance(topic, dict) and topic.get("Text") and topic.get("FirstURL"):
                results.append(
                    {
                        "title": str(topic.get("Text"))[:80],
                        "url": str(topic.get("FirstURL")),
                        "snippet": str(topic.get("Text")),
                    }
                )
            if len(results) >= max_results:
                break
        return results[:max_results]


async def _search_tavily(query: str, api_key: str, max_results: int, timeout_sec: float) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        resp = await client.post(
            "https://api.tavily.com/search",
            json={
                "api_key": api_key,
                "query": query,
                "max_results": max_results,
                "search_depth": "basic",
            },
        )
        resp.raise_for_status()
        data = resp.json()
        return [
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("url") or ""),
                "snippet": str(item.get("content") or ""),
            }
            for item in data.get("results", [])[:max_results]
        ]


async def _search_brave(query: str, api_key: str, max_results: int, timeout_sec: float) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        resp = await client.get(
            "https://api.search.brave.com/res/v1/web/search",
            params={"q": query, "count": max_results},
            headers={"Accept": "application/json", "X-Subscription-Token": api_key},
        )
        resp.raise_for_status()
        data = resp.json()
        web_items = (data.get("web") or {}).get("results") or []
        return [
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("url") or ""),
                "snippet": str(item.get("description") or ""),
            }
            for item in web_items[:max_results]
        ]


async def _search_serper(query: str, api_key: str, max_results: int, timeout_sec: float) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        resp = await client.post(
            "https://google.serper.dev/search",
            json={"q": query, "num": max_results},
            headers={"X-API-KEY": api_key, "Content-Type": "application/json"},
        )
        resp.raise_for_status()
        data = resp.json()
        return [
            {
                "title": str(item.get("title") or ""),
                "url": str(item.get("link") or ""),
                "snippet": str(item.get("snippet") or ""),
            }
            for item in (data.get("organic") or [])[:max_results]
        ]


async def _search_bocha(query: str, api_key: str, max_results: int, timeout_sec: float) -> list[dict[str, str]]:
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        resp = await client.post(
            "https://api.bochaai.com/v1/web-search",
            json={"query": query, "count": max_results, "summary": True},
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        )
        resp.raise_for_status()
        data = resp.json()
        pages = ((data.get("data") or {}).get("webPages") or {}).get("value") or []
        return [
            {
                "title": str(item.get("name") or ""),
                "url": str(item.get("url") or ""),
                "snippet": str(item.get("summary") or item.get("snippet") or ""),
            }
            for item in pages[:max_results]
        ]


async def _search_custom(
    query: str, base_url: str, api_key: str, max_results: int, timeout_sec: float
) -> list[dict[str, str]]:
    url = base_url.strip()
    if not url:
        raise ValueError("Custom search provider requires base_url.")
    headers = {"Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    async with httpx.AsyncClient(timeout=timeout_sec) as client:
        if "{query}" in url:
            resp = await client.get(url.replace("{query}", quote_plus(query)), headers=headers)
        else:
            resp = await client.post(
                url,
                json={"query": query, "q": query, "max_results": max_results},
                headers=headers,
            )
        resp.raise_for_status()
        data = resp.json()
        raw_list = data.get("results") or data.get("items") or data.get("organic") or []
        return [
            {
                "title": str(item.get("title") or item.get("name") or ""),
                "url": str(item.get("url") or item.get("link") or ""),
                "snippet": str(item.get("snippet") or item.get("content") or item.get("description") or ""),
            }
            for item in raw_list[:max_results]
            if isinstance(item, dict)
        ]


async def execute_web_search(
    query: str,
    search_config: dict[str, Any],
    *,
    max_results: int | None = None,
) -> dict[str, Any]:
    """Execute a web search using the configured provider."""
    started = time.perf_counter()
    cfg = search_config or {}
    if not cfg.get("enabled", True):
        return {
            "ok": False,
            "provider": cfg.get("provider", "duckduckgo"),
            "query": query,
            "results": [],
            "latency_ms": 0.0,
            "error": "网页搜索已在设置中关闭。",
        }
    provider = str(cfg.get("provider") or "duckduckgo").lower()
    api_key = str(cfg.get("api_key") or "").strip()
    base_url = str(cfg.get("base_url") or "").strip()
    limit = max(1, min(int(max_results or cfg.get("max_results") or 6), 15))
    timeout_sec = max(3.0, min(float(cfg.get("timeout_sec") or 12.0), 30.0))

    try:
        if provider == "duckduckgo":
            results = await _search_duckduckgo(query, limit, timeout_sec)
        elif provider == "tavily":
            if not api_key:
                raise ValueError("Tavily 需要填写 API Key")
            results = await _search_tavily(query, api_key, limit, timeout_sec)
        elif provider == "brave":
            if not api_key:
                raise ValueError("Brave Search 需要填写 API Key")
            results = await _search_brave(query, api_key, limit, timeout_sec)
        elif provider == "serper":
            if not api_key:
                raise ValueError("Serper 需要填写 API Key")
            results = await _search_serper(query, api_key, limit, timeout_sec)
        elif provider == "bocha":
            if not api_key:
                raise ValueError("Bocha 需要填写 API Key")
            results = await _search_bocha(query, api_key, limit, timeout_sec)
        elif provider == "custom":
            results = await _search_custom(query, base_url, api_key, limit, timeout_sec)
        else:
            raise ValueError(f"不支持的搜索提供商: {provider}")

        return {
            "ok": True,
            "provider": provider,
            "query": query,
            "results": results,
            "latency_ms": round((time.perf_counter() - started) * 1000, 1),
            "error": "",
        }
    except Exception as exc:
        return {
            "ok": False,
            "provider": provider,
            "query": query,
            "results": [],
            "latency_ms": round((time.perf_counter() - started) * 1000, 1),
            "error": str(exc),
        }
