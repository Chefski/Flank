"""Team-logo index and bounded match-list enrichment."""
import asyncio

import pytest

from api import team_logo_enrichment
from api.team_logo_enrichment import enrich_match_list_logos
from utils.match_records import build_match_record, match_team
from utils.team_logos import TeamLogoStore, team_logo_store


def _team(team_id, name, logo, dark=None):
    return {
        "id": team_id,
        "name": name,
        "url": f"https://www.vlr.gg/team/{team_id}/x",
        "logo": logo,
        "logo_light": logo,
        "logo_dark": dark or logo,
    }


def _list_payload(*pairs):
    """A V2 match-list payload whose canonical records carry names only."""
    segments = []
    for match_id, (name1, name2) in pairs:
        segments.append(
            {
                "match_id": match_id,
                "match": build_match_record(
                    source="upcoming",
                    match_id=match_id,
                    url=f"/{match_id}/x",
                    status="scheduled",
                    teams=[match_team(name=name1), match_team(name=name2)],
                ),
            }
        )
    return {"status": 200, "segments": segments, "meta": {"record_schema": "match-list"}}


def _teams_of(payload, index=0):
    return payload["segments"][index]["match"]["teams"]


# ---------------------------------------------------------------------------
# TeamLogoStore
# ---------------------------------------------------------------------------


def test_store_prefers_the_exact_match_slot_then_the_name():
    store = TeamLogoStore()
    store.record_match("10", [_team("1", "Alpha", "//cdn/a.png"), _team("2", "Bravo", "/img/b.png")])

    assert store.lookup("10", 0, "whatever")["logo"] == "https://cdn/a.png"
    assert store.lookup("10", 1, "Bravo")["logo"] == "https://www.vlr.gg/img/b.png"
    # Another match with the same team is found by name.
    assert store.lookup("99", 0, "  alpha ")["id"] == "1"
    assert store.lookup("99", 0, "Charlie") is None


def test_store_drops_a_name_seen_with_two_team_ids():
    store = TeamLogoStore()
    store.record_team(_team("1", "Phoenix", "https://cdn/1.png"))
    store.record_team(_team("2", "Phoenix", "https://cdn/2.png"))

    assert store.lookup("1", 0, "Phoenix") is None


def test_id_less_sources_never_override_known_teams():
    store = TeamLogoStore()
    store.record_team(_team("1", "Sentinels", "https://cdn/real.png"))
    store.record_team({"logo": "https://cdn/rankings.png"}, name="Sentinels")

    assert store.lookup("", 0, "Sentinels")["logo"] == "https://cdn/real.png"


def test_store_ignores_placeholder_names_and_missing_logos():
    store = TeamLogoStore()
    store.record_team(_team("1", "TBD", "https://cdn/tbd.png"))
    store.record_team(_team("2", "Real", ""))

    assert store.lookup("", 0, "TBD") is None
    assert store.lookup("", 0, "Real") is None


# ---------------------------------------------------------------------------
# Enrichment
# ---------------------------------------------------------------------------


def _install_fetch(monkeypatch, pages, delay=0.0):
    """Fake match-page fetch: ``pages`` maps match id -> (team1, team2)."""
    calls = []

    async def fake_fetch(match_id, store=team_logo_store):
        calls.append(match_id)
        await asyncio.sleep(delay)
        if match_id not in pages:
            store.record_miss(match_id)
            return False
        store.record_match(match_id, list(pages[match_id]))
        return True

    monkeypatch.setattr(team_logo_enrichment, "fetch_match_logos", fake_fetch)
    return calls


@pytest.mark.anyio
async def test_enrichment_fills_from_the_index_without_fetching(monkeypatch):
    calls = _install_fetch(monkeypatch, {})
    team_logo_store.record_match("5", [_team("1", "A", "https://cdn/a.png"), _team("2", "B", "https://cdn/b.png")])
    payload = _list_payload(("5", ("A", "B")))

    enriched, complete = await enrich_match_list_logos(payload)

    assert complete is True
    assert calls == []
    teams = _teams_of(enriched)
    assert [t["logo"] for t in teams] == ["https://cdn/a.png", "https://cdn/b.png"]
    assert [t["id"] for t in teams] == ["1", "2"]
    # The (shared, cached) input payload is never mutated.
    assert _teams_of(payload)[0]["logo"] == ""


@pytest.mark.anyio
async def test_enrichment_fetches_at_most_the_cap_in_list_order(monkeypatch):
    pages = {
        str(i): (_team(f"{i}1", f"T{i}a", f"https://cdn/{i}a.png"), _team(f"{i}2", f"T{i}b", f"https://cdn/{i}b.png"))
        for i in range(1, 6)
    }
    calls = _install_fetch(monkeypatch, pages)
    payload = _list_payload(*[(str(i), (f"T{i}a", f"T{i}b")) for i in range(1, 6)])

    enriched, complete = await enrich_match_list_logos(payload, max_fetches=3)

    assert calls == ["1", "2", "3"]
    assert complete is False
    assert _teams_of(enriched, 2)[1]["logo"] == "https://cdn/3b.png"
    assert _teams_of(enriched, 3)[0]["logo"] == ""

    # The next request picks up where this one stopped.
    enriched, complete = await enrich_match_list_logos(payload, max_fetches=3)
    assert calls == ["1", "2", "3", "4", "5"]
    assert complete is True


@pytest.mark.anyio
async def test_enrichment_responds_within_its_budget_and_keeps_the_fetch(monkeypatch):
    pages = {"7": (_team("1", "Slow", "https://cdn/s.png"), _team("2", "Poke", "https://cdn/p.png"))}
    _install_fetch(monkeypatch, pages, delay=0.2)
    payload = _list_payload(("7", ("Slow", "Poke")))

    enriched, complete = await enrich_match_list_logos(payload, budget=0.01)

    assert complete is False
    assert _teams_of(enriched)[0]["logo"] == ""
    await asyncio.sleep(0.3)
    enriched, complete = await enrich_match_list_logos(payload, budget=0.01)
    assert complete is True
    assert _teams_of(enriched)[0]["logo"] == "https://cdn/s.png"


@pytest.mark.anyio
async def test_failed_and_placeholder_matches_do_not_hold_the_list_incomplete(monkeypatch):
    calls = _install_fetch(monkeypatch, {})
    payload = _list_payload(("8", ("Gone", "Away")), ("9", ("TBD", "TBD")))

    _, complete = await enrich_match_list_logos(payload)
    _, again = await enrich_match_list_logos(payload)

    assert calls == ["8"]  # TBD-only match never fetched; the miss is not retried
    assert complete is True and again is True


@pytest.mark.anyio
async def test_concurrent_requests_share_one_fetch_per_match(monkeypatch):
    pages = {"3": (_team("1", "X", "https://cdn/x.png"), _team("2", "Y", "https://cdn/y.png"))}
    calls = _install_fetch(monkeypatch, pages, delay=0.05)
    payload = _list_payload(("3", ("X", "Y")))

    await asyncio.gather(*[enrich_match_list_logos(payload) for _ in range(5)])

    assert calls == ["3"]


# ---------------------------------------------------------------------------
# V3 endpoint
# ---------------------------------------------------------------------------


@pytest.mark.anyio
async def test_v3_match_list_serves_enriched_logos_with_the_same_shape(async_client, monkeypatch):
    payload = _list_payload(("11", ("Alpha", "Bravo")), ("12", ("Charlie", "Delta")))

    async def fake_matches(*args, **kwargs):
        return {"data": payload}

    monkeypatch.setattr("routers.v3_router.get_match_data", fake_matches)
    _install_fetch(
        monkeypatch,
        {"11": (_team("1", "Alpha", "https://cdn/a.png", "https://cdn/a-dark.png"), _team("2", "Bravo", "https://cdn/b.png"))},
    )

    resp = await async_client.get("/v3/matches?q=upcoming")

    assert resp.status_code == 200
    first, second = resp.json()["data"]
    assert first["teams"][0]["image"] == {
        "url": "https://cdn/a.png",
        "light_url": "https://cdn/a.png",
        "dark_url": "https://cdn/a-dark.png",
    }
    assert first["teams"][0]["id"] == 1
    assert first["teams"][0]["url"] == "https://www.vlr.gg/team/1/x"
    # The unfetchable match keeps the documented null image.
    assert second["teams"][0]["image"] == {"url": None, "light_url": None, "dark_url": None}
    assert set(first["teams"][0]) == set(second["teams"][0])
    # Match 12 is a known miss now, so the list counts as complete.
    assert "s-maxage=300," in resp.headers["cache-control"]


@pytest.mark.anyio
async def test_v3_match_list_with_pending_logos_gets_a_short_edge_ttl(async_client, monkeypatch):
    payload = _list_payload(("21", ("Slow", "Team")))

    async def fake_matches(*args, **kwargs):
        return {"data": payload}

    monkeypatch.setattr("routers.v3_router.get_match_data", fake_matches)
    monkeypatch.setattr(team_logo_enrichment, "BUDGET_SECONDS", 0.01)
    _install_fetch(
        monkeypatch,
        {"21": (_team("1", "Slow", "https://cdn/s.png"), _team("2", "Team", "https://cdn/t.png"))},
        delay=0.2,
    )

    resp = await async_client.get("/v3/matches?q=upcoming")

    assert resp.status_code == 200
    assert resp.headers["cache-control"] == "public, max-age=0, s-maxage=15, stale-while-revalidate=7"
    await asyncio.sleep(0.3)
