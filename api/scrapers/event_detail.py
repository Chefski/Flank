"""
Scraper for individual VLR.GG event detail pages.

Extracts event metadata, navigation, calendar links, stages, groups, brackets,
prize pool breakdown, participating teams, and legacy standings tables.
"""
import logging
import re
from urllib.parse import parse_qs, urlparse

from fastapi import HTTPException

from utils.cache_manager import cache_manager
from utils.constants import CACHE_TTL_EVENTS, VLR_BASE_URL
from utils.error_handling import handle_scraper_errors, raise_for_upstream_status
from utils.html_parsers import (
    HTMLParser,
    build_full_url,
    extract_text_content,
    normalize_image_url,
    parse_href_id_slug,
    parse_html,
)
from utils.http_client import fetch_with_retries, get_http_client
from utils.id_mapper import id_mapper

logger = logging.getLogger(__name__)

_STAGE_SLUG = re.compile(r"^[a-z0-9-]+$")


def validate_event_stage(stage: str | None) -> str | None:
    """Validate an optional event stage path segment before building a URL."""
    if stage is None:
        return None
    normalized = stage.lower()
    if not _STAGE_SLUG.fullmatch(normalized):
        raise HTTPException(
            status_code=400,
            detail="Invalid event stage. Use the stage slug returned by the event endpoint.",
        )
    return normalized


def _parse_event_header(html: HTMLParser) -> dict:
    """Extract event name, series, dates, prize pool, location, and logo.

    Supports both the new VLR layout (event-header-main) and the legacy
    layout (event-desc-inner / event-desc-item).
    """
    series = ""
    name = ""
    subtitle = ""
    dates = ""
    prize = ""
    location = ""
    location_code = ""
    logo = ""
    series_links: list[dict] = []

    header = html.css_first(".event-header") or html.css_first(".wf-card")
    if not header:
        return {
            "name": name,
            "series": series,
            "series_links": series_links,
            "subtitle": subtitle,
            "dates": dates,
            "prize": prize,
            "location": location,
            "location_code": location_code,
            "logo": logo,
        }

    logo_elem = header.css_first(".event-header-thumb img") or header.css_first("img")
    if logo_elem:
        logo = normalize_image_url(logo_elem.attributes.get("src", ""))

    main = header.css_first(".event-header-main")
    if main:
        bc = main.css_first(".event-header-main-bc")
        if bc:
            for index, series_link in enumerate(bc.css("a")):
                href = series_link.attributes.get("href", "")
                label = extract_text_content(series_link)
                if index == 0:
                    series = label
                parsed = urlparse(href)
                series_links.append(
                    {
                        "name": label,
                        "url": build_full_url(href),
                        "path": parsed.path,
                        "query": {
                            key: values[0]
                            for key, values in parse_qs(parsed.query).items()
                            if values
                        },
                    }
                )

        title = main.css_first("h1.event-header-main-title")
        if title:
            name = extract_text_content(title)

        sub = main.css_first("h2.event-header-main-desc")
        if sub:
            subtitle = extract_text_content(sub)

        meta = main.css_first(".event-header-main-meta")
        if meta:
            child = meta.child
            while child is not None:
                if getattr(child, "tag", None) == "div":
                    label_elem = child.css_first(".label")
                    if label_elem:
                        label = extract_text_content(label_elem).rstrip(":").lower()
                        value_elem = child.css_first(".value")
                        value = extract_text_content(value_elem) if value_elem else ""
                        if label == "dates":
                            dates = value
                        elif label == "prize":
                            prize = value
                        elif label in ("location", "venue"):
                            location = value
                            flag = child.css_first(".flag")
                            if flag:
                                location_code = next(
                                    (
                                        part.removeprefix("mod-")
                                        for part in flag.attributes.get("class", "").split()
                                        if part.startswith("mod-")
                                    ),
                                    "",
                                )
                child = child.next
    else:
        desc_inner = header.css_first(".event-desc-inner")
        if desc_inner:
            series_link = desc_inner.css_first("a")
            if series_link:
                series = extract_text_content(series_link)

        title = header.css_first("h1.wf-title")
        if title:
            name = extract_text_content(title)

        sub = header.css_first(".event-desc-subtitle")
        if sub:
            subtitle = extract_text_content(sub)

        for item in header.css(".event-desc-item"):
            label_elem = item.css_first(".event-desc-item-label")
            value_elem = item.css_first(".event-desc-item-value")
            if not label_elem or not value_elem:
                continue
            label = extract_text_content(label_elem).rstrip(":")
            value = extract_text_content(value_elem)
            if label.lower() == "dates":
                dates = value
            elif label.lower() == "prize":
                prize = value
            elif label.lower() in ("location", "venue"):
                location = value

    return {
        "name": name,
        "series": series,
        "series_links": series_links,
        "subtitle": subtitle,
        "dates": dates,
        "prize": prize,
        "location": location,
        "location_code": location_code,
        "logo": logo,
    }


def _parse_calendar_links(html: HTMLParser) -> dict:
    """Parse public calendar subscription and one-time export URLs."""
    calendar = {
        "google": "",
        "apple": "",
        "subscription": "",
        "download": "",
    }
    menu = html.css_first(".event-header-addcal .zx-menu")
    if menu is None:
        return calendar

    for link in menu.css("a"):
        label = extract_text_content(link).lower()
        href = link.attributes.get("href", "")
        if "google" in label:
            calendar["google"] = href
        elif "apple" in label:
            calendar["apple"] = href
        elif "copy link" in label:
            calendar["subscription"] = link.attributes.get("data-copy", "")
        elif "download" in label:
            calendar["download"] = build_full_url(href)
    return calendar


def _parse_event_navigation(html: HTMLParser) -> tuple[list[dict], list[dict]]:
    """Parse top-level event resources and stage tabs."""
    resources: list[dict] = []
    nav = html.css_first(".wf-nav")
    if nav:
        for link in nav.css("a.wf-nav-item"):
            title_node = link.css_first(".wf-nav-item-title")
            title = extract_text_content(title_node)
            count = ""
            count_node = title_node.css_first("sup") if title_node else None
            if count_node:
                count = extract_text_content(count_node).strip("()")
                title = title.replace(extract_text_content(count_node), "").strip()
            href = link.attributes.get("href", "")
            resources.append(
                {
                    "name": title,
                    "count": count,
                    "url": build_full_url(href),
                    "active": "mod-active" in link.attributes.get("class", ""),
                }
            )

    stages: list[dict] = []
    subnav = html.css_first(".wf-subnav")
    if subnav:
        for link in subnav.css("a.wf-subnav-item"):
            href = link.attributes.get("href", "")
            parsed = urlparse(href)
            parts = [part for part in parsed.path.split("/") if part]
            stages.append(
                {
                    "name": extract_text_content(link.css_first(".wf-subnav-item-title")),
                    "dates": extract_text_content(link.css_first(".ge-text-light")),
                    "slug": parts[-1] if len(parts) >= 4 else "",
                    "url": build_full_url(href),
                    "active": "mod-active" in link.attributes.get("class", ""),
                }
            )
    return resources, stages


def _parse_group_match(item) -> dict:
    href = item.attributes.get("href", "")
    match_id, _ = parse_href_id_slug(href)
    teams = []
    for team in item.css(".team"):
        teams.append(
            {
                "name": extract_text_content(team.css_first(".team-name")) or "TBD",
                "logo": normalize_image_url(
                    team.css_first("img").attributes.get("src", "")
                    if team.css_first("img")
                    else ""
                ),
                "is_winner": "mod-winner" in team.attributes.get("class", ""),
            }
        )
    while len(teams) < 2:
        teams.append({"name": "TBD", "logo": "", "is_winner": False})

    score_left = item.css_first(".score-left")
    score_right = item.css_first(".score-right")
    date_block = item.css_first("div")
    series = item.css_first(".ss-name.mod-full")
    all_text = extract_text_content(item)
    format_match = re.search(r"\bBo\d+\b", all_text, re.IGNORECASE)
    return {
        "match_id": match_id,
        "url": build_full_url(href),
        "date": extract_text_content(date_block),
        "series": extract_text_content(series),
        "format": format_match.group(0) if format_match else "",
        "team1": {**teams[0], "score": extract_text_content(score_left)},
        "team2": {**teams[1], "score": extract_text_content(score_right)},
    }


def _parse_event_groups(html: HTMLParser) -> list[dict]:
    """Parse current ``event-group`` standings and their embedded schedules."""
    groups: list[dict] = []
    for group in html.css(".event-group"):
        title = extract_text_content(group.css_first("th.mod-title"))
        expand = group.css_first(".group-expand-btn")
        group_id = expand.attributes.get("data-group-id", "") if expand else ""
        teams: list[dict] = []
        block = group.css_first(".event-group-block")
        rows = block.css("tbody tr") if block else []
        for rank, row in enumerate(rows, start=1):
            link = row.css_first("a.event-group-team")
            if link is None:
                continue
            href = link.attributes.get("href", "")
            team_id, _ = parse_href_id_slug(href)
            name_node = link.css_first(".event-group-team-name")
            region_node = link.css_first(".event-group-team-region")
            region = extract_text_content(region_node)
            name = extract_text_content(name_node)
            if region:
                name = name.removesuffix(region).strip()
            logo = row.css_first(".event-group-team-logo")
            stats = row.css("td.mod-stat")
            classes = row.attributes.get("class", "")
            state = "advanced" if "mod-adv" in classes else "eliminated" if "mod-elim" in classes else "active"
            teams.append(
                {
                    "rank": rank,
                    "id": team_id,
                    "name": name,
                    "region": region,
                    "logo": normalize_image_url(
                        logo.attributes.get("src", "") if logo else ""
                    ),
                    "state": state,
                    "record": extract_text_content(stats[0]) if len(stats) > 0 else "",
                    "maps": extract_text_content(stats[1]) if len(stats) > 1 else "",
                    "rounds": extract_text_content(stats[2]) if len(stats) > 2 else "",
                    "round_differential": extract_text_content(stats[3]) if len(stats) > 3 else "",
                    "url": build_full_url(href),
                }
            )
            id_mapper.register_team(name, team_id)

        matches = [_parse_group_match(item) for item in group.css("a.event-group-series-match")]
        if title or teams or matches:
            groups.append(
                {
                    "id": group_id,
                    "name": title,
                    "teams": teams,
                    "matches": matches,
                }
            )
    return groups


def _parse_bracket_match(item) -> dict:
    href = item.attributes.get("href", "")
    match_id, _ = parse_href_id_slug(href)
    teams: list[dict] = []
    for team in item.css(".bracket-item-team")[:2]:
        logo = team.css_first("img")
        teams.append(
            {
                "id": team.attributes.get("data-team-id", ""),
                "name": extract_text_content(team.css_first(".bracket-item-team-name span")) or "TBD",
                "logo": normalize_image_url(
                    logo.attributes.get("src", "") if logo else ""
                ),
                "score": extract_text_content(team.css_first(".bracket-item-team-score")),
                "is_winner": "mod-winner" in team.attributes.get("class", ""),
            }
        )
    while len(teams) < 2:
        teams.append(
            {"id": "", "name": "TBD", "logo": "", "score": "", "is_winner": False}
        )
    status = item.css_first(".bracket-item-status")
    return {
        "match_id": match_id,
        "url": build_full_url(href),
        "title": item.attributes.get("title", ""),
        "utc_timestamp": status.attributes.get("data-utc-ts", "") if status else "",
        "status": extract_text_content(status),
        "has_stream": bool(status and status.css_first(".fa-video-camera")),
        "team1": teams[0],
        "team2": teams[1],
    }


def _parse_event_brackets(html: HTMLParser) -> list[dict]:
    """Parse upper/lower/single-elimination bracket rounds and match IDs."""
    brackets: list[dict] = []
    for container in html.css(".bracket-container"):
        classes = container.attributes.get("class", "").split()
        bracket_type = next(
            (part.removeprefix("mod-") for part in classes if part in {"mod-upper", "mod-lower"}),
            "main",
        )
        rounds: list[dict] = []
        columns = []
        child = container.child
        while child is not None:
            if (
                getattr(child, "tag", None) == "div"
                and "bracket-col" in child.attributes.get("class", "").split()
            ):
                columns.append(child)
            child = child.next
        for column in columns:
            name = extract_text_content(column.css_first(".bracket-col-label"))
            matches = [_parse_bracket_match(item) for item in column.css("a.bracket-item")]
            if name or matches:
                rounds.append({"name": name, "matches": matches})
        if rounds:
            brackets.append({"type": bracket_type, "rounds": rounds})
    return brackets
def _parse_event_stages(html: HTMLParser) -> list[dict]:
    """Parse the stage tabs (.wf-subnav) of an event page.

    Each tab links to /event/{id}/{event-slug}/{stage-slug}. Single-stage
    events have no tabs and return [].
    """
    stages: list[dict] = []
    for item in html.css(".wf-subnav a.wf-subnav-item"):
        parts = item.attributes.get("href", "").strip("/").split("/")
        if len(parts) != 4 or parts[0] != "event":
            continue
        title = item.css_first(".wf-subnav-item-title")
        dates = item.css_first(".ge-text-light")
        stages.append({
            "name": extract_text_content(title),
            "slug": parts[3],
            "dates": extract_text_content(dates),
            "active": "mod-active" in item.attributes.get("class", ""),
        })
    return stages


def _parse_prizes(html: HTMLParser) -> list[dict]:
    """Parse the prize breakdown table from the event page."""
    prizes: list[dict] = []

    # Bracket match cards also use ``wf-card mod-dark`` and can precede the prize
    # distribution. Select the ptable whose header names the prize columns.
    ptable = None
    for candidate in html.css(".wf-ptable"):
        header = candidate.css_first(".row")
        labels = [extract_text_content(cell).lower() for cell in header.css(".cell")] if header else []
        if "place" in labels and "prize" in labels and "team" in labels:
            ptable = candidate
            break
    if ptable is None:
        return prizes

    rows = ptable.css(".row")
    for row in rows[1:]:  # skip header row
        cells = row.css(".cell")
        if len(cells) < 3:
            continue

        placement = extract_text_content(cells[0])
        amount = extract_text_content(cells[1])

        # Team cell: contains an <a> link with name and optional region
        team_name = ""
        team_id = ""
        team_logo = ""
        team_region = ""

        team_link = cells[2].css_first("a")
        if team_link:
            href = team_link.attributes.get("href", "")
            team_id, _ = parse_href_id_slug(href)
            name_div = team_link.css_first(".text-of")
            if name_div:
                region_div = name_div.css_first(".ge-text-light")
                if region_div:
                    team_name = extract_text_content(name_div).replace(extract_text_content(region_div), "").strip()
                    team_region = extract_text_content(region_div)
                else:
                    team_name = extract_text_content(name_div)
            else:
                team_name = extract_text_content(team_link)
            img = team_link.css_first("img")
            if img:
                team_logo = normalize_image_url(img.attributes.get("src", ""))

        prizes.append({
            "placement": placement,
            "amount": amount,
            "team": {
                "id": team_id,
                "name": team_name,
                "logo": team_logo,
                "region": team_region,
            },
        })
        id_mapper.register_team(team_name, team_id)

    return prizes


def _qualifier_event_id(href: str) -> str:
    """Event id from a qualification note's link, or "" when it is not usable.

    Notes point at a relative ``/event/<id>/<slug>`` path or an absolute vlr.gg
    URL. Another host, a non-event route or an unparseable href yields "" so a
    malformed note can never fail the surrounding event parse.
    """
    if not href:
        return ""
    if "://" in href:
        try:
            parts = urlparse(href)
        except ValueError:
            return ""
        host = (parts.hostname or "").lower()
        if host and host != "vlr.gg" and not host.endswith(".vlr.gg"):
            return ""
        path = parts.path
    else:
        path = href
    if not path.strip("/").startswith("event/"):
        return ""
    event_id, _ = parse_href_id_slug(path)
    return event_id if event_id.isdigit() else ""


def _parse_event_teams(html: HTMLParser) -> list[dict]:
    """Parse participating teams from event-team cards."""
    teams: list[dict] = []

    for card in html.css(".wf-card.event-team"):
        # Team name link
        name_link = card.css_first(".event-team-name")
        team_name = ""
        team_id = ""
        if name_link:
            team_name = extract_text_content(name_link)
            href = name_link.attributes.get("href", "")
            team_id, _ = parse_href_id_slug(href)

        logo = card.css_first(".event-team-players-mask-team")
        team_logo = normalize_image_url(logo.attributes.get("src", "") if logo else "")

        # Players
        players: list[dict] = []
        for player_link in card.css(".event-team-players-item"):
            href = player_link.attributes.get("href", "")
            p_id, _ = parse_href_id_slug(href)
            p_name = extract_text_content(player_link)
            if not href or not p_name:
                continue
            # Parse flag class (e.g. "flag mod-us")
            flag = ""
            flag_elem = player_link.css_first(".flag")
            if flag_elem:
                flag = next(
                    (
                        part.removeprefix("mod-")
                        for part in flag_elem.attributes.get("class", "").split()
                        if part.startswith("mod-")
                    ),
                    "",
                )
            players.append({"id": p_id, "name": p_name, "flag": flag})

        # Qualification note; its link also names the qualifier event the team
        # came through, which is useful for walking backwards through a circuit.
        note = ""
        note_url = ""
        note_event_id = ""
        note_elem = card.css_first(".event-team-note")
        if note_elem:
            note_link = note_elem.css_first("a")
            if note_link:
                note = extract_text_content(note_link)
                note_url = build_full_url(note_link.attributes.get("href", ""))
                note_event_id = _qualifier_event_id(note_link.attributes.get("href", "") or "")

        teams.append({
            "id": team_id,
            "name": team_name,
            "logo": team_logo,
            "url": build_full_url(name_link.attributes.get("href", "") if name_link else ""),
            "players": players,
            "qualification": note,
            "qualification_url": note_url,
            "qualification_event_id": note_event_id,
        })
        id_mapper.register_team(team_name, team_id)

    return teams


def _parse_standings(html: HTMLParser) -> list[dict]:
    """Parse group/stage standings tables from the event page.

    VLR uses div.wf-ptable elements inside .wf-card containers for standings.
    Handles variable column counts (3-column groups, 5/6-column full tables).
    """
    standings: list[dict] = []

    for card in html.css(".wf-card"):
        ptable = card.css_first(".wf-ptable")
        if not ptable:
            continue
        # Skip the prize table (already handled in _parse_prizes)
        parent_classes = card.attributes.get("class", "")
        if "mod-dark" in parent_classes:
            continue

        # Check for a stage/group label before the table
        stage = ""
        label_elem = card.css_first(".wf-label") or card.css_first("h2")
        if label_elem:
            stage = extract_text_content(label_elem)

        # Parse headers
        header_row = ptable.css_first(".row")
        if not header_row:
            continue
        headers: list[str] = []
        for cell in header_row.css(".cell"):
            headers.append(extract_text_content(cell))

        if not headers:
            continue

        # Parse data rows
        rows: list[dict[str, str]] = []
        for row in ptable.css(".row")[1:]:
            cells = row.css(".cell")
            if len(cells) < 1:
                continue
            row_data: dict[str, str] = {}
            for idx, cell in enumerate(cells):
                label = headers[idx] if idx < len(headers) else str(idx)
                # Team column may have an anchor with name
                team_link = cell.css_first("a")
                if team_link and idx == 0:
                    row_data[label] = extract_text_content(team_link)
                else:
                    row_data[label] = extract_text_content(cell)
            rows.append(row_data)

        standings.append({"stage": stage, "group": "", "columns": headers, "rows": rows})

    standings.extend(_parse_group_tables(html))
    return standings


def _preceding_label(node, max_depth: int = 4) -> str:
    """Text of the nearest .wf-label before ``node`` (checking up to ``max_depth`` ancestors)."""
    current = node
    for _ in range(max_depth):
        sibling = current.prev
        while sibling is not None:
            if sibling.tag and "wf-label" in (sibling.attributes.get("class") or ""):
                return extract_text_content(sibling)
            sibling = sibling.prev
        current = current.parent
        if current is None:
            break
    return ""


def _parse_group_tables(html: HTMLParser) -> list[dict]:
    """Parse group / round-robin standings (table.wf-table.mod-group).

    Each table sits under a stage label ("Round Robin", "Group Stage"); a
    multi-group stage names the group in the table's th.mod-title.
    """
    standings: list[dict] = []

    for table in html.css("table.wf-table.mod-group"):
        header_cells = table.css("thead th")
        if not header_cells:
            continue
        group = extract_text_content(header_cells[0])
        # The title th spans the logo and team columns
        columns = ["Team"] + [extract_text_content(th) for th in header_cells[1:]]

        rows: list[dict[str, str]] = []
        for tr in table.css("tbody tr"):
            team_link = tr.css_first("a.event-group-team")
            if not team_link:
                continue
            name_elem = team_link.css_first(".event-group-team-name") or team_link
            team_name = extract_text_content(name_elem)
            region_elem = name_elem.css_first(".event-group-team-region")
            if region_elem:
                team_name = team_name.replace(extract_text_content(region_elem), "").strip()

            cells = tr.css("td")[2:]  # skip the logo and team cells
            row_data = {"Team": team_name}
            for label, cell in zip(columns[1:], cells, strict=False):
                row_data[label] = extract_text_content(cell)
            rows.append(row_data)

        standings.append({
            "stage": _preceding_label(table),
            "group": group,
            "columns": columns,
            "rows": rows,
        })

    return standings


@handle_scraper_errors
async def vlr_event_detail(event_id: str, stage: str | None = None) -> dict:
    """Fetch the event overview and an optional stage-specific page.

    Args:
        event_id: Numeric VLR.GG event ID.
        stage: Safe stage slug returned by the event navigation.
    """
    stage = validate_event_stage(stage)

    async def build():
        base_url = (
            f"{VLR_BASE_URL}/event/{event_id}/-/{stage}"
            if stage
            else f"{VLR_BASE_URL}/event/{event_id}"
        )
        client = get_http_client()
        resp = await fetch_with_retries(base_url, client=client)
        status = resp.status_code
        raise_for_upstream_status(status, f"event detail {event_id}")

        html = parse_html(resp.text)

        resources, stages = _parse_event_navigation(html)
        # An unknown stage slug silently serves the default stage
        if stage and not any(s["slug"] == stage and s["active"] for s in stages):
            available = ", ".join(s["slug"] for s in stages) or "none"
            raise HTTPException(
                status_code=404,
                detail=f"Stage '{stage}' not found for event {event_id}. Available stages: {available}",
            )

        header = _parse_event_header(html)
        header.update(
            {
                "event_id": event_id,
                "url": f"{VLR_BASE_URL}/event/{event_id}",
                "calendar": _parse_calendar_links(html),
            }
        )
        prizes = _parse_prizes(html)
        teams = _parse_event_teams(html)
        standings = _parse_standings(html)
        groups = _parse_event_groups(html)
        brackets = _parse_event_brackets(html)
        active_stage = next((item for item in stages if item["active"]), None)
        id_mapper.register_event(header["name"], event_id)

        data = {
            "data": {
                "status": status,
                "segments": {
                    "event": header,
                    "stages": stages,
                    "prizes": prizes,
                    "teams": teams,
                    "standings": standings,
                    "resources": resources,
                    "active_stage": active_stage,
                    "groups": groups,
                    "brackets": brackets,
                },
            }
        }
        return data

    return await cache_manager.get_or_create_async(
        CACHE_TTL_EVENTS, build, "event_detail", event_id, stage or ""
    )
