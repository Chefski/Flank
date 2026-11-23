from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError

from api.utils.rate_limiter import _match_tier, _normalise
from api.v3_adapters import (
    adapt_event_detail,
    adapt_match_detail,
    adapt_match_list,
    adapt_news_archive,
    adapt_news_article,
    adapt_stats,
)
from main import app
from models.v3 import V3Image


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as api_client:
        yield api_client


MATCH_RECORD = {
    "source": "results",
    "match_id": "123",
    "stats_match_id": "456",
    "url": "https://www.vlr.gg/123/example",
    "status": "completed",
    "status_text": "Final",
    "scheduled_at": "2026-07-30T18:00:00Z",
    "display": {"date": "July 30", "time": "7:00 PM", "relative": "2h ago"},
    "event": {
        "id": "77",
        "name": "Example Event",
        "stage": "Group Stage",
        "stage_slug": "group-stage",
        "series": "Week 1",
        "url": "https://www.vlr.gg/event/77/example/group-stage",
        "logo": "https://owcdn.net/img/event.png",
    },
    "teams": [
        {
            "id": "10",
            "name": "Alpha",
            "country_code": "us",
            "score": "2",
            "is_winner": True,
            "logo": "https://owcdn.net/img/alpha.png",
        },
        {
            "id": "20",
            "name": "Beta",
            "country_code": "ca",
            "score": "0",
            "is_winner": False,
            "logo": "https://owcdn.net/img/beta.png",
        },
    ],
    "note": "",
    "page": 2,
}


def test_v3_models_forbid_undeclared_fields():
    with pytest.raises(ValidationError):
        V3Image(url=None, light_url=None, dark_url=None, legacy_logo="unexpected")


def test_rate_limiter_normalizes_v3_paths_to_existing_tiers():
    assert _normalise("/v3/news") == "/news"
    assert _normalise("/v3/matches/123") == "/matches/123"
    assert _normalise("/v30/news") == "/v30/news"
    assert _match_tier("/v3/matches/123", "") == "expensive"
    assert _match_tier("/v3/matches", "q=upcoming") == "moderate"
    assert _match_tier("/v3/matches", "q=results") == "expensive"


def test_match_list_adapter_normalizes_ids_numbers_timestamps_and_nulls():
    records, meta = adapt_match_list(
        {
            "segments": [{"match": MATCH_RECORD}],
            "meta": {
                "page_range": "2-2",
                "total_pages_requested": 1,
                "successful_pages": 1,
                "failed_pages": [],
            },
        },
        query="results",
    )

    match = records[0]
    assert match.id == 123
    assert match.stats_id == 456
    assert match.starts_at == datetime(2026, 7, 30, 18, tzinfo=UTC)
    assert match.event.id == 77
    assert match.teams[0].id == 10
    assert match.teams[0].score == 2
    assert match.note is None
    assert meta.page_range == "2-2"


def test_stats_adapter_normalizes_numeric_and_percentage_fields():
    data = adapt_stats(
        {
            "filters": {
                "tier": "vct",
                "region": "americas",
                "span": "custom",
                "side": "all",
                "role": "all",
                "agent": "all",
                "map_id": "12",
                "min_rounds": 100,
                "min_rating": 0,
                "sort": "rating2",
                "dir": "desc",
                "from": "2026-01-01",
                "to": "2026-06-30",
            },
            "segments": [
                {
                    "player": "Example",
                    "player_id": "9",
                    "player_url": "https://www.vlr.gg/player/9/example",
                    "country": "us",
                    "org": "N/A",
                    "agent_usage": [{"agent": "sage", "usage": "75%"}],
                    "maps_played": "10",
                    "rounds_played": "200",
                    "rating": "1.25",
                    "average_combat_score": "240",
                    "kill_deaths": "1.50",
                    "kill_assists_survived_traded": "80%",
                    "headshot_percentage": "23%",
                    "clutch_success_percentage": "25%",
                    "clutch_attempts": "3/12",
                    "kills": "300",
                }
            ],
        }
    )

    player = data.players[0]
    assert data.filters.map_id == 12
    assert data.filters.from_date.isoformat() == "2026-01-01"
    assert player.player.id == 9
    assert player.organization is None
    assert player.agents[0].usage_percent == 75.0
    assert player.rating == 1.25
    assert player.kast_percent == 80.0
    assert player.clutches_won == 3
    assert player.clutches_attempted == 12
    assert player.kills == 300


def test_news_adapters_use_direct_resources_and_explicit_nulls():
    archive, meta = adapt_news_archive(
        {
            "segments": [
                {
                    "article_id": "725612",
                    "slug": "example",
                    "title": "Example",
                    "description": "",
                    "published_date": "2026-07-30",
                    "author": "writer",
                    "region_code": "us",
                    "url": "https://www.vlr.gg/725612/example",
                }
            ],
            "meta": {
                "page": 1,
                "total_pages": 126,
                "has_previous": False,
                "has_next": True,
            },
        }
    )
    article = adapt_news_article(
        {
            "article_id": "725612",
            "slug": "example",
            "url": "https://www.vlr.gg/725612/example",
            "title": "Example",
            "description": "Summary",
            "published_at": "2026-07-30T02:17:33+01:00",
            "relative_time": "9 hours ago",
            "author": {
                "name": "Writer Name",
                "handle": "writer",
                "url": "https://www.vlr.gg/user/writer",
                "avatar": "",
            },
            "event": {"id": "", "name": "", "url": "", "logo": ""},
            "content": {"html": "<p>Body</p>", "text": "Body", "links": [], "media": []},
            "comments_url": "https://www.vlr.gg/725612/example#comments",
        }
    )

    assert archive[0].id == 725612
    assert archive[0].description is None
    assert meta.total_pages == 126
    assert article.published_at.utcoffset().total_seconds() == 3600
    assert article.author.avatar_url is None
    assert article.event is None


def test_event_detail_adapter_normalizes_money_records_and_bracket_time():
    detail = adapt_event_detail(
        {
            "event": {
                "event_id": "77",
                "name": "Example Event",
                "series": "VCT 2026",
                "dates": "Jul 1 – Aug 1, 2026",
                "prize": "$250,000",
                "location": "Dublin",
                "location_code": "ie",
                "logo": "https://owcdn.net/img/event.png",
                "url": "https://www.vlr.gg/event/77",
                "calendar": {},
            },
            "stages": [],
            "resources": [],
            "teams": [],
            "prizes": [],
            "standings": [],
            "groups": [
                {
                    "id": "100",
                    "name": "Group A",
                    "teams": [
                        {
                            "rank": 1,
                            "id": "10",
                            "name": "Alpha",
                            "region": "Europe",
                            "logo": "https://owcdn.net/img/alpha.png",
                            "url": "https://www.vlr.gg/team/10/alpha",
                            "state": "advanced",
                            "record": "5–1",
                            "maps": "10/3",
                            "rounds": "150/120",
                            "round_differential": "+30",
                        }
                    ],
                    "matches": [],
                }
            ],
            "brackets": [
                {
                    "type": "main",
                    "rounds": [
                        {
                            "name": "Final",
                            "matches": [
                                {
                                    "match_id": "123",
                                    "url": "https://www.vlr.gg/123/final",
                                    "utc_timestamp": "1785065400",
                                    "status": "12:30 pm",
                                    "has_stream": True,
                                    "team1": {"id": "10", "name": "Alpha", "score": "2"},
                                    "team2": {"id": "20", "name": "Beta", "score": "1"},
                                }
                            ],
                        }
                    ],
                }
            ],
        }
    )

    assert detail.id == 77
    assert detail.prize.amount == 250000
    assert detail.groups[0].teams[0].series_wins == 5
    assert detail.groups[0].teams[0].series_losses == 1
    assert detail.groups[0].teams[0].round_differential == 30
    assert detail.brackets[0].rounds[0].matches[0].starts_at.tzinfo == UTC


def test_match_detail_adapter_normalizes_fidelity_fields():
    detail = adapt_match_detail(
        {
            "match_id": "123",
            "stats_match_id": "456",
            "url": "https://www.vlr.gg/123/example",
            "status": "11h 9m",
            "scheduled_at": "2026-07-30T18:00:00Z",
            "event": {
                "id": "77",
                "name": "Example Event",
                "stage": "group-stage",
                "series": "Group Stage: Week 1",
                "url": "https://www.vlr.gg/event/77/example/group-stage",
            },
            "teams": [
                {"id": "10", "name": "Alpha", "score": "13"},
                {"id": "20", "name": "Beta", "score": "10"},
            ],
            "maps": [
                {
                    "game_id": "900",
                    "map_number": 1,
                    "map_name": "Haven",
                    "status": "completed",
                    "pick": {
                        "slot": "team1",
                        "team_id": "10",
                        "team": "Alpha",
                        "team_url": "https://www.vlr.gg/team/10/alpha",
                    },
                    "score": {"team1": 13, "team2": 10},
                    "side_scores": {
                        "team1": {"total": 13, "attack": "8", "defense": "5", "overtime": ""},
                        "team2": {"total": 10, "attack": "5", "defense": "5", "overtime": ""},
                    },
                    "players": {
                        "team1": [
                            {
                                "player_id": "9",
                                "player_url": "https://www.vlr.gg/player/9/example",
                                "name": "Example",
                                "rating": "1.25",
                                "kills": "20",
                                "kast": "80%",
                                "attack": {"kills": "12"},
                                "defense": {"kills": "8"},
                            }
                        ],
                        "team2": [],
                    },
                    "rounds": [
                        {
                            "round_num": 1,
                            "winner": "team1",
                            "side_name": "attack",
                            "method": "elimination",
                            "method_code": "elim",
                            "method_icon": "https://www.vlr.gg/img/vlr/game/round/elim.webp",
                            "score_after": {"team1": 1, "team2": 0},
                        }
                    ],
                    "performance": {"kill_matrix": [], "advanced_stats": []},
                    "economy": [
                        {
                            "team_id": "10",
                            "Team": "ALP",
                            "Pistol Won": "2",
                            "Eco (won)": "4 (1)",
                            "$ (won)": "3 (2)",
                            "$$ (won)": "5 (3)",
                            "$$$ (won)": "10 (7)",
                        },
                        {
                            "team_id": "20",
                            "Team": "BET",
                            "Pistol": "50%",
                        },
                    ],
                }
            ],
            "streams": [],
            "vods": [],
            "head_to_head": [],
            "performance": {"kill_matrix": [], "advanced_stats": [], "by_map": []},
            "economy": [],
            "economy_by_map": [],
        }
    )

    assert detail.id == 123
    assert detail.status == "scheduled"
    assert detail.event.stage == "Group Stage"
    assert detail.event.stage_slug == "group-stage"
    assert detail.event.series == "Week 1"
    game = detail.games[0]
    assert game.id == 900
    assert game.pick.team.id == 10
    assert game.players.team1[0].rating == 1.25
    assert game.players.team1[0].kast_percent == 80.0
    assert game.side_scores.team1.attack == 8
    assert game.rounds[0].score_after.team1 == 1
    assert game.economy[0].pistol_wins == 2
    assert game.economy[0].pistol_win_percent is None
    assert game.economy[0].full.rounds == 10
    assert game.economy[0].full.wins == 7
    assert game.economy[1].pistol_wins is None
    assert game.economy[1].pistol_win_percent == 50.0


@pytest.mark.anyio
async def test_v3_news_endpoint_returns_typed_direct_data(client, monkeypatch):
    async def fake_news(page=1):
        return {
            "data": {
                "status": 200,
                "segments": [
                    {
                        "article_id": "1",
                        "slug": "example",
                        "title": "Example",
                        "published_date": "2026-07-30",
                        "url": "https://www.vlr.gg/1/example",
                    }
                ],
                "meta": {
                    "page": page,
                    "total_pages": 2,
                    "has_previous": page > 1,
                    "has_next": page < 2,
                },
            }
        }

    monkeypatch.setattr("routers.v3_router.get_news_data", fake_news)
    response = await client.get("/v3/news?page=2")

    assert response.status_code == 200
    body = response.json()
    assert body["api_version"] == "3"
    assert body["data"][0]["id"] == 1
    assert "segments" not in body["data"][0]
    assert body["meta"]["page"] == 2


@pytest.mark.anyio
async def test_v3_match_endpoint_serializes_numbers_and_nulls(client, monkeypatch):
    async def fake_matches(*args):
        return {
            "data": {
                "status": 200,
                "segments": [{"match": MATCH_RECORD}],
                "meta": {"failed_pages": []},
            }
        }

    monkeypatch.setattr("routers.v3_router.get_match_data", fake_matches)
    response = await client.get("/v3/matches?q=results")

    assert response.status_code == 200
    match = response.json()["data"][0]
    assert match["id"] == 123
    assert match["teams"][0]["score"] == 2
    assert match["note"] is None
    assert match["starts_at"] == "2026-07-30T18:00:00Z"


@pytest.mark.anyio
async def test_v3_propagates_scraper_errors(client, monkeypatch):
    async def fake_news(page=1):
        return {"data": {"status": 503, "error": "upstream unavailable", "segments": []}}

    monkeypatch.setattr("routers.v3_router.get_news_data", fake_news)
    response = await client.get("/v3/news")

    assert response.status_code == 503
    assert response.json()["detail"] == "upstream unavailable"


def test_openapi_exposes_concrete_v3_response_schemas():
    schema = app.openapi()
    for path in (
        "/v3/news",
        "/v3/news/{article_id}",
        "/v3/stats",
        "/v3/matches",
        "/v3/matches/{match_id}",
        "/v3/events",
        "/v3/events/{event_id}/matches",
        "/v3/events/{event_id}/stats",
        "/v3/events/{event_id}",
    ):
        response_schema = schema["paths"][path]["get"]["responses"]["200"]["content"][
            "application/json"
        ]["schema"]
        assert "$ref" in response_schema
        assert "V3Response" in response_schema["$ref"]

    v3_objects = {
        name: component
        for name, component in schema["components"]["schemas"].items()
        if name.startswith("V3") and component.get("type") == "object"
    }
    assert v3_objects
    assert all(
        component.get("additionalProperties") is False
        for component in v3_objects.values()
    )
    assert schema["info"]["version"] == "3.0.0"


def test_match_detail_adapter_maps_the_redesigned_ecm_economy():
    """vlr.gg's October 2026 ``table.ecm`` rows use wins/attempts per buy state."""
    detail = adapt_match_detail(
        {
            "match_id": "9",
            "url": "https://www.vlr.gg/9/x",
            "teams": [{"id": "2131", "name": "Chivas"}, {"id": "11720", "name": "OSK"}],
            "economy": [
                {
                    "Team": "CHV",
                    "team_id": "2131",
                    "Pistol": "1/2",
                    "Conv.": "1/1",
                    "Bonus": "",
                    "On Eco <10k: vs. Eco": "",
                    "On Eco <10k: vs. Full": "1/1",
                    "On Half buy 10–18k: vs. Full": "",
                    "On Full buy 18k+: vs. Eco": "3/3",
                    "On Full buy 18k+: vs. Full": "6/8",
                }
            ],
        }
    )

    row = detail.economy[0]
    assert row.team_id == 2131
    assert row.team_tag == "CHV"
    assert row.pistol_wins == 1
    assert row.pistol_win_percent == 50.0
    assert (row.eco.rounds, row.eco.wins) == (1, 1)
    assert (row.low.rounds, row.low.wins) == (None, None)
    assert (row.medium.rounds, row.medium.wins) == (None, None)
    assert (row.full.rounds, row.full.wins) == (11, 9)
