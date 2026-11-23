"""Shared-cache (Vercel edge) Cache-Control headers."""
import pytest

from utils.cache_headers import (
    MATCH_DETAIL,
    NO_STORE,
    PRIVATE_REVALIDATE,
    route_ttl,
    shared_cache_control,
    stale_while_revalidate,
)
from utils.constants import (
    CACHE_TTL_EVENT_MATCHES,
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
    CACHE_TTL_STATS,
    CACHE_TTL_TEAM,
    CACHE_TTL_TEAM_MATCHES,
    CACHE_TTL_TEAM_SCHEDULE,
    CACHE_TTL_UPCOMING,
)


@pytest.mark.parametrize(
    "path,query,expected",
    [
        # The Flank app's contract
        ("/v3/matches", "q=upcoming", CACHE_TTL_UPCOMING),
        ("/v3/matches", "q=live_score", CACHE_TTL_LIVE),
        ("/v3/matches", "q=results&num_pages=2", CACHE_TTL_RESULTS),
        ("/v3/matches/793238", "", MATCH_DETAIL),
        ("/v3/news", "page=3", CACHE_TTL_NEWS),
        ("/v3/news/793834", "", CACHE_TTL_NEWS_ARTICLE),
        ("/v2/rankings", "region=na", CACHE_TTL_RANKINGS),
        ("/v2/stats", "region=all&timespan=30", CACHE_TTL_STATS),
        ("/v2/team", "id=2&q=profile", CACHE_TTL_TEAM),
        ("/v2/team", "id=2&q=matches&page=1", CACHE_TTL_TEAM_MATCHES),
        ("/v2/player", "id=9&q=profile&timespan=90d", CACHE_TTL_PLAYER),
        ("/v2/player", "id=9&q=matches&page=1", CACHE_TTL_PLAYER_MATCHES),
        # Other forms
        ("/v2/match", "q=live_score", CACHE_TTL_LIVE),
        ("/match", "q=upcoming_extended", CACHE_TTL_UPCOMING),
        ("/v2/match/details", "match_id=1", MATCH_DETAIL),
        ("/v2/match/1/details", "", MATCH_DETAIL),
        ("/v2/match/logs", "match_id=1", CACHE_TTL_MATCH_DETAIL),
        ("/v2/team", "id=2", CACHE_TTL_TEAM),
        ("/v2/team/2", "", CACHE_TTL_TEAM),
        ("/v2/team/2/schedule", "", CACHE_TTL_TEAM_SCHEDULE),
        ("/team/matches", "id=2", CACHE_TTL_TEAM_MATCHES),
        ("/v2/player/9/matches", "", CACHE_TTL_PLAYER_MATCHES),
        ("/v2/events", "q=upcoming", CACHE_TTL_EVENTS),
        ("/v2/events/matches", "event_id=1", CACHE_TTL_EVENT_MATCHES),
        ("/v3/events/1/matches", "", CACHE_TTL_EVENT_MATCHES),
        ("/v2/event/1", "", CACHE_TTL_EVENTS),
        ("/", "", 300),
        ("/openapi.json", "", 300),
    ],
)
def test_route_ttls_come_from_the_cache_constants(path, query, expected):
    assert route_ttl(path, query) == expected


@pytest.mark.parametrize(
    "path,query",
    [
        ("/v2/health", ""),
        ("/health", ""),
        ("/v2/match", "q=bogus"),
        ("/v3/matches", ""),
        ("/v2/team", "id=2&q=bogus"),
        ("/v2/unknown", ""),
    ],
)
def test_unlisted_or_invalid_routes_are_not_shared_cached(path, query):
    assert route_ttl(path, query) is None


def test_stale_while_revalidate_scales_with_the_ttl():
    assert stale_while_revalidate(CACHE_TTL_LIVE) == 15
    assert stale_while_revalidate(CACHE_TTL_RESULTS) == 30
    assert stale_while_revalidate(CACHE_TTL_UPCOMING) == 600
    assert stale_while_revalidate(CACHE_TTL_RANKINGS) == 7200
    assert stale_while_revalidate(10**6) == 86400
    assert shared_cache_control(30) == "public, max-age=0, s-maxage=30, stale-while-revalidate=15"


async def _upcoming(*args, **kwargs):
    return {
        "data": {
            "status": 200,
            "segments": [],
            "meta": {"record_schema": "match-list"},
        }
    }


@pytest.mark.anyio
async def test_v3_match_list_gets_its_route_ttl(async_client, monkeypatch):
    monkeypatch.setattr("routers.v3_router.get_match_data", _upcoming)

    resp = await async_client.get("/v3/matches?q=upcoming")

    assert resp.status_code == 200
    assert resp.headers["cache-control"] == (
        "public, max-age=0, s-maxage=300, stale-while-revalidate=600"
    )


def _detail(status: str):
    async def fake_detail(match_id, light=False):
        return {
            "data": {
                "status": 200,
                "segments": [
                    {
                        "match_id": match_id,
                        "url": f"https://www.vlr.gg/{match_id}",
                        "status": status,
                        "teams": [{"id": "1", "name": "A"}, {"id": "2", "name": "B"}],
                    }
                ],
            }
        }

    return fake_detail


@pytest.mark.anyio
@pytest.mark.parametrize(
    "status,ttl",
    [("LIVE", CACHE_TTL_MATCH_DETAIL_LIVE), ("final", CACHE_TTL_MATCH_DETAIL)],
)
async def test_match_detail_ttl_follows_live_status(async_client, monkeypatch, status, ttl):
    monkeypatch.setattr("routers.v3_router.get_match_detail_data", _detail(status))
    monkeypatch.setattr("routers.v2_router.get_match_detail_data", _detail(status))

    v3 = await async_client.get("/v3/matches/42")
    v2 = await async_client.get("/v2/match/details?match_id=42")

    assert v3.status_code == 200 and v2.status_code == 200
    assert f"s-maxage={ttl}," in v3.headers["cache-control"]
    assert f"s-maxage={ttl}," in v2.headers["cache-control"]


@pytest.mark.anyio
async def test_error_responses_are_never_cached(async_client, monkeypatch):
    async def failing(*args, **kwargs):
        return {"data": {"status": 503, "error": "vlr.gg down", "segments": []}}

    monkeypatch.setattr("routers.v3_router.get_match_data", failing)

    resp = await async_client.get("/v3/matches?q=results")

    assert resp.status_code == 503
    assert resp.headers["cache-control"] == NO_STORE


@pytest.mark.anyio
async def test_validation_errors_are_never_cached(async_client):
    resp = await async_client.get("/v3/matches?q=nope")

    assert resp.status_code == 400
    assert resp.headers["cache-control"] == NO_STORE


@pytest.mark.anyio
async def test_embedded_upstream_errors_on_legacy_routes_are_never_cached(async_client, monkeypatch):
    """Original routes pass scraper payloads through, error status included."""

    async def failing_rankings(region):
        return {"data": {"status": 502, "error": "upstream", "segments": []}}

    monkeypatch.setattr("routers.vlr_router.get_rankings_data", failing_rankings)

    resp = await async_client.get("/rankings?region=na")

    assert resp.headers["cache-control"] == NO_STORE


@pytest.mark.anyio
async def test_rate_limited_responses_are_never_cached(async_client, monkeypatch):
    monkeypatch.setattr("routers.v3_router.get_match_detail_data", _detail("final"))

    statuses = []
    for _ in range(21):
        resp = await async_client.get("/v3/matches/42")
        statuses.append(resp.status_code)

    assert statuses[-1] == 429
    assert resp.headers["cache-control"] == NO_STORE
    # CORS still wraps the 429.
    assert "retry-after" in {key.lower() for key in resp.headers}


@pytest.mark.anyio
async def test_not_modified_is_private(async_client, monkeypatch):
    async def rankings(region):
        return {"data": {"status": 200, "segments": [{"team": "Sentinels"}]}}

    monkeypatch.setattr("routers.v2_router.get_rankings_data", rankings)

    first = await async_client.get("/v2/rankings?region=na")
    second = await async_client.get(
        "/v2/rankings?region=na", headers={"If-None-Match": first.headers["etag"]}
    )

    assert first.headers["cache-control"].startswith("public, max-age=0, s-maxage=3600")
    assert second.status_code == 304
    assert second.headers["cache-control"] == PRIVATE_REVALIDATE


@pytest.mark.anyio
async def test_health_and_non_get_requests_are_left_alone(async_client, monkeypatch):
    async def healthy():
        return {"vlr.gg": {"status": "healthy"}}

    monkeypatch.setattr("routers.v2_router.get_health_data", healthy)

    health = await async_client.get("/v2/health")
    post = await async_client.post("/v3/matches?q=upcoming")

    assert "s-maxage" not in health.headers.get("cache-control", "")
    assert "s-maxage" not in post.headers.get("cache-control", "")
