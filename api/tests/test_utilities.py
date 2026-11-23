"""Tests for utility modules: pagination, html_parsers, error_handling, cache_manager."""
import asyncio
from datetime import timedelta

import httpx
import pytest
from fastapi import HTTPException

from api.scrapers.events import vlr_event_matches, vlr_events
from api.scrapers.match_detail import vlr_match_detail
from api.scrapers.players import _parse_event_placements, vlr_player, vlr_player_matches
from utils.cache_manager import CacheManager, cache_manager
from utils.constants import CACHE_TTL_EVENTS, CACHE_TTL_MATCH_DETAIL
from utils.error_handling import validate_event_query, validate_match_query, validate_region, validate_timespan
from utils.html_parsers import (
    HTMLParser,
    combine_date_and_time,
    parse_eta_to_timedelta,
    parse_html,
    parse_match_timestamp,
)
from utils.http_client import (
    CircuitOpenError,
    circuit_breaker,
    fetch_theme_variants,
    fetch_with_retries,
)
from utils.pagination import PaginationConfig, scrape_multiple_pages


@pytest.mark.anyio
async def test_retry_logs_identify_the_upstream_without_echoing_the_url(monkeypatch, caplog):
    """The URL carries caller-supplied ids, so it must never reach a log line."""
    marker = "forged-entry"
    url = f"https://www.vlr.gg/match/123/{marker}"
    client = FakeAsyncClient({url: [FakeResponse(503), FakeResponse(503)]})

    async def fake_sleep(_delay):
        return None

    monkeypatch.setattr("utils.http_client.asyncio.sleep", fake_sleep)
    circuit_breaker.reset()

    with caplog.at_level("WARNING", logger="utils.http_client"):
        await fetch_with_retries(url, client=client, max_retries=2)

    assert marker not in caplog.text
    assert "https://www.vlr.gg" not in caplog.text
    assert "www.vlr.gg" in caplog.text


# --- PaginationConfig.get_page_range ---

class TestPaginationConfig:
    def test_default_single_page(self):
        cfg = PaginationConfig(num_pages=1)
        assert cfg.get_page_range() == (1, 1, 1)

    def test_num_pages_from_start(self):
        cfg = PaginationConfig(num_pages=5)
        assert cfg.get_page_range() == (1, 5, 5)

    def test_from_and_to_page(self):
        cfg = PaginationConfig(from_page=3, to_page=7)
        assert cfg.get_page_range() == (3, 7, 5)

    def test_from_page_with_num_pages(self):
        cfg = PaginationConfig(num_pages=3, from_page=5)
        assert cfg.get_page_range() == (5, 7, 3)

    def test_to_page_with_num_pages(self):
        cfg = PaginationConfig(num_pages=3, to_page=10)
        assert cfg.get_page_range() == (8, 10, 3)

    def test_to_page_clamps_to_1(self):
        cfg = PaginationConfig(num_pages=20, to_page=5)
        assert cfg.get_page_range() == (1, 5, 5)


# --- parse_eta_to_timedelta ---

class TestParseEta:
    def test_hours_minutes(self):
        assert parse_eta_to_timedelta("4h 1m") == timedelta(hours=4, minutes=1)

    def test_days_hours(self):
        assert parse_eta_to_timedelta("1d 2h") == timedelta(days=1, hours=2)

    def test_minutes_only(self):
        assert parse_eta_to_timedelta("30m") == timedelta(minutes=30)

    def test_live_returns_none(self):
        assert parse_eta_to_timedelta("LIVE") is None

    def test_ago_returns_none(self):
        assert parse_eta_to_timedelta("2h ago") is None

    def test_empty_returns_none(self):
        assert parse_eta_to_timedelta("") is None

    def test_none_returns_none(self):
        assert parse_eta_to_timedelta(None) is None


class TestParseMatchTimestamp:
    @staticmethod
    def _item(ts: str):
        return HTMLParser(f'<div><div class="moment-tz-convert" data-utc-ts="{ts}">2:20 AM CEST</div></div>').body

    def test_data_utc_ts_is_eastern_summer(self):
        # Match 706350: data-utc-ts 20:20 EDT is shown as 2:20 AM CEST
        assert parse_match_timestamp(self._item("2026-07-16 20:20:00"), "") == "2026-07-17 00:20:00"

    def test_data_utc_ts_is_eastern_winter(self):
        assert parse_match_timestamp(self._item("2026-01-15 20:00:00"), "") == "2026-01-16 01:00:00"

    def test_data_utc_ts_unix_number(self):
        # Homepage: 1790845200 is shown as 11:00 AM CEST
        assert parse_match_timestamp(self._item("1790845200"), "") == "2026-10-01 09:00:00"

    def test_unparseable_data_utc_ts_falls_through(self):
        assert parse_match_timestamp(self._item("soon"), "") == ""


# --- combine_date_and_time ---


class TestCombineDateAndTime:
    def test_valid_12h_format(self):
        result = combine_date_and_time("Mon, February 9, 2026", "4:00 AM")
        assert result == "2026-02-09 09:00:00"

    def test_valid_24h_format(self):
        result = combine_date_and_time("February 9, 2026", "16:00")
        assert result == "2026-02-09 21:00:00"

    def test_short_month_format(self):
        result = combine_date_and_time("Feb 9, 2026", "12:30 PM")
        assert result == "2026-02-09 17:30:00"

    def test_today_tomorrow(self):
        result = combine_date_and_time("Today", "4:00 AM")
        assert result != ""
        result_tomorrow = combine_date_and_time("Tomorrow", "4:00 AM")
        assert result_tomorrow != ""

    def test_empty_or_none(self):
        assert combine_date_and_time("", "4:00 AM") == ""
        assert combine_date_and_time("February 9, 2026", "") == ""
        assert combine_date_and_time(None, "4:00 AM") == ""
        assert combine_date_and_time("February 9, 2026", None) == ""

    def test_sentinel_times(self):
        assert combine_date_and_time("February 9, 2026", "TBD") == ""
        assert combine_date_and_time("February 9, 2026", "LIVE") == ""
        assert combine_date_and_time("February 9, 2026", "-") == ""

    def test_invalid_date_or_time(self):
        assert combine_date_and_time("not-a-date", "4:00 AM") == ""
        assert combine_date_and_time("February 9, 2026", "not-a-time") == ""


# --- Validators ---

class TestValidators:
    def test_validate_region_valid(self):
        assert validate_region("na") == "north-america"
        assert validate_region("eu") == "europe"

    def test_validate_region_invalid(self):
        with pytest.raises(HTTPException) as exc_info:
            validate_region("invalid_region")
        assert exc_info.value.status_code == 400

    def test_validate_timespan_valid(self):
        for ts in ("30", "60", "90", "all"):
            validate_timespan(ts)  # Should not raise

    def test_validate_timespan_invalid(self):
        with pytest.raises(HTTPException) as exc_info:
            validate_timespan("45")
        assert exc_info.value.status_code == 400

    def test_validate_match_query_valid(self):
        for q in ("upcoming", "upcoming_extended", "live_score", "results"):
            validate_match_query(q)  # Should not raise

    def test_validate_match_query_invalid(self):
        with pytest.raises(HTTPException) as exc_info:
            validate_match_query("invalid")
        assert exc_info.value.status_code == 400

    def test_validate_event_query_valid(self):
        for q in ("upcoming", "completed", None):
            validate_event_query(q)  # Should not raise

    def test_validate_event_query_invalid(self):
        with pytest.raises(HTTPException) as exc_info:
            validate_event_query("invalid")
        assert exc_info.value.status_code == 400


# --- CacheManager ---

class TestCacheManager:
    def test_get_set(self):
        cm = CacheManager()
        cm.set(60, "value1", "key1")
        assert cm.get(60, "key1") == "value1"

    def test_get_missing(self):
        cm = CacheManager()
        assert cm.get(60, "nonexistent") is None

    def test_different_args_different_keys(self):
        cm = CacheManager()
        cm.set(60, "a", "key1")
        cm.set(60, "b", "key2")
        assert cm.get(60, "key1") == "a"
        assert cm.get(60, "key2") == "b"

    def test_invalidate(self):
        cm = CacheManager()
        cm.set(60, "value", "key1")
        cm.invalidate(60, "key1")
        assert cm.get(60, "key1") is None

    def test_clear_all(self):
        cm = CacheManager()
        cm.set(60, "a", "k1")
        cm.set(120, "b", "k2")
        cm.clear_all()
        assert cm.get(60, "k1") is None
        assert cm.get(120, "k2") is None

    def test_make_cache_key_deterministic(self):
        key1 = CacheManager.make_cache_key("a", "b", x=1)
        key2 = CacheManager.make_cache_key("a", "b", x=1)
        assert key1 == key2

    def test_make_cache_key_different_args(self):
        key1 = CacheManager.make_cache_key("a")
        key2 = CacheManager.make_cache_key("b")
        assert key1 != key2

    def test_set_if_cacheable_skips_error_statuses(self):
        cm = CacheManager()
        stored = cm.set_if_cacheable(60, {"data": {"status": 503, "segments": []}}, "key1")
        assert stored is False
        assert cm.get(60, "key1") is None

    def test_set_if_cacheable_skips_error_payloads(self):
        cm = CacheManager()
        stored = cm.set_if_cacheable(60, {"data": {"status": 200, "error": "bad gateway"}}, "key1")
        assert stored is False
        assert cm.get(60, "key1") is None

    @pytest.mark.anyio
    async def test_get_or_create_async_coalesces_concurrent_calls(self):
        cm = CacheManager()
        calls = 0

        async def producer():
            nonlocal calls
            calls += 1
            await asyncio.sleep(0)
            return {"data": {"status": 200, "segments": ["ok"]}}

        results = await asyncio.gather(
            cm.get_or_create_async(60, producer, "key1"),
            cm.get_or_create_async(60, producer, "key1"),
            cm.get_or_create_async(60, producer, "key1"),
        )

        assert calls == 1
        assert results == [
            {"data": {"status": 200, "segments": ["ok"]}},
            {"data": {"status": 200, "segments": ["ok"]}},
            {"data": {"status": 200, "segments": ["ok"]}},
        ]
        assert cm.get(60, "key1") == {"data": {"status": 200, "segments": ["ok"]}}

    @pytest.mark.anyio
    async def test_get_or_create_async_does_not_cache_non_cacheable_results(self):
        cm = CacheManager()
        calls = 0

        async def producer():
            nonlocal calls
            calls += 1
            await asyncio.sleep(0)
            return {"data": {"status": 503, "segments": []}}

        first, second = await asyncio.gather(
            cm.get_or_create_async(60, producer, "key1"),
            cm.get_or_create_async(60, producer, "key1"),
        )
        third = await cm.get_or_create_async(60, producer, "key1")

        assert calls == 2
        assert first == {"data": {"status": 503, "segments": []}}
        assert second == {"data": {"status": 503, "segments": []}}
        assert third == {"data": {"status": 503, "segments": []}}
        assert cm.get(60, "key1") is None


class FakeResponse:
    def __init__(self, status_code: int, text: str = "<html></html>", headers: dict | None = None):
        self.status_code = status_code
        self.text = text
        self.content = text.encode("utf-8") if len(text) >= 100 else (text + "x" * 100).encode("utf-8")
        self.headers = headers or {}


class FakeAsyncClient:
    def __init__(self, responses: dict[str, list[FakeResponse | Exception]]):
        self._responses = responses
        self.calls: list[tuple[str, int | None]] = []

    async def get(self, url: str, timeout=None, headers=None):
        self.calls.append((url, timeout))
        response = self._responses[url].pop(0)
        if isinstance(response, Exception):
            raise response
        return response


@pytest.mark.anyio
async def test_scrape_multiple_pages_raises_when_any_page_exhausts_retries(monkeypatch):
    client = FakeAsyncClient(
        {
            "https://example.test/page-1": [FakeResponse(200)],
            "https://example.test/page-2": [FakeResponse(503), FakeResponse(503)],
        }
    )

    async def fake_sleep(_delay):
        return None

    monkeypatch.setattr("utils.pagination.get_http_client", lambda: client)
    monkeypatch.setattr("utils.pagination.asyncio.sleep", fake_sleep)

    def parse_func(_html, page: int):
        return [{"page": page}]

    config = PaginationConfig(
        num_pages=2,
        max_retries=2,
        request_delay=0.1,
        timeout=5,
    )

    with pytest.raises(HTTPException) as exc_info:
        await scrape_multiple_pages(
            base_url="https://example.test",
            parse_func=parse_func,
            config=config,
            page_url_func=lambda _base, page: f"https://example.test/page-{page}",
        )

    assert exc_info.value.status_code == 502
    assert "Pages with exhausted retries: 2" in exc_info.value.detail
    assert client.calls == [
        ("https://example.test/page-1", 5),
        ("https://example.test/page-2", 5),
        ("https://example.test/page-2", 5),
    ]


def _three_pages(client, monkeypatch, max_retries=3):
    async def fake_sleep(_delay):
        return None

    monkeypatch.setattr("utils.pagination.get_http_client", lambda: client)
    monkeypatch.setattr("utils.pagination.asyncio.sleep", fake_sleep)
    return scrape_multiple_pages(
        base_url="https://example.test",
        parse_func=lambda _html, page: [{"page": page}],
        config=PaginationConfig(num_pages=3, max_retries=max_retries, request_delay=0.1, timeout=5),
        page_url_func=lambda _base, page: f"https://example.test/page-{page}",
    )


@pytest.mark.anyio
async def test_a_failing_page_counts_once_against_the_shared_circuit(monkeypatch):
    """Retries belong to fetch_with_retries: one circuit failure per page, not per attempt."""
    circuit_breaker.reset()
    client = FakeAsyncClient(
        {
            "https://example.test/page-1": [FakeResponse(200)],
            "https://example.test/page-2": [FakeResponse(503)] * 3,
            "https://example.test/page-3": [FakeResponse(200)],
        }
    )
    try:
        with pytest.raises(HTTPException) as exc_info:
            await _three_pages(client, monkeypatch)

        assert exc_info.value.status_code == 502
        assert "Pages with exhausted retries: 2." in exc_info.value.detail
        assert [url for url, _ in client.calls].count("https://example.test/page-2") == 3
        # Page 3's success closed it again; before that page 2 added just one failure.
        assert circuit_breaker._failures.get("example.test") == 0
    finally:
        circuit_breaker.reset()


@pytest.mark.anyio
async def test_two_bad_paginated_scrapes_do_not_open_the_circuit(monkeypatch):
    circuit_breaker.reset()
    try:
        for _ in range(2):
            client = FakeAsyncClient(
                {f"https://example.test/page-{page}": [FakeResponse(503)] * 3 for page in (1, 2)}
            )

            async def fake_sleep(_delay):
                return None

            monkeypatch.setattr("utils.pagination.get_http_client", lambda client=client: client)
            monkeypatch.setattr("utils.pagination.asyncio.sleep", fake_sleep)
            with pytest.raises(HTTPException):
                await scrape_multiple_pages(
                    base_url="https://example.test",
                    parse_func=lambda _html, page: [],
                    config=PaginationConfig(num_pages=2, max_retries=3, request_delay=0.1, timeout=5),
                    page_url_func=lambda _base, page: f"https://example.test/page-{page}",
                )
        assert circuit_breaker._failures.get("example.test") == 4
        assert circuit_breaker.allow_request("https://example.test/page-1")
    finally:
        circuit_breaker.reset()


@pytest.mark.anyio
@pytest.mark.parametrize(
    "pushback",
    [
        FakeResponse(429),
        FakeResponse(403),
        FakeResponse(503, headers={"Retry-After": "60"}),
    ],
)
async def test_pushback_stops_further_pages(monkeypatch, pushback):
    client = FakeAsyncClient(
        {
            "https://example.test/page-1": [FakeResponse(200)],
            "https://example.test/page-2": [pushback],
            "https://example.test/page-3": [FakeResponse(200)],
        }
    )

    with pytest.raises(HTTPException) as exc_info:
        await _three_pages(client, monkeypatch)

    assert exc_info.value.status_code == 502
    assert "Pages with exhausted retries: 2, 3." in exc_info.value.detail
    assert "asked us to slow down at page 2" in exc_info.value.detail
    assert [url for url, _ in client.calls] == [
        "https://example.test/page-1",
        "https://example.test/page-2",
    ]


@pytest.mark.anyio
async def test_vlr_events_does_not_cache_non_200_responses(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            "https://www.vlr.gg/events": [
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(200),
            ],
        }
    )

    monkeypatch.setattr("api.scrapers.events.get_http_client", lambda: client)

    first = await vlr_events()
    second = await vlr_events()

    assert first["data"]["status"] == 503
    assert first["data"]["error"] == "VLR.GG returned status 503 for events"
    assert first["data"]["segments"] == []
    assert second["data"]["status"] == 200
    assert client.calls == [
        ("https://www.vlr.gg/events", httpx.USE_CLIENT_DEFAULT),
        ("https://www.vlr.gg/events", httpx.USE_CLIENT_DEFAULT),
        ("https://www.vlr.gg/events", httpx.USE_CLIENT_DEFAULT),
        ("https://www.vlr.gg/events", httpx.USE_CLIENT_DEFAULT),
    ]
    assert cache_manager.get(CACHE_TTL_EVENTS, "events", True, True, 1, False) == second
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_event_matches_returns_error_payload_for_non_200(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            "https://www.vlr.gg/event/matches/42": [
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(200),
            ],
        }
    )

    monkeypatch.setattr("api.scrapers.events.get_http_client", lambda: client)

    first = await vlr_event_matches("42")
    second = await vlr_event_matches("42")

    assert first["data"] == {
        "status": 503,
        "error": "VLR.GG returned status 503 for event matches 42",
        "segments": [],
    }
    assert second["data"]["status"] == 200
    cache_manager.clear_all()


PLAYER_EVENTS_HTML = """
<html>
  <a class="wf-module-item player-event-item" href="/event/3123/champions">
    <div class="text-of">Champions Tour</div>
    <div class="ge-text-light">Playoffs — 4th</div>
    <div class="ge-text-light">$10,000</div>
    <div>Team 2024 2025</div>
  </a>
</html>
"""


def test_parse_event_placements_uses_the_trailing_year_as_the_date():
    """The date column follows the team name, so a year inside the name is kept."""
    placements = _parse_event_placements(parse_html(PLAYER_EVENTS_HTML))

    assert len(placements) == 1
    assert placements[0]["date"] == "2025"
    assert placements[0]["team"] == "Team 2024"


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("scraper", "args", "url", "expected_error"),
    [
        (
            vlr_player,
            ("9", "90d"),
            "https://www.vlr.gg/player/9/?timespan=90d",
            "VLR.GG returned status 503 for player 9",
        ),
        (
            vlr_player_matches,
            ("9", 2),
            "https://www.vlr.gg/player/matches/9/?page=2",
            "VLR.GG returned status 503 for player matches 9 page 2",
        ),
    ],
)
async def test_player_scrapers_return_error_payload_for_non_200(
    monkeypatch, scraper, args, url, expected_error
):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            url: [
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(200),
            ],
        }
    )

    monkeypatch.setattr("api.scrapers.players.get_http_client", lambda: client)

    first = await scraper(*args)
    second = await scraper(*args)

    assert first["data"] == {
        "status": 503,
        "error": expected_error,
        "segments": [],
    }
    assert second["data"]["status"] == 200
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_match_detail_does_not_cache_non_200_responses(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            # A failed light page is not followed by a dark fetch.
            "https://www.vlr.gg/123": [
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(503),
                FakeResponse(200),
                FakeResponse(200),
            ],
        }
    )

    monkeypatch.setattr("api.scrapers.match_detail.crawler.get_http_client", lambda: client)

    first = await vlr_match_detail("123")
    second = await vlr_match_detail("123")

    assert first["data"]["status"] == 503
    assert first["data"]["error"] == "VLR.GG returned status 503 for match detail 123"
    assert first["data"]["segments"] == []
    assert second["data"]["status"] == 200
    # FakeResponse(200) carries no CDN images, so the second call needs one request.
    assert client.calls == [("https://www.vlr.gg/123", httpx.USE_CLIENT_DEFAULT)] * 4
    assert cache_manager.get(CACHE_TTL_MATCH_DETAIL, "match_detail", "123", False) == second
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_fetch_with_retries_retries_retryable_status_codes(monkeypatch):
    client = FakeAsyncClient(
        {
            "https://example.test/resource": [FakeResponse(503), FakeResponse(200)],
        }
    )

    async def fake_sleep(_delay):
        return None

    monkeypatch.setattr("utils.http_client.asyncio.sleep", fake_sleep)

    response = await fetch_with_retries(
        "https://example.test/resource",
        client=client,
        max_retries=2,
        request_delay=0.1,
    )

    assert response.status_code == 200
    assert client.calls == [
        ("https://example.test/resource", httpx.USE_CLIENT_DEFAULT),
        ("https://example.test/resource", httpx.USE_CLIENT_DEFAULT),
    ]


@pytest.mark.anyio
async def test_fetch_with_retries_retries_request_errors(monkeypatch):
    client = FakeAsyncClient(
        {
            "https://example.test/resource": [
                httpx.ReadTimeout("timed out"),
                FakeResponse(200),
            ],
        }
    )

    async def fake_sleep(_delay):
        return None

    monkeypatch.setattr("utils.http_client.asyncio.sleep", fake_sleep)

    response = await fetch_with_retries(
        "https://example.test/resource",
        client=client,
        max_retries=2,
        request_delay=0.1,
    )

    assert response.status_code == 200
    assert client.calls == [
        ("https://example.test/resource", httpx.USE_CLIENT_DEFAULT),
        ("https://example.test/resource", httpx.USE_CLIENT_DEFAULT),
    ]


@pytest.mark.anyio
async def test_fetch_with_retries_does_not_retry_429_and_pauses_the_host(monkeypatch):
    from utils.http_client import UpstreamCooldownError, upstream_guard

    client = FakeAsyncClient(
        {
            "https://example.test/resource": [
                FakeResponse(429, headers={"Retry-After": "120"}),
                FakeResponse(200),
            ],
            "https://example.test/other": [FakeResponse(200)],
        }
    )
    sleep_calls: list[float] = []

    async def fake_sleep(delay):
        sleep_calls.append(delay)

    monkeypatch.setattr("utils.http_client.asyncio.sleep", fake_sleep)

    response = await fetch_with_retries("https://example.test/resource", client=client, max_retries=3)

    assert response.status_code == 429
    assert sleep_calls == []
    assert len(client.calls) == 1
    assert 119 < upstream_guard.cooldown_remaining("https://example.test/resource") <= 120

    # Every path on the host is paused, and nothing reaches the network.
    with pytest.raises(UpstreamCooldownError):
        await fetch_with_retries("https://example.test/other", client=client)
    assert len(client.calls) == 1


@pytest.mark.anyio
async def test_403_starts_an_escalating_cooldown_that_resets_on_success(monkeypatch):
    from utils.http_client import upstream_guard

    url = "https://example.test/resource"
    client = FakeAsyncClient({url: [FakeResponse(403), FakeResponse(403), FakeResponse(200), FakeResponse(403)]})

    def expire_cooldown():
        upstream_guard._cooldown_until.clear()

    first = await fetch_with_retries(url, client=client)
    assert first.status_code == 403
    assert upstream_guard.cooldown_remaining(url) == pytest.approx(upstream_guard.cooldown_base, abs=1)

    expire_cooldown()
    await fetch_with_retries(url, client=client)
    assert upstream_guard.cooldown_remaining(url) == pytest.approx(upstream_guard.cooldown_base * 2, abs=1)

    expire_cooldown()
    assert (await fetch_with_retries(url, client=client)).status_code == 200

    await fetch_with_retries(url, client=client)
    assert upstream_guard.cooldown_remaining(url) == pytest.approx(upstream_guard.cooldown_base, abs=1)


@pytest.mark.anyio
async def test_503_with_retry_after_is_pushback_not_a_retry(monkeypatch):
    from utils.http_client import upstream_guard

    url = "https://example.test/resource"
    client = FakeAsyncClient({url: [FakeResponse(503, headers={"Retry-After": "90"}), FakeResponse(200)]})

    response = await fetch_with_retries(url, client=client, max_retries=3)

    assert response.status_code == 503
    assert len(client.calls) == 1
    assert upstream_guard.cooldown_remaining(url) > 89


@pytest.mark.anyio
async def test_upstream_guard_spaces_request_starts(monkeypatch):
    from utils import http_client
    from utils.http_client import UpstreamGuard

    guard = UpstreamGuard(max_concurrency=4, min_interval=0.5)
    clock = [1000.0]
    paced: list[float] = []

    async def fake_pace(delay):
        paced.append(round(delay, 1))
        clock[0] += delay

    monkeypatch.setattr(http_client, "_pace_sleep", fake_pace)
    monkeypatch.setattr(http_client.time, "monotonic", lambda: clock[0])

    for _ in range(3):
        async with guard.slot():
            pass

    assert paced == [0.5, 0.5]


@pytest.mark.anyio
async def test_upstream_guard_caps_requests_in_flight():
    from utils.http_client import UpstreamGuard

    guard = UpstreamGuard(max_concurrency=2, min_interval=0.0)
    in_flight = 0
    peak = 0

    async def request():
        nonlocal in_flight, peak
        async with guard.slot():
            in_flight += 1
            peak = max(peak, in_flight)
            await asyncio.sleep(0.01)
            in_flight -= 1

    await asyncio.gather(*(request() for _ in range(6)))
    assert peak == 2


# --- CircuitBreaker ---

class TestCircuitBreaker:
    def setup_method(self):
        circuit_breaker.reset()

    def test_allows_request_when_closed(self):
        assert circuit_breaker.allow_request("https://example.test/resource") is True

    def test_opens_after_fail_max_failures(self):
        circuit_breaker.fail_max = 3
        for _ in range(3):
            circuit_breaker.record_failure("https://example.test/resource")
        assert circuit_breaker.allow_request("https://example.test/resource") is False

    def test_record_success_resets_failure_count(self):
        circuit_breaker.fail_max = 3
        circuit_breaker.record_failure("https://example.test/resource")
        circuit_breaker.record_failure("https://example.test/resource")
        circuit_breaker.record_success("https://example.test/resource")
        # After success, failure count resets — needs fail_max more failures to open
        circuit_breaker.record_failure("https://example.test/resource")
        assert circuit_breaker.allow_request("https://example.test/resource") is True

    def test_transitions_to_half_open_after_reset_timeout(self):
        import time as _time
        circuit_breaker.fail_max = 1
        circuit_breaker.reset_timeout = 30.0
        circuit_breaker.record_failure("https://example.test/resource")
        assert circuit_breaker.allow_request("https://example.test/resource") is False

        # Backdate opened_at to simulate reset_timeout having elapsed
        circuit_breaker._opened_at["example.test"] = _time.monotonic() - 100.0
        assert circuit_breaker.allow_request("https://example.test/resource") is True

    def test_circuit_is_per_host(self):
        circuit_breaker.fail_max = 1
        circuit_breaker.record_failure("https://example.test/resource")
        assert circuit_breaker.allow_request("https://example.test/resource") is False
        assert circuit_breaker.allow_request("https://other.test/resource") is True

    def teardown_method(self):
        circuit_breaker.reset()
        circuit_breaker.fail_max = 5
        circuit_breaker.reset_timeout = 30.0


@pytest.mark.anyio
async def test_fetch_with_retries_raises_circuit_open_error_when_circuit_is_open():
    circuit_breaker.reset()
    circuit_breaker.fail_max = 1
    circuit_breaker.record_failure("https://example.test/resource")

    with pytest.raises(CircuitOpenError):
        await fetch_with_retries("https://example.test/resource")

    circuit_breaker.reset()
    circuit_breaker.fail_max = 5

@pytest.mark.anyio
async def test_fetch_with_retries_records_failure_after_exhausting_retries(monkeypatch):
    circuit_breaker.reset()
    circuit_breaker.fail_max = 2

    client = FakeAsyncClient(
        {"https://example.test/resource": [FakeResponse(503), FakeResponse(503)]}
    )

    async def fake_sleep(_delay):
        pass

    monkeypatch.setattr("utils.http_client.asyncio.sleep", fake_sleep)

    # First call exhausts retries — records 1 failure
    await fetch_with_retries("https://example.test/resource", client=client, max_retries=2)
    assert circuit_breaker.allow_request("https://example.test/resource") is True

    # Second call exhausts retries — records 2nd failure, trips circuit
    client2 = FakeAsyncClient(
        {"https://example.test/resource": [FakeResponse(503), FakeResponse(503)]}
    )
    await fetch_with_retries("https://example.test/resource", client=client2, max_retries=2)
    assert circuit_breaker.allow_request("https://example.test/resource") is False

    circuit_breaker.reset()
    circuit_breaker.fail_max = 5


@pytest.mark.anyio
async def test_fetch_with_retries_does_not_count_429_as_circuit_failure(monkeypatch):
    from utils.http_client import upstream_guard

    circuit_breaker.reset()
    circuit_breaker.fail_max = 1

    client = FakeAsyncClient({"https://example.test/resource": [FakeResponse(429), FakeResponse(429)]})

    await fetch_with_retries("https://example.test/resource", client=client, max_retries=2)
    upstream_guard._cooldown_until.clear()
    await fetch_with_retries("https://example.test/resource", client=client, max_retries=2)
    assert circuit_breaker.allow_request("https://example.test/resource") is True

    circuit_breaker.reset()
    circuit_breaker.fail_max = 5


@pytest.mark.anyio
async def test_dark_theme_failure_does_not_open_shared_circuit(monkeypatch):
    circuit_breaker.reset()
    circuit_breaker.fail_max = 1

    class ThemeClient:
        async def get(self, url, timeout=None, headers=None):
            if "%3A1%7D" in headers.get("Cookie", ""):
                raise httpx.ReadTimeout("dark theme timed out")
            return FakeResponse(200)

    async def fake_sleep(_delay):
        pass

    monkeypatch.setattr("utils.http_client.asyncio.sleep", fake_sleep)

    light, dark = await fetch_theme_variants(
        "https://example.test/resource",
        client=ThemeClient(),
        max_retries=2,
    )

    assert light.status_code == 200
    assert dark is light
    assert circuit_breaker.allow_request("https://example.test/resource") is True

    circuit_breaker.reset()
    circuit_breaker.fail_max = 5
