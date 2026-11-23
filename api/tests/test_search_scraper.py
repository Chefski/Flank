"""Tests for the search scraper: result types, URLs and the cache key."""
import pytest

from api.scrapers.search import vlr_search
from utils.cache_manager import cache_manager


def _item(href: str, title: str, desc: str = "") -> str:
    return f"""
    <a class="wf-module-item search-item mod-first" href="{href}">
      <div class="search-item-thumb"><img src="//owcdn.net/img/x.png"></div>
      <div><div class="search-item-title">{title}</div><div class="search-item-desc">{desc}</div></div>
    </a>"""


SEARCH_HTML = f"""
<html><body>
  <div class="wf-card mod-dark"><form></form></div>
  <div class="wf-card">
    {_item("/search/r/player/9/idx", "TenZ")}
    {_item("/search/r/team/2/idx", "Sentinels")}
    {_item("/search/r/event/2283/idx", "Valorant Champions 2025", "event")}
    {_item("/search/r/eventgroup/14/idx", "Valorant Champions Tour", "series")}
  </div>
</body></html>
"""


class FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text
        self.content = text.encode("utf-8")
        self.headers: dict = {}


@pytest.fixture
def fake_search(monkeypatch):
    cache_manager.clear_all()
    calls: list[str] = []
    registered: list[tuple[str, str]] = []

    async def fake_fetch(url, *, client=None, **kwargs):
        calls.append(url)
        return FakeResponse(200, SEARCH_HTML)

    monkeypatch.setattr("api.scrapers.search.fetch_with_retries", fake_fetch)
    monkeypatch.setattr("api.scrapers.search.get_http_client", lambda: object())
    monkeypatch.setattr(
        "api.scrapers.search.id_mapper.register_event",
        lambda name, event_id: registered.append((name, event_id)),
    )
    yield calls, registered
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_event_hits_carry_their_type_and_absolute_url(fake_search):
    _calls, registered = fake_search

    data = await vlr_search("champions")
    events = data["data"]["segments"]["results"]["events"]

    assert [(hit["id"], hit["type"], hit["url"]) for hit in events] == [
        ("2283", "event", "https://www.vlr.gg/search/r/event/2283/idx"),
        ("14", "series", "https://www.vlr.gg/search/r/eventgroup/14/idx"),
    ]
    # Only real events may be mapped to an event id.
    assert registered == [("Valorant Champions 2025", "2283")]
    # Team and player hits are unchanged.
    assert "type" not in data["data"]["segments"]["results"]["teams"][0]
    assert "type" not in data["data"]["segments"]["results"]["players"][0]


@pytest.mark.anyio
async def test_search_cache_key_ignores_case_and_surrounding_space(fake_search):
    calls, _registered = fake_search

    first = await vlr_search("Champions ")
    second = await vlr_search("  CHAMPIONS")

    assert second is first
    assert len(calls) == 1
