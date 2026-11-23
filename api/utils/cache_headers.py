"""
Shared-cache (CDN) ``Cache-Control`` headers for the scraped JSON endpoints.

On Vercel every request that misses the edge cache cold-starts or wakes a
function, and the in-process TTL caches in ``utils.cache_manager`` die with
it. Telling the edge how long each payload stays fresh lets it absorb repeat
traffic instead: successful GETs get

    Cache-Control: public, max-age=0, s-maxage=<route TTL>, stale-while-revalidate=<SWR>

``max-age=0`` keeps browsers and app HTTP caches revalidating every time, so
only the shared cache holds a copy. ``s-maxage`` reuses the route's existing
``CACHE_TTL_*`` constant, so the edge never serves data older than the
in-process cache would have.

What never gets a shared-cache lifetime:

* non-GET/HEAD requests, and paths not listed in ``_ROUTE_TTLS`` (``/health``
  included, since it reports live upstream reachability);
* any non-2xx response, including the rate limiter's 429 and every error;
* a 200 whose JSON body embeds an upstream error (``data.status >= 400``),
  which the original unversioned routes pass through as-is;
* a 304 from ``ConditionalGetMiddleware``: it is answered with
  ``private, max-age=0, must-revalidate`` so a shared cache can never store
  an empty body against the URL.

Match detail is the one route whose TTL depends on the payload: a live match
uses ``CACHE_TTL_MATCH_DETAIL_LIVE`` (the scraper's own split), read from the
``status`` field of the response.

Registered between CORS and the rate limiter so it sees the limiter's 429s
and the conditional layer's 304s (see ``main.py``).
"""

import json
from urllib.parse import parse_qs

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from utils.constants import (
    CACHE_TTL_EVENT_AGENTS,
    CACHE_TTL_EVENT_MATCHES,
    CACHE_TTL_EVENT_NEWS,
    CACHE_TTL_EVENT_PICKEM,
    CACHE_TTL_EVENT_STATS,
    CACHE_TTL_EVENTS,
    CACHE_TTL_LIVE,
    CACHE_TTL_MATCH_DETAIL,
    CACHE_TTL_MATCH_DETAIL_LIVE,
    CACHE_TTL_NEWS,
    CACHE_TTL_NEWS_ARTICLE,
    CACHE_TTL_PLAYER,
    CACHE_TTL_PLAYER_MATCHES,
    CACHE_TTL_RANKINGS,
    CACHE_TTL_RESULTS,
    CACHE_TTL_SEARCH,
    CACHE_TTL_STATS,
    CACHE_TTL_TEAM,
    CACHE_TTL_TEAM_MATCHES,
    CACHE_TTL_TEAM_ROSTER,
    CACHE_TTL_TEAM_SCHEDULE,
    CACHE_TTL_TEAM_STATS,
    CACHE_TTL_TEAM_TRANSACTIONS,
    CACHE_TTL_UPCOMING,
)

# Docs and the schema only change on deploy, and Vercel purges its cache on
# every deploy, so a short lifetime is plenty.
CACHE_TTL_DOCS = 300
# Upper bound for stale-while-revalidate, whatever the route TTL.
MAX_STALE_WHILE_REVALIDATE = 86400

PRIVATE_REVALIDATE = "private, max-age=0, must-revalidate"

# A route handler may lower the shared-cache TTL for one response by setting
# ``request.state.<EDGE_TTL_CAP_STATE>`` to a number of seconds (the V3 match
# lists do this while team logos are still being fetched).
EDGE_TTL_CAP_STATE = "edge_ttl_cap"
NO_STORE = "no-store"

_MATCH_LIST_TTLS = {
    "live_score": CACHE_TTL_LIVE,
    "upcoming": CACHE_TTL_UPCOMING,
    "upcoming_extended": CACHE_TTL_UPCOMING,
    "results": CACHE_TTL_RESULTS,
}
_TEAM_QUERY_TTLS = {
    "profile": CACHE_TTL_TEAM,
    "matches": CACHE_TTL_TEAM_MATCHES,
    "transactions": CACHE_TTL_TEAM_TRANSACTIONS,
    "stats": CACHE_TTL_TEAM_STATS,
    "roster": CACHE_TTL_TEAM_ROSTER,
    "schedule": CACHE_TTL_TEAM_SCHEDULE,
}
_PLAYER_QUERY_TTLS = {"profile": CACHE_TTL_PLAYER, "matches": CACHE_TTL_PLAYER_MATCHES}
_EVENT_RESOURCE_TTLS = {
    "stats": CACHE_TTL_EVENT_STATS,
    "agents": CACHE_TTL_EVENT_AGENTS,
    "news": CACHE_TTL_EVENT_NEWS,
    "pickem": CACHE_TTL_EVENT_PICKEM,
    "matches": CACHE_TTL_EVENT_MATCHES,
}

# Marker TTL: resolved from the response body by ``_match_detail_ttl``.
MATCH_DETAIL = -1


def _split(path: str) -> tuple[str, list[str]]:
    """Return (api version, path segments) with the version prefix removed."""
    parts = [part for part in path.lower().split("/") if part]
    if parts and parts[0] in ("v2", "v3"):
        return parts[0], parts[1:]
    return "", parts


def _first(query: dict[str, list[str]], name: str, default: str = "") -> str:
    values = query.get(name)
    return values[0].lower() if values else default


def route_ttl(path: str, query_string: str) -> int | None:
    """Return the shared-cache TTL for a GET path, or None to leave it uncached.

    ``MATCH_DETAIL`` means the TTL depends on whether the match is live.
    """
    version, parts = _split(path)
    query = parse_qs(query_string)

    if not parts:
        return CACHE_TTL_DOCS if not version else None
    head, rest = parts[0], parts[1:]

    if head in ("openapi.json", "docs", "redoc"):
        return CACHE_TTL_DOCS if not version else None
    if head == "version":
        return CACHE_TTL_DOCS
    if head == "health":
        return None

    if head == "news":
        return CACHE_TTL_NEWS_ARTICLE if rest else CACHE_TTL_NEWS
    if head == "stats":
        return CACHE_TTL_STATS if not rest else None
    if head == "rankings":
        return CACHE_TTL_RANKINGS if not rest else None
    if head == "search":
        return CACHE_TTL_SEARCH if not rest else None

    # /match?q=, /v3/matches?q=, /match/details, /match/{id}/details,
    # /v3/matches/{id}, /match/logs, /match/{id}/logs
    if head in ("match", "matches"):
        if not rest:
            return _MATCH_LIST_TTLS.get(_first(query, "q"))
        if rest[-1] == "logs":
            return CACHE_TTL_MATCH_DETAIL
        if rest[-1] == "details" or (head == "matches" and len(rest) == 1):
            return MATCH_DETAIL
        return None

    if head == "team":
        if not rest:
            return _TEAM_QUERY_TTLS.get(_first(query, "q", "profile"))
        if len(rest) == 1:
            # Legacy /team/matches etc. vs. /v2/team/{id}
            return _TEAM_QUERY_TTLS.get(rest[0], CACHE_TTL_TEAM)
        return _TEAM_QUERY_TTLS.get(rest[-1])

    if head == "player":
        if not rest:
            return _PLAYER_QUERY_TTLS.get(_first(query, "q", "profile"))
        if len(rest) == 1:
            return _PLAYER_QUERY_TTLS.get(rest[0], CACHE_TTL_PLAYER)
        return _PLAYER_QUERY_TTLS.get(rest[-1])

    # /events, /events/matches, /v3/events/{id}, /v3/events/{id}/matches,
    # /event/{id}, /event/{id}/stats|agents|news|pickem
    if head in ("events", "event"):
        if not rest:
            return CACHE_TTL_EVENTS
        if rest == ["matches"]:
            return CACHE_TTL_EVENT_MATCHES
        if len(rest) == 1:
            return CACHE_TTL_EVENTS
        return _EVENT_RESOURCE_TTLS.get(rest[-1])

    return None


def stale_while_revalidate(ttl: int) -> int:
    """How long the edge may serve a stale copy while it refreshes in the background.

    Short-lived payloads (live scores, results) get half their TTL so a busy
    page is never more than 1.5x the TTL behind; everything else gets twice
    its TTL, capped at a day.
    """
    if ttl <= CACHE_TTL_RESULTS:
        return max(ttl // 2, 1)
    return min(ttl * 2, MAX_STALE_WHILE_REVALIDATE)


def shared_cache_control(ttl: int) -> str:
    return (
        f"public, max-age=0, s-maxage={ttl}, "
        f"stale-while-revalidate={stale_while_revalidate(ttl)}"
    )


def _payload_status(payload) -> str:
    """Return the match status a match-detail payload reports, lowercased."""
    if not isinstance(payload, dict):
        return ""
    data = payload.get("data")
    if isinstance(data, dict):
        # V3: {"data": {"status": "live", ...}}
        if isinstance(data.get("status"), str):
            return data["status"].lower()
        # V2 / original: {"data": {"segments": [{"status": "LIVE", ...}]}}
        segments = data.get("segments")
        if isinstance(segments, list) and segments and isinstance(segments[0], dict):
            return str(segments[0].get("status", "")).lower()
    return ""


def _is_error_status(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 400


def _embedded_error(payload) -> bool:
    """True when a 200 body wraps a scraper error.

    Scraper payloads carry it as ``data.status``; the legacy rankings shape
    hoists it to a top-level ``status``.
    """
    if not isinstance(payload, dict):
        return False
    data = payload.get("data")
    if isinstance(data, dict) and _is_error_status(data.get("status")):
        return True
    return _is_error_status(payload.get("status"))


def _match_detail_ttl(payload) -> int:
    return (
        CACHE_TTL_MATCH_DETAIL_LIVE
        if "live" in _payload_status(payload)
        else CACHE_TTL_MATCH_DETAIL
    )


def _set_header(headers: list[tuple[bytes, bytes]], name: bytes, value: str) -> list:
    kept = [(key, val) for key, val in headers if key.lower() != name]
    kept.append((name, value.encode("latin-1")))
    return kept


def _is_json(headers: list[tuple[bytes, bytes]]) -> bool:
    for key, value in headers:
        if key.lower() == b"content-type":
            return value.strip().lower().startswith(b"application/json")
    return False


class CacheControlMiddleware:
    """Attach per-route shared-cache headers to successful GET responses."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("method") not in ("GET", "HEAD"):
            await self.app(scope, receive, send)
            return

        ttl = route_ttl(
            scope.get("path", ""),
            scope.get("query_string", b"").decode("latin-1"),
        )

        # Shared with the route via request.state (Starlette stores it here).
        state = scope.setdefault("state", {})

        def capped(value: int) -> int:
            cap = state.get(EDGE_TTL_CAP_STATE)
            return min(value, cap) if isinstance(cap, int) and cap > 0 else value

        start: Message | None = None
        chunks: list[bytes] = []
        buffering = False

        async def wrapped_send(message: Message) -> None:
            nonlocal start, buffering
            if message["type"] == "http.response.start":
                status = message["status"]
                headers = list(message.get("headers", []))
                if status == 304:
                    headers = _set_header(headers, b"cache-control", PRIVATE_REVALIDATE)
                elif not 200 <= status < 300:
                    headers = _set_header(headers, b"cache-control", NO_STORE)
                elif ttl is not None and _is_json(headers):
                    # The TTL (and whether to cache at all) depends on the body.
                    start = {**message, "headers": headers}
                    buffering = True
                    return
                elif ttl is not None and ttl != MATCH_DETAIL:
                    headers = _set_header(
                        headers, b"cache-control", shared_cache_control(capped(ttl))
                    )
                await send({**message, "headers": headers})
                return

            if not buffering:
                await send(message)
                return

            chunks.append(message.get("body", b""))
            if message.get("more_body", False):
                return

            body = b"".join(chunks)
            await send(self._finalise(start, body, ttl, capped))
            await send({"type": "http.response.body", "body": body, "more_body": False})

        await self.app(scope, receive, wrapped_send)

    @staticmethod
    def _finalise(start: Message, body: bytes, ttl: int, capped) -> Message:
        headers = list(start["headers"])
        try:
            payload = json.loads(body) if body else None
        except ValueError:
            payload = None

        if _embedded_error(payload):
            value = NO_STORE
        else:
            effective = _match_detail_ttl(payload) if ttl == MATCH_DETAIL else ttl
            value = shared_cache_control(capped(effective))
        return {**start, "headers": _set_header(headers, b"cache-control", value)}
