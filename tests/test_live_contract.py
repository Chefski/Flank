"""
Live end-to-end check of the endpoints the Flank iOS app depends on.

``tests/test_vlr_selectors.py`` proves the CSS selectors still resolve; this
module proves the *parsed output* is still usable: it runs the real app
in-process against live vlr.gg and asserts the payloads the app decodes are
populated, not just well-typed. A vlr.gg change that keeps selectors present
but empties a field (the October 2026 stats revamp, the sibling agent cell)
fails here.

Opt-in, because it makes ~30 live requests: set ``VLR_LIVE_CONTRACT=1``.
The daily selector-check workflow does.

    VLR_LIVE_CONTRACT=1 uv run pytest tests/test_live_contract.py -v
"""

import asyncio
import os

import pytest
from httpx import ASGITransport, AsyncClient

from main import app

pytestmark = [
    pytest.mark.anyio,
    pytest.mark.skipif(
        os.environ.get("VLR_LIVE_CONTRACT") != "1",
        reason="live vlr.gg contract check; set VLR_LIVE_CONTRACT=1",
    ),
]

# Request timeouts are generous: a cold results page plus logo enrichment can
# take several seconds from a CI runner.
TIMEOUT = 90


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
async def live(monkeypatch):
    """ASGI client over the real app, with real logo enrichment enabled."""
    from api import team_logo_enrichment
    from utils.http_client import circuit_breaker, close_http_client

    monkeypatch.undo()  # drop conftest's offline enrichment stub
    team_logo_enrichment._reset_for_tests()
    circuit_breaker.reset()
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://live", timeout=TIMEOUT) as client:
        yield client
    # Each test runs on its own event loop: stop background logo fetches and
    # drop the loop-bound outbound client before this loop closes.
    pending = list(team_logo_enrichment._inflight.values())
    team_logo_enrichment._reset_for_tests()
    await asyncio.gather(*pending, return_exceptions=True)
    await close_http_client()


async def _get(client, path: str) -> dict:
    resp = await client.get(path)
    assert resp.status_code == 200, f"GET {path} -> {resp.status_code}: {resp.text[:300]}"
    assert "s-maxage=" in resp.headers.get("cache-control", ""), f"GET {path} is not edge-cacheable"
    return resp.json()


def _share(items, predicate) -> float:
    items = list(items)
    return sum(1 for item in items if predicate(item)) / len(items) if items else 0.0


def _real_teams(matches):
    return [team for match in matches for team in match["teams"] if team["name"] != "TBD"]


# ---------------------------------------------------------------------------
# V3 match lists
# ---------------------------------------------------------------------------


async def test_v3_upcoming_matches(live):
    body = await _get(live, "/v3/matches?q=upcoming")
    matches = body["data"]

    assert len(matches) >= 3, f"only {len(matches)} upcoming matches parsed"
    assert all(len(match["teams"]) == 2 for match in matches)
    assert _share(matches, lambda m: m["event"]["name"] != "Unknown") >= 0.9, "event names missing"
    assert _share(matches, lambda m: m["status"] in {"scheduled", "live"}) >= 0.9, "statuses unparsed"


async def test_v3_live_score(live):
    body = await _get(live, "/v3/matches?q=live_score")

    for match in body["data"]:
        assert match["status"] == "live"
        # Live rows always come with logos: the scraper reads each match page.
        assert all(team["image"]["url"] for team in match["teams"]), match["url"]


async def test_v3_results(live):
    body = await _get(live, "/v3/matches?q=results")
    matches = body["data"]

    assert len(matches) >= 10, f"only {len(matches)} results parsed"
    assert _share(matches, lambda m: m["status"] == "completed") >= 0.9
    assert _share(
        matches, lambda m: all(team["score"] is not None for team in m["teams"])
    ) >= 0.9, "result scores unparsed"


async def test_v3_list_logos_fill_in(live):
    """Logos are enriched from match pages within a few requests."""
    share = 0.0
    for _attempt in range(4):
        matches = (await _get(live, "/v3/matches?q=results"))["data"][:10]
        share = _share(_real_teams(matches), lambda team: team["image"]["url"])
        if share >= 0.8:
            break
        await asyncio.sleep(3)
    assert share >= 0.8, f"only {share:.0%} of the first 10 results' teams have logos"


# ---------------------------------------------------------------------------
# V3 match detail
# ---------------------------------------------------------------------------


async def _completed_match_with_stats(client) -> dict:
    results = (await _get(client, "/v3/matches?q=results"))["data"]
    for match in results[:8]:
        detail = (await _get(client, f"/v3/matches/{match['id']}"))["data"]
        if any(game["rounds"] and game["players"]["team1"] for game in detail["games"]):
            return detail
    pytest.fail("none of the 8 newest results has round-by-round data")


async def test_v3_match_detail(live):
    detail = await _completed_match_with_stats(live)
    url = detail["url"]

    assert all(team["id"] and team["image"]["url"] for team in detail["teams"]), url
    played = [game for game in detail["games"] if game["rounds"]]
    game = played[0]
    assert game["map_name"], url
    players = game["players"]["team1"] + game["players"]["team2"]
    assert len(players) == 10, f"{url}: {len(players)} players"
    assert _share(players, lambda p: p["agent"]) >= 0.9, f"{url}: player agents unparsed"
    assert _share(players, lambda p: p["rating"] is not None) >= 0.9, f"{url}: ratings unparsed"
    assert all(rnd["winner"] in {"team1", "team2"} for rnd in game["rounds"]), url
    assert detail["performance"]["kill_matrix"] or detail["performance_by_game"], f"{url}: no performance"
    economy = [row for item in detail["economy_by_game"] for row in item["teams"]]
    assert economy, f"{url}: economy unparsed"
    assert any(row["pistol_wins"] is not None for row in economy), f"{url}: pistol rounds unparsed"


# ---------------------------------------------------------------------------
# V3 news
# ---------------------------------------------------------------------------


async def test_v3_news_archive_and_article(live):
    first = await _get(live, "/v3/news?page=1")
    second = await _get(live, "/v3/news?page=2")

    articles = first["data"]
    assert len(articles) >= 10
    assert first["meta"]["has_next"] is True
    assert _share(articles, lambda a: a["published_date"]) >= 0.9, "news dates unparsed"
    assert {a["id"] for a in articles}.isdisjoint({a["id"] for a in second["data"]})

    article = (await _get(live, f"/v3/news/{articles[0]['id']}"))["data"]
    assert article["title"] != "Untitled"
    assert len(article["content"]["text"]) > 200, "article body unparsed"
    assert article["published_at"], "article timestamp unparsed"
    assert article["author"]["name"] != "Unknown"


# ---------------------------------------------------------------------------
# V2 query-style routes
# ---------------------------------------------------------------------------


async def test_v2_rankings(live):
    body = await _get(live, "/v2/rankings?region=na")
    rows = body["data"]["segments"]

    assert body["status"] == "success"
    assert len(rows) >= 20
    assert all(r["team"] and r["rank"] and r["rating"] for r in rows), "ranking rows unparsed"
    # Lower-ranked teams often have no logo on vlr.gg at all; the top ten do.
    assert _share(rows[:10], lambda r: r["logo"]) >= 0.8, "ranking logos unparsed"


async def test_v2_stats(live):
    body = await _get(live, "/v2/stats?region=all&timespan=30")
    rows = body["data"]["segments"]

    assert len(rows) >= 20, f"only {len(rows)} stats rows"
    assert _share(rows, lambda r: r["player_id"] and r["rating"]) >= 0.95
    float(rows[0]["rating"])
    float(rows[0]["average_combat_score"])


async def test_v2_team_and_player(live):
    detail = await _completed_match_with_stats(live)
    team_id = detail["teams"][0]["id"]
    game = next(game for game in detail["games"] if game["players"]["team1"])
    player_id = game["players"]["team1"][0]["player"]["id"]

    profile = (await _get(live, f"/v2/team?id={team_id}&q=profile"))["data"]["segments"][0]
    assert profile["name"] and profile["logo"], f"team {team_id} profile unparsed"
    assert profile["roster"], f"team {team_id} roster unparsed"

    team_matches = (await _get(live, f"/v2/team?id={team_id}&q=matches&page=1"))["data"]["segments"]
    assert team_matches and all(m["match_id"] for m in team_matches), f"team {team_id} matches"

    player = (await _get(live, f"/v2/player?id={player_id}&q=profile&timespan=90d"))["data"]["segments"][0]
    assert player["name"], f"player {player_id} profile unparsed"
    assert player["agent_stats"], f"player {player_id} agent stats unparsed"

    player_matches = (await _get(live, f"/v2/player?id={player_id}&q=matches&page=1"))["data"]["segments"]
    assert player_matches and all(m["match_id"] for m in player_matches), f"player {player_id} matches"
