"""
Main match detail scraper orchestrator.

Fetches the base match page, extracts game IDs, and concurrently
fetches performance and economy tabs for enriched per-map data.
"""
import asyncio
import copy
import logging

from utils.cache_headers import cap_edge_ttl
from utils.cache_manager import cache_manager
from utils.constants import (
    CACHE_TTL_MATCH_DETAIL,
    CACHE_TTL_MATCH_DETAIL_FINAL,
    CACHE_TTL_MATCH_DETAIL_LIVE,
    MATCH_DETAIL_TAB_FETCH_CONCURRENCY,
    MATCH_DETAIL_TAB_FETCH_TIMEOUT,
    VLR_BASE_URL,
)
from utils.error_handling import handle_scraper_errors, upstream_error_payload
from utils.html_parsers import HTMLParser, add_image_variants, parse_html
from utils.http_client import fetch_theme_variants, fetch_with_retries, get_http_client
from utils.team_logos import team_logo_store

from .parsers import (
    _is_live,
    _parse_advanced_stats,
    _parse_economy,
    _parse_event_info,
    _parse_head_to_head,
    _parse_kill_matrix,
    _parse_maps,
    _parse_match_header,
    _parse_streams_vods,
    _parse_teams,
)

logger = logging.getLogger(__name__)

# Every TTL a match detail may be cached under, checked shortest first.
_MATCH_DETAIL_TTLS = (
    CACHE_TTL_MATCH_DETAIL_LIVE,
    CACHE_TTL_MATCH_DETAIL,
    CACHE_TTL_MATCH_DETAIL_FINAL,
)


# Parsed performance/economy tabs of a map that has finished never change, so
# a live match only re-fetches the tabs of the map still being played.
CACHE_TTL_FINISHED_MAP_TAB = CACHE_TTL_MATCH_DETAIL_FINAL


def _tab_cache_key(match_id: str, game_id: str, tab: str) -> tuple:
    return ("match_detail_tab", match_id, game_id, tab)


def _parse_tab(tab: str, tab_html: HTMLParser):
    if tab == "performance":
        return {
            "kill_matrix": _parse_kill_matrix(tab_html),
            "advanced_stats": _parse_advanced_stats(tab_html),
        }
    return _parse_economy(tab_html)


def _tab_has_data(tab: str, parsed) -> bool:
    if tab == "performance":
        return bool(parsed["kill_matrix"] or parsed["advanced_stats"])
    return bool(parsed)


def _extract_game_ids(html: HTMLParser) -> list[str]:
    """Return playable data-game-id values from the stats nav."""
    game_ids: list[str] = []
    for item in html.css(".vm-stats-gamesnav-item"):
        gid = item.attributes.get("data-game-id", "")
        if (
            gid
            and gid != "all"
            and item.attributes.get("data-disabled", "0") != "1"
        ):
            game_ids.append(gid)
    return game_ids


def _player_lookup(map_data: dict) -> dict[str, dict]:
    players = [
        player
        for side in ("team1", "team2")
        for player in map_data.get("players", {}).get(side, [])
    ]
    return {
        player.get("name", "").casefold(): player
        for player in players
        if player.get("name")
    }


def _enrich_performance_identities(performance: dict, map_data: dict) -> None:
    lookup = _player_lookup(map_data)
    for row in performance.get("kill_matrix", []):
        player = lookup.get(row.get("player", "").casefold(), {})
        row["player_id"] = player.get("player_id", "")
        row["player_url"] = player.get("player_url", "")
        for matchup in row.get("matchups", []):
            opponent = lookup.get(matchup.get("opponent", "").casefold(), {})
            matchup["opponent_id"] = opponent.get("player_id", "")
            matchup["opponent_url"] = opponent.get("player_url", "")

    for row in performance.get("advanced_stats", []):
        player = lookup.get(row.get("player", "").casefold(), {})
        row["player_id"] = player.get("player_id", "")
        row["player_url"] = player.get("player_url", "")


def _enrich_economy_identities(
    rows: list[dict],
    teams: list[dict],
    map_data: dict,
) -> None:
    lookup = {
        value.casefold(): team
        for team in teams
        for value in (team.get("name", ""), team.get("tag", ""))
        if value
    }
    for index, side in enumerate(("team1", "team2")):
        players = map_data.get("players", {}).get(side, [])
        if index < len(teams) and players:
            team_tag = players[0].get("team_tag", "")
            if team_tag:
                lookup[team_tag.casefold()] = teams[index]
    for row in rows:
        team = lookup.get(row.get("Team", "").casefold(), {})
        row["team_id"] = team.get("id", "")


async def _fetch_game_tab_html(
    client,
    base_url: str,
    game_id: str,
    tab: str,
    timeout: int = MATCH_DETAIL_TAB_FETCH_TIMEOUT,
) -> tuple[str, str, "HTMLParser | None"]:
    """Fetch one game-tab page and return parsed HTML when available."""
    url = f"{base_url}/?game={game_id}&tab={tab}"
    try:
        resp = await fetch_with_retries(url, client=client, timeout=timeout)
        if resp.status_code >= 400:
            logger.warning(
                "Failed to fetch %s tab for game %s: upstream status %d",
                tab, game_id, resp.status_code,
            )
            return game_id, tab, None
        return game_id, tab, parse_html(resp.text)
    except Exception as exc:
        logger.warning("Failed to fetch %s tab for game %s: %s", tab, game_id, exc)
        return game_id, tab, None


@handle_scraper_errors
async def vlr_match_detail(match_id: str, light: bool = False) -> dict:
    """
    Scrape a single VLR.GG match page and return structured match data.

    Fetches the base page, then concurrently fetches the performance and
    economy tabs for every started game; tabs of maps that have finished are
    reused from a per-map cache. Cache TTL is 30 s for live matches, 1 h for
    final ones and 300 s otherwise. A payload missing any tab (fetch failed,
    host cooling down) is cached for 30 s at most, at the edge too, and never
    replaces a complete last-good payload. With ``light`` the per-map tabs are
    skipped (upcoming matches have no stats yet), leaving header, teams, maps
    and head-to-head at roughly one request instead of one per game per tab.
    """
    base_url = f"{VLR_BASE_URL}/{match_id}"
    cache_key = ("match_detail", match_id, bool(light))

    def cached_detail():
        for ttl in _MATCH_DETAIL_TTLS:
            cached = cache_manager.get(ttl, *cache_key)
            if cached is not None:
                return cached
        return None

    def respond(result):
        # The edge never keeps a payload longer than this process does (a
        # partial final match sits in the 30 s cache, not the 1 h one).
        ttl = cache_manager.cached_ttl(result, _MATCH_DETAIL_TTLS, *cache_key)
        if ttl is not None and ttl < CACHE_TTL_MATCH_DETAIL_FINAL:
            cap_edge_ttl(ttl)
        return result

    cached = cached_detail()
    if cached is not None:
        return respond(cached)

    async def build():
        cached = cached_detail()
        if cached is not None:
            return cached

        client = get_http_client()

        light_resp, dark_resp = await fetch_theme_variants(base_url, client=client)
        http_status = light_resp.status_code
        if http_status >= 400:
            return upstream_error_payload(http_status, f"match detail {match_id}")

        base_html = parse_html(light_resp.text)
        dark_html = parse_html(dark_resp.text)

        event_info = _parse_event_info(base_html)
        add_image_variants(event_info, _parse_event_info(dark_html))
        header_info = _parse_match_header(base_html)
        teams = _parse_teams(base_html)
        dark_teams = _parse_teams(dark_html)
        dark_teams_by_id = {team["id"]: team for team in dark_teams if team["id"]}
        for index, team in enumerate(teams):
            dark_team = dark_teams_by_id.get(team["id"])
            if dark_team is None and index < len(dark_teams):
                dark_team = dark_teams[index]
            add_image_variants(team, dark_team)
        team_logo_store.record_match(match_id, teams)
        streams, vods = _parse_streams_vods(base_html)
        maps = _parse_maps(base_html, teams)
        h2h = _parse_head_to_head(base_html, teams)

        all_game_ids = _extract_game_ids(base_html)
        map_statuses = {game["game_id"]: game["status"] for game in maps}
        game_ids = [
            game_id
            for game_id in all_game_ids
            if map_statuses.get(game_id, "in_progress") != "scheduled"
        ]
        first_game_id = game_ids[0] if game_ids else None

        performance_by_game: dict[str, dict] = {}
        economy_by_game: dict[str, list[dict]] = {}
        failed_tabs: list[tuple[str, str]] = []

        if game_ids and not light:
            tab_fetch_semaphore = asyncio.Semaphore(MATCH_DETAIL_TAB_FETCH_CONCURRENCY)

            async def fetch_tab(game_id: str, tab: str):
                async with tab_fetch_semaphore:
                    return await _fetch_game_tab_html(
                        client,
                        base_url,
                        game_id,
                        tab,
                        timeout=MATCH_DETAIL_TAB_FETCH_TIMEOUT,
                    )

            parsed_tabs: dict[tuple[str, str], object] = {}
            to_fetch: list[tuple[str, str]] = []
            for game_id in game_ids:
                for tab in ("performance", "economy"):
                    reused = None
                    if map_statuses.get(game_id) == "completed":
                        reused = cache_manager.get(
                            CACHE_TTL_FINISHED_MAP_TAB, *_tab_cache_key(match_id, game_id, tab)
                        )
                    if reused is not None:
                        # Enrichment below mutates rows; keep the cached copy clean.
                        parsed_tabs[(game_id, tab)] = copy.deepcopy(reused)
                    else:
                        to_fetch.append((game_id, tab))

            tab_results = await asyncio.gather(
                *[fetch_tab(game_id, tab) for game_id, tab in to_fetch]
            )

            for game_id, tab, tab_html in tab_results:
                if tab_html is None:
                    failed_tabs.append((game_id, tab))
                    continue
                parsed = _parse_tab(tab, tab_html)
                parsed_tabs[(game_id, tab)] = parsed
                if map_statuses.get(game_id) == "completed" and _tab_has_data(tab, parsed):
                    cache_manager.set(
                        CACHE_TTL_FINISHED_MAP_TAB,
                        copy.deepcopy(parsed),
                        *_tab_cache_key(match_id, game_id, tab),
                    )

            for (game_id, tab), parsed in parsed_tabs.items():
                if tab == "performance":
                    performance_by_game[game_id] = parsed
                else:
                    economy_by_game[game_id] = parsed

        for map_data in maps:
            game_id = map_data["game_id"]
            map_data["game_url"] = (
                f"{base_url}/?game={game_id}&tab=overview" if game_id else ""
            )
            performance = performance_by_game.get(
                game_id, {"kill_matrix": [], "advanced_stats": []}
            )
            economy = economy_by_game.get(game_id, [])
            _enrich_performance_identities(performance, map_data)
            _enrich_economy_identities(economy, teams, map_data)
            map_data["performance"] = performance
            map_data["economy"] = economy

        first_game_performance = performance_by_game.get(
            first_game_id or "", {"kill_matrix": [], "advanced_stats": []}
        )
        first_game_economy = economy_by_game.get(first_game_id or "", [])

        stats = base_html.css_first(".vm-stats")
        segment = {
            "match_id": match_id,
            "url": base_url,
            "stats_match_id": stats.attributes.get("data-match-id", "") if stats else "",
            "event": event_info,
            "date": header_info["date"],
            "utc_timestamp": header_info["utc_timestamp"],
            "scheduled_at": header_info["scheduled_at"],
            "patch": header_info["patch"],
            "map_vetos": header_info["map_vetos"],
            "notes": header_info["notes"],
            "status": header_info["status"],
            "format": header_info["format"],
            "teams": teams,
            "streams": streams,
            "vods": vods,
            "maps": maps,
            "head_to_head": h2h,
            "performance": {
                "kill_matrix": first_game_performance["kill_matrix"],
                "advanced_stats": first_game_performance["advanced_stats"],
                "by_map": [
                    {
                        "game_id": game_id,
                        **performance_by_game.get(
                            game_id,
                            {"kill_matrix": [], "advanced_stats": []},
                        ),
                    }
                    for game_id in all_game_ids
                ],
            },
            "economy": first_game_economy,
            "economy_by_map": [
                {"game_id": game_id, "rows": economy_by_game.get(game_id, [])}
                for game_id in all_game_ids
            ],
        }

        data = {"data": {"status": http_status, "segments": [segment]}}

        if _is_live(base_html):
            ttl = CACHE_TTL_MATCH_DETAIL_LIVE
        elif str(header_info["status"]).strip().lower() == "final":
            ttl = CACHE_TTL_MATCH_DETAIL_FINAL
        else:
            ttl = CACHE_TTL_MATCH_DETAIL
        if failed_tabs:
            logger.warning(
                "Match detail %s is missing %d tab(s); caching it briefly",
                match_id, len(failed_tabs),
            )
            cache_manager.set_partial_if_cacheable(
                min(ttl, CACHE_TTL_MATCH_DETAIL_LIVE), data, *cache_key
            )
        else:
            cache_manager.set_if_cacheable(ttl, data, *cache_key)

        return data

    result = await cache_manager.with_stale_fallback(
        lambda: cache_manager.coalesce_async(f"match_detail:{match_id}:{bool(light)}", build),
        *cache_key,
    )
    return respond(result)
