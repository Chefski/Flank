"""
In-memory TTL cache manager using cachetools.

Besides the per-TTL caches it keeps the last good payload for each key for
``STALE_FALLBACK_TTL``. When a refresh fails because vlr.gg is down, rate
limiting us, or cooling down (see ``utils.http_client.UpstreamGuard``), that
payload is served instead of an error, so a pushback from vlr.gg costs
freshness rather than availability and never invites a retry storm. A
last-good payload is served with a short edge lifetime and ``X-Data-Stale: 1``
(see ``utils.cache_headers.cap_edge_ttl``), so the edge asks again soon.
"""
import asyncio
import hashlib
import json
import logging

import httpx
from cachetools import TTLCache
from fastapi import HTTPException

from utils.cache_headers import cap_edge_ttl, mark_stale
from utils.constants import CACHE_MAX_SIZE, CACHE_TTL_STALE_FALLBACK_EDGE, STALE_FALLBACK_TTL
from utils.http_client import CircuitOpenError
from utils.id_mapper import id_mapper

logger = logging.getLogger(__name__)


def _is_transient_status(status) -> bool:
    return isinstance(status, int) and not isinstance(status, bool) and (
        status >= 500 or status in (403, 429)
    )


def is_transient_failure(exc: BaseException) -> bool:
    """True for failures that say nothing about the data itself (upstream health)."""
    if isinstance(exc, (CircuitOpenError, httpx.HTTPError)):
        return True
    return isinstance(exc, HTTPException) and _is_transient_status(exc.status_code)


def is_transient_error_payload(value) -> bool:
    """True for a scraper error payload caused by upstream health, not a bad id."""
    if not isinstance(value, dict):
        return False
    payload = value.get("data", value)
    return isinstance(payload, dict) and _is_transient_status(payload.get("status"))


class CacheManager:
    """Per-endpoint TTL caches keyed by endpoint + query params."""

    def __init__(self, max_size: int = CACHE_MAX_SIZE, stale_ttl: int = STALE_FALLBACK_TTL):
        self._max_size = max_size
        self._caches: dict[str, TTLCache] = {}
        self._inflight: dict[str, asyncio.Task] = {}
        self._last_good: TTLCache = TTLCache(maxsize=max_size, ttl=stale_ttl)
        # Keys whose last-good payload is known to be incomplete.
        self._last_good_partial: TTLCache = TTLCache(maxsize=max_size, ttl=stale_ttl)

    def _get_cache(self, ttl: int) -> TTLCache:
        key = str(ttl)
        if key not in self._caches:
            self._caches[key] = TTLCache(maxsize=self._max_size, ttl=ttl)
        return self._caches[key]

    @staticmethod
    def make_cache_key(*args, **kwargs) -> str:
        """Deterministic cache key from args and kwargs."""
        raw = json.dumps({"a": args, "k": kwargs}, sort_keys=True, default=str)
        return hashlib.md5(raw.encode()).hexdigest()

    def get(self, ttl: int, *args, **kwargs):
        """Get cached value or None."""
        cache = self._get_cache(ttl)
        key = self.make_cache_key(*args, **kwargs)
        return cache.get(key)

    def set(self, ttl: int, value, *args, **kwargs):
        """Store a value in the cache."""
        cache = self._get_cache(ttl)
        key = self.make_cache_key(*args, **kwargs)
        cache[key] = value

    @staticmethod
    def is_cacheable(value) -> bool:
        """Return True when a response payload is safe to cache."""
        if not isinstance(value, dict):
            return True

        payload = value.get("data", value)
        if not isinstance(payload, dict):
            return True

        status = payload.get("status")
        if isinstance(status, int) and status >= 400:
            return False

        if payload.get("error"):
            return False

        return True

    def set_if_cacheable(self, ttl: int, value, *args, **kwargs) -> bool:
        """Store a value only when it does not represent an upstream error."""
        if not self.is_cacheable(value):
            return False
        self.set(ttl, value, *args, **kwargs)
        key = self.make_cache_key(*args, **kwargs)
        self._last_good[key] = value
        self._last_good_partial.pop(key, None)
        return True

    def set_partial_if_cacheable(self, ttl: int, value, *args, **kwargs) -> bool:
        """Store an incomplete (but usable) payload.

        It is cached under ``ttl`` like any other, but only becomes the last
        good payload when there is no complete one to keep.
        """
        if not self.is_cacheable(value):
            return False
        self.set(ttl, value, *args, **kwargs)
        key = self.make_cache_key(*args, **kwargs)
        if key not in self._last_good or key in self._last_good_partial:
            self._last_good[key] = value
            self._last_good_partial[key] = True
        return True

    def cached_ttl(self, value, ttls, *args, **kwargs) -> int | None:
        """The TTL of the cache (among ``ttls``) holding exactly ``value``, if any."""
        if value is None:
            return None
        for ttl in ttls:
            if self.get(ttl, *args, **kwargs) is value:
                return ttl
        return None

    def last_good(self, *args, **kwargs):
        """The most recent cacheable payload for this key, however old (or None)."""
        return self._last_good.get(self.make_cache_key(*args, **kwargs))

    @staticmethod
    def _serve_stale(stale):
        # Runs in the caller's context (never inside a coalesced task), so the
        # cap lands on this caller's response.
        cap_edge_ttl(CACHE_TTL_STALE_FALLBACK_EDGE)
        mark_stale()
        return stale

    async def with_stale_fallback(self, producer, *args, **kwargs):
        """Run ``producer``; on a transient upstream failure serve the last good payload.

        Failures that are about the request itself (404, 400) still surface.
        A stale payload gets a short edge lifetime and ``X-Data-Stale: 1``.
        """
        try:
            value = await producer()
        except Exception as exc:
            if is_transient_failure(exc):
                stale = self.last_good(*args, **kwargs)
                if stale is not None:
                    logger.warning("Serving last good payload after %s", type(exc).__name__)
                    return self._serve_stale(stale)
            raise
        if is_transient_error_payload(value):
            stale = self.last_good(*args, **kwargs)
            if stale is not None:
                logger.warning("Serving last good payload after an upstream error status")
                return self._serve_stale(stale)
        return value

    async def coalesce_async(self, key: str, producer):
        """Share one in-flight async producer across concurrent callers."""
        task = self._inflight.get(key)
        if task is None:
            task = asyncio.create_task(producer())
            self._inflight[key] = task

        try:
            return await task
        finally:
            if self._inflight.get(key) is task and task.done():
                self._inflight.pop(key, None)

    async def get_or_create_async(self, ttl: int, producer, *args, **kwargs):
        """Return cached data or coalesce one producer call per cache key."""
        cached = self.get(ttl, *args, **kwargs)
        if cached is not None:
            return cached

        key = f"{ttl}:{self.make_cache_key(*args, **kwargs)}"

        async def build():
            cached_value = self.get(ttl, *args, **kwargs)
            if cached_value is not None:
                return cached_value

            value = await producer()
            self.set_if_cacheable(ttl, value, *args, **kwargs)
            return value

        return await self.with_stale_fallback(
            lambda: self.coalesce_async(key, build), *args, **kwargs
        )

    def invalidate(self, ttl: int, *args, **kwargs):
        """Remove a specific entry."""
        cache = self._get_cache(ttl)
        key = self.make_cache_key(*args, **kwargs)
        cache.pop(key, None)

    def clear_all(self):
        """Clear all caches and the id mapper."""
        for cache in self._caches.values():
            cache.clear()
        self._last_good.clear()
        self._last_good_partial.clear()
        self._inflight.clear()
        id_mapper.clear()


cache_manager = CacheManager()
