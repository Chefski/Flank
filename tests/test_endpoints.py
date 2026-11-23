"""Endpoint smoke tests for original and v2 routers."""
import pytest
from starlette.middleware.cors import CORSMiddleware

from main import app


@pytest.mark.anyio
async def test_browser_clients_get_cors_headers(async_client):
    resp = await async_client.get("/version", headers={"Origin": "https://example.test"})

    assert resp.status_code == 200
    assert resp.headers["access-control-allow-origin"] == "*"
    assert "Retry-After" in resp.headers["access-control-expose-headers"]


def test_cors_wraps_the_rate_limiter():
    """A rate-limited 429 must still carry CORS headers, so CORS is outermost."""
    assert app.user_middleware[0].cls is CORSMiddleware


@pytest.mark.anyio
async def test_v2_stats_rejects_an_unknown_map(async_client):
    resp = await async_client.get("/v2/stats?region=all&timespan=all&map=summit2")

    assert resp.status_code == 400
    assert "Invalid map" in resp.json()["detail"]


@pytest.mark.anyio
async def test_v2_team_rejects_an_invalid_date_start(async_client):
    resp = await async_client.get("/v2/team?id=1&q=stats&date_start=2026-13-45")

    assert resp.status_code == 400
    assert "Invalid date" in resp.json()["detail"]


@pytest.mark.anyio
async def test_v2_team_passes_date_start_to_the_stats_scraper(async_client, monkeypatch):
    seen: dict = {}

    async def fake_team_stats(team_id, date_start=""):
        seen["args"] = (team_id, date_start)
        return {"data": {"status": 200, "segments": []}}

    monkeypatch.setattr("routers.v2_router.get_team_stats_data", fake_team_stats)

    resp = await async_client.get("/v2/team?id=77&q=stats&date_start=2026-01-01")

    assert resp.status_code == 200
    assert seen["args"] == ("77", "2026-01-01")


@pytest.mark.anyio
async def test_version_endpoint(async_client):
    resp = await async_client.get("/version")
    assert resp.status_code == 200
    data = resp.json()
    assert data["version"] == "3.0.0"
    assert data["default_api"] == "v3"
    assert data["compatibility_api"] == "v2"


@pytest.mark.anyio
async def test_v2_health(async_client):
    resp = await async_client.get("/v2/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "success"
    assert "data" in data


@pytest.mark.anyio
async def test_v2_invalid_region_returns_400(async_client):
    resp = await async_client.get("/v2/rankings?region=invalid_xyz")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_invalid_match_query_returns_400(async_client):
    resp = await async_client.get("/v2/match?q=bad_query")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_invalid_timespan_returns_400(async_client):
    resp = await async_client.get("/v2/stats?region=na&timespan=45")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_stats_requires_timespan_or_span(async_client):
    resp = await async_client.get("/v2/stats?region=americas")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_stats_forwards_current_filters(async_client, monkeypatch):
    captured = {}

    async def fake_stats(
        region, timespan=None, event_id=None, map_name="all", min_rounds=200, min_rating=1550, **filters
    ):
        captured.update(
            {
                "region": region,
                "timespan": timespan,
                "event_id": event_id,
                "map_name": map_name,
                "min_rounds": min_rounds,
                "min_rating": min_rating,
                **filters,
            }
        )
        return {
            "data": {
                "status": 200,
                "filters": {"region": region, "span": filters["span"]},
                "segments": [],
            }
        }

    monkeypatch.setattr("routers.v2_router.get_stats_data", fake_stats)
    resp = await async_client.get(
        "/v2/stats?region=emea&span=custom&from=2026-01-01&to=2026-06-30"
        "&tier=vct&side=ct&role=sentinel&agent=killjoy&map_id=12"
        "&min_rounds=100&min_rating=0&sort=kmax&dir=asc"
    )

    assert resp.status_code == 200
    assert captured == {
        "region": "emea",
        "timespan": None,
        "event_id": None,
        "map_name": "all",
        "span": "custom",
        "from_date": "2026-01-01",
        "to_date": "2026-06-30",
        "tier": "vct",
        "side": "ct",
        "role": "sentinel",
        "agent": "killjoy",
        "map_id": "12",
        "min_rounds": 100,
        "min_rating": 0,
        "sort": "kmax",
        "direction": "asc",
    }


@pytest.mark.anyio
async def test_v2_invalid_event_query_returns_400(async_client):
    resp = await async_client.get("/v2/events?q=bad_query")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_event_detail_forwards_stage(async_client, monkeypatch):
    captured = {}

    async def fake_detail(event_id, stage=None):
        captured.update({"event_id": event_id, "stage": stage})
        return {"data": {"status": 200, "segments": {"groups": []}}}

    monkeypatch.setattr("routers.v2_router.get_event_detail_data", fake_detail)
    resp = await async_client.get("/v2/event/2978?stage=group-stage")

    assert resp.status_code == 200
    assert captured == {"event_id": "2978", "stage": "group-stage"}


@pytest.mark.anyio
async def test_v2_event_detail_rejects_unsafe_stage(async_client):
    resp = await async_client.get("/v2/event/2978?stage=../stats")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_event_stats_forwards_filters(async_client, monkeypatch):
    captured = {}

    async def fake_stats(event_id, **filters):
        captured.update({"event_id": event_id, **filters})
        return {"data": {"status": 200, "segments": []}}

    monkeypatch.setattr("routers.v2_router.get_event_stats_data", fake_stats)
    resp = await async_client.get(
        "/v2/event/2978/stats?sort=kmax&dir=asc&side=ct&role=sentinel"
        "&agent=killjoy&map_id=12&min_rounds=100&exclude=551.552"
    )

    assert resp.status_code == 200
    assert captured == {
        "event_id": "2978",
        "sort": "kmax",
        "direction": "asc",
        "side": "ct",
        "role": "sentinel",
        "agent": "killjoy",
        "map_id": "12",
        "min_rounds": 100,
        "exclude": "551.552",
    }


@pytest.mark.anyio
@pytest.mark.parametrize("resource", ["stats", "agents", "news", "pickem"])
async def test_v2_event_resources_reject_invalid_id(async_client, resource):
    resp = await async_client.get(f"/v2/event/not-an-id/{resource}")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_event_agents_rejects_invalid_exclude(async_client):
    resp = await async_client.get("/v2/event/2978/agents?exclude=551,552")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_original_event_detail_forwards_stage(async_client, monkeypatch):
    captured = {}

    async def fake_detail(event_id, stage=None):
        captured.update({"event_id": event_id, "stage": stage})
        return {"data": {"status": 200, "segments": {"groups": []}}}

    monkeypatch.setattr("routers.vlr_router.get_event_detail_data", fake_detail)
    resp = await async_client.get("/event/2978?stage=playoffs")

    assert resp.status_code == 200
    assert captured == {"event_id": "2978", "stage": "playoffs"}


@pytest.mark.anyio
async def test_original_news_serves_payload(async_client, monkeypatch):
    """Original /news serves the scraper payload without redirecting."""

    async def fake_news(page=1):
        return {"data": {"status": 200, "segments": [{"title": "Patch notes"}]}}

    monkeypatch.setattr("routers.vlr_router.get_news_data", fake_news)

    resp = await async_client.get("/news")
    assert resp.status_code == 200
    assert resp.json()["data"]["segments"] == [{"title": "Patch notes"}]


@pytest.mark.anyio
async def test_original_invalid_match_returns_error(async_client):
    """Original /match with bad q should return error dict, not 400."""
    resp = await async_client.get("/match?q=bad_query", follow_redirects=False)
    assert resp.status_code == 200
    data = resp.json()
    assert "error" in data


@pytest.mark.anyio
async def test_original_player_rejects_invalid_id(async_client):
    resp = await async_client.get("/player?id=abc")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_original_player_rejects_invalid_timespan(async_client):
    resp = await async_client.get("/player?id=9&timespan=45d")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_original_match_detail_rejects_invalid_id(async_client):
    resp = await async_client.get("/match/details?match_id=abc")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_match_detail_exposes_team_ids(async_client, monkeypatch):
    async def fake_match_detail(match_id, light=False):
        return {
            "data": {
                "status": 200,
                "segments": [
                    {
                        "match_id": match_id,
                        "teams": [
                            {"id": "100", "name": "Team One"},
                            {"id": "200", "name": "Team Two"},
                        ],
                    }
                ],
            }
        }

    monkeypatch.setattr("routers.v2_router.get_match_detail_data", fake_match_detail)

    resp = await async_client.get("/v2/match/details?match_id=123")
    assert resp.status_code == 200
    assert resp.json()["data"]["segments"][0]["teams"] == [
        {"id": "100", "name": "Team One"},
        {"id": "200", "name": "Team Two"},
    ]


@pytest.mark.anyio
async def test_original_match_detail_strips_team_ids(async_client, monkeypatch):
    async def fake_match_detail(match_id, light=False):
        return {
            "data": {
                "status": 200,
                "segments": [
                    {
                        "match_id": match_id,
                        "teams": [
                            {"id": "100", "name": "Team One"},
                            {"id": "200", "name": "Team Two"},
                        ],
                    }
                ],
            }
        }

    monkeypatch.setattr("routers.vlr_router.get_match_detail_data", fake_match_detail)

    resp = await async_client.get("/match/details?match_id=123")
    assert resp.status_code == 200
    assert resp.json()["data"]["segments"][0]["teams"] == [
        {"name": "Team One"},
        {"name": "Team Two"},
    ]


@pytest.mark.anyio
async def test_v2_wrap_propagates_scraper_error_status(async_client, monkeypatch):
    async def fake_news(page=1):
        return {"data": {"status": 502, "error": "upstream failure", "segments": []}}

    monkeypatch.setattr("routers.v2_router.get_news_data", fake_news)
    resp = await async_client.get("/v2/news")
    assert resp.status_code == 502
    assert "detail" in resp.json()


@pytest.mark.anyio
async def test_v2_news_forwards_page_and_article_id(async_client, monkeypatch):
    captured = {}

    async def fake_news(page=1):
        captured["page"] = page
        return {"data": {"status": 200, "segments": [], "meta": {"page": page}}}

    async def fake_article(article_id):
        captured["article_id"] = article_id
        return {
            "data": {
                "status": 200,
                "segments": [{"article_id": article_id}],
            }
        }

    monkeypatch.setattr("routers.v2_router.get_news_data", fake_news)
    monkeypatch.setattr("routers.v2_router.get_news_article_data", fake_article)

    archive = await async_client.get("/v2/news?page=126")
    article = await async_client.get("/v2/news/725612")

    assert archive.status_code == 200
    assert archive.json()["data"]["meta"] == {"page": 126}
    assert article.status_code == 200
    assert article.json()["data"]["segments"][0]["article_id"] == "725612"
    assert captured == {"page": 126, "article_id": "725612"}


@pytest.mark.anyio
async def test_v2_news_validates_archive_page_and_article_id(async_client):
    assert (await async_client.get("/v2/news?page=501")).status_code == 422
    assert (await async_client.get("/v2/news/not-a-number")).status_code == 400


@pytest.mark.anyio
async def test_original_news_article_propagates_embedded_error_status(
    async_client,
    monkeypatch,
):
    async def fake_article(article_id):
        return {
            "data": {
                "status": 404,
                "error": f"news article {article_id} not found",
                "segments": [],
            }
        }

    monkeypatch.setattr("routers.vlr_router.get_news_article_data", fake_article)

    response = await async_client.get("/news/725612")

    assert response.status_code == 404
    assert response.json()["detail"] == "news article 725612 not found"


@pytest.mark.anyio
async def test_v2_events_propagates_scraper_error_status(async_client, monkeypatch):
    async def fake_events(q, page):
        return {"data": {"status": 503, "error": "events unavailable", "segments": []}}

    monkeypatch.setattr("routers.v2_router.get_events_data", fake_events)

    resp = await async_client.get("/v2/events")

    assert resp.status_code == 503
    assert resp.json()["detail"] == "events unavailable"


@pytest.mark.anyio
async def test_v2_player_propagates_scraper_error_status(async_client, monkeypatch):
    async def fake_player(player_id, timespan):
        return {
            "data": {
                "status": 404,
                "error": f"player {player_id} not found",
                "segments": [],
            }
        }

    monkeypatch.setattr("routers.v2_router.get_player_data", fake_player)

    resp = await async_client.get("/v2/player?id=9")

    assert resp.status_code == 404
    assert resp.json()["detail"] == "player 9 not found"


@pytest.mark.anyio
async def test_v2_match_rejects_oversized_workload(async_client):
    resp = await async_client.get("/v2/match?q=results&num_pages=21")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_match_rejects_pagination_for_upcoming_query(async_client):
    resp = await async_client.get("/v2/match?q=upcoming&num_pages=2")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_original_match_rejects_pagination_for_live_score_query(async_client):
    resp = await async_client.get("/match?q=live_score&from_page=2")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_event_detail_passes_stage_through(async_client, monkeypatch):
    seen = {}

    async def fake_event_detail(event_id, stage=None):
        seen["args"] = (event_id, stage)
        return {"data": {"status": 200, "segments": {"stages": [], "prizes": []}}}

    monkeypatch.setattr("routers.v2_router.get_event_detail_data", fake_event_detail)

    resp = await async_client.get("/v2/event/2766?stage=playoffs")

    assert resp.status_code == 200
    assert seen["args"] == ("2766", "playoffs")


@pytest.mark.anyio
@pytest.mark.parametrize("stage", ["Playoffs", "group_stage", "../x", "-playoffs"])
async def test_v2_event_detail_rejects_invalid_stage_slug(async_client, stage):
    resp = await async_client.get("/v2/event/2766", params={"stage": stage})
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_v2_match_logs_passes_game_id_through(async_client, monkeypatch):
    seen = {}

    async def fake_logs(match_id, game_id=None):
        seen["args"] = (match_id, game_id)
        return {"data": {"status": 200, "segments": [{"match_id": match_id, "game_id": game_id, "rounds": []}]}}

    monkeypatch.setattr("routers.v2_router.get_match_logs_data", fake_logs)

    resp = await async_client.get("/v2/match/logs?match_id=766311&game_id=285688")

    assert resp.status_code == 200
    assert seen["args"] == ("766311", "285688")
    assert resp.json()["data"]["segments"][0]["game_id"] == "285688"


@pytest.mark.anyio
async def test_v2_match_logs_allows_missing_game_id(async_client, monkeypatch):
    seen = {}

    async def fake_logs(match_id, game_id=None):
        seen["args"] = (match_id, game_id)
        return {"data": {"status": 200, "segments": []}}

    monkeypatch.setattr("routers.v2_router.get_match_logs_data", fake_logs)

    resp = await async_client.get("/v2/match/logs?match_id=766311")

    assert resp.status_code == 200
    assert seen["args"] == ("766311", None)


@pytest.mark.anyio
@pytest.mark.parametrize("query", ["match_id=abc", "match_id=123&game_id=xyz"])
async def test_v2_match_logs_rejects_invalid_ids(async_client, query):
    resp = await async_client.get(f"/v2/match/logs?{query}")
    assert resp.status_code == 400


@pytest.mark.anyio
async def test_original_match_logs_route(async_client, monkeypatch):
    async def fake_logs(match_id, game_id=None):
        return {"data": {"status": 200, "segments": [{"match_id": match_id, "game_id": game_id}]}}

    monkeypatch.setattr("routers.vlr_router.get_match_logs_data", fake_logs)

    resp = await async_client.get("/match/logs?match_id=766311")

    assert resp.status_code == 200
    assert resp.json()["data"]["segments"][0]["match_id"] == "766311"


def test_match_logs_falls_in_the_expensive_rate_limit_tier():
    """A logs request costs two scrapes, so it must not land in a cheap tier."""
    from api.utils.rate_limiter import _match_tier

    assert _match_tier("/v2/match/logs", "") == "expensive"
    assert _match_tier("/match/logs", "") == "expensive"

