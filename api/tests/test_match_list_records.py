import pytest

from api.scrapers.events import vlr_event_matches
from api.scrapers.matches import _parse_single_match, _parse_single_result
from api.scrapers.players import _parse_player_match_item
from api.scrapers.teams.parsers import _parse_team_match_item
from utils.cache_manager import cache_manager
from utils.html_parsers import build_full_url, parse_html
from utils.match_records import parse_history_match_record

GLOBAL_CARD = """
<a href="698903/full-sense-vs-zeta" class="wf-module-item match-item">
  <div class="match-item-time">12:00 PM</div>
  <div class="match-item-vs">
    <div class="match-item-vs-team">
      <div class="match-item-vs-team-name"><span class="flag mod-th"></span>FULL SENSE</div>
      <div class="match-item-vs-team-score">-</div>
    </div>
    <div class="match-item-vs-team">
      <div class="match-item-vs-team-name"><span class="flag mod-jp"></span>ZETA DIVISION</div>
      <div class="match-item-vs-team-score">-</div>
    </div>
  </div>
  <div class="ml-status">Upcoming</div><div class="ml-eta">45m</div>
  <div class="match-item-event"><div class="match-item-event-series">Group Stage–Week 3</div>
    VCT 2026: Pacific Stage 2</div>
  <div class="match-item-icon"><img src="//owcdn.net/img/event.png"></div>
</a>
"""


RESULT_CARD = GLOBAL_CARD.replace(
    'href="698903/full-sense-vs-zeta"',
    'href="/716587/full-sense-vs-zeta"',
).replace(
    '<div class="match-item-vs-team">',
    '<div class="match-item-vs-team mod-winner">',
    1,
).replace(
    '<div class="match-item-vs-team-score">-</div>',
    '<div class="match-item-vs-team-score">2</div>',
    1,
).replace(
    '<div class="match-item-vs-team-score">-</div>',
    '<div class="match-item-vs-team-score">0</div>',
    1,
).replace(
    '<div class="ml-status">Upcoming</div><div class="ml-eta">45m</div>',
    '<div class="ml-status">Completed</div><div class="ml-eta">2h 5m</div>',
)


HISTORY_CARD = """
<a href="/701063/nova-vs-bilibili" class="wf-card fc-flex m-item">
  <div class="m-item-thumb"><img src="//owcdn.net/img/event.png"></div>
  <div class="m-item-event text-of">
    <div style="font-weight: 700" class="text-of">VCT 26: CN Stage 2</div>
    Group Stage ⋅ Seeding
  </div>
  <div class="m-item-team"><span class="m-item-team-name">Nova Esports</span>
    <span class="m-item-team-tag">NOVA</span></div>
  <div class="m-item-logo"><img src="//owcdn.net/img/nova.png"></div>
  <div class="m-item-result mod-win" data-match-id="113328"><span>2</span>:<span>0</span></div>
  <div class="m-item-logo mod-right"><img src="//owcdn.net/img/blg.png"></div>
  <div class="m-item-team mod-right"><span class="m-item-team-name">Bilibili Gaming</span>
    <span class="m-item-team-tag">BLG</span></div>
  <div class="m-item-date"><div>2026/07/26</div>12:30 pm</div>
</a>
"""


EVENT_PAGE = f"""
<html>
  <div class="event-header"><h1 class="event-header-main-title">Example Event</h1>
    <div class="event-header-thumb"><img src="//owcdn.net/img/event.png"></div></div>
  <div class="wf-label mod-large">Thu, July 30, 2026</div>
  {RESULT_CARD.replace('Group Stage–Week 3', 'Week 3').replace('VCT 2026: Pacific Stage 2', 'Group Stage')}
</html>
"""


class FakeResponse:
    def __init__(self, text: str):
        self.status_code = 200
        self.text = text
        self.content = text.encode()
        self.headers = {}


class FakeClient:
    async def get(self, url, timeout=None, headers=None):
        return FakeResponse(EVENT_PAGE)


def test_global_upcoming_and_results_share_the_canonical_shape():
    upcoming = _parse_single_match(
        parse_html(GLOBAL_CARD).css_first("a"),
        "Thu, July 30, 2026",
        1,
    )
    result = _parse_single_result(
        parse_html(RESULT_CARD).css_first("a"),
        "Wed, July 29, 2026",
        2,
    )

    assert upcoming["match_id"] == "698903"
    assert upcoming["match_page"] == "https://www.vlr.gg/698903/full-sense-vs-zeta"
    assert result["match_id"] == "716587"
    assert result["team1"] == "FULL SENSE"
    assert result["score1"] == "2"
    assert set(upcoming["match"]) == set(result["match"])
    assert upcoming["match"]["status"] == "scheduled"
    assert upcoming["match"]["event"]["stage"] == "Group Stage"
    assert upcoming["match"]["event"]["stage_slug"] == ""
    assert upcoming["match"]["event"]["series"] == "Week 3"
    assert result["match"]["status"] == "completed"
    assert result["match"]["event"]["stage"] == "Group Stage"
    assert result["match"]["event"]["series"] == "Week 3"
    assert result["match"]["teams"][0]["is_winner"] is True
    assert result["match"]["event"]["logo"] == "https://owcdn.net/img/event.png"


def test_team_and_player_history_share_identity_event_and_time_fields():
    item = parse_html(HISTORY_CARD).css_first("a")
    canonical = parse_history_match_record(
        item,
        source="team",
        context_team_id="12064",
        page=3,
    )
    team_legacy = _parse_team_match_item(
        item,
        team_id="12064",
        page=3,
    )
    player_legacy = _parse_player_match_item(item, page=3)

    assert canonical["match_id"] == "701063"
    assert canonical["stats_match_id"] == "113328"
    assert canonical["display"] == {
        "date": "2026/07/26",
        "time": "12:30 pm",
        "relative": "",
    }
    assert canonical["event"]["name"] == "VCT 26: CN Stage 2"
    assert canonical["event"]["stage"] == "Group Stage"
    assert canonical["event"]["series"] == "Seeding"
    assert canonical["teams"][0]["id"] == "12064"
    assert canonical["teams"][0]["score"] == "2"
    assert canonical["teams"][1]["logo"] == "https://owcdn.net/img/blg.png"
    assert set(team_legacy["match"]) == set(player_legacy["match"])
    assert team_legacy["score"] == "2:0"
    assert player_legacy["result"] == "win"


@pytest.mark.anyio
async def test_event_matches_add_event_context_to_the_canonical_record(monkeypatch):
    cache_manager.clear_all()
    monkeypatch.setattr("api.scrapers.events.get_http_client", FakeClient)

    data = await vlr_event_matches("77")
    match = data["data"]["segments"][0]["match"]

    assert data["data"]["meta"] == {
        "record_schema": "match-list",
        "event_id": "77",
    }
    assert match["event"]["id"] == "77"
    assert match["event"]["name"] == "Example Event"
    assert match["event"]["stage"] == "Group Stage"
    assert match["event"]["series"] == "Week 3"
    assert match["status"] == "completed"
    cache_manager.clear_all()


def test_build_full_url_handles_root_relative_and_path_relative_links():
    assert build_full_url("/123/example") == "https://www.vlr.gg/123/example"
    assert build_full_url("123/example") == "https://www.vlr.gg/123/example"
    assert build_full_url("https://example.com/path") == "https://example.com/path"
