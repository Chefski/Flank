import re

from utils.cache_manager import cache_manager
from utils.constants import CACHE_TTL_RANKINGS, VLR_RANKINGS_URL
from utils.error_handling import handle_scraper_errors, raise_for_upstream_status, validate_region
from utils.html_parsers import add_image_variants, parse_html
from utils.http_client import fetch_theme_variants, get_http_client
from utils.team_logos import team_logo_store


def _normalize_text(value: str) -> str:
    """Collapse whitespace in scraped text values."""
    return re.sub(r"\s+", " ", value or "").strip()


def _extract_ranked_team_name(item) -> str:
    """Extract the ranked team name from structured DOM nodes."""
    team_link = item.css_first("a.rank-item-team")
    if not team_link:
        return ""

    candidates = [
        team_link.attributes.get("data-sort-value", ""),
    ]

    logo_img = team_link.css_first("img")
    if logo_img:
        candidates.append(logo_img.attributes.get("alt", ""))

    for candidate in candidates:
        normalized = _normalize_text(candidate)
        if normalized:
            return normalized

    team_text_elem = team_link.css_first("div.ge-text")
    if not team_text_elem:
        return _normalize_text(team_link.text())

    raw_text = _normalize_text(team_text_elem.text())
    removable_text = [
        _normalize_text(child.text())
        for child in team_text_elem.css("span.ge-text-light, div.rank-item-team-country")
    ]
    for child_text in removable_text:
        if child_text:
            raw_text = raw_text.replace(child_text, "", 1)

    return _normalize_text(raw_text)


def _extract_last_played_summary(item) -> tuple[str, str, str]:
    """Extract last-played time, opponent label, and opponent logo."""
    last_match = item.css_first("a.rank-item-last")
    if not last_match:
        return "", "", ""

    last_played = ""
    time_block = last_match.css_first("div")
    if time_block:
        last_played = _normalize_text(time_block.text())

    vs_elem = last_match.css_first(".rank-item-last-vs")
    vs_text = _normalize_text(vs_elem.text()) if vs_elem else ""

    opponent_logo = ""
    opponent_name = ""
    opponent_img = last_match.css_first("img")
    if opponent_img:
        opponent_logo = opponent_img.attributes.get("src", "")
        opponent_name = _normalize_text(opponent_img.attributes.get("alt", ""))

    if not opponent_name:
        for span in last_match.css("span"):
            span_text = _normalize_text(span.text())
            span_class = span.attributes.get("class", "")
            if span_text and "rank-item-last-vs" not in span_class:
                opponent_name = span_text
                break

    if not opponent_name:
        blocks = last_match.css("div")
        if len(blocks) > 1:
            trailing_text = _normalize_text(blocks[1].text())
            if trailing_text.startswith(vs_text):
                trailing_text = trailing_text[len(vs_text):]
            opponent_name = _normalize_text(trailing_text)

    if opponent_name and vs_text:
        last_played_team = _normalize_text(f"{vs_text} {opponent_name}")
    elif opponent_name:
        last_played_team = opponent_name
    else:
        last_played_team = ""

    return last_played, last_played_team, opponent_logo


def _parse_rankings(html) -> list[dict]:
    """Parse ranking rows from one appearance variant of the page."""
    result = []
    for item in html.css("div.rank-item"):
        rank_elem = item.css_first("div.rank-item-rank-num")
        rank = _normalize_text(rank_elem.text()) if rank_elem else ""
        team = _extract_ranked_team_name(item)
        team_link = item.css_first("a.rank-item-team")
        team_logo = team_link.css_first("img") if team_link else None
        logo = team_logo.attributes.get("src", "") if team_logo else ""
        logo = re.sub(r"/img/vlr/tmp/vlr.png", "", logo)
        country = _normalize_text(item.css_first("div.rank-item-team-country").text())
        last_played, last_played_team, last_played_team_logo = _extract_last_played_summary(item)

        record_elems = item.css("div.rank-item-record")
        record = _normalize_text(record_elems[0].text()) if record_elems else ""
        recent_record = _normalize_text(record_elems[1].text()) if len(record_elems) > 1 else ""

        earnings = _normalize_text(item.css_first("div.rank-item-earnings").text())

        rating_elem = item.css_first("div.rank-item-rating")
        rating = _normalize_text(rating_elem.text()) if rating_elem else ""

        streak_elem = item.css_first("div.rank-item-streak")
        streak = _normalize_text(streak_elem.text()) if streak_elem else ""

        result.append(
            {
                "rank": rank,
                "team": team,
                "country": country,
                "rating": rating,
                "streak": streak,
                "last_played": last_played,
                "last_played_team": last_played_team,
                "last_played_team_logo": last_played_team_logo,
                "record": record,
                "recent_record": recent_record,
                "earnings": earnings,
                "logo": logo,
            }
        )
    return result


@handle_scraper_errors
async def vlr_rankings(region_key):
    async def build():
        region_name = validate_region(region_key)
        url = f"{VLR_RANKINGS_URL}/{region_name}"

        client = get_http_client()
        light_resp, dark_resp = await fetch_theme_variants(url, client=client)
        status = light_resp.status_code
        raise_for_upstream_status(status, "rankings")

        result = _parse_rankings(parse_html(light_resp.text))
        dark_result = _parse_rankings(parse_html(dark_resp.text))
        dark_by_team = {item["team"]: item for item in dark_result if item["team"]}

        for index, item in enumerate(result):
            dark_item = dark_by_team.get(item["team"])
            if dark_item is None and index < len(dark_result):
                dark_item = dark_result[index]
            add_image_variants(item, dark_item)
            add_image_variants(item, dark_item, "last_played_team_logo")
            team_logo_store.record_team(item, name=item["team"])

        data = {"data": {"status": status, "segments": result}}

        return data

    return await cache_manager.get_or_create_async(
        CACHE_TTL_RANKINGS, build, "rankings", region_key
    )
