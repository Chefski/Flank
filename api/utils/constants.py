"""
Configuration constants for VLR.GG API
"""
import math
import os

# Base URLs
VLR_BASE_URL = "https://www.vlr.gg"
VLR_EVENTS_URL = f"{VLR_BASE_URL}/events"
VLR_MATCHES_URL = f"{VLR_BASE_URL}/matches"
VLR_RANKINGS_URL = f"{VLR_BASE_URL}/rankings"
VLR_STATS_URL = f"{VLR_BASE_URL}/stats"
VLR_NEWS_URL = f"{VLR_BASE_URL}/news"

# Entity URL prefixes — scrapers append the id and any query string
VLR_PLAYER_URL = f"{VLR_BASE_URL}/player"
VLR_TEAM_URL = f"{VLR_BASE_URL}/team"

# API Settings
API_TITLE = "vlrggapi"
API_DESCRIPTION = (
    "An Unofficial REST API for [vlr.gg](https://www.vlr.gg/), "
    "a site for Valorant Esports match and news coverage. "
    "Made by [axsddlr](https://github.com/axsddlr)"
)
API_PORT = 3001

# Single runtime source of truth for the API version. Packaging declares its own
# copy in pyproject.toml (which is not copied into the Docker image);
# tests/test_version_consistency.py fails if the two ever drift apart.
API_VERSION = "3.0.0"

# Request settings
DEFAULT_TIMEOUT = 30
DEFAULT_RETRIES = 3
DEFAULT_REQUEST_DELAY = 1.0
MIN_RESPONSE_SIZE = 100

# Pagination concurrency
PAGINATION_SEMAPHORE_LIMIT = 4

# Circuit breaker
CIRCUIT_FAIL_MAX = 5
CIRCUIT_RESET_TIMEOUT = 30.0


def _env_float(name: str, default: float) -> float:
    """A finite float from the environment, or ``default`` if unset or invalid."""
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        return default
    return value if math.isfinite(value) else default


# Upstream politeness (utils.http_client.UpstreamGuard). Every request to
# vlr.gg from this process, whichever scraper sends it, shares these limits.
# They are per process: on Vercel each warm instance has its own budget.
#   - at most UPSTREAM_MAX_CONCURRENCY requests in flight at once;
#   - request starts spaced at least UPSTREAM_MIN_INTERVAL seconds apart;
#   - a 403 or 429 (or a 503 with Retry-After) pauses every request to the
#     host for the longer of Retry-After and an escalating cooldown, which
#     starts at UPSTREAM_COOLDOWN_BASE and doubles on each repeat up to
#     UPSTREAM_COOLDOWN_MAX, resetting after the next success.
UPSTREAM_MAX_CONCURRENCY = int(_env_float("VLR_MAX_CONCURRENCY", 6))
UPSTREAM_MIN_INTERVAL = _env_float("VLR_MIN_REQUEST_INTERVAL", 0.1)
UPSTREAM_COOLDOWN_BASE = 60.0
UPSTREAM_COOLDOWN_MAX = 900.0
# Retry-After is honoured above UPSTREAM_COOLDOWN_MAX, but never beyond this.
UPSTREAM_RETRY_AFTER_CAP = 3600.0
# A request waits at most this long for a free slot, then fails fast with
# UpstreamBusyError (503, or the last good payload) instead of queueing.
UPSTREAM_SLOT_WAIT_TIMEOUT = 15.0

# A light-theme image URL's dark-theme counterpart, learned whenever both
# themes of a page are fetched, so later pages whose images are all known can
# skip the second (dark) request. See utils.http_client.ThemeImageMap.
THEME_IMAGE_MAP_TTL = 86400
THEME_IMAGE_MAP_SIZE = 20000

# How long the last successful payload for a cache key is kept so it can be
# served when vlr.gg is unavailable, rate limiting, or cooling down.
STALE_FALLBACK_TTL = 6 * 3600

# Request hardening limits for expensive paginated scrapes
MAX_MATCH_PAGE_WINDOW = 20
MAX_MATCH_QUERY_BOUND = 100
MAX_NEWS_PAGE = 500
MAX_MATCH_RETRIES = 3
MAX_MATCH_TIMEOUT = 45
LIVE_DETAIL_FETCH_CONCURRENCY = 4
LIVE_DETAIL_FETCH_TIMEOUT = 10
MATCH_DETAIL_TAB_FETCH_CONCURRENCY = 4
MATCH_DETAIL_TAB_FETCH_TIMEOUT = 10

# Cache TTLs (seconds)
CACHE_TTL_LIVE = 30
CACHE_TTL_UPCOMING = 300
CACHE_TTL_RESULTS = 60
CACHE_TTL_NEWS = 600
CACHE_TTL_NEWS_ARTICLE = 600
CACHE_TTL_STATS = 1800
CACHE_TTL_RANKINGS = 3600
CACHE_TTL_EVENTS = 1800
CACHE_TTL_SEARCH = 300
CACHE_MAX_SIZE = 1000

# Cache TTLs — new scraper endpoints
CACHE_TTL_MATCH_DETAIL = 300
CACHE_TTL_MATCH_DETAIL_LIVE = 30
# A finished match only changes when VODs are attached, so it can sit in the
# caches far longer than an upcoming one.
CACHE_TTL_MATCH_DETAIL_FINAL = 3600
CACHE_TTL_PLAYER = 1800
CACHE_TTL_PLAYER_MATCHES = 600
CACHE_TTL_TEAM = 1800
CACHE_TTL_TEAM_MATCHES = 600
CACHE_TTL_TEAM_TRANSACTIONS = 3600
CACHE_TTL_TEAM_STATS = 600
CACHE_TTL_TEAM_ROSTER = 1800
CACHE_TTL_TEAM_SCHEDULE = 300
CACHE_TTL_EVENT_MATCHES = 600
CACHE_TTL_EVENT_STATS = 600
CACHE_TTL_EVENT_AGENTS = 1800
CACHE_TTL_EVENT_NEWS = 600
CACHE_TTL_EVENT_PICKEM = 300
CACHE_TTL_HEALTH_UPSTREAM = 60

# Team logos are effectively static, so the per-match / per-team logo index
# outlives every payload cache. See utils/team_logos.py.
CACHE_TTL_TEAM_LOGO = 86400
TEAM_LOGO_CACHE_SIZE = 4096
# A match page that could not be fetched is not retried for this long.
TEAM_LOGO_MISS_TTL = 600
# Match-list logo enrichment: at most this many match pages are fetched for
# one list request, this many at once across all requests, and the request
# waits at most this long for them before responding with what it has.
TEAM_LOGO_ENRICH_MAX_PER_REQUEST = 10
TEAM_LOGO_ENRICH_CONCURRENCY = 4
TEAM_LOGO_ENRICH_BUDGET_SECONDS = 2.5
TEAM_LOGO_ENRICH_FETCH_TIMEOUT = 8
# Edge lifetime for a list response that still has fetchable logo gaps, so the
# next request (after the in-flight fetches land) is not held off for long.
CACHE_TTL_PARTIAL_LOGOS = 15
# Edge lifetime for a last-good payload served because a refresh failed, so
# the edge asks again soon instead of pinning old data for the route's TTL.
CACHE_TTL_STALE_FALLBACK_EDGE = 30

# /stats region vocabulary
# The /stats page uses a DIFFERENT region taxonomy from /rankings. vlr.gg's
# filter form submits exactly these canonical values (as ``region[]`` checkboxes
# since the October 2026 revamp); any other value silently falls back to "all".
# Kept separate from utils.utils.region (the /rankings contract) so
# /rankings?region=americas still returns 400.
STATS_REGIONS = frozenset({"all", "americas", "emea", "pacific", "china", "intl"})

# The /stats ``tier[]`` checkboxes in the order the page renders them. When the
# request omits the group, vlr.gg applies its own default of VCT alone (the form
# carries ``data-defaults`` tier=vct and only the vct box comes back checked),
# which silently narrows the ladder to VCT events. Every value is sent so the
# scope stays what the pre-revamp page returned.
STATS_TIERS = ("vct", "vcl", "t3", "gc", "cg", "off")

# /stats filters by vlr.gg's internal numeric map_id, not by map name. These ids
# come from the <select name="map_id"> on the stats page itself; callers pass a
# map name (or "all") and the scraper translates it.
STATS_MAP_IDS = {
    "ascent": "5",
    "bind": "1",
    "breeze": "8",
    "corrode": "14",
    "fracture": "9",
    "haven": "2",
    "icebox": "6",
    "lotus": "11",
    "pearl": "10",
    "split": "3",
    "summit": "16",
    "sunset": "12",
    "abyss": "13",
}
