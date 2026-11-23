import pytest
from fastapi import HTTPException
from selectolax.lexbor import LexborHTMLParser as HTMLParser

import api.scrapers.event_detail as detail_mod
import api.scrapers.event_resources as resources_mod
from api.scrapers.event_detail import (
    _parse_bracket_match,
    _parse_calendar_links,
    _parse_event_brackets,
    _parse_event_groups,
    _parse_event_header,
    _parse_event_navigation,
    _parse_event_teams,
    _parse_prizes,
    validate_event_stage,
    vlr_event_detail,
)
from api.scrapers.event_resources import (
    _event_filter_mismatches,
    _parse_agent_compositions,
    _parse_agent_pick_rates,
    _parse_event_news,
    _parse_pickem,
    _parse_stage_filters,
    normalize_event_stats_filters,
    normalize_excluded_series,
    vlr_event_agents,
    vlr_event_news,
    vlr_event_pickem,
    vlr_event_stats,
)
from utils.cache_manager import cache_manager

DETAIL_HTML = """
<html><body>
  <div class="event-header">
    <div class="event-header-thumb"><img src="//cdn.test/event.png"></div>
    <div class="event-header-main">
      <div class="event-header-main-bc">
        <a href="/vct">Valorant Champions Tour 2026</a>
        <a href="/vct/?stage=16">Stage 2</a>
        <a href="/vct/?region=24">China</a>
      </div>
      <h1 class="event-header-main-title">VCT 2026: China Stage 2</h1>
      <h2 class="event-header-main-desc">Official circuit event.</h2>
      <div class="event-header-addcal"><div class="zx-menu">
        <a href="https://calendar.google.test">Google Calendar</a>
        <a href="webcal://calendar.test/event/9">Apple Calendar</a>
        <a href="#" data-copy="https://calendar.test/event/9">Copy link</a>
        <a href="/event/ical/9">Download .ics</a>
      </div></div>
      <div class="event-header-main-meta">
        <div><div class="label">Dates</div><div class="value">Jul 9 – Aug 23, 2026</div></div>
        <div><div class="label">Prize</div><div class="value">$250,000</div></div>
        <div><div class="label">Location</div><div class="value"><i class="flag mod-cn"></i>China</div></div>
      </div>
    </div>
  </div>
  <div class="wf-nav">
    <a class="wf-nav-item mod-active" href="/event/9/test"><div class="wf-nav-item-title">Overview</div></a>
    <a class="wf-nav-item" href="/event/matches/9/test"><div class="wf-nav-item-title">Matches <sup>(12)</sup></div></a>
    <a class="wf-nav-item" href="/event/stats/9/test"><div class="wf-nav-item-title">Stats</div></a>
  </div>
  <div class="wf-subnav">
    <a class="wf-subnav-item mod-active" href="/event/9/test/group-stage">
      <div class="ge-text-light">Jul 9–26</div><div class="wf-subnav-item-title">Group Stage</div>
    </a>
    <a class="wf-subnav-item" href="/event/9/test/playoffs">
      <div class="ge-text-light">Aug 14–23</div><div class="wf-subnav-item-title">Playoffs</div>
    </a>
  </div>
  <a class="wf-card mod-dark"><span>not the prize table</span></a>
  <div class="wf-card mod-dark"><div class="wf-ptable">
    <div class="row"><div class="cell">Place</div><div class="cell">Prize</div><div class="cell">Team</div></div>
    <div class="row"><div class="cell">1st</div><div class="cell">$100,000</div><div class="cell">
      <a href="/team/10/winners"><img src="//cdn.test/team.png"><div class="text-of">Winners<div class="ge-text-light">China</div></div></a>
    </div></div>
  </div></div>
  <div class="event-group">
    <div class="event-group-block"><table><thead><tr><th class="mod-title">Group Alpha</th></tr></thead><tbody>
      <tr class="mod-first mod-adv">
        <td><img class="event-group-team-logo" src="//cdn.test/team.png"></td>
        <td><a class="event-group-team" href="/team/10/winners"><div class="event-group-team-name">Winners<div class="event-group-team-region">China</div></div></a></td>
        <td class="mod-stat">5–0</td><td class="mod-stat">10/2</td><td class="mod-stat">150/120</td><td class="mod-stat"><span>+30</span></td>
      </tr>
    </tbody></table></div>
    <div class="group-expand-btn" data-group-id="44"></div>
    <a class="event-group-series-match" href="/777/winners-vs-losers">
      <div><b>Jul 10</b><br>9:00 am</div>
      <div class="team mod-winner"><div class="team-name">WIN</div><img src="//cdn.test/team.png"></div>
      <div class="score"><div class="score-left">2</div><div class="score-right">0</div></div>
      <div class="team mod-loser"><div class="team-name">LOS</div></div>
      <span class="ss-name mod-full">Week 1</span><span>Bo3</span>
    </a>
  </div>
  <div class="bracket-container mod-upper">
    <div class="bracket-col"><div class="bracket-col-label">Upper Final</div>
      <a class="bracket-item" href="/888/final" title="Winners vs. Losers">
        <div class="bracket-item-team mod-first mod-winner" data-team-id="10"><div class="bracket-item-team-name"><span>Winners</span></div><div class="bracket-item-team-score">3</div></div>
        <div class="bracket-item-team" data-team-id="20"><div class="bracket-item-team-name"><span>Losers</span></div><div class="bracket-item-team-score">1</div></div>
        <div class="bracket-item-status" data-utc-ts="1786003200"><span>9:00 am</span><i class="fa fa-video-camera"></i></div>
      </a>
    </div>
  </div>
  <div class="wf-card event-team">
    <a class="event-team-name" href="/team/10/winners">Winners</a>
    <img class="event-team-players-mask-team" src="//cdn.test/team.png">
    <div class="event-team-players">
      <span class="event-team-players-item">&nbsp;</span>
      <a class="event-team-players-item" href="/player/100/ace"><i class="flag mod-us"></i>Ace</a>
    </div>
    <div class="event-team-note"><a href="/event/9/test/group-stage">Group Stage (#1)</a></div>
  </div>
</body></html>
"""


STATS_HTML = """
<html><body>
  <input type="hidden" name="sort" value="rating">
  <input type="hidden" name="dir" value="desc">
  <select name="side"><option value="ct" selected>Defense</option></select>
  <select name="role"><option value="all" selected>All roles</option></select>
  <select name="agent"><option value="all" selected>All agents</option></select>
  <select name="map_id"><option value="all" selected>All maps</option></select>
  <input name="min_rounds" value="0">
  <input type="hidden" name="exclude" value="551">
  <div class="st-ss-group"><div class="st-ss-lbl"><span>Group Stage</span><a data-series-id="55"></a></div>
    <label><input class="st-ss" value="551" checked><span>Week 1</span></label>
    <label><input class="st-ss" value="552"><span>Week 2</span></label>
  </div>
  <table><thead><tr>
    <th>Player</th><th data-col="agents">Agents</th><th data-col="rnd">Rnd</th>
    <th data-col="rating">R</th><th data-col="acs">ACS</th><th data-col="kd">KD</th>
    <th data-col="adr">ADR</th><th data-col="kmax">KMAX</th>
  </tr></thead><tbody><tr>
    <td class="mod-player"><a href="/player/100/ace"><i class="flag mod-us"></i><div class="text-of">Ace</div><div class="st-pl-country">WIN</div></a></td>
    <td class="mod-agents"><span class="st-agent"><img src="/img/vlr/game/agents/jett.png"><span class="st-agent-n">100%</span></span></td>
    <td>200</td><td>1.25</td><td>250</td><td>1.40</td><td>170</td>
    <td><a href="/888/final/?game=999">31</a></td>
  </tr></tbody></table>
</body></html>
"""


AGENTS_HTML = """
<html><body><form>
  <input type="hidden" name="exclude" value="552">
  <div><div><div class="wf-label">Group Stage</div><a class="group-tag-btn" data-series-id="55"></a></div>
    <div><div class="wf-tag-btn" data-subseries-id="551">Week 1</div><div class="wf-tag-btn mod-unselected" data-subseries-id="552">Week 2</div></div>
  </div>
</form>
<table class="wf-table mod-pr-global">
  <tr><th>Map</th><th>#</th><th>ATK</th><th>DEF</th><th><img src="/img/vlr/game/agents/jett.png"></th><th><img src="/img/vlr/game/agents/omen.png"></th></tr>
  <tr class="pr-global-row mod-all"><td></td><td>10</td><td>55%</td><td>45%</td><td>70%</td><td>30%</td></tr>
  <tr class="pr-global-row"><td><span class="map-pseudo-icon">A</span>Ascent</td><td>4</td><td>60%</td><td>40%</td><td>100%</td><td>0%</td></tr>
</table>
<div class="pr-matrix-map"><table class="wf-table">
  <tr><th><span class="map-pseudo-icon">A</span>Ascent</th><th></th><th><img src="/img/vlr/game/agents/jett.png"></th><th><img src="/img/vlr/game/agents/omen.png"></th></tr>
  <tr class="pr-matrix-row"><td><a href="/team/10/winners"><img src="//cdn.test/team.png"><span class="text-of">Winners</span></a></td><td></td><td class="mod-picked"></td><td></td></tr>
  <tr class="pr-matrix-row mod-dropdown"><td><a href="/888/final">Match</a></td><td></td><td class="mod-picked"></td><td></td></tr>
</table></div>
</body></html>
"""


NEWS_HTML = """
<html><body><div class="wf-card">
  <a class="wf-module-item" href="/123/event-story" title="Event story"><div class="ge-text-light">2026/07/27</div>Event story</a>
  <a class="wf-module-item" href="/team/10/winners" title="Not news"><div>Winners</div></a>
</div></body></html>
"""


PICKEM_HTML = """
<html><body>
  <div class="pickem-subseries-container">
    <div class="wf-label mod-large">Group Stage: Week 1</div>
    <div class="pi-match-item">
      <div class="pi-match-item-team" data-team-id="10"><img src="//cdn.test/team.png"><div class="pi-match-item-name">Winners</div></div>
      <div class="pi-match-item-team mod-false" data-team-id="20"><div class="pi-match-item-name">Losers</div></div>
      <input name="subseries-item-id-winner-500" value="">
    </div>
    <div>Picks are locked.</div>
  </div>
  <a href="/event/pickemgroup/9/test">Group</a>
  <div class="event-sidebar mod-leaderboard">
    <a href="/event/leaderboard/9/test">Top Pick'ems</a>
    <div class="wf-card"><div>125 points</div><div class="ge-text-light">10% / 5 users</div></div>
  </div>
</body></html>
"""


class FakeResponse:
    def __init__(self, text, status_code=200):
        self.text = text
        self.status_code = status_code
        self.content = text.encode()
        self.headers = {}


@pytest.fixture(autouse=True)
def clear_caches():
    cache_manager.clear_all()
    yield
    cache_manager.clear_all()


def test_event_overview_parsers_cover_current_site_surfaces():
    html = HTMLParser(DETAIL_HTML)
    header = _parse_event_header(html)
    resources, stages = _parse_event_navigation(html)
    groups = _parse_event_groups(html)
    brackets = _parse_event_brackets(html)

    assert header["name"] == "VCT 2026: China Stage 2"
    assert header["series"] == "Valorant Champions Tour 2026"
    assert header["series_links"][1]["query"] == {"stage": "16"}
    assert header["location_code"] == "cn"
    assert _parse_calendar_links(html)["subscription"] == "https://calendar.test/event/9"
    assert resources[1] == {
        "name": "Matches",
        "count": "12",
        "url": "https://www.vlr.gg/event/matches/9/test",
        "active": False,
    }
    assert stages[0]["slug"] == "group-stage"
    assert stages[0]["active"] is True
    assert groups[0]["id"] == "44"
    assert groups[0]["teams"][0]["record"] == "5–0"
    assert groups[0]["teams"][0]["state"] == "advanced"
    assert groups[0]["matches"][0]["match_id"] == "777"
    assert brackets[0]["type"] == "upper"
    assert brackets[0]["rounds"][0]["matches"][0]["utc_timestamp"] == "1786003200"


def test_prizes_skip_earlier_dark_cards_and_teams_skip_placeholders():
    html = HTMLParser(DETAIL_HTML)

    assert _parse_prizes(html)[0]["team"]["id"] == "10"
    team = _parse_event_teams(html)[0]
    assert team["logo"] == "https://cdn.test/team.png"
    assert team["players"] == [{"id": "100", "name": "Ace", "flag": "us"}]
    assert team["qualification_url"].endswith("/event/9/test/group-stage")


def test_bracket_match_handles_tbd_slots():
    item = HTMLParser('<a class="bracket-item" href="/1/tbd"><div class="bracket-item-team"></div></a>').css_first("a")
    parsed = _parse_bracket_match(item)
    assert parsed["team1"]["name"] == "TBD"
    assert parsed["team2"]["name"] == "TBD"


@pytest.mark.parametrize("stage", ["group-stage", "playoffs", "stage-2"])
def test_validate_event_stage_accepts_safe_slug(stage):
    assert validate_event_stage(stage) == stage


@pytest.mark.parametrize("stage", ["../stats", "stage?x=1", "stage one"])
def test_validate_event_stage_rejects_unsafe_slug(stage):
    with pytest.raises(HTTPException) as exc:
        validate_event_stage(stage)
    assert exc.value.status_code == 400


def test_event_resource_parsers():
    stats_html = HTMLParser(STATS_HTML)
    agents_html = HTMLParser(AGENTS_HTML)

    assert _parse_stage_filters(stats_html)[0]["subseries"][0]["included"] is True
    rates = _parse_agent_pick_rates(agents_html)
    assert rates[0]["map"] == "all"
    assert rates[1]["map"] == "Ascent"
    assert rates[1]["agents"][0] == {"agent": "jett", "pick_rate": "100%"}
    compositions = _parse_agent_compositions(agents_html)
    assert compositions == [
        {
            "map": "Ascent",
            "teams": [
                {
                    "team_id": "10",
                    "team": "Winners",
                    "team_url": "https://www.vlr.gg/team/10/winners",
                    "logo": "https://cdn.test/team.png",
                    "agents": ["jett"],
                }
            ],
        }
    ]
    assert _parse_event_news(HTMLParser(NEWS_HTML))[0]["article_id"] == "123"
    pickem = _parse_pickem(HTMLParser(PICKEM_HTML))
    assert pickem["sections"][0]["locked"] is True
    assert pickem["sections"][0]["matches"][0]["team1"]["is_winner"] is True
    assert pickem["sections"][0]["matches"][0]["team2"]["is_winner"] is False
    assert pickem["leaderboard_distribution"] == [
        {"points": "125", "distribution": "10% / 5 users"}
    ]


def test_event_stats_filter_validation():
    filters = normalize_event_stats_filters(
        side="CT",
        role="sentinel",
        agent="Killjoy",
        map_id="12",
        min_rounds=100,
        exclude="551.552",
        sort="kmax",
        direction="asc",
    )
    assert filters.side == "ct"
    assert filters.agent == "killjoy"
    assert filters.exclude == "551.552"

    for kwargs in (
        {"sort": "player"},
        {"direction": "up"},
        {"side": "attack"},
        {"role": "flex"},
        {"agent": "bad agent"},
        {"map_id": "split"},
        {"min_rounds": 1000},
        {"exclude": "551,552"},
    ):
        with pytest.raises(HTTPException):
            normalize_event_stats_filters(**kwargs)
    with pytest.raises(HTTPException):
        normalize_excluded_series("1..2")


def test_event_filter_mismatches_requires_every_control():
    html = HTMLParser(
        """
        <select name="side"><option value="all" selected>All</option></select>
        <input name="min_rounds" value="100">
        """
    )
    assert _event_filter_mismatches(
        html,
        {"side": "ct", "min_rounds": 100, "agent": "killjoy"},
    ) == {
        "side": ("ct", "all"),
        "agent": ("killjoy", "<missing>"),
    }


@pytest.mark.anyio
async def test_event_detail_crawler_uses_stage_path_and_caches(monkeypatch):
    calls = []

    async def fake_fetch(url, *, client=None, **kwargs):
        calls.append(url)
        return FakeResponse(DETAIL_HTML)

    monkeypatch.setattr(detail_mod, "fetch_with_retries", fake_fetch)
    monkeypatch.setattr(detail_mod, "get_http_client", lambda: object())

    data = await vlr_event_detail("9", "group-stage")
    assert calls == ["https://www.vlr.gg/event/9/-/group-stage"]
    assert data["data"]["segments"]["event"]["event_id"] == "9"
    assert data["data"]["segments"]["groups"][0]["name"] == "Group Alpha"
    await vlr_event_detail("9", "group-stage")
    assert len(calls) == 1


@pytest.mark.anyio
async def test_event_detail_rejects_upstream_stage_fallback(monkeypatch):
    async def fake_fetch(url, *, client=None, **kwargs):
        return FakeResponse(DETAIL_HTML)

    monkeypatch.setattr(detail_mod, "fetch_with_retries", fake_fetch)
    monkeypatch.setattr(detail_mod, "get_http_client", lambda: object())

    with pytest.raises(HTTPException) as exc:
        await vlr_event_detail("9", "not-a-real-stage")
    assert exc.value.status_code == 404
    assert "not-a-real-stage" in exc.value.detail


@pytest.mark.anyio
async def test_event_resource_crawlers(monkeypatch):
    calls = []

    async def fake_fetch(url, *, client=None, **kwargs):
        calls.append(url)
        if "/stats/" in url:
            return FakeResponse(STATS_HTML)
        if "/agents/" in url:
            return FakeResponse(AGENTS_HTML)
        if "/news/" in url:
            return FakeResponse(NEWS_HTML)
        return FakeResponse(PICKEM_HTML)

    monkeypatch.setattr(resources_mod, "fetch_with_retries", fake_fetch)
    monkeypatch.setattr(resources_mod, "get_http_client", lambda: object())

    stats = await vlr_event_stats("9", side="ct", exclude="551")
    agents = await vlr_event_agents("9", "552")
    news = await vlr_event_news("9")
    pickem = await vlr_event_pickem("9")

    assert stats["data"]["segments"][0]["player_id"] == "100"
    assert stats["data"]["segments"][0]["max_kills_game_id"] == "999"
    assert stats["data"]["filters"]["side"] == "ct"
    assert agents["data"]["pick_rates"][0]["map"] == "all"
    assert news["data"]["segments"][0]["title"] == "Event story"
    assert pickem["data"]["sections"][0]["matches"][0]["pick_id"] == "500"
    assert any("side=ct" in call and "exclude=551" in call for call in calls)
