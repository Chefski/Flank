import json
import re
from datetime import datetime

from utils.cache_manager import cache_manager
from utils.constants import (
    CACHE_TTL_NEWS,
    CACHE_TTL_NEWS_ARTICLE,
    VLR_BASE_URL,
    VLR_NEWS_URL,
)
from utils.error_handling import (
    handle_scraper_errors,
    raise_for_upstream_status,
    upstream_error_payload,
)
from utils.html_parsers import (
    build_full_url,
    extract_region_from_flag,
    extract_text_content,
    normalize_image_url,
    parse_href_id_slug,
    parse_html,
)
from utils.http_client import fetch_with_retries, get_http_client


def _iter_children(node):
    """Yield direct child nodes in document order."""
    child = node.child if node else None
    while child is not None:
        yield child
        child = child.next


def _extract_news_text(item) -> tuple[str, str]:
    """Extract title and description from the item's direct content block."""
    content = next((child for child in _iter_children(item) if child.tag == "div"), None)
    if content is None:
        return "", ""

    blocks = [child for child in _iter_children(content) if child.tag == "div"]
    title = blocks[0].text(strip=True) if blocks else ""
    description = blocks[1].text(strip=True) if len(blocks) > 1 else ""
    return title, description


def _normalize_meta_fragment(text: str) -> str:
    """Normalize legacy and current bullet separators for metadata parsing."""
    text = text.replace("\xa0", " ").replace("â€¢", "•")
    return re.sub(r"\s+", " ", text).strip()


def _extract_news_meta(item) -> tuple[str, str]:
    """Extract date and author from the metadata block."""
    meta = item.css_first("div.ge-text-light")
    if meta is None:
        return "", ""

    date = ""
    author = ""
    text_fragments: list[str] = []

    for child in _iter_children(meta):
        if child.tag != "-text":
            continue
        fragment = _normalize_meta_fragment(child.text())
        if not fragment or fragment == "•":
            continue
        text_fragments.append(fragment)
        if fragment.lower().startswith("by "):
            author = fragment[3:].strip()
        elif not date:
            date = fragment.strip("• ").strip()

    if author or len(text_fragments) > 1:
        return date, author

    meta_text = _normalize_meta_fragment(meta.text())
    before_author, separator, after_author = meta_text.rpartition(" by ")
    if separator:
        author = after_author.strip()
        meta_text = before_author.strip()

    meta_text = re.sub(r"^\s*posted\s*", "", meta_text, flags=re.IGNORECASE)
    parts = [part.strip() for part in re.split(r"\s*[•]\s*", meta_text) if part.strip()]
    date = parts[-1] if parts else meta_text.strip()
    return date, author


def _published_date(value: str) -> str:
    """Convert the archive's display date to ISO 8601 when possible."""
    try:
        return datetime.strptime(value, "%B %d, %Y").date().isoformat()
    except ValueError:
        return ""


def _parse_news_item(item) -> dict | None:
    """Parse one archive card while retaining its historical aliases."""
    href = item.attributes.get("href", "")
    article_id, slug = parse_href_id_slug(href)
    if not article_id:
        return None

    title, description = _extract_news_text(item)
    date, author = _extract_news_meta(item)
    url = build_full_url(href)
    return {
        "article_id": article_id,
        "slug": slug,
        "title": title,
        "description": description,
        "date": date,
        "published_date": _published_date(date),
        "author": author,
        "region_code": extract_region_from_flag(item.css_first(".flag")),
        "url": url,
        "url_path": url,
    }


def _parse_news_pagination(html, page: int) -> dict:
    """Read the current and final archive pages from VLR's pager."""
    pages = []
    for node in html.css(".action-container-pages .btn.mod-page"):
        value = extract_text_content(node)
        if value.isdigit():
            pages.append(int(value))
    total_pages = max(pages, default=page)
    return {
        "page": page,
        "total_pages": total_pages,
        "has_previous": page > 1,
        "has_next": page < total_pages,
    }


def _find_news_schema(raw_html: str) -> dict:
    """Return the NewsArticle JSON-LD object when the page exposes one."""
    pending = []
    scripts = re.findall(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        raw_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    for script in scripts:
        try:
            pending.append(json.loads(script))
        except (json.JSONDecodeError, TypeError):
            continue

    while pending:
        value = pending.pop(0)
        if isinstance(value, list):
            pending.extend(value)
            continue
        if not isinstance(value, dict):
            continue
        schema_type = value.get("@type")
        if schema_type == "NewsArticle" or (
            isinstance(schema_type, list) and "NewsArticle" in schema_type
        ):
            return value
        graph = value.get("@graph")
        if isinstance(graph, list):
            pending.extend(graph)
    return {}


def _schema_author(schema: dict) -> tuple[str, str]:
    """Extract the display name and URL from supported JSON-LD author shapes."""
    author = schema.get("author", {})
    if isinstance(author, list):
        author = author[0] if author else {}
    if isinstance(author, str):
        return author, ""
    if not isinstance(author, dict):
        return "", ""
    name = author.get("name") or ""
    url = author.get("url") or ""
    return str(name), build_full_url(str(url))


def _article_content(body) -> dict:
    """Return original formatted content plus a clean reading representation."""
    if body is None:
        return {"html": "", "text": "", "links": [], "media": []}

    formatted = parse_html(body.inner_html)
    for node in formatted.css("[href]"):
        node.attrs["href"] = build_full_url(node.attributes.get("href", ""))
    for node in formatted.css("[src]"):
        node.attrs["src"] = build_full_url(node.attributes.get("src", ""))

    content_html = formatted.body.inner_html.strip()
    clean = parse_html(content_html)
    for selector in ("style", ".article-ref-card"):
        for node in clean.css(selector):
            node.decompose()

    raw_text = clean.root.text(separator="\n", strip=True)
    text_lines = [" ".join(line.split()) for line in raw_text.splitlines()]
    content_text = "\n".join(line for line in text_lines if line)

    links = []
    seen_links = set()
    for node in clean.css("a[href]"):
        url = build_full_url(node.attributes.get("href", ""))
        key = (url, extract_text_content(node))
        if not url or key in seen_links:
            continue
        seen_links.add(key)
        links.append({"text": key[1], "url": url})

    media = []
    seen_media = set()
    for node in clean.css("img[src], iframe[src], video[src], source[src]"):
        url = build_full_url(node.attributes.get("src", ""))
        if not url or url in seen_media:
            continue
        seen_media.add(url)
        media.append(
            {
                "type": "image" if node.tag == "img" else "embed",
                "url": url,
                "alt": node.attributes.get("alt", ""),
            }
        )

    return {
        "html": content_html,
        "text": content_text,
        "links": links,
        "media": media,
    }


def _parse_news_article(
    html,
    requested_article_id: str,
    schema: dict | None = None,
) -> dict | None:
    """Parse a VLR article page, rejecting numeric forum or match pages."""
    body = html.css_first(".article-body")
    title_node = html.css_first(".wf-title.mod-article-title")
    if body is None or title_node is None:
        return None

    schema = schema or {}
    canonical_node = html.css_first('link[rel="canonical"]')
    schema_page = schema.get("mainEntityOfPage") or ""
    if isinstance(schema_page, dict):
        schema_page = schema_page.get("@id") or schema_page.get("url") or ""
    canonical_url = build_full_url(
        canonical_node.attributes.get("href", "")
        if canonical_node
        else str(schema_page)
    )
    article_id, slug = parse_href_id_slug(canonical_url)
    article_id = article_id or requested_article_id
    if article_id != requested_article_id:
        return None

    meta_author = html.css_first(".article-meta-author")
    author_handle = extract_text_content(meta_author)
    author_name, schema_author_url = _schema_author(schema)
    author_url = build_full_url(
        meta_author.attributes.get("href", "") if meta_author else ""
    ) or schema_author_url
    author_avatar = html.css_first(".article-meta-avatar")

    published_node = html.css_first(".article-meta time")
    published_at = str(schema.get("datePublished") or "") or (
        published_node.attributes.get("datetime", "") if published_node else ""
    )

    event_node = html.css_first(".article-header-event")
    event_href = event_node.attributes.get("href", "") if event_node else ""
    event_id, _ = parse_href_id_slug(event_href)
    event_logo = event_node.css_first("img") if event_node else None

    description = str(schema.get("description") or "")
    if not description:
        description_node = html.css_first('meta[property="og:description"]')
        description = (
            description_node.attributes.get("content", "")
            if description_node
            else ""
        )

    return {
        "article_id": article_id,
        "slug": slug,
        "url": canonical_url or f"{VLR_BASE_URL}/{article_id}",
        "title": extract_text_content(title_node),
        "description": description,
        "published_at": published_at,
        "relative_time": extract_text_content(published_node),
        "author": {
            "name": author_name or author_handle,
            "handle": author_handle,
            "url": author_url,
            "avatar": normalize_image_url(
                author_avatar.attributes.get("src", "") if author_avatar else ""
            ),
        },
        "event": {
            "id": event_id,
            "name": extract_text_content(event_node),
            "url": build_full_url(event_href),
            "logo": normalize_image_url(
                event_logo.attributes.get("src", "") if event_logo else ""
            ),
        },
        "content": _article_content(body),
        "comments_url": f"{canonical_url or f'{VLR_BASE_URL}/{article_id}'}#comments",
    }


@handle_scraper_errors
async def vlr_news(page: int = 1):
    async def build():
        client = get_http_client()
        url = VLR_NEWS_URL if page == 1 else f"{VLR_NEWS_URL}/?page={page}"
        resp = await fetch_with_retries(url, client=client)
        status = resp.status_code
        raise_for_upstream_status(status, "news")

        html = parse_html(resp.text)

        result = []
        for item in html.css("a.wf-module-item"):
            parsed = _parse_news_item(item)
            if parsed is not None:
                result.append(parsed)

        data = {
            "data": {
                "status": status,
                "segments": result,
                "meta": _parse_news_pagination(html, page),
            }
        }

        return data

    return await cache_manager.get_or_create_async(
        CACHE_TTL_NEWS,
        build,
        "news",
        page,
    )


@handle_scraper_errors
async def vlr_news_article(article_id: str):
    """Get full article metadata and content from a numeric VLR article ID."""
    async def build():
        client = get_http_client()
        resp = await fetch_with_retries(
            f"{VLR_BASE_URL}/{article_id}",
            client=client,
        )
        status = resp.status_code
        if status >= 400:
            return upstream_error_payload(status, f"news article {article_id}")

        article = _parse_news_article(
            parse_html(resp.text),
            article_id,
            schema=_find_news_schema(resp.text),
        )
        if article is None:
            return upstream_error_payload(404, f"news article {article_id}")
        return {
            "data": {
                "status": status,
                "segments": [article],
                "meta": {"article_id": article_id},
            }
        }

    return await cache_manager.get_or_create_async(
        CACHE_TTL_NEWS_ARTICLE,
        build,
        "news_article",
        article_id,
    )
