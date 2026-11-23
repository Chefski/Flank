"""Fewer and gentler requests to vlr.gg: request slots, theme-image reuse, stale fallback."""
import asyncio

import httpx
import pytest
from fastapi import HTTPException

from utils import http_client
from utils.cache_headers import _edge_hints
from utils.cache_manager import CacheManager
from utils.constants import CACHE_TTL_STALE_FALLBACK_EDGE
from utils.http_client import (
    CircuitOpenError,
    ThemeImageMap,
    UpstreamBusyError,
    UpstreamCooldownError,
    UpstreamGuard,
    circuit_breaker,
    fetch_theme_variants,
    fetch_with_retries,
    theme_image_map,
    upstream_guard,
)

# Real-looking owcdn uniqid names: light and dark uploaded seconds apart.
TEAM_A_LIGHT = "//owcdn.net/img/603c00d5c5a08.png"
TEAM_A_DARK = "//owcdn.net/img/603c00dbb7d39.png"
TEAM_B = "//owcdn.net/img/6466d79e1ed40.png"  # same in both themes
TEAM_C_LIGHT = "//owcdn.net/img/679314c8ac387.png"
UNRELATED = "//owcdn.net/img/5a1b2c3d4e5f6.png"  # uploaded years earlier


def page(*srcs: str) -> str:
    imgs = "".join(f'<img src="{src}">' for src in srcs)
    return f"<html><body>{imgs}{'x' * 120}</body></html>"


class FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text
        self.content = text.encode()
        self.headers = {"content-type": "text/html; charset=UTF-8"}


class ThemeClient:
    """Serves the light or dark page depending on the settings cookie."""

    def __init__(self, light: str, dark: str):
        self.pages = {"0": light, "1": dark}
        self.calls: list[str] = []

    async def get(self, url, timeout=None, headers=None):
        theme = "1" if "dark_mode%22%3A1" in (headers or {}).get("Cookie", "") else "0"
        self.calls.append(theme)
        return FakeResponse(200, self.pages[theme])


def test_learns_identity_and_plausible_pairs():
    themes = ThemeImageMap()
    themes.learn(page(TEAM_A_LIGHT, TEAM_B), page(TEAM_A_DARK, TEAM_B))

    assert themes.dark_variant(page(TEAM_B, TEAM_A_LIGHT)) == page(TEAM_B, TEAM_A_DARK)


def test_unknown_image_means_the_dark_page_must_be_fetched():
    themes = ThemeImageMap()
    themes.learn(page(TEAM_A_LIGHT), page(TEAM_A_DARK))

    assert themes.dark_variant(page(TEAM_A_LIGHT, TEAM_C_LIGHT)) is None


def test_does_not_pair_logos_uploaded_far_apart():
    """A list that reordered between the two fetches must not cross-wire teams."""
    themes = ThemeImageMap()
    themes.learn(page(TEAM_C_LIGHT), page(UNRELATED))

    assert themes.dark_variant(page(TEAM_C_LIGHT)) is None


def test_theme_invariant_flair_does_not_erase_a_known_dark_logo():
    """Forum flairs show a team's light logo in both themes."""
    themes = ThemeImageMap()
    themes.learn(page(TEAM_A_LIGHT), page(TEAM_A_DARK))
    themes.learn(page(TEAM_B, TEAM_A_LIGHT), page(TEAM_B, TEAM_A_LIGHT))

    assert themes.dark_variant(page(TEAM_A_LIGHT)) == page(TEAM_A_DARK)


def test_page_without_cdn_images_needs_no_dark_variant():
    assert ThemeImageMap().dark_variant(page()) == page()


@pytest.mark.anyio
async def test_second_page_with_known_images_is_fetched_once():
    first = ThemeClient(page(TEAM_A_LIGHT, TEAM_B), page(TEAM_A_DARK, TEAM_B))
    light, dark = await fetch_theme_variants("https://example.test/match/1", client=first)
    assert first.calls == ["0", "1"]
    assert TEAM_A_DARK in dark.text

    second = ThemeClient(page(TEAM_B, TEAM_A_LIGHT), "unused")
    light, dark = await fetch_theme_variants("https://example.test/match/2", client=second)

    assert second.calls == ["0"]
    assert light.text == page(TEAM_B, TEAM_A_LIGHT)
    assert dark.text == page(TEAM_B, TEAM_A_DARK)
    assert dark.status_code == 200
    theme_image_map.clear()


# --- stale fallback ---------------------------------------------------------


@pytest.mark.anyio
@pytest.mark.parametrize(
    "failure",
    [
        UpstreamCooldownError("cooling down"),
        HTTPException(status_code=503, detail="down"),
    ],
)
async def test_serves_last_good_payload_when_upstream_fails(failure):
    cache = CacheManager()
    good = {"data": {"status": 200, "segments": [1]}}

    async def ok():
        return good

    async def broken():
        raise failure

    assert await cache.get_or_create_async(1, ok, "rankings", "na") == good
    cache._caches["1"].clear()  # fresh entry expired; last good remains

    assert await cache.get_or_create_async(1, broken, "rankings", "na") == good


@pytest.mark.anyio
async def test_serves_last_good_payload_instead_of_an_upstream_429_payload():
    cache = CacheManager()
    good = {"data": {"status": 200, "segments": [1]}}

    async def ok():
        return good

    async def limited():
        return {"data": {"status": 429, "error": "rate limited", "segments": []}}

    await cache.get_or_create_async(1, ok, "news", 1)
    cache._caches["1"].clear()

    assert await cache.get_or_create_async(1, limited, "news", 1) == good


@pytest.mark.anyio
async def test_does_not_hide_not_found_or_fail_without_a_last_good_payload():
    cache = CacheManager()
    good = {"data": {"status": 200, "segments": [1]}}

    async def ok():
        return good

    async def missing():
        raise HTTPException(status_code=404, detail="no such match")

    async def broken():
        raise UpstreamCooldownError("cooling down")

    await cache.get_or_create_async(1, ok, "match", 7)
    cache._caches["1"].clear()

    with pytest.raises(HTTPException):
        await cache.get_or_create_async(1, missing, "match", 7)
    with pytest.raises(UpstreamCooldownError):
        await cache.get_or_create_async(1, broken, "match", 8)


# --- theme image map: flairs, comments, upload gap -------------------------


def flair(src: str) -> str:
    return f'<img class="post-header-flair" src="{src}" title="Team">'


def page_with_comments(header_srcs: tuple[str, ...], comment_srcs: tuple[str, ...]) -> str:
    header = "".join(f'<img src="{src}">' for src in header_srcs)
    comments = "".join(f'<img src="{src}">' for src in comment_srcs)
    return (
        f"<html><body>{header}<div id=\"comments\"></div>"
        f"<div class=\"threading\">{comments}</div>{'x' * 120}</body></html>"
    )


def test_team_first_seen_as_a_flair_still_gets_its_dark_logo_learned():
    """A flair shows the light logo in both themes; it must not teach identity."""
    themes = ThemeImageMap()
    forum_light = f"<html><body>{flair(TEAM_A_LIGHT)}{'x' * 120}</body></html>"
    themes.learn(forum_light, forum_light)

    # The team's header logo is still unknown, so the dark page must be fetched...
    assert themes.dark_variant(page(TEAM_A_LIGHT)) is None

    # ...and once it is, the real pair is learned.
    themes.learn(page(TEAM_A_LIGHT), page(TEAM_A_DARK))
    assert themes.dark_variant(page(TEAM_A_LIGHT)) == page(TEAM_A_DARK)


def test_flairs_and_comment_images_are_not_required_to_be_known():
    themes = ThemeImageMap()
    themes.learn(page(TEAM_A_LIGHT), page(TEAM_A_DARK))

    with_flair = f"<html><body><img src=\"{TEAM_A_LIGHT}\">{flair(TEAM_C_LIGHT)}{'x' * 120}</body></html>"
    dark = themes.dark_variant(with_flair)
    assert dark is not None
    assert TEAM_A_DARK in dark
    assert TEAM_C_LIGHT in dark  # unknown flair left as it is

    in_comments = page_with_comments((TEAM_A_LIGHT,), (TEAM_C_LIGHT,))
    assert themes.dark_variant(in_comments) == page_with_comments((TEAM_A_DARK,), (TEAM_C_LIGHT,))


def test_comment_images_are_not_learned():
    themes = ThemeImageMap()
    light = page_with_comments((TEAM_A_LIGHT,), (TEAM_C_LIGHT,))
    dark = page_with_comments((TEAM_A_DARK,), (TEAM_C_LIGHT,))
    themes.learn(light, dark)

    assert themes.dark_variant(page(TEAM_C_LIGHT)) is None
    assert themes.dark_variant(page(TEAM_A_LIGHT)) == page(TEAM_A_DARK)


def test_does_not_pair_logos_uploaded_minutes_apart():
    ten_minutes_later = "//owcdn.net/img/603c032dc5a08.png"  # 0x603c00d5 + 600 s
    themes = ThemeImageMap()
    themes.learn(page(TEAM_A_LIGHT), page(ten_minutes_later))

    assert themes.dark_variant(page(TEAM_A_LIGHT)) is None


# --- request slots: re-check before dispatch, pacing, busy, timeout ----------


class GatedClient:
    """Holds every request until ``release`` is set, then answers ``status``."""

    def __init__(self, status: int):
        self.status = status
        self.release = asyncio.Event()
        self.calls: list[str] = []
        self.timeouts: list = []

    async def get(self, url, timeout=None, headers=None):
        self.calls.append(url)
        self.timeouts.append(timeout)
        await self.release.wait()
        return FakeResponse(self.status, "x" * 200)


@pytest.mark.anyio
async def test_requests_queued_behind_a_429_are_never_sent(monkeypatch):
    monkeypatch.setattr(upstream_guard, "max_concurrency", 1)
    client = GatedClient(429)

    first = asyncio.create_task(fetch_with_retries("https://example.test/a", client=client))
    await asyncio.sleep(0)
    queued = asyncio.create_task(fetch_with_retries("https://example.test/b", client=client))
    await asyncio.sleep(0)
    client.release.set()

    assert (await first).status_code == 429
    with pytest.raises(UpstreamCooldownError):
        await queued
    assert client.calls == ["https://example.test/a"]


@pytest.mark.anyio
async def test_requests_queued_while_the_circuit_opens_are_never_sent(monkeypatch):
    monkeypatch.setattr(upstream_guard, "max_concurrency", 1)
    client = GatedClient(200)
    circuit_breaker.reset()
    try:
        first = asyncio.create_task(
            fetch_with_retries("https://example.test/a", client=client, record_circuit_outcome=False)
        )
        await asyncio.sleep(0)
        queued = asyncio.create_task(fetch_with_retries("https://example.test/b", client=client))
        await asyncio.sleep(0)
        for _ in range(circuit_breaker.fail_max):
            circuit_breaker.record_failure("https://example.test/")
        client.release.set()

        assert (await first).status_code == 200
        with pytest.raises(CircuitOpenError):
            await queued
        assert client.calls == ["https://example.test/a"]
    finally:
        circuit_breaker.reset()


def test_a_burst_of_pushback_is_one_strike():
    guard = UpstreamGuard(cooldown_base=60, cooldown_max=900)
    url = "https://example.test/x"

    for _ in range(4):
        guard.record_pushback(url, None)
    assert guard._strikes["example.test"] == 1
    assert guard.cooldown_remaining(url) == pytest.approx(60, abs=1)

    # A longer Retry-After during the cooldown still extends it.
    guard.record_pushback(url, 300)
    assert guard.cooldown_remaining(url) == pytest.approx(300, abs=1)
    assert guard._strikes["example.test"] == 1

    guard._cooldown_until.clear()
    guard.record_pushback(url, None)
    assert guard._strikes["example.test"] == 2
    assert guard.cooldown_remaining(url) == pytest.approx(120, abs=1)


@pytest.mark.anyio
async def test_pacing_counts_from_the_actual_dispatch_time(monkeypatch):
    guard = UpstreamGuard(max_concurrency=4, min_interval=0.5)
    clock = [1000.0]
    paced: list[float] = []

    async def oversleeping_pace(delay):
        paced.append(round(delay, 2))
        clock[0] += delay + 0.3  # the event loop woke us late

    monkeypatch.setattr(http_client, "_pace_sleep", oversleeping_pace)
    monkeypatch.setattr(http_client.time, "monotonic", lambda: clock[0])

    for _ in range(3):
        async with guard.slot():
            pass

    # Second request dispatched at 1000.8, so the third waits a full 0.5 s
    # from then (to 1001.3), not just until the 1001.0 it had reserved.
    assert paced == [0.5, 0.5]


@pytest.mark.anyio
async def test_waiting_for_a_slot_is_bounded():
    guard = UpstreamGuard(max_concurrency=1, min_interval=0.0)
    holding = asyncio.Event()
    done = asyncio.Event()

    async def hold():
        async with guard.slot():
            holding.set()
            await done.wait()

    holder = asyncio.create_task(hold())
    await holding.wait()

    with pytest.raises(UpstreamBusyError) as exc_info:
        async with guard.slot(wait_timeout=0.01):
            pass
    assert isinstance(exc_info.value, CircuitOpenError)

    done.set()
    await holder
    # The timed-out waiter did not leak or consume the slot.
    async with guard.slot(wait_timeout=0.1):
        pass


@pytest.mark.anyio
async def test_no_timeout_override_keeps_the_client_timeout():
    client = GatedClient(200)
    client.release.set()

    await fetch_with_retries("https://example.test/a", client=client)
    await fetch_with_retries("https://example.test/a", client=client, timeout=7)

    assert client.timeouts == [httpx.USE_CLIENT_DEFAULT, 7]


# --- stale fallback: edge lifetime and staleness -----------------------------


@pytest.mark.anyio
async def test_stale_fallback_caps_the_edge_ttl_and_flags_staleness():
    cache = CacheManager()
    good = {"data": {"status": 200, "segments": [1]}}

    async def ok():
        return good

    async def broken():
        raise UpstreamCooldownError("cooling down")

    fresh_hints: dict = {}
    token = _edge_hints.set(fresh_hints)
    try:
        await cache.get_or_create_async(1, ok, "rankings", "eu")
    finally:
        _edge_hints.reset(token)
    assert fresh_hints == {}

    cache._caches["1"].clear()
    stale_hints: dict = {}
    token = _edge_hints.set(stale_hints)
    try:
        assert await cache.get_or_create_async(1, broken, "rankings", "eu") == good
    finally:
        _edge_hints.reset(token)
    assert stale_hints == {"cap": CACHE_TTL_STALE_FALLBACK_EDGE, "stale": True}


def test_partial_payload_never_replaces_a_complete_last_good():
    cache = CacheManager()
    complete = {"data": {"status": 200, "segments": ["complete"]}}
    partial = {"data": {"status": 200, "segments": ["partial"]}}
    newer_partial = {"data": {"status": 200, "segments": ["newer partial"]}}

    cache.set_partial_if_cacheable(30, partial, "k")
    assert cache.last_good("k") is partial  # better than nothing
    cache.set_partial_if_cacheable(30, newer_partial, "k")
    assert cache.last_good("k") is newer_partial

    cache.set_if_cacheable(3600, complete, "k")
    cache.set_partial_if_cacheable(30, partial, "k")
    assert cache.last_good("k") is complete
    assert cache.get(30, "k") is partial
    assert cache.cached_ttl(partial, (30, 3600), "k") == 30
    assert cache.cached_ttl(complete, (30, 3600), "k") == 3600
