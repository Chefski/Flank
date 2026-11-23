import httpx
import pytest
from selectolax.lexbor import LexborHTMLParser as HTMLParser

from api.scrapers.rankings import (
    _extract_last_played_summary,
    _extract_ranked_team_name,
    vlr_rankings,
)
from utils.cache_manager import cache_manager

RANKINGS_HTML = """
<html>
  <body>
    <div class="rank-item wf-card fc-flex">
      <div class="rank-item-rank-num">1</div>
      <a href="/team/1034/nrg" data-sort-value="NRG" class="rank-item-team fc-flex">
        <img src="//owcdn.net/img/team.png" alt="NRG">
        <div class="ge-text">
          NRG
          <span class="ge-text-light">#Z5K</span>
          <div class="rank-item-team-country">United States</div>
        </div>
      </a>
      <div class="rank-item-rating">1916</div>
      <div class="rank-item-streak"><span>1L</span></div>
      <a data-sort-value="9172" class="rank-item-last fc-flex" href="/626550/example-match">
        <div>6d ago</div>
        <div>
          <span class="rank-item-last-vs">vs.</span>
          <img src="//owcdn.net/img/opponent.png" alt="Paper Rex">
          <span style="font-weight: 700;">Paper Rex</span>
        </div>
      </a>
      <div class="rank-item-record">47-24</div>
      <div class="rank-item-record">166-85</div>
      <div class="rank-item-earnings">$2,125,500</div>
    </div>
  </body>
</html>
"""

DARK_RANKINGS_HTML = RANKINGS_HTML.replace(
    "//owcdn.net/img/team.png",
    "//owcdn.net/img/team-dark.png",
).replace(
    "//owcdn.net/img/opponent.png",
    "//owcdn.net/img/opponent-dark.png",
)


FALLBACK_ROW_HTML = """
<div class="rank-item wf-card fc-flex">
  <a class="rank-item-team fc-flex" href="/team/1/example">
    <div class="ge-text">
      Team Liquid
      <span class="ge-text-light">#ABC</span>
      <div class="rank-item-team-country">Brazil</div>
    </div>
  </a>
  <a class="rank-item-last fc-flex" href="/match/1">
    <div>22h ago</div>
    <div>
      <span class="rank-item-last-vs">vs.</span>
      <span style="font-weight: 700;">Evil Geniuses</span>
    </div>
  </a>
</div>
"""


class FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text
        self.content = text.encode("utf-8")
        self.headers: dict = {}


class FakeAsyncClient:
    def __init__(self, light_response: FakeResponse, dark_response: FakeResponse | None = None):
        self.light_response = light_response
        self.dark_response = dark_response or light_response
        self.calls = []
        self.request_headers = []

    async def get(self, url: str, timeout=None, headers=None):
        self.calls.append((url, timeout))
        self.request_headers.append(headers)
        if headers and "%3A1%7D" in headers.get("Cookie", ""):
            return self.dark_response
        return self.light_response


@pytest.mark.anyio
async def test_vlr_rankings_preserves_current_output_shape(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(
        FakeResponse(200, RANKINGS_HTML),
        FakeResponse(200, DARK_RANKINGS_HTML),
    )

    monkeypatch.setattr("api.scrapers.rankings.get_http_client", lambda: client)

    data = await vlr_rankings("na")

    assert data == {
        "data": {
            "status": 200,
            "segments": [
                {
                    "rank": "1",
                    "team": "NRG",
                    "country": "United States",
                    "rating": "1916",
                    "streak": "1L",
                    "last_played": "6d ago",
                    "last_played_team": "vs. Paper Rex",
                    "last_played_team_logo": "//owcdn.net/img/opponent.png",
                    "last_played_team_logo_light": "//owcdn.net/img/opponent.png",
                    "last_played_team_logo_dark": "//owcdn.net/img/opponent-dark.png",
                    "record": "47-24",
                    "recent_record": "166-85",
                    "earnings": "$2,125,500",
                    "logo": "//owcdn.net/img/team.png",
                    "logo_light": "//owcdn.net/img/team.png",
                    "logo_dark": "//owcdn.net/img/team-dark.png",
                }
            ],
        }
    }
    assert client.calls == [
        ("https://www.vlr.gg/rankings/north-america", httpx.USE_CLIENT_DEFAULT),
        ("https://www.vlr.gg/rankings/north-america", httpx.USE_CLIENT_DEFAULT),
    ]
    assert {headers["Cookie"] for headers in client.request_headers} == {
        "settings=%7B%22dark_mode%22%3A0%7D",
        "settings=%7B%22dark_mode%22%3A1%7D",
    }
    cache_manager.clear_all()


def test_rankings_helpers_fall_back_to_structured_text_nodes():
    row = HTMLParser(FALLBACK_ROW_HTML).css_first("div.rank-item")

    assert _extract_ranked_team_name(row) == "Team Liquid"
    assert _extract_last_played_summary(row) == (
        "22h ago",
        "vs. Evil Geniuses",
        "",
    )
