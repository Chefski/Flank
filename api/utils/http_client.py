"""
Async HTTP client singleton using httpx.

Every request to vlr.gg goes through ``fetch_with_retries``, which applies
the process-wide ``UpstreamGuard`` (concurrency cap, request pacing and a
host cooldown after 403/429) before the per-host ``CircuitBreaker``.
"""
import asyncio
import difflib
import logging
import random
import re
import time
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from urllib.parse import urlparse

import httpx
from cachetools import TTLCache

from utils.constants import (
    CIRCUIT_FAIL_MAX,
    CIRCUIT_RESET_TIMEOUT,
    DEFAULT_REQUEST_DELAY,
    DEFAULT_RETRIES,
    DEFAULT_TIMEOUT,
    MIN_RESPONSE_SIZE,
    THEME_IMAGE_MAP_SIZE,
    THEME_IMAGE_MAP_TTL,
    UPSTREAM_COOLDOWN_BASE,
    UPSTREAM_COOLDOWN_MAX,
    UPSTREAM_MAX_CONCURRENCY,
    UPSTREAM_MIN_INTERVAL,
    UPSTREAM_RETRY_AFTER_CAP,
    UPSTREAM_SLOT_WAIT_TIMEOUT,
    VLR_BASE_URL,
)
from utils.utils import headers

logger = logging.getLogger(__name__)

RETRYABLE_STATUS_CODES = {500, 502, 503, 504}
# Statuses that mean "you are sending too much" (or "you are blocked"). They
# are never retried: retrying is exactly what turns a rate limit into a ban.
PUSHBACK_STATUS_CODES = {403, 429}

# Captured at import so tests that patch ``asyncio.sleep`` to observe retry
# backoff do not also see (or skip) request pacing.
_pace_sleep = asyncio.sleep

VLR_THEME_COOKIES = {
    "light": "settings=%7B%22dark_mode%22%3A0%7D",
    "dark": "settings=%7B%22dark_mode%22%3A1%7D",
}

# Log lines must never interpolate the request URL: its path and query carry
# caller-supplied ids and search terms, so a crafted value could forge a log
# entry. Every request goes to the same configured origin, so the constant host
# (taken from the config, not from the URL being fetched) identifies the
# upstream on its own.
_UPSTREAM_HOST = urlparse(VLR_BASE_URL).netloc or "upstream"


class CircuitOpenError(Exception):
    """Raised when the circuit breaker is open for a host."""


class CircuitBreaker:
    """Per-host open/half-open/closed circuit breaker.

    Trips after fail_max consecutive failures and re-probes after reset_timeout seconds.
    Only network errors and 5xx responses count as failures; 429 does not.
    """

    _CLOSED = "closed"
    _OPEN = "open"
    _HALF_OPEN = "half_open"

    def __init__(self, fail_max: int = CIRCUIT_FAIL_MAX, reset_timeout: float = CIRCUIT_RESET_TIMEOUT) -> None:
        self.fail_max = fail_max
        self.reset_timeout = reset_timeout
        self._failures: dict[str, int] = {}
        self._state: dict[str, str] = {}
        self._opened_at: dict[str, float] = {}

    @staticmethod
    def _host(url: str) -> str:
        return urlparse(url).netloc

    def _current_state(self, host: str) -> str:
        state = self._state.get(host, self._CLOSED)
        if state == self._OPEN:
            if time.monotonic() - self._opened_at.get(host, 0.0) >= self.reset_timeout:
                self._state[host] = self._HALF_OPEN
                return self._HALF_OPEN
        return state

    def allow_request(self, url: str) -> bool:
        """Return True if a request should proceed; False when the circuit is open."""
        return self._current_state(self._host(url)) != self._OPEN

    def record_success(self, url: str) -> None:
        host = self._host(url)
        self._failures[host] = 0
        self._state[host] = self._CLOSED

    def record_failure(self, url: str) -> None:
        host = self._host(url)
        count = self._failures.get(host, 0) + 1
        self._failures[host] = count
        if count >= self.fail_max:
            self._state[host] = self._OPEN
            self._opened_at[host] = time.monotonic()
            logger.warning("Circuit opened after %d consecutive failures", count)

    def reset(self) -> None:
        """Clear all state. Intended for use in tests."""
        self._failures.clear()
        self._state.clear()
        self._opened_at.clear()


circuit_breaker = CircuitBreaker()


class UpstreamCooldownError(CircuitOpenError):
    """Raised while a host is cooling down after it answered 403/429.

    Subclasses CircuitOpenError so every existing handler maps it to a 503
    (and the cache serves its last good payload where it has one).
    """


class UpstreamBusyError(CircuitOpenError):
    """Raised when no upstream request slot frees up in time.

    Every slot is held by a slow request; queueing longer would only pile up
    callers. Like the cooldown it maps to a 503 or the last good payload.
    """


class UpstreamGuard:
    """Process-wide politeness shared by every request to every host.

    * ``slot()`` caps requests in flight and spaces request starts at least
      ``min_interval`` apart, so a burst of cache misses (a cold instance,
      a Bo5 match detail with ten tab pages, list logo enrichment) reaches
      vlr.gg as a steady trickle rather than a spike.
    * ``record_pushback()`` pauses a host after a 403/429 for the longer of
      its Retry-After and an escalating cooldown. While paused no request is
      sent at all; callers fail fast and the cache serves stale data.
    """

    def __init__(
        self,
        max_concurrency: int = UPSTREAM_MAX_CONCURRENCY,
        min_interval: float = UPSTREAM_MIN_INTERVAL,
        cooldown_base: float = UPSTREAM_COOLDOWN_BASE,
        cooldown_max: float = UPSTREAM_COOLDOWN_MAX,
    ) -> None:
        self.max_concurrency = max(1, max_concurrency)
        self.min_interval = max(0.0, min_interval)
        self.cooldown_base = cooldown_base
        self.cooldown_max = cooldown_max
        self._semaphore: asyncio.Semaphore | None = None
        self._next_start = 0.0
        self._cooldown_until: dict[str, float] = {}
        self._strikes: dict[str, int] = {}

    @staticmethod
    def _host(url: str) -> str:
        return urlparse(url).netloc

    @asynccontextmanager
    async def slot(self, wait_timeout: float | None = UPSTREAM_SLOT_WAIT_TIMEOUT):
        """Hold one request slot, paced after the previous request start.

        Waits at most ``wait_timeout`` seconds for a free slot, then raises
        UpstreamBusyError. Callers must re-check the cooldown and circuit
        inside the slot: both can change while a request is queued here.
        """
        if self._semaphore is None:
            self._semaphore = asyncio.Semaphore(self.max_concurrency)
        semaphore = self._semaphore
        try:
            if wait_timeout is None:
                await semaphore.acquire()
            else:
                async with asyncio.timeout(wait_timeout):
                    await semaphore.acquire()
        except TimeoutError:
            raise UpstreamBusyError(
                f"No request slot for {_UPSTREAM_HOST} freed up within {wait_timeout:.0f}s"
            ) from None
        try:
            if self.min_interval > 0:
                now = time.monotonic()
                start = max(now, self._next_start)
                # Reserve the start now so queued requests space themselves out,
                # then move it to the real dispatch time below.
                self._next_start = start + self.min_interval
                if start > now:
                    await _pace_sleep(start - now)
                self._next_start = max(self._next_start, time.monotonic() + self.min_interval)
            yield
        finally:
            semaphore.release()

    def cooldown_remaining(self, url: str) -> float:
        until = self._cooldown_until.get(self._host(url), 0.0)
        return max(0.0, until - time.monotonic())

    def record_pushback(self, url: str, retry_after: float | None) -> float:
        """Start (or extend) the host's cooldown and return its length in seconds.

        Pushback that lands while the host is already cooling down (a burst of
        requests answered 429 together) is one strike, not several: it only
        extends the pause when its own Retry-After asks for longer.
        """
        host = self._host(url)
        remaining = self.cooldown_remaining(url)
        if remaining > 0:
            if retry_after is not None:
                wanted = min(retry_after, UPSTREAM_RETRY_AFTER_CAP)
                if wanted > remaining:
                    self._cooldown_until[host] = time.monotonic() + wanted
                    return wanted
            return remaining
        strikes = self._strikes.get(host, 0) + 1
        self._strikes[host] = strikes
        delay = min(self.cooldown_base * 2 ** (strikes - 1), self.cooldown_max)
        if retry_after is not None:
            delay = max(delay, min(retry_after, UPSTREAM_RETRY_AFTER_CAP))
        until = time.monotonic() + delay
        self._cooldown_until[host] = max(self._cooldown_until.get(host, 0.0), until)
        return delay

    def record_ok(self, url: str) -> None:
        self._strikes.pop(self._host(url), None)

    def reset(self) -> None:
        """Clear all state. Intended for use in tests."""
        self._semaphore = None
        self._next_start = 0.0
        self._cooldown_until.clear()
        self._strikes.clear()


upstream_guard = UpstreamGuard()


# Image URLs on vlr.gg's CDN. Team and event logos are the only parts of a page
# that differ between themes, and they always live here.
_CDN_SRC = re.compile(r'src="((?:https?:)?//owcdn\.net/[^"]+)"')
# owcdn file names are PHP uniqid()s: 8 hex digits of Unix seconds, then 5 of
# microseconds. A team's light and dark logos are uploaded together.
_UNIQID_NAME = re.compile(r"/([0-9a-f]{13})\.[a-z]+$")
# Real light/dark pairs were uploaded 6-11 s apart.
_MAX_THEME_PAIR_UPLOAD_GAP = 300
# Forum post flairs show a team's light logo in both themes, so they say
# nothing about its dark variant. They live in the comments, which start at
# this marker on match and news pages; flairs elsewhere are skipped by class.
_COMMENTS_MARKER = '<div id="comments"'
_IMG_TAG = re.compile(r"<img\b[^>]*>", re.IGNORECASE)
_FLAIR_CLASS = re.compile(r'class="[^"]*\bpost-header-flair\b', re.IGNORECASE)


def _theme_srcs(html: str) -> list[str]:
    """CDN image URLs that differ by theme, in page order.

    Skips everything from the comments onwards and any forum flair.
    """
    cut = html.find(_COMMENTS_MARKER)
    if cut >= 0:
        html = html[:cut]
    srcs: list[str] = []
    for tag in _IMG_TAG.findall(html):
        if _FLAIR_CLASS.search(tag):
            continue
        srcs.extend(_CDN_SRC.findall(tag))
    return srcs


def _plausible_theme_pair(light: str, dark: str) -> bool:
    """Guard against pairing two different teams' logos.

    Pairs are learned positionally, so if a list reorders between the light
    and dark fetch two unrelated logos could line up. Real pairs were
    uploaded within moments of each other.
    """
    light_match = _UNIQID_NAME.search(light)
    dark_match = _UNIQID_NAME.search(dark)
    if not light_match or not dark_match:
        return False
    gap = abs(int(light_match.group(1)[:8], 16) - int(dark_match.group(1)[:8], 16))
    return gap <= _MAX_THEME_PAIR_UPLOAD_GAP


class ThemeImageMap:
    """Learned light-theme → dark-theme image URLs.

    vlr.gg only varies CDN images between themes, so once every CDN image on
    a light page has a known dark counterpart the dark page can be rebuilt
    locally instead of fetched, halving requests for match, team and
    rankings pages.
    """

    def __init__(self, ttl: int = THEME_IMAGE_MAP_TTL, maxsize: int = THEME_IMAGE_MAP_SIZE) -> None:
        self._dark: TTLCache = TTLCache(maxsize=maxsize, ttl=ttl)

    def learn(self, light_html: str, dark_html: str) -> None:
        light = _theme_srcs(light_html)
        dark = _theme_srcs(dark_html)
        matcher = difflib.SequenceMatcher(a=light, b=dark, autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                for src in light[i1:i2]:
                    # Never let an identity pair hide a known dark variant.
                    if self._dark.get(src, src) == src:
                        self._dark[src] = src
            elif tag == "replace" and i2 - i1 == j2 - j1:
                for light_src, dark_src in zip(light[i1:i2], dark[j1:j2]):
                    if _plausible_theme_pair(light_src, dark_src):
                        self._dark[light_src] = dark_src

    def dark_variant(self, light_html: str) -> str | None:
        """Return the page with dark images, or None if any image is unknown.

        Flairs and comment images do not need to be known; they are swapped
        too when known, which is harmless (the dark page shows either).
        """
        mapping: dict[str, str] = {}
        for src in set(_theme_srcs(light_html)):
            dark = self._dark.get(src)
            if dark is None:
                return None
            mapping[src] = dark
        if all(light == dark for light, dark in mapping.items()):
            return light_html
        return _CDN_SRC.sub(
            lambda m: f'src="{mapping.get(m.group(1), m.group(1))}"', light_html
        )

    def clear(self) -> None:
        self._dark.clear()


theme_image_map = ThemeImageMap()


def _synthesized_response(source: httpx.Response, html: str) -> httpx.Response:
    content_type = source.headers.get("content-type") or "text/html; charset=utf-8"
    return httpx.Response(
        source.status_code,
        headers={"content-type": content_type},
        content=html.encode("utf-8"),
    )


def _parse_retry_after(response: httpx.Response) -> float | None:
    """Parse the Retry-After header into seconds. Returns None if absent or unparseable."""
    value = response.headers.get("Retry-After")
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        pass
    try:
        dt = parsedate_to_datetime(value)
        delta = (dt - datetime.now(tz=UTC)).total_seconds()
        return max(0.0, delta)
    except Exception:
        return None


def is_pushback(response: httpx.Response) -> bool:
    """True when vlr.gg says "slow down": 403, 429, or a 503 carrying Retry-After."""
    status = response.status_code
    return status in PUSHBACK_STATUS_CODES or (
        status == 503 and _parse_retry_after(response) is not None
    )


def _backoff(request_delay: float, attempt: int) -> float:
    """Exponential backoff with up to 25% jitter so retries never move in lockstep."""
    return request_delay * (2 ** (attempt - 1)) * random.uniform(1.0, 1.25)


_client: httpx.AsyncClient | None = None


def get_http_client() -> httpx.AsyncClient:
    """Get or create the singleton async HTTP client."""
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient(
            headers=headers,
            timeout=httpx.Timeout(DEFAULT_TIMEOUT),
            follow_redirects=True,
            limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
        )
    return _client


def _raise_if_blocked(url: str) -> None:
    """Raise if no request may be sent to the host right now."""
    remaining = upstream_guard.cooldown_remaining(url)
    if remaining > 0:
        raise UpstreamCooldownError(
            f"{_UPSTREAM_HOST} asked us to slow down; pausing requests for {remaining:.0f}s more"
        )
    if not circuit_breaker.allow_request(url):
        raise CircuitOpenError(f"Circuit open for {_UPSTREAM_HOST}; request blocked")


async def fetch_with_retries(
    url: str,
    *,
    client: httpx.AsyncClient | None = None,
    timeout: int | float | httpx.Timeout | None = None,
    max_retries: int = DEFAULT_RETRIES,
    request_delay: float = DEFAULT_REQUEST_DELAY,
    extra_headers: dict[str, str] | None = None,
    record_circuit_outcome: bool = True,
) -> httpx.Response:
    """Fetch a URL with bounded retries for transient upstream failures.

    Raises CircuitOpenError immediately if the per-host circuit is open, and
    UpstreamCooldownError (a CircuitOpenError) while the host is cooling down
    after pushing back. Both are checked again right before dispatch, after
    waiting for a request slot, so requests queued behind a 429 never go out.
    UpstreamBusyError (also a CircuitOpenError) means no slot freed up in
    time. Records a failure against the circuit only after all retries are
    exhausted.

    ``timeout=None`` keeps the client's own timeout; it never disables it.

    403 and 429 are pushback, not outages: they are returned at once without a
    retry, start the host cooldown (honouring Retry-After), and leave the
    circuit alone. A 503 that carries Retry-After is treated the same way.

    Set ``record_circuit_outcome`` to False for optional requests whose success
    or failure must not alter shared host health. The request still respects an
    already-open circuit and an active cooldown.
    """
    _raise_if_blocked(url)

    client = client or get_http_client()
    # An explicit timeout=None would switch the client's timeout off.
    request_timeout = httpx.USE_CLIENT_DEFAULT if timeout is None else timeout
    retries = max(1, max_retries)
    last_response: httpx.Response | None = None

    request_headers: dict[str, str] = {}
    if extra_headers:
        request_headers.update(extra_headers)

    for attempt in range(1, retries + 1):
        if attempt > 1 and upstream_guard.cooldown_remaining(url) > 0:
            # Another request tripped the cooldown while this one was backing off.
            if last_response is not None:
                return last_response
            raise UpstreamCooldownError(f"{_UPSTREAM_HOST} is cooling down")

        try:
            async with upstream_guard.slot():
                # The host may have pushed back, or the circuit opened, while
                # this request waited for its slot or its pacing turn.
                try:
                    _raise_if_blocked(url)
                except CircuitOpenError:
                    if last_response is not None:
                        return last_response
                    raise
                response = await client.get(
                    url,
                    timeout=request_timeout,
                    headers=request_headers if request_headers else None,
                )
        except httpx.RequestError as exc:
            if attempt >= retries:
                if record_circuit_outcome:
                    circuit_breaker.record_failure(url)
                raise
            logger.warning(
                "Retrying %s after request error on attempt %d/%d: %s",
                _UPSTREAM_HOST, attempt, retries, type(exc).__name__,
            )
            await asyncio.sleep(_backoff(request_delay, attempt))
            continue

        last_response = response
        status = response.status_code
        retry_after = _parse_retry_after(response)

        if is_pushback(response):
            pause = upstream_guard.record_pushback(url, retry_after)
            logger.warning(
                "%s answered %d; pausing all requests to it for %.0fs",
                _UPSTREAM_HOST, status, pause,
            )
            return response

        empty_body = status == 200 and len(response.content) < MIN_RESPONSE_SIZE

        if not empty_body and (status not in RETRYABLE_STATUS_CODES or attempt >= retries):
            if status not in RETRYABLE_STATUS_CODES:
                upstream_guard.record_ok(url)
                if record_circuit_outcome:
                    circuit_breaker.record_success(url)
            elif record_circuit_outcome:
                circuit_breaker.record_failure(url)
            return response

        if empty_body:
            logger.warning(
                "Retrying %s after empty response body (%d bytes) on attempt %d/%d",
                _UPSTREAM_HOST, len(response.content), attempt, retries,
            )
            if attempt >= retries:
                return response

        backoff = _backoff(request_delay, attempt)

        logger.warning(
            "Retrying %s after upstream status %d on attempt %d/%d (backoff %.1fs)",
            _UPSTREAM_HOST, response.status_code, attempt, retries, backoff,
        )
        await asyncio.sleep(backoff)

    if last_response is not None:
        return last_response
    raise RuntimeError(f"Failed to fetch {url} without producing a response")


async def fetch_theme_variants(
    url: str,
    *,
    client: httpx.AsyncClient | None = None,
    timeout: int | float | httpx.Timeout | None = None,
    max_retries: int = DEFAULT_RETRIES,
    request_delay: float = DEFAULT_REQUEST_DELAY,
) -> tuple[httpx.Response, httpx.Response]:
    """Fetch VLR.GG's light and dark variants of the same page.

    VLR.GG chooses theme-specific logo assets server-side from the ``settings``
    cookie. Both requests use explicit cookie values so the singleton client's
    state cannot make the result depend on an earlier request.

    The light response remains authoritative for status and page content. If
    only the optional dark request fails, callers receive the light response as
    both variants so existing endpoints remain available with a safe fallback.

    The light page is fetched first. When ``theme_image_map`` already knows
    the dark counterpart of every CDN image on it, the dark page is rebuilt
    from it and no second request is sent; otherwise the dark page is fetched
    and its image pairs are learned for next time.
    """
    client = client or get_http_client()

    async def fetch(appearance: str) -> httpx.Response:
        return await fetch_with_retries(
            url,
            client=client,
            timeout=timeout,
            max_retries=max_retries,
            request_delay=request_delay,
            extra_headers={"Cookie": VLR_THEME_COOKIES[appearance]},
            record_circuit_outcome=appearance == "light",
        )

    light_result = await fetch("light")
    if light_result.status_code >= 400:
        return light_result, light_result

    dark_html = theme_image_map.dark_variant(light_result.text)
    if dark_html is not None:
        if dark_html is light_result.text:
            return light_result, light_result
        return light_result, _synthesized_response(light_result, dark_html)

    try:
        dark_result = await fetch("dark")
    except Exception as exc:
        logger.warning(
            "Dark-theme fetch from %s failed: %s", _UPSTREAM_HOST, type(exc).__name__
        )
        return light_result, light_result

    if dark_result.status_code >= 400:
        logger.warning(
            "Dark-theme fetch from %s returned status %d; using light fallback",
            _UPSTREAM_HOST,
            dark_result.status_code,
        )
        return light_result, light_result

    theme_image_map.learn(light_result.text, dark_result.text)
    return light_result, dark_result


async def close_http_client():
    """Close the HTTP client. Call during app shutdown."""
    global _client
    if _client is not None and not _client.is_closed:
        await _client.aclose()
        _client = None
