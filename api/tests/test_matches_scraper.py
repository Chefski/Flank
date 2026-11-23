import asyncio

import httpx
import pytest

from api.scrapers.matches import (
    _parse_results_page,
    _parse_single_match,
    vlr_live_score,
    vlr_upcoming_matches,
)
from utils.cache_manager import cache_manager
from utils.html_parsers import parse_html

UPCOMING_HTML = """
<html>
  <div class="js-home-matches-upcoming">
    <a class="wf-module-item">
      <div class="h-match-eta mod-upcoming">51m</div>
      <div class="h-match-team">
        <div class="h-match-team-name">Alpha</div>
      </div>
      <div class="h-match-team">
        <div class="h-match-team-name">Beta</div>
      </div>
    </a>
  </div>
</html>
"""


LIVE_HTML = """
<html>
  <div class="js-home-matches-upcoming">
    <a class="wf-module-item" href="/123">
      <div class="h-match-eta mod-live">LIVE</div>
      <div class="h-match-team">
        <div class="h-match-team-name">Team One</div>
        <div class="h-match-team-score">12</div>
        <div class="h-match-team-rounds">
          <span class="mod-ct">6</span>
        </div>
      </div>
      <div class="h-match-team"></div>
    </a>
  </div>
</html>
"""


MATCH_DETAIL_HTML = """
<html>
<a class="match-header-event" href="/event/77/example-event/group-stage">
  <div><div>Example Event</div><div class="match-header-event-series">Group Stage: W1</div></div>
</a>
<div class="match-header-date">
  <div class="moment-tz-convert" data-utc-ts="2026-07-30 04:00:00">Thursday, July 30</div>
  <div class="moment-tz-convert" data-utc-ts="2026-07-30 04:00:00">9:30 AM IST</div>
</div>
<a class="match-header-link mod-1" href="/team/10/team-one"></a>
<a class="match-header-link mod-2" href="/team/20/team-two"></a>
<div class="match-header-vs">
  <img src="//owcdn.net/img/team-one-light.png">
  <img src="//owcdn.net/img/team-two-light.png">
</div></html>
"""
DARK_MATCH_DETAIL_HTML = MATCH_DETAIL_HTML.replace("-light.png", "-dark.png")

MULTI_LIVE_HTML = """
<html>
  <div class="js-home-matches-upcoming">
    <a class="wf-module-item" href="/101">
      <div class="h-match-eta mod-live">LIVE</div>
      <div class="h-match-team"><div class="h-match-team-name">One</div><div class="h-match-team-score">1</div></div>
      <div class="h-match-team"><div class="h-match-team-name">Two</div><div class="h-match-team-score">2</div></div>
    </a>
    <a class="wf-module-item" href="/102">
      <div class="h-match-eta mod-live">LIVE</div>
      <div class="h-match-team"><div class="h-match-team-name">Three</div><div class="h-match-team-score">3</div></div>
      <div class="h-match-team"><div class="h-match-team-name">Four</div><div class="h-match-team-score">4</div></div>
    </a>
    <a class="wf-module-item" href="/103">
      <div class="h-match-eta mod-live">LIVE</div>
      <div class="h-match-team"><div class="h-match-team-name">Five</div><div class="h-match-team-score">5</div></div>
      <div class="h-match-team"><div class="h-match-team-name">Six</div><div class="h-match-team-score">6</div></div>
    </a>
  </div>
</html>
"""


class FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text
        self.content = text.encode("utf-8")
        self.headers: dict = {}


class FakeAsyncClient:
    def __init__(self, responses: dict[str, list[FakeResponse]]):
        self._responses = responses
        self.calls: list[tuple[str, int | None]] = []

    async def get(self, url: str, timeout=None, headers=None):
        self.calls.append((url, timeout))
        return self._responses[url].pop(0)


@pytest.mark.anyio
async def test_vlr_upcoming_matches_handles_missing_homepage_fields(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            "https://www.vlr.gg": [FakeResponse(200, UPCOMING_HTML)],
        }
    )

    monkeypatch.setattr("api.scrapers.matches.get_http_client", lambda: client)

    data = await vlr_upcoming_matches()
    segment = data["data"]["segments"][0]

    assert data["data"]["status"] == 200
    assert data["data"]["meta"] == {"record_schema": "match-list"}
    assert segment["team1"] == "Alpha"
    assert segment["team2"] == "Beta"
    assert segment["time_until_match"] == "51m from now"
    assert segment["unix_timestamp"] == ""
    assert segment["match_page"] == ""
    assert segment["match"]["status"] == "scheduled"
    assert [team["name"] for team in segment["match"]["teams"]] == [
        "Alpha",
        "Beta",
    ]
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_live_score_handles_missing_homepage_fields(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            "https://www.vlr.gg": [FakeResponse(200, LIVE_HTML)],
            "https://www.vlr.gg/123": [
                FakeResponse(200, MATCH_DETAIL_HTML),
                FakeResponse(200, DARK_MATCH_DETAIL_HTML),
            ],
        }
    )

    monkeypatch.setattr("api.scrapers.matches.get_http_client", lambda: client)

    data = await vlr_live_score()
    segment = data["data"]["segments"][0]

    assert data["data"]["status"] == 200
    assert data["data"]["meta"] == {"record_schema": "match-list"}
    assert segment["team1"] == "Team One"
    assert segment["team2"] == "TBD"
    assert segment["team1_logo"] == "https://owcdn.net/img/team-one-light.png"
    assert segment["team1_logo_dark"] == "https://owcdn.net/img/team-one-dark.png"
    assert segment["score1"] == "12"
    assert segment["team1_round_ct"] == "6"
    assert segment["current_map"] == "Unknown"
    assert segment["time_until_match"] == "LIVE"
    assert segment["match_page"] == "https://www.vlr.gg/123"
    assert segment["match_id"] == "123"
    assert segment["match"]["source"] == "live"
    assert segment["match"]["status"] == "live"
    assert segment["match"]["scheduled_at"] == "2026-07-30T04:00:00Z"
    assert segment["match"]["event"]["id"] == "77"
    assert segment["match"]["event"]["stage"] == "Group Stage"
    assert segment["match"]["event"]["stage_slug"] == "group-stage"
    assert segment["match"]["event"]["series"] == "W1"
    assert [team["id"] for team in segment["match"]["teams"]] == ["10", "20"]
    assert segment["match"]["teams"][0]["logo"] == (
        "https://owcdn.net/img/team-one-light.png"
    )
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_live_score_limits_concurrent_detail_fetches_and_falls_back_on_timeout(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            "https://www.vlr.gg": [FakeResponse(200, MULTI_LIVE_HTML)],
        }
    )

    active_fetches = 0
    max_active_fetches = 0
    detail_timeouts: list[float | None] = []

    async def fake_fetch_with_retries(url, *, client=None, timeout=None, max_retries=3, request_delay=1.0):
        return await client.get(url, timeout=timeout)

    async def fake_fetch_theme_variants(
        url, *, client=None, timeout=None, max_retries=3, request_delay=1.0
    ):
        nonlocal active_fetches, max_active_fetches
        active_fetches += 1
        max_active_fetches = max(max_active_fetches, active_fetches)
        detail_timeouts.append(timeout)
        try:
            assert timeout == 7
            assert max_retries == 1
            # Yield so concurrent detail fetches have a chance to overlap;
            # without this the counter never leaves 1 and the bound is vacuous.
            await asyncio.sleep(0)
            if url.endswith("/102"):
                raise httpx.ReadTimeout("timed out")
            response = FakeResponse(200, MATCH_DETAIL_HTML)
            return response, response
        finally:
            active_fetches -= 1

    monkeypatch.setattr("api.scrapers.matches.get_http_client", lambda: client)
    monkeypatch.setattr("api.scrapers.matches.fetch_with_retries", fake_fetch_with_retries)
    monkeypatch.setattr("api.scrapers.matches.fetch_theme_variants", fake_fetch_theme_variants)
    monkeypatch.setattr("api.scrapers.matches.LIVE_DETAIL_FETCH_CONCURRENCY", 2)
    monkeypatch.setattr("api.scrapers.matches.LIVE_DETAIL_FETCH_TIMEOUT", 7)

    data = await vlr_live_score()

    assert max_active_fetches == 2
    assert detail_timeouts == [7, 7, 7]
    assert [segment["match_page"] for segment in data["data"]["segments"]] == [
        "https://www.vlr.gg/101",
        "https://www.vlr.gg/102",
        "https://www.vlr.gg/103",
    ]
    timed_out_segment = data["data"]["segments"][1]
    assert timed_out_segment["team1_logo"] == ""
    assert timed_out_segment["team2_logo"] == ""
    assert timed_out_segment["current_map"] == "Unknown"
    assert timed_out_segment["map_number"] == "Unknown"
    cache_manager.clear_all()


UPCOMING_WITH_ID_HTML = """
<html>
  <div class="js-home-matches-upcoming">
    <a class="wf-module-item" href="/430123/sentinels-vs-fnatic">
      <div class="h-match-eta mod-upcoming">51m</div>
      <div class="h-match-team">
        <div class="h-match-team-name">Sentinels</div>
      </div>
      <div class="h-match-team">
        <div class="h-match-team-name">Fnatic</div>
      </div>
    </a>
  </div>
</html>
"""

RESULTS_HTML = """
<html>
  <a class="wf-module-item match-item" href="/430123/sentinels-vs-fnatic">
    <div class="match-item-time">2:30 PM</div>
    <div class="match-item-vs">
      <div class="match-item-vs-team">
        <div class="match-item-vs-team-name">
          <div class="text-of"><span class="flag mod-us"></span>Sentinels</div>
        </div>
        <div class="match-item-vs-team-score">2</div>
      </div>
      <div class="match-item-vs-team mod-winner">
        <div class="match-item-vs-team-name">
          <div class="text-of"><span class="flag mod-eu"></span>Fnatic</div>
        </div>
        <div class="match-item-vs-team-score">1</div>
      </div>
    </div>
    <div class="ml-eta">2h</div>
    <div class="match-item-event-series">Grand Final</div>
    <div class="match-item-event">
      <div class="match-item-event-series">Grand Final</div>
      VCT Champions
    </div>
    <div class="match-item-icon">
      <img src="//owcdn.net/img/icon.png">
    </div>
  </a>
</html>
"""


@pytest.mark.anyio
async def test_vlr_upcoming_matches_extracts_match_id(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        {
            "https://www.vlr.gg": [FakeResponse(200, UPCOMING_WITH_ID_HTML)],
        }
    )
    monkeypatch.setattr("api.scrapers.matches.get_http_client", lambda: client)

    data = await vlr_upcoming_matches()
    segments = data["data"]["segments"]
    assert len(segments) == 1
    assert segments[0]["match_id"] == "430123"
    assert segments[0]["team1"] == "Sentinels"
    assert segments[0]["team2"] == "Fnatic"
    cache_manager.clear_all()


def test_parse_single_match_extracts_match_id():
    html = parse_html(RESULTS_HTML)
    item = html.css_first("a.wf-module-item")
    match_data = _parse_single_match(item, "2026-02-09", 1)
    assert match_data is not None
    assert match_data["match_id"] == "430123"


def test_parse_results_page_extracts_match_id():
    html = parse_html(RESULTS_HTML)
    results = _parse_results_page(html, 1)
    assert len(results) == 1
    assert results[0]["match_id"] == "430123"
