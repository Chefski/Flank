import asyncio
import logging
import re

from api.scrapers.match_detail.parsers import (
    _parse_event_info,
    _parse_match_header,
    _parse_teams,
)
from utils.cache_manager import cache_manager
from utils.constants import (
    CACHE_TTL_LIVE,
    CACHE_TTL_RESULTS,
    CACHE_TTL_UPCOMING,
    LIVE_DETAIL_FETCH_CONCURRENCY,
    LIVE_DETAIL_FETCH_TIMEOUT,
    VLR_BASE_URL,
    VLR_MATCHES_URL,
)
from utils.error_handling import handle_scraper_errors, raise_for_upstream_status
from utils.html_parsers import (
    HTMLParser,
    build_full_url,
    extract_match_teams,
    extract_text_content,
    normalize_image_url,
    pad_to_length,
    parse_href_id_slug,
    parse_html,
    parse_match_timestamp,
)
from utils.http_client import fetch_theme_variants, fetch_with_retries, get_http_client
from utils.match_records import (
    build_match_record,
    match_team,
    normalize_match_status,
)
from utils.pagination import PaginationConfig, scrape_multiple_pages

logger = logging.getLogger(__name__)


def _safe_flag(team_node) -> str:
    """Safely extract the homepage flag token from a team node."""
    flag_elem = team_node.css_first(".flag") if team_node else None
    if not flag_elem:
        return ""
    flag_class = flag_elem.attributes.get("class", "")
    return flag_class.replace(" mod-", "").replace("16", "_")


def _country_code(value: str) -> str:
    """Normalize legacy homepage/match-card flag values to a country code."""
    return (
        value.removeprefix("flag_")
        .removeprefix("flag ")
        .removeprefix("mod-")
        .replace("_", "")
    )


def _match_list_meta(**extra) -> dict:
    return {"record_schema": "match-list", **extra}


def _split_event_context(value: str) -> tuple[str, str]:
    """Split VLR labels such as Group Stage–Week 3 into stage and series."""
    parts = re.split(r"\s*(?:[–—]|:)\s*", value, maxsplit=1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return "", value


@handle_scraper_errors
async def vlr_upcoming_matches():
    """Get upcoming matches from VLR.GG homepage."""
    async def build():
        client = get_http_client()
        resp = await fetch_with_retries(VLR_BASE_URL, client=client)
        status = resp.status_code
        raise_for_upstream_status(status, "upcoming matches")

        html = parse_html(resp.text)

        result = []
        for item in html.css(".js-home-matches-upcoming a.wf-module-item"):
            is_upcoming = item.css_first(".h-match-eta.mod-upcoming")
            if not is_upcoming:
                continue

            team1, team2 = extract_match_teams(item, ".h-match-team")

            eta = extract_text_content(item.css_first(".h-match-eta"))
            if eta != "LIVE":
                eta = eta + " from now"

            match_event = extract_text_content(item.css_first(".h-match-preview-event"))
            match_series = extract_text_content(item.css_first(".h-match-preview-series"))
            timestamp = parse_match_timestamp(item, "")
            href = item.attributes.get("href", "")
            match_id, _ = parse_href_id_slug(href)
            url_path = build_full_url(href)
            event_stage, event_series = _split_event_context(match_series)
            canonical = build_match_record(
                source="upcoming",
                match_id=match_id,
                url=url_path,
                status="scheduled",
                status_text=extract_text_content(item.css_first(".h-match-eta")),
                relative_time=extract_text_content(item.css_first(".h-match-eta")),
                event_name=match_event,
                event_stage=event_stage,
                event_series=event_series,
                teams=[
                    match_team(
                        name=team1["name"],
                        country_code=_country_code(team1["flag"]),
                    ),
                    match_team(
                        name=team2["name"],
                        country_code=_country_code(team2["flag"]),
                    ),
                ],
            )

            result.append(
                {
                    "match_id": match_id,
                    "url": url_path,
                    "team1": team1["name"],
                    "team2": team2["name"],
                    "flag1": team1["flag"],
                    "flag2": team2["flag"],
                    "time_until_match": eta,
                    "match_series": match_series,
                    "match_event": match_event,
                    "unix_timestamp": timestamp,
                    "match_page": url_path,
                    "match": canonical,
                }
            )

        data = {
            "data": {
                "status": status,
                "segments": result,
                "meta": _match_list_meta(),
            }
        }

        return data

    return await cache_manager.get_or_create_async(CACHE_TTL_UPCOMING, build, "upcoming")


@handle_scraper_errors
async def vlr_live_score():
    """Get live match scores from VLR.GG. Fetches match detail pages concurrently."""
    async def build():
        client = get_http_client()
        resp = await fetch_with_retries(VLR_BASE_URL, client=client)
        status = resp.status_code
        raise_for_upstream_status(status, "live scores")

        html = parse_html(resp.text)

        matches = html.css(".js-home-matches-upcoming a.wf-module-item")
        live_matches = []
        for match in matches:
            is_live = match.css_first(".h-match-eta.mod-live")
            if not is_live:
                continue

            teams = []
            flags = []
            scores = []
            round_texts = []
            for team in match.css(".h-match-team"):
                teams.append(extract_text_content(team.css_first(".h-match-team-name")) or "TBD")
                flags.append(_safe_flag(team))
                scores.append(extract_text_content(team.css_first(".h-match-team-score")))
                round_info_ct = team.css(".h-match-team-rounds .mod-ct")
                round_info_t = team.css(".h-match-team-rounds .mod-t")
                round_text_ct = round_info_ct[0].text().strip() if round_info_ct else "N/A"
                round_text_t = round_info_t[0].text().strip() if round_info_t else "N/A"
                round_texts.append({"ct": round_text_ct, "t": round_text_t})

            pad_to_length(teams, 2, lambda: "TBD")
            pad_to_length(flags, 2, lambda: "")
            pad_to_length(scores, 2, lambda: "")
            pad_to_length(round_texts, 2, lambda: {"ct": "N/A", "t": "N/A"})

            match_event = extract_text_content(match.css_first(".h-match-preview-event"))
            match_series = extract_text_content(match.css_first(".h-match-preview-series"))
            timestamp = parse_match_timestamp(match, "")
            href = match.attributes.get("href", "")
            url_path = build_full_url(href)
            match_id, _ = parse_href_id_slug(href)

            live_matches.append({
                "teams": teams,
                "flags": flags,
                "scores": scores,
                "round_texts": round_texts,
                "match_event": match_event,
                "match_series": match_series,
                "timestamp": timestamp,
                "url_path": url_path,
                "match_id": match_id,
            })

        detail_fetch_semaphore = asyncio.Semaphore(LIVE_DETAIL_FETCH_CONCURRENCY)

        async def fetch_match_detail(url):
            try:
                async with detail_fetch_semaphore:
                    light_resp, dark_resp = await fetch_theme_variants(
                        url,
                        client=client,
                        timeout=LIVE_DETAIL_FETCH_TIMEOUT,
                        max_retries=1,
                    )
                    if light_resp.status_code >= 400:
                        logger.warning(
                            "Failed to fetch live match detail %s: upstream status %d",
                            url,
                            light_resp.status_code,
                        )
                        return None
                    return light_resp, dark_resp
            except Exception as e:
                logger.warning("Failed to fetch match detail %s: %s", url, e)
                return None

        detail_responses = await asyncio.gather(
            *[fetch_match_detail(m["url_path"]) for m in live_matches]
        )

        result = []
        for match_data, detail_response_pair in zip(live_matches, detail_responses):
            team_logos_light = ["", ""]
            team_logos_dark = ["", ""]
            current_map = "Unknown"
            map_number = "Unknown"

            if detail_response_pair is not None:
                light_detail_resp, dark_detail_resp = detail_response_pair
                match_html = parse_html(light_detail_resp.text)
                dark_match_html = parse_html(dark_detail_resp.text)
                detail_event = _parse_event_info(match_html)
                detail_header = _parse_match_header(match_html)
                detail_teams = _parse_teams(match_html)

                light_logos = [
                    normalize_image_url(img.attributes.get("src", ""))
                    for img in match_html.css(".match-header-vs img")
                ]
                dark_logos = [
                    normalize_image_url(img.attributes.get("src", ""))
                    for img in dark_match_html.css(".match-header-vs img")
                ]
                if len(light_logos) >= 2:
                    team_logos_light = light_logos[:2]
                if len(dark_logos) >= 2:
                    team_logos_dark = dark_logos[:2]
                else:
                    team_logos_dark = team_logos_light.copy()

                current_map_element = match_html.css_first(
                    ".vm-stats-gamesnav-item.js-map-switch.mod-active.mod-live"
                )
                if current_map_element:
                    map_text = (
                        current_map_element.css_first("div", default="Unknown")
                        .text().strip().replace("\n", "").replace("\t", "")
                    )
                    current_map = re.sub(r"^\d+", "", map_text)
                    map_number_match = re.search(r"^\d+", map_text)
                    map_number = map_number_match.group(0) if map_number_match else "Unknown"

            else:
                detail_event = {}
                detail_header = {}
                detail_teams = []

            rt = match_data["round_texts"]
            canonical_teams = []
            for index in range(2):
                detail_team = detail_teams[index] if index < len(detail_teams) else {}
                canonical_teams.append(
                    match_team(
                        team_id=detail_team.get("id", ""),
                        name=match_data["teams"][index],
                        tag=detail_team.get("tag", ""),
                        country_code=_country_code(match_data["flags"][index]),
                        logo=team_logos_light[index],
                        score=match_data["scores"][index],
                    )
                )
            event_stage, event_series = _split_event_context(
                detail_event.get("series", "") or match_data["match_series"]
            )
            canonical = build_match_record(
                source="live",
                match_id=match_data["match_id"],
                url=match_data["url_path"],
                status="live",
                status_text="LIVE",
                scheduled_at=detail_header.get("scheduled_at", ""),
                date=detail_header.get("date", ""),
                event_id=detail_event.get("id", ""),
                event_name=detail_event.get("name", "")
                or match_data["match_event"],
                event_stage=event_stage,
                event_stage_slug=detail_event.get("stage", ""),
                event_series=event_series,
                event_url=detail_event.get("url", ""),
                event_logo=detail_event.get("logo", ""),
                teams=canonical_teams,
            )
            result.append(
                {
                    "team1": match_data["teams"][0],
                    "team2": match_data["teams"][1],
                    "flag1": match_data["flags"][0],
                    "flag2": match_data["flags"][1],
                    "team1_logo": team_logos_light[0],
                    "team1_logo_light": team_logos_light[0],
                    "team1_logo_dark": team_logos_dark[0] or team_logos_light[0],
                    "team2_logo": team_logos_light[1],
                    "team2_logo_light": team_logos_light[1],
                    "team2_logo_dark": team_logos_dark[1] or team_logos_light[1],
                    "score1": match_data["scores"][0],
                    "score2": match_data["scores"][1],
                    "team1_round_ct": rt[0]["ct"] if len(rt) > 0 else "N/A",
                    "team1_round_t": rt[0]["t"] if len(rt) > 0 else "N/A",
                    "team2_round_ct": rt[1]["ct"] if len(rt) > 1 else "N/A",
                    "team2_round_t": rt[1]["t"] if len(rt) > 1 else "N/A",
                    "map_number": map_number,
                    "current_map": current_map,
                    "time_until_match": "LIVE",
                    "match_event": match_data["match_event"],
                    "match_series": match_data["match_series"],
                    "unix_timestamp": match_data["timestamp"],
                    "match_page": match_data["url_path"],
                    "match_id": match_data["match_id"],
                    "url": match_data["url_path"],
                    "match": canonical,
                }
            )

        data = {
            "data": {
                "status": status,
                "segments": result,
                "meta": _match_list_meta(),
            }
        }

        return data

    return await cache_manager.get_or_create_async(CACHE_TTL_LIVE, build, "live_score")


def _parse_single_match(item, date_str, page):
    """Extract all match fields from one <a> element. Returns dict or None."""
    eta_element = item.css_first(".ml-eta")
    if eta_element and "ago" in eta_element.text():
        return None

    href = item.attributes.get("href", "")
    match_id, _ = parse_href_id_slug(href)
    url_path = build_full_url(href)

    eta = item.css_first(".ml-status").text().strip() if item.css_first(".ml-status") else ""
    if not eta:
        eta_elem = item.css_first(".ml-eta")
        if eta_elem:
            eta_text = eta_elem.text().strip()
            if eta_text and "ago" not in eta_text:
                eta = eta_text

    teams = []
    flags = []
    scores_list = []
    for team_div in item.css(".match-item-vs-team"):
        team_name_elem = team_div.css_first(".match-item-vs-team-name")
        teams.append(team_name_elem.text().strip() if team_name_elem else "TBD")

        flag_elem = team_div.css_first(".flag")
        if flag_elem:
            flag_class = flag_elem.attributes.get("class")
            flags.append(flag_class.replace("flag ", "").replace(" mod-", "_") if flag_class else "")
        else:
            flags.append("")

        score_elem = team_div.css_first(".match-item-vs-team-score")
        scores_list.append(score_elem.text().strip() if score_elem else "")

    pad_to_length(teams, 2, lambda: "TBD")
    pad_to_length(flags, 2, lambda: "")
    pad_to_length(scores_list, 2, lambda: "")

    match_event_elem = item.css_first(".match-item-event-series")
    match_series = ""
    if match_event_elem:
        event_text = match_event_elem.text().replace("\n", "").replace("\t", "").strip()
        parts = event_text.split()
        if parts:
            match_series = " ".join(parts)

    tourney_elem = item.css_first(".match-item-event")
    tourney = ""
    if tourney_elem:
        tourney_lines = [line.strip() for line in tourney_elem.text().split("\n") if line.strip()]
        tourney = tourney_lines[-1] if tourney_lines else ""

    tourney_icon_elem = item.css_first(".match-item-icon img")
    tourney_icon_url = ""
    if tourney_icon_elem:
        icon_src = tourney_icon_elem.attributes.get("src", "")
        if icon_src:
            tourney_icon_url = normalize_image_url(icon_src)

    timestamp = parse_match_timestamp(item, date_str)
    time_text = extract_text_content(item.css_first(".match-item-time"))
    relative_time = extract_text_content(item.css_first(".ml-eta"))
    note = extract_text_content(item.css_first(".match-item-note"))
    status = normalize_match_status(eta, relative_time)
    team_nodes = item.css(".match-item-vs-team")
    canonical_teams = [
        match_team(
            name=teams[index],
            country_code=_country_code(flags[index]),
            score=scores_list[index],
            is_winner=(
                index < len(team_nodes)
                and "mod-winner" in team_nodes[index].attributes.get("class", "")
            ),
        )
        for index in range(2)
    ]
    event_stage, event_series = _split_event_context(match_series)
    canonical = build_match_record(
        source="matches",
        match_id=match_id,
        url=url_path,
        status=status,
        status_text=eta,
        date=date_str,
        time=time_text,
        relative_time=relative_time,
        event_name=tourney,
        event_stage=event_stage,
        event_series=event_series,
        event_logo=tourney_icon_url,
        teams=canonical_teams,
        note=note,
        page=page,
    )

    return {
        "match_id": match_id,
        "url": url_path,
        "status": status,
        "date": date_str,
        "time": time_text,
        "team1": teams[0],
        "team2": teams[1],
        "flag1": flags[0],
        "flag2": flags[1],
        "score1": scores_list[0],
        "score2": scores_list[1],
        "time_until_match": eta,
        "match_series": match_series,
        "match_event": tourney,
        "unix_timestamp": timestamp,
        "match_page": url_path,
        "tournament_icon": tourney_icon_url,
        "page_number": page,
        "match": canonical,
    }


def _parse_upcoming_page(html: HTMLParser, page: int) -> list[dict]:
    """Parse callback for scrape_multiple_pages — upcoming extended matches."""
    page_results = []
    date_labels = html.css(".wf-label.mod-large")

    if date_labels:
        for label in date_labels:
            date_str = label.text(deep=False, strip=True)
            sibling = label.next
            card = None
            while sibling is not None:
                if hasattr(sibling, 'tag') and sibling.tag and sibling.attributes:
                    classes = sibling.attributes.get("class", "")
                    if "wf-card" in classes:
                        card = sibling
                        break
                sibling = sibling.next
            if card is None:
                continue
            for item in card.css("a.wf-module-item"):
                try:
                    match_data = _parse_single_match(item, date_str, page)
                    if match_data is not None:
                        page_results.append(match_data)
                except Exception as e:
                    logger.warning("Failed to parse match on page %d: %s", page, e)
    else:
        for item in html.css("a.wf-module-item"):
            try:
                match_data = _parse_single_match(item, "", page)
                if match_data is not None:
                    page_results.append(match_data)
            except Exception as e:
                logger.warning("Failed to parse match on page %d: %s", page, e)

    return page_results


def _parse_single_result(item, date_str: str, page: int) -> dict | None:
    """Parse one completed global match card with legacy and canonical fields."""
    href = item.attributes.get("href", "")
    if not href:
        return None
    match_id, _ = parse_href_id_slug(href)
    url_path = build_full_url(href)

    team_nodes = item.css(".match-item-vs-team")
    teams = []
    legacy_flags = []
    for team_node in team_nodes[:2]:
        flag_node = team_node.css_first(".flag")
        flag_class = flag_node.attributes.get("class", "") if flag_node else ""
        legacy_flags.append(flag_class.replace(" mod-", "_"))
        teams.append(
            match_team(
                name=extract_text_content(
                    team_node.css_first(".match-item-vs-team-name")
                ),
                country_code=_country_code(flag_class),
                score=extract_text_content(
                    team_node.css_first(".match-item-vs-team-score")
                ),
                is_winner="mod-winner" in team_node.attributes.get("class", ""),
            )
        )
    while len(teams) < 2:
        teams.append(match_team())
        legacy_flags.append("")

    relative_time = extract_text_content(item.css_first(".ml-eta"))
    completed_ago = (
        relative_time if relative_time.casefold().endswith("ago") else f"{relative_time} ago"
    ).strip()
    status_text = extract_text_content(item.css_first(".ml-status"))
    event_series = extract_text_content(
        item.css_first(".match-item-event-series")
    )
    event_series_legacy = event_series.replace("\u2013", "-")
    event_elem = item.css_first(".match-item-event")
    event_lines = [
        line.strip() for line in event_elem.text().splitlines() if line.strip()
    ] if event_elem else []
    event_name = event_lines[-1] if event_lines else ""
    icon_elem = item.css_first(".match-item-icon img")
    event_logo = normalize_image_url(
        icon_elem.attributes.get("src", "") if icon_elem else ""
    )
    time_text = extract_text_content(item.css_first(".match-item-time"))
    note = extract_text_content(item.css_first(".match-item-note"))
    event_stage, canonical_series = _split_event_context(event_series)
    canonical = build_match_record(
        source="results",
        match_id=match_id,
        url=url_path,
        status="completed",
        status_text=status_text,
        date=date_str,
        time=time_text,
        relative_time=completed_ago,
        event_name=event_name,
        event_stage=event_stage,
        event_series=canonical_series,
        event_logo=event_logo,
        teams=teams,
        note=note,
        page=page,
    )
    return {
        "match_id": match_id,
        "url": url_path,
        "status": "completed",
        "date": date_str,
        "time": time_text,
        "team1": teams[0]["name"],
        "team2": teams[1]["name"],
        "score1": teams[0]["score"],
        "score2": teams[1]["score"],
        "flag1": legacy_flags[0],
        "flag2": legacy_flags[1],
        "time_completed": completed_ago,
        "round_info": event_series_legacy,
        "tournament_name": event_name,
        "match_page": url_path,
        "tournament_icon": event_logo,
        "page_number": page,
        "match": canonical,
    }


def _parse_results_page(html: HTMLParser, page: int) -> list[dict]:
    """Parse callback for scrape_multiple_pages — match results."""
    page_results = []
    labels = html.css(".wf-label.mod-large")
    if labels:
        for label in labels:
            date_str = label.text(deep=False, strip=True)
            card = label.next
            while card is not None and (
                not getattr(card, "attributes", None)
                or "wf-card" not in card.attributes.get("class", "")
            ):
                card = card.next
            if card is None:
                continue
            items = card.css("a.wf-module-item.match-item")
            for item in items:
                try:
                    parsed = _parse_single_result(item, date_str, page)
                    if parsed:
                        page_results.append(parsed)
                except Exception as exc:
                    logger.warning("Failed to parse result on page %d: %s", page, exc)
    else:
        for item in html.css("a.wf-module-item.match-item"):
            try:
                parsed = _parse_single_result(item, "", page)
                if parsed:
                    page_results.append(parsed)
            except Exception as exc:
                logger.warning("Failed to parse result on page %d: %s", page, exc)
    return page_results


@handle_scraper_errors
async def vlr_upcoming_matches_extended(
    num_pages=1, from_page=None, to_page=None,
    max_retries=3, request_delay=1.0, timeout=30,
):
    """Scrape upcoming matches from the paginated matches page."""
    config = PaginationConfig(
        num_pages=num_pages, from_page=from_page, to_page=to_page,
        max_retries=max_retries, request_delay=request_delay, timeout=timeout,
    )
    cache_key = ("upcoming_ext", num_pages, from_page, to_page)

    async def build():
        return await scrape_multiple_pages(
            base_url=VLR_MATCHES_URL,
            parse_func=_parse_upcoming_page,
            config=config,
        )

    return await cache_manager.get_or_create_async(CACHE_TTL_UPCOMING, build, *cache_key)


@handle_scraper_errors
async def vlr_match_results(
    num_pages=1, from_page=None, to_page=None,
    max_retries=3, request_delay=1.0, timeout=30,
):
    """Scrape match results with pagination."""
    config = PaginationConfig(
        num_pages=num_pages, from_page=from_page, to_page=to_page,
        max_retries=max_retries, request_delay=request_delay, timeout=timeout,
    )
    cache_key = ("results", num_pages, from_page, to_page)

    async def build():
        return await scrape_multiple_pages(
            base_url=f"{VLR_MATCHES_URL}/results",
            parse_func=_parse_results_page,
            config=config,
        )

    return await cache_manager.get_or_create_async(CACHE_TTL_RESULTS, build, *cache_key)
