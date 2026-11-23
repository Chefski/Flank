"""
Fill missing team logos in match-list payloads without a scrape fan-out.

vlr.gg's list pages carry no team logos, so a list record only gets one when
``utils.team_logos.team_logo_store`` already knows the match or the team. For
the rest, a bounded number of match pages is fetched per request:

* at most ``TEAM_LOGO_ENRICH_MAX_PER_REQUEST`` new matches per list request,
  in list order (the rows a client shows first);
* at most ``TEAM_LOGO_ENRICH_CONCURRENCY`` match pages in flight across all
  requests, via one shared semaphore, and one fetch per match ever in flight;
* the request waits at most ``TEAM_LOGO_ENRICH_BUDGET_SECONDS``. Fetches still
  running then keep going and land in the store for the next request;
* a match page that fails is not retried for ``TEAM_LOGO_MISS_TTL``.

The payload is copied, never mutated, because list payloads are shared
in-process cache entries.
"""

import asyncio
import copy
import logging

from api.scrapers.match_detail.parsers import _parse_teams
from utils.constants import (
    TEAM_LOGO_ENRICH_BUDGET_SECONDS,
    TEAM_LOGO_ENRICH_CONCURRENCY,
    TEAM_LOGO_ENRICH_FETCH_TIMEOUT,
    TEAM_LOGO_ENRICH_MAX_PER_REQUEST,
    VLR_BASE_URL,
)
from utils.html_parsers import add_image_variants, parse_html
from utils.http_client import fetch_theme_variants, get_http_client
from utils.team_logos import TeamLogoStore, team_logo_store

logger = logging.getLogger(__name__)

_PLACEHOLDER_NAMES = frozenset({"", "tbd", "tba"})

MAX_FETCHES_PER_REQUEST = TEAM_LOGO_ENRICH_MAX_PER_REQUEST
BUDGET_SECONDS = TEAM_LOGO_ENRICH_BUDGET_SECONDS

_semaphore: asyncio.Semaphore | None = None
_inflight: dict[str, asyncio.Task] = {}


def _get_semaphore() -> asyncio.Semaphore:
    global _semaphore
    if _semaphore is None:
        _semaphore = asyncio.Semaphore(TEAM_LOGO_ENRICH_CONCURRENCY)
    return _semaphore


def _reset_for_tests() -> None:
    global _semaphore
    _semaphore = None
    for task in _inflight.values():
        task.cancel()
    _inflight.clear()


async def fetch_match_logos(match_id: str, store: TeamLogoStore = team_logo_store) -> bool:
    """Fetch one match page (both themes) and record its two teams' logos."""
    async with _get_semaphore():
        if store.has_match(match_id):
            return True
        try:
            light, dark = await fetch_theme_variants(
                f"{VLR_BASE_URL}/{match_id}",
                client=get_http_client(),
                timeout=TEAM_LOGO_ENRICH_FETCH_TIMEOUT,
                max_retries=1,
            )
        except Exception as exc:  # network error, open circuit
            logger.info("Logo fetch for match %s failed: %s", match_id, type(exc).__name__)
            store.record_miss(match_id)
            return False
        if light.status_code >= 400:
            store.record_miss(match_id)
            return False
        teams = _parse_teams(parse_html(light.text))
        dark_teams = _parse_teams(parse_html(dark.text))
        for index, team in enumerate(teams):
            add_image_variants(team, dark_teams[index] if index < len(dark_teams) else None)
        store.record_match(match_id, teams)
        if not store.has_match(match_id):
            store.record_miss(match_id)
        return store.has_match(match_id)


def _schedule(match_id: str, store: TeamLogoStore) -> asyncio.Task:
    task = _inflight.get(match_id)
    if task is None or task.done():
        task = asyncio.ensure_future(fetch_match_logos(match_id, store))
        _inflight[match_id] = task
        task.add_done_callback(lambda _t, key=match_id: _inflight.pop(key, None))
    return task


def _needs_logo(team: dict) -> bool:
    name = " ".join(str(team.get("name") or "").split()).casefold()
    return not team.get("logo") and name not in _PLACEHOLDER_NAMES


def _apply(record: dict, store: TeamLogoStore) -> bool:
    """Fill logos into one canonical match record; True if a gap remains."""
    match_id = record.get("match_id")
    gap = False
    for slot, team in enumerate((record.get("teams") or [])[:2]):
        if not isinstance(team, dict) or not _needs_logo(team):
            continue
        entry = store.lookup(match_id, slot, team.get("name"))
        if entry is None:
            gap = True
            continue
        team["logo"] = entry["logo"]
        team["logo_light"] = entry["logo_light"]
        team["logo_dark"] = entry["logo_dark"]
        # A match-page entry is exact, so it may also supply the missing identity.
        if store.has_match(match_id):
            team["id"] = team.get("id") or entry["id"]
            team["url"] = team.get("url") or entry["url"]
    return gap


async def enrich_match_list_logos(
    payload: dict,
    *,
    store: TeamLogoStore = team_logo_store,
    max_fetches: int | None = None,
    budget: float | None = None,
) -> tuple[dict, bool]:
    """Return ``(payload copy with logos filled, complete)``.

    ``complete`` is False when a fetchable logo is still missing, so callers can
    shorten how long the response is cached. ``max_fetches`` and ``budget``
    default to the module settings, read at call time.
    """
    if max_fetches is None:
        max_fetches = MAX_FETCHES_PER_REQUEST
    if budget is None:
        budget = BUDGET_SECONDS
    payload = copy.deepcopy(payload)
    records = [
        segment["match"]
        for segment in payload.get("segments") or []
        if isinstance(segment, dict) and isinstance(segment.get("match"), dict)
    ]

    pending: list[str] = []
    for record in records:
        if _apply(record, store):
            match_id = str(record.get("match_id") or "")
            if match_id.isdigit() and not store.is_known_miss(match_id) and match_id not in pending:
                pending.append(match_id)

    if pending and max_fetches > 0:
        tasks = [_schedule(match_id, store) for match_id in pending[:max_fetches]]
        await asyncio.wait(tasks, timeout=budget)

    complete = True
    for record in records:
        if _apply(record, store):
            match_id = str(record.get("match_id") or "")
            if match_id.isdigit() and not store.is_known_miss(match_id):
                complete = False
    return payload, complete
