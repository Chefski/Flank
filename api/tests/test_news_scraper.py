import asyncio

import pytest

from api.scrapers.news import vlr_news, vlr_news_article
from utils.cache_manager import cache_manager

NEWS_HTML = """
<html>
  <body>
    <a class="wf-module-item" href="/123/example-news">
      <div>
        <div>Article title</div>
        <div>Article summary</div>
      </div>
      <div class="ge-text-light">Posted • April 23, 2024 by author_name</div>
    </a>
  </body>
</html>
"""

LIVE_NEWS_HTML = """
<html>
  <body>
    <a class="wf-module-item mod-first" href="/645756/eternal-fire-replaces-ulf-esports-in-vct-emea">
      <div>
        <div>
          Eternal Fire replaces ULF Esports in VCT EMEA
        </div>
        <div>
          A new banner for the ULF Esports core.
        </div>
        <div class="ge-text-light">
          <i class="flag mod-tr"></i> <span>&bull;</span> March 20, 2026 <span>&bull;</span> by jenopelle
        </div>
      </div>
    </a>
    <a class="wf-module-item" href="/644767/m80-rebuild-heats-up-with-kaplan-and-nismos-return">
      <div>
        <div>
          M80 rebuild heats up with kaplan and NiSMO's return
        </div>
        <div>
          After a long spell with Sen City, kaplan is taking NiSMO's spot in the coaching booth following his return to play.
        </div>
        <div class="ge-text-light">
          <i class="flag mod-us"></i> <span>&bull;</span> March 19, 2026 <span>&bull;</span> by jenopelle
        </div>
      </div>
    </a>
    <div class="action-container-pages">
      <span class="btn mod-page mod-active">1</span>
      <a class="btn mod-page" href="/news/?page=2">2</a>
      <a class="btn mod-page" href="/news/?page=126">126</a>
    </div>
  </body>
</html>
"""

ARTICLE_HTML = """
<html>
  <head>
    <link rel="canonical" href="https://www.vlr.gg/123/example-news">
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "NewsArticle",
        "headline": "Article title",
        "datePublished": "2026-07-30T02:17:33+01:00",
        "author": {
          "@type": "Person",
          "name": "Author Name",
          "url": "https://www.vlr.gg/user/author_name"
        },
        "description": "Article summary"
      }
    </script>
  </head>
  <body>
    <div class="wf-card mod-article">
      <div class="article-header">
        <a class="article-header-event" href="/event/77/example-event">
          <img src="//owcdn.net/img/event.png">Example Event
        </a>
        <h1 class="wf-title mod-article-title">Article title</h1>
        <div class="article-meta">
          <img class="article-meta-avatar" src="//owcdn.net/img/avatar.png">
          <a class="article-meta-author" href="/user/author_name">author_name</a>
          <time datetime="2026-07-30T02:17:33+01:00">9 hours ago</time>
        </div>
      </div>
      <div class="article-body">
        <style>.unused { color: red; }</style>
        <p>First paragraph with <a href="/team/10/example">Example Team</a>.</p>
        <span class="article-ref-card"><a href="/player/20/hidden">Hidden roster</a></span>
        <p><img src="//owcdn.net/img/article.png" alt="Article image"></p>
        <iframe src="https://clips.twitch.tv/embed?clip=example"></iframe>
      </div>
    </div>
  </body>
</html>
"""

NOT_ARTICLE_HTML = """
<html><body><div class="wf-card post">Forum thread</div></body></html>
"""


class FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text
        self.content = text.encode("utf-8")
        self.headers: dict = {}


class FakeAsyncClient:
    def __init__(self, response: FakeResponse):
        self.response = response
        self.calls: list[tuple[str, int | None]] = []

    async def get(self, url: str, timeout=None, headers=None):
        self.calls.append((url, timeout))
        return self.response


@pytest.mark.anyio
async def test_vlr_news_parses_fixture_shape(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(FakeResponse(200, NEWS_HTML))

    monkeypatch.setattr("api.scrapers.news.get_http_client", lambda: client)

    data = await vlr_news()
    segment = data["data"]["segments"][0]

    assert data["data"]["status"] == 200
    assert data["data"]["meta"] == {
        "page": 1,
        "total_pages": 1,
        "has_previous": False,
        "has_next": False,
    }
    assert segment == {
        "article_id": "123",
        "slug": "example-news",
        "title": "Article title",
        "description": "Article summary",
        "date": "April 23, 2024",
        "published_date": "2024-04-23",
        "author": "author_name",
        "region_code": "",
        "url": "https://www.vlr.gg/123/example-news",
        "url_path": "https://www.vlr.gg/123/example-news",
    }
    assert client.calls == [("https://www.vlr.gg/news", None)]
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_news_parses_live_like_markup_without_raw_text_splitting(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(FakeResponse(200, LIVE_NEWS_HTML))

    monkeypatch.setattr("api.scrapers.news.get_http_client", lambda: client)

    data = await vlr_news()
    first, second = data["data"]["segments"]

    assert data["data"]["meta"] == {
        "page": 1,
        "total_pages": 126,
        "has_previous": False,
        "has_next": True,
    }
    assert first["article_id"] == "645756"
    assert first["slug"] == "eternal-fire-replaces-ulf-esports-in-vct-emea"
    assert first["region_code"] == "tr"
    assert first["published_date"] == "2026-03-20"
    assert first["title"] == "Eternal Fire replaces ULF Esports in VCT EMEA"
    assert second["article_id"] == "644767"
    assert second["region_code"] == "us"
    assert second["description"].startswith("After a long spell with Sen City")
    assert client.calls == [("https://www.vlr.gg/news", None)]
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_news_fetches_requested_archive_page(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(FakeResponse(200, LIVE_NEWS_HTML))
    monkeypatch.setattr("api.scrapers.news.get_http_client", lambda: client)

    data = await vlr_news(page=2)

    assert data["data"]["meta"] == {
        "page": 2,
        "total_pages": 126,
        "has_previous": True,
        "has_next": True,
    }
    assert client.calls == [("https://www.vlr.gg/news/?page=2", None)]
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_news_article_parses_metadata_content_links_and_media(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(FakeResponse(200, ARTICLE_HTML))
    monkeypatch.setattr("api.scrapers.news.get_http_client", lambda: client)

    data = await vlr_news_article("123")
    article = data["data"]["segments"][0]

    assert data["data"]["meta"] == {"article_id": "123"}
    assert article["article_id"] == "123"
    assert article["slug"] == "example-news"
    assert article["published_at"] == "2026-07-30T02:17:33+01:00"
    assert article["author"] == {
        "name": "Author Name",
        "handle": "author_name",
        "url": "https://www.vlr.gg/user/author_name",
        "avatar": "https://owcdn.net/img/avatar.png",
    }
    assert article["event"] == {
        "id": "77",
        "name": "Example Event",
        "url": "https://www.vlr.gg/event/77/example-event",
        "logo": "https://owcdn.net/img/event.png",
    }
    assert "First paragraph" in article["content"]["text"]
    assert "Hidden roster" not in article["content"]["text"]
    assert 'href="https://www.vlr.gg/team/10/example"' in article["content"]["html"]
    assert 'src="https://owcdn.net/img/article.png"' in article["content"]["html"]
    assert article["content"]["links"] == [
        {"text": "Example Team", "url": "https://www.vlr.gg/team/10/example"}
    ]
    assert article["content"]["media"] == [
        {
            "type": "image",
            "url": "https://owcdn.net/img/article.png",
            "alt": "Article image",
        },
        {
            "type": "embed",
            "url": "https://clips.twitch.tv/embed?clip=example",
            "alt": "",
        },
    ]
    assert article["comments_url"] == (
        "https://www.vlr.gg/123/example-news#comments"
    )
    assert client.calls == [("https://www.vlr.gg/123", None)]
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_news_article_rejects_non_article_numeric_pages(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(FakeResponse(200, NOT_ARTICLE_HTML))
    monkeypatch.setattr("api.scrapers.news.get_http_client", lambda: client)

    data = await vlr_news_article("123")

    assert data["data"]["status"] == 404
    assert data["data"]["segments"] == []
    cache_manager.clear_all()


@pytest.mark.anyio
async def test_vlr_news_coalesces_concurrent_cache_misses(monkeypatch):
    cache_manager.clear_all()
    client = FakeAsyncClient(FakeResponse(200, NEWS_HTML))

    async def delayed_get(url: str, timeout=None, headers=None):
        await asyncio.sleep(0)
        return await FakeAsyncClient.get(client, url, timeout)

    monkeypatch.setattr("api.scrapers.news.get_http_client", lambda: client)
    monkeypatch.setattr(client, "get", delayed_get)

    first, second = await asyncio.gather(vlr_news(), vlr_news())

    assert first == second
    assert client.calls == [("https://www.vlr.gg/news", None)]
    cache_manager.clear_all()
