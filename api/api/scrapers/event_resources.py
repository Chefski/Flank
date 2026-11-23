"""Scrapers for public VLR.GG event subresources.

Covers event-scoped player stats, agent pick rates/compositions, related news,
and Pick'em fixtures. All resources are additive to the existing event overview.
"""

import logging
import re
from dataclasses import asdict, dataclass
from urllib.parse import urlencode

from fastapi import HTTPException

from api.scrapers.stats import (
    _LEGACY_DATA_COLS,
    DEFAULT_STATS_SORT,
    REQUIRED_STATS_KEYS,
    STATS_DIRECTIONS,
    STATS_ROLES,
    STATS_SIDES,
    STATS_SORTS,
    _build_column_map,
    _echoed_filter,
    _parse_stats_row,
)
from utils.cache_manager import cache_manager
from utils.constants import (
    CACHE_TTL_EVENT_AGENTS,
    CACHE_TTL_EVENT_NEWS,
    CACHE_TTL_EVENT_PICKEM,
    CACHE_TTL_EVENT_STATS,
    VLR_BASE_URL,
)
from utils.error_handling import handle_scraper_errors, raise_for_upstream_status
from utils.html_parsers import (
    build_full_url,
    extract_text_content,
    normalize_image_url,
    parse_href_id_slug,
    parse_html,
)
from utils.http_client import fetch_with_retries, get_http_client

logger = logging.getLogger(__name__)

_SAFE_SLUG = re.compile(r"^[a-z0-9-]+$")
_EXCLUDE_SERIES = re.compile(r"^\d+(?:\.\d+)*$")


def _invalid(name: str, value, valid: str) -> None:
    raise HTTPException(
        status_code=400,
        detail=f"Invalid event {name} '{value}'. Valid values: {valid}",
    )


def normalize_excluded_series(value: str | None) -> str:
    """Validate VLR's dot-separated subseries exclusion list."""
    if value is None or value == "":
        return ""
    if not _EXCLUDE_SERIES.fullmatch(value):
        _invalid("exclude", value, "dot-separated numeric subseries IDs")
    return value


@dataclass(frozen=True)
class EventStatsFilters:
    sort: str = DEFAULT_STATS_SORT
    direction: str = "desc"
    side: str = "all"
    role: str = "all"
    agent: str = "all"
    map_id: str = "all"
    min_rounds: int = 0
    exclude: str = ""

    def query(self) -> dict[str, str | int]:
        values = asdict(self)
        values["dir"] = values.pop("direction")
        return values

    def metadata(self) -> dict[str, str | int]:
        return self.query()

    def echoed_query(self) -> dict[str, str | int]:
        """Filters the event stats form echoes back faithfully.

        ``agent`` is excluded because ticking a role pre-ticks every agent of
        that role, and ``exclude`` is a stage-selection list, not a form control.
        """
        values = self.query()
        values.pop("agent")
        values.pop("exclude")
        return values


def normalize_event_stats_filters(
    *,
    sort: str = DEFAULT_STATS_SORT,
    direction: str = "desc",
    side: str = "all",
    role: str = "all",
    agent: str = "all",
    map_id: str = "all",
    min_rounds: int = 0,
    exclude: str | None = None,
) -> EventStatsFilters:
    sort = sort.lower()
    sort = _LEGACY_DATA_COLS.get(sort, sort)
    direction = direction.lower()
    side = side.lower()
    role = role.lower()
    agent = agent.lower()
    map_id = map_id.lower()

    if sort not in STATS_SORTS:
        _invalid("stats sort", sort, ", ".join(sorted(STATS_SORTS)))
    if direction not in STATS_DIRECTIONS:
        _invalid("stats dir", direction, "asc, desc")
    if side not in STATS_SIDES:
        _invalid("stats side", side, ", ".join(sorted(STATS_SIDES)))
    if role not in STATS_ROLES:
        _invalid("stats role", role, ", ".join(sorted(STATS_ROLES)))
    if not _SAFE_SLUG.fullmatch(agent):
        _invalid("stats agent", agent, "all or a lowercase VLR agent slug")
    if map_id != "all" and not map_id.isdigit():
        _invalid("stats map_id", map_id, "all or a numeric VLR map ID")
    if not 0 <= min_rounds <= 999:
        _invalid("stats min_rounds", min_rounds, "an integer from 0 to 999")

    return EventStatsFilters(
        sort=sort,
        direction=direction,
        side=side,
        role=role,
        agent=agent,
        map_id=map_id,
        min_rounds=min_rounds,
        exclude=normalize_excluded_series(exclude),
    )


def _event_filter_mismatches(
    html,
    expected: dict[str, str | int],
) -> dict[str, tuple[str, str]]:
    """Compare requested filters with controls echoed by the event page."""
    mismatches = {}
    for name, requested_value in expected.items():
        applied = _echoed_filter(html, name)
        requested = str(requested_value)
        if applied is None:
            mismatches[name] = (requested, "<missing>")
        elif applied != requested:
            mismatches[name] = (requested, applied)
    return mismatches


def _raise_filter_mismatch(resource: str, mismatches: dict[str, tuple[str, str]]) -> None:
    if not mismatches:
        return
    details = ", ".join(
        f"{name}: requested '{requested}', applied '{applied}'"
        for name, (requested, applied) in sorted(mismatches.items())
    )
    raise HTTPException(
        status_code=502,
        detail=f"VLR.GG event {resource} ignored requested filters: {details}",
    )


def _parse_stage_filters(html) -> list[dict]:
    """Parse series/subseries IDs offered by stats and agents filters."""
    stages: list[dict] = []
    for group in html.css(".st-ss-group"):
        label = extract_text_content(group.css_first(".st-ss-lbl span"))
        series_link = group.css_first("[data-series-id]")
        series_id = series_link.attributes.get("data-series-id", "") if series_link else ""
        subseries = []
        for option in group.css("input.st-ss"):
            parent = option.parent
            subseries.append(
                {
                    "id": option.attributes.get("value", ""),
                    "name": extract_text_content(parent.css_first("span")) if parent else "",
                    "included": "checked" in option.attributes,
                }
            )
        stages.append({"name": label, "series_id": series_id, "subseries": subseries})

    if stages:
        return stages

    # The agents page uses tag divs rather than checkbox inputs.
    seen: set[str] = set()
    for button in html.css(".group-tag-btn[data-series-id]"):
        series_id = button.attributes.get("data-series-id", "")
        if not series_id or series_id in seen:
            continue
        seen.add(series_id)
        outer = button.parent.parent if button.parent and button.parent.parent else button.parent
        subseries = []
        for option in outer.css(".wf-tag-btn[data-subseries-id]") if outer else []:
            subseries.append(
                {
                    "id": option.attributes.get("data-subseries-id", ""),
                    "name": extract_text_content(option),
                    "included": "mod-unselected" not in option.attributes.get("class", ""),
                }
            )
        stages.append(
            {
                "name": extract_text_content(outer.css_first(".wf-label")) if outer else "",
                "series_id": series_id,
                "subseries": subseries,
            }
        )
    return stages


def _without_pseudo_icon(cell) -> str:
    text = extract_text_content(cell)
    icon = cell.css_first(".map-pseudo-icon") if cell else None
    icon_text = extract_text_content(icon)
    return text.removeprefix(icon_text).strip() if icon_text else text


def _parse_agent_pick_rates(html) -> list[dict]:
    table = html.css_first("table.wf-table.mod-pr-global")
    if table is None:
        return []
    header = table.css_first("tr")
    agents = []
    for th in header.css("th")[4:] if header else []:
        image = th.css_first("img")
        src = image.attributes.get("src", "") if image else ""
        agents.append(src.rsplit("/", 1)[-1].split(".", 1)[0] if src else "")

    rows = []
    for row in table.css("tr.pr-global-row"):
        cells = row.css("td")
        if len(cells) < 4:
            continue
        rates = []
        for agent, cell in zip(agents, cells[4:], strict=False):
            if agent:
                rates.append({"agent": agent, "pick_rate": extract_text_content(cell)})
        rows.append(
            {
                "map": _without_pseudo_icon(cells[0]) or "all",
                "maps_played": extract_text_content(cells[1]),
                "attack_win_percentage": extract_text_content(cells[2]),
                "defense_win_percentage": extract_text_content(cells[3]),
                "agents": rates,
            }
        )
    return rows


def _parse_agent_compositions(html) -> list[dict]:
    compositions: list[dict] = []
    for map_container in html.css(".pr-matrix-map"):
        table = map_container.css_first("table")
        header = table.css_first("tr") if table else None
        if table is None or header is None:
            continue
        first_header = header.css_first("th")
        map_name = _without_pseudo_icon(first_header)
        agent_names = []
        for th in header.css("th")[2:]:
            image = th.css_first("img")
            src = image.attributes.get("src", "") if image else ""
            agent_names.append(src.rsplit("/", 1)[-1].split(".", 1)[0] if src else "")

        teams = []
        for row in table.css("tr.pr-matrix-row"):
            if "mod-dropdown" in row.attributes.get("class", ""):
                continue
            cells = row.css("td")
            team_link = cells[0].css_first("a") if cells else None
            if team_link is None:
                continue
            href = team_link.attributes.get("href", "")
            team_id, _ = parse_href_id_slug(href)
            logo = team_link.css_first("img")
            picked = [
                agent
                for agent, cell in zip(agent_names, cells[2:], strict=False)
                if agent and "mod-picked" in cell.attributes.get("class", "")
            ]
            teams.append(
                {
                    "team_id": team_id,
                    "team": extract_text_content(team_link.css_first(".text-of")),
                    "team_url": build_full_url(href),
                    "logo": normalize_image_url(
                        logo.attributes.get("src", "") if logo else ""
                    ),
                    "agents": picked,
                }
            )
        if map_name or teams:
            compositions.append({"map": map_name, "teams": teams})
    return compositions


def _parse_event_news(html) -> list[dict]:
    articles = []
    for item in html.css('a.wf-module-item[href^="/"]'):
        href = item.attributes.get("href", "")
        article_id, _ = parse_href_id_slug(href)
        title = item.attributes.get("title", "") or extract_text_content(item)
        date_node = item.css_first(".ge-text-light")
        date_text = extract_text_content(date_node)
        if not re.fullmatch(r"\d{4}/\d{2}/\d{2}", date_text):
            continue
        if date_text:
            title = title.removesuffix(date_text).strip()
        if article_id and title:
            articles.append(
                {
                    "article_id": article_id,
                    "title": title,
                    "date": date_text,
                    "url": build_full_url(href),
                }
            )
    return articles


def _parse_pickem(html) -> dict:
    sections = []
    for container in html.css(".pickem-subseries-container"):
        matches = []
        for item in container.css(".pi-match-item"):
            input_node = item.css_first('input[name^="subseries-item-id-winner-"]')
            input_name = input_node.attributes.get("name", "") if input_node else ""
            pick_id = input_name.rsplit("-", 1)[-1] if input_name else ""
            team_nodes = item.css(".pi-match-item-team")
            has_result = any("mod-false" in team.attributes.get("class", "") for team in team_nodes)
            teams = []
            for team in team_nodes[:2]:
                classes = team.attributes.get("class", "")
                logo = team.css_first("img")
                teams.append(
                    {
                        "team_id": team.attributes.get("data-team-id", ""),
                        "name": extract_text_content(team.css_first(".pi-match-item-name")),
                        "logo": normalize_image_url(
                            logo.attributes.get("src", "") if logo else ""
                        ),
                        "is_winner": (
                            "mod-false" not in classes if has_result else None
                        ),
                        "is_selected": "mod-selected" in classes,
                    }
                )
            while len(teams) < 2:
                teams.append(
                    {
                        "team_id": "",
                        "name": "TBD",
                        "logo": "",
                        "is_winner": None,
                        "is_selected": False,
                    }
                )
            matches.append({"pick_id": pick_id, "team1": teams[0], "team2": teams[1]})
        sections.append(
            {
                "name": extract_text_content(container.css_first(".wf-label.mod-large")),
                "locked": "picks are locked" in extract_text_content(container).lower(),
                "matches": matches,
            }
        )

    leaderboard = []
    sidebar = html.css_first(".event-sidebar.mod-leaderboard")
    leaderboard_url = ""
    if sidebar:
        leaderboard_link = sidebar.css_first('a[href*="/event/leaderboard/"]')
        leaderboard_url = build_full_url(
            leaderboard_link.attributes.get("href", "") if leaderboard_link else ""
        )
        for card in sidebar.css(".wf-card"):
            text = extract_text_content(card)
            points_match = re.search(r"(\d+)\s+points?", text, re.IGNORECASE)
            distribution = extract_text_content(card.css_first(".ge-text-light"))
            if points_match:
                leaderboard.append(
                    {"points": points_match.group(1), "distribution": distribution}
                )

    group_link = html.css_first('a[href*="/event/pickemgroup/"]')
    return {
        "sections": sections,
        "leaderboard_distribution": leaderboard,
        "leaderboard_url": leaderboard_url,
        "group_url": build_full_url(
            group_link.attributes.get("href", "") if group_link else ""
        ),
    }


async def _fetch_event_resource(path: str, context: str):
    client = get_http_client()
    response = await fetch_with_retries(path, client=client)
    raise_for_upstream_status(response.status_code, context)
    return response.status_code, parse_html(response.text)


@handle_scraper_errors
async def vlr_event_stats(event_id: str, **filter_values) -> dict:
    filters = normalize_event_stats_filters(**filter_values)

    async def build():
        url = f"{VLR_BASE_URL}/event/stats/{event_id}/?{urlencode(filters.query())}"
        status, html = await _fetch_event_resource(url, f"event stats {event_id}")
        _raise_filter_mismatch(
            "stats",
            _event_filter_mismatches(html, filters.echoed_query()),
        )
        col_map = _build_column_map(html)
        if col_map is not None:
            missing = REQUIRED_STATS_KEYS - col_map.keys()
            if missing:
                raise HTTPException(
                    status_code=502,
                    detail=f"VLR.GG event stats columns changed: missing {sorted(missing)}",
                )
        players = []
        for row in html.css("tbody tr"):
            parsed = _parse_stats_row(row, col_map)
            if parsed["player"]:
                players.append(parsed)
        return {
            "data": {
                "status": status,
                "event_id": event_id,
                "filters": filters.metadata(),
                "stages": _parse_stage_filters(html),
                "segments": players,
            }
        }

    return await cache_manager.get_or_create_async(
        CACHE_TTL_EVENT_STATS,
        build,
        "event_stats",
        event_id,
        filters.query(),
    )


@handle_scraper_errors
async def vlr_event_agents(event_id: str, exclude: str | None = None) -> dict:
    exclude = normalize_excluded_series(exclude)

    async def build():
        url = f"{VLR_BASE_URL}/event/agents/{event_id}/?{urlencode({'exclude': exclude})}"
        status, html = await _fetch_event_resource(url, f"event agents {event_id}")
        _raise_filter_mismatch(
            "agents",
            _event_filter_mismatches(html, {"exclude": exclude}),
        )
        return {
            "data": {
                "status": status,
                "event_id": event_id,
                "filters": {"exclude": exclude},
                "stages": _parse_stage_filters(html),
                "pick_rates": _parse_agent_pick_rates(html),
                "compositions": _parse_agent_compositions(html),
            }
        }

    return await cache_manager.get_or_create_async(
        CACHE_TTL_EVENT_AGENTS,
        build,
        "event_agents",
        event_id,
        exclude,
    )


@handle_scraper_errors
async def vlr_event_news(event_id: str) -> dict:
    async def build():
        url = f"{VLR_BASE_URL}/event/news/{event_id}/"
        status, html = await _fetch_event_resource(url, f"event news {event_id}")
        return {
            "data": {
                "status": status,
                "event_id": event_id,
                "segments": _parse_event_news(html),
            }
        }

    return await cache_manager.get_or_create_async(
        CACHE_TTL_EVENT_NEWS,
        build,
        "event_news",
        event_id,
    )


@handle_scraper_errors
async def vlr_event_pickem(event_id: str) -> dict:
    async def build():
        url = f"{VLR_BASE_URL}/event/pickem/{event_id}/"
        status, html = await _fetch_event_resource(url, f"event pickem {event_id}")
        return {
            "data": {
                "status": status,
                "event_id": event_id,
                **_parse_pickem(html),
            }
        }

    return await cache_manager.get_or_create_async(
        CACHE_TTL_EVENT_PICKEM,
        build,
        "event_pickem",
        event_id,
    )
