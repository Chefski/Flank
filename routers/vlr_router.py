"""
Original unversioned API router — preserved for backwards compatibility.
"""
from fastapi import APIRouter, HTTPException, Query

from routers.shared_handlers import (
    get_event_agents_data,
    get_event_detail_data,
    get_event_matches_data,
    get_event_news_data,
    get_event_pickem_data,
    get_event_stats_data,
    get_events_data,
    get_health_data,
    get_match_data,
    get_match_detail_data,
    get_match_logs_data,
    get_news_article_data,
    get_news_data,
    get_player_data,
    get_player_matches_data,
    get_rankings_data,
    get_stats_data,
    get_team_data,
    get_team_matches_data,
    get_team_roster_data,
    get_team_schedule_data,
    get_team_transactions_data,
    to_legacy_rankings_shape,
)
from utils.constants import MAX_MATCH_QUERY_BOUND, MAX_NEWS_PAGE
from utils.error_handling import (
    validate_id_param,
    validate_match_workload,
    validate_player_timespan,
)

router = APIRouter(tags=["Default"])


def _strip_match_team_ids(payload: dict) -> dict:
    """Preserve the historical /match/details team shape for legacy clients."""
    data = payload.get("data")
    if not isinstance(data, dict):
        return payload

    segments = data.get("segments")
    if not isinstance(segments, list):
        return payload

    for segment in segments:
        if not isinstance(segment, dict):
            continue
        teams = segment.get("teams")
        if not isinstance(teams, list):
            continue
        for team in teams:
            if isinstance(team, dict):
                team.pop("id", None)

    return payload


@router.get("/news")
async def VLR_news(
    page: int = Query(1, description="Archive page number", ge=1, le=MAX_NEWS_PAGE),
):
    return await get_news_data(page)


@router.get("/news/{article_id}")
async def VLR_news_article(article_id: str):
    validate_id_param(article_id, "article_id")
    result = await get_news_article_data(article_id)
    data = result.get("data")
    status_code = data.get("status") if isinstance(data, dict) else None
    if isinstance(status_code, int) and status_code >= 400:
        raise HTTPException(
            status_code=status_code,
            detail=data.get("error", "Upstream request failed"),
        )
    return result


@router.get("/stats")
async def VLR_stats(
    region: str = Query(..., description="Region: all, americas, emea, pacific, china, intl (deprecated aliases accepted)"),
    timespan: str | None = Query(None, description="Legacy window: 30, 60, 90, or all. Either timespan or span is required."),
    span: str | None = Query(None, description="VLR span: 30d, 60d, 90d, custom, a year from 2020 onward, or all"),
    from_date: str | None = Query(None, alias="from", description="Custom span start date (YYYY-MM-DD)"),
    to_date: str | None = Query(None, alias="to", description="Custom span end date (YYYY-MM-DD)"),
    event_id: str | None = Query(None, description="Optional numeric event ID to filter stats by event"),
    map_name: str = Query("all", alias="map", description="Map name filter (alternative to map_id)"),
    tier: str = Query("all", description="Tier: all, vct, vcl, t3, gc, cg, or off"),
    side: str = Query("all", description="Side: all, t, or ct"),
    role: str = Query("all", description="Role filter"),
    agent: str = Query("all", description="Agent slug or all"),
    map_id: str = Query("all", description="VLR map ID or all"),
    min_rounds: int = Query(200, description="Minimum rounds (historical API default: 200)"),
    min_rating: float = Query(1550, description="Minimum rating threshold (historical API default: 1550; 0-2 scale accepted)"),
    sort: str = Query("rating", description="VLR data-col to sort by"),
    sort_dir: str = Query("desc", alias="dir", description="Sort direction: asc or desc"),
):
    """
    Get VLR stats with query parameters.

    regions (the /stats page taxonomy — differs from /rankings):\n
        all | americas | emea | pacific | china | intl\n
    deprecated aliases (normalized):\n
        na, br -> americas\n
        eu -> emea\n
        ap, kr, jp, oce -> pacific\n
        cn -> china\n
    """
    return await get_stats_data(
        region,
        timespan,
        event_id,
        map_name,
        min_rounds,
        min_rating,
        span=span,
        from_date=from_date,
        to_date=to_date,
        tier=tier,
        side=side,
        role=role,
        agent=agent,
        map_id=map_id,
        sort=sort,
        direction=sort_dir,
    )


@router.get("/rankings")
async def VLR_ranks(
    region: str = Query(..., description="Region shortname"),
):
    """
    Get VLR rankings for a specific region.

    region shortnames:\n
        "na": "north-america",\n
        "eu": "europe",\n
        "ap": "asia-pacific",\n
        "la": "latin-america",\n
        "la-s": "la-s",\n
        "la-n": "la-n",\n
        "oce": "oceania",\n
        "kr": "korea",\n
        "mn": "mena",\n
        "gc": "gc",\n
        "br": "Brazil",\n
        "cn": "china",\n
        "jp": "japan",\n
        "col": "collegiate",\n
    """
    return to_legacy_rankings_shape(await get_rankings_data(region))


@router.get("/match")
async def VLR_match(
    q: str,
    num_pages: int = Query(1, description="Number of pages to scrape (default: 1)", ge=1, le=MAX_MATCH_QUERY_BOUND),
    from_page: int = Query(None, description="Starting page number (1-based, optional)", ge=1, le=MAX_MATCH_QUERY_BOUND),
    to_page: int = Query(None, description="Ending page number (1-based, inclusive, optional)", ge=1, le=MAX_MATCH_QUERY_BOUND),
    max_retries: int = Query(3, description="Maximum retry attempts per page (default: 3)", ge=1, le=5),
    request_delay: float = Query(1.0, description="Delay between requests in seconds (default: 1.0)", ge=0.5, le=5.0),
    timeout: int = Query(30, description="Request timeout in seconds (default: 30)", ge=10, le=120)
):
    """
    query parameters:\n
        "upcoming": upcoming matches (from homepage),\n
        "upcoming_extended": upcoming matches (from paginated /matches page),\n
        "live_score": live match scores,\n
        "results": match results,\n

    Page Range Options:
    - num_pages: Number of pages from page 1 (ignored if from_page/to_page specified)
    - from_page: Starting page number (1-based, optional)
    - to_page: Ending page number (1-based, inclusive, optional)
    """
    if q not in {"upcoming", "upcoming_extended", "live_score", "results"}:
        return {"error": "Invalid query parameter"}

    if q in {"upcoming_extended", "results"}:
        validate_match_workload(num_pages, from_page, to_page, max_retries, timeout)

    return await get_match_data(
        q, num_pages, from_page, to_page, max_retries, request_delay, timeout
    )


@router.get("/events")
async def VLR_events(
    q: str = Query(
        None,
        description="Event type filter",
        examples=["completed"],
        json_schema_extra={"enum": ["upcoming", "completed", "live"]}
    ),
    page: int = Query(
        1,
        description="Page number for pagination (only applies to completed events)",
        examples=[1],
        ge=1,
        le=100
    )
):
    """
    Get Valorant events from VLR.GG with optional filtering and pagination.
    """
    return await get_events_data(q, page)


@router.get("/match/details")
async def VLR_match_detail(
    match_id: str = Query(..., description="VLR.GG match ID"),
):
    """Get detailed match data including per-map stats, rounds, and head-to-head."""
    validate_id_param(match_id, "match_id")
    return _strip_match_team_ids(await get_match_detail_data(match_id))


@router.get("/match/logs")
async def VLR_match_logs(
    match_id: str = Query(..., description="VLR.GG match ID"),
    game_id: str = Query(None, description="Optional game (map) ID; defaults to the first played map"),
):
    """Get the per-round 2D replay of one map — results, buys, kills and positions."""
    validate_id_param(match_id, "match_id")
    if game_id is not None:
        validate_id_param(game_id, "game_id")
    return await get_match_logs_data(match_id, game_id)


@router.get("/player")
async def VLR_player(
    id: str = Query(..., description="VLR.GG player ID"),
    timespan: str = Query("90d", description="Stats timespan: 30d, 60d, 90d, or all"),
):
    """Get player profile with agent stats, event placements, and team history."""
    validate_id_param(id)
    validate_player_timespan(timespan)
    return await get_player_data(id, timespan)


@router.get("/player/matches")
async def VLR_player_matches(
    id: str = Query(..., description="VLR.GG player ID"),
    page: int = Query(1, description="Page number", ge=1, le=100),
):
    """Get paginated match history for a player."""
    validate_id_param(id)
    return await get_player_matches_data(id, page)


@router.get("/team")
async def VLR_team(
    id: str = Query(..., description="VLR.GG team ID"),
):
    """Get team profile with roster, rating, and event placements."""
    validate_id_param(id)
    return await get_team_data(id)


@router.get("/team/matches")
async def VLR_team_matches(
    id: str = Query(..., description="VLR.GG team ID"),
    page: int = Query(1, description="Page number", ge=1, le=100),
):
    """Get paginated match history for a team."""
    validate_id_param(id)
    return await get_team_matches_data(id, page)


@router.get("/team/transactions")
async def VLR_team_transactions(
    id: str = Query(..., description="VLR.GG team ID"),
):
    """Get roster transaction history for a team."""
    validate_id_param(id)
    return await get_team_transactions_data(id)


@router.get("/team/roster")
async def VLR_team_roster(
    id: str = Query(..., description="VLR.GG team ID"),
):
    """Get grouped roster with active, staff, former, and benched players."""
    validate_id_param(id)
    return await get_team_roster_data(id)


@router.get("/team/schedule")
async def VLR_team_schedule(
    id: str = Query(..., description="VLR.GG team ID"),
):
    """Get upcoming match schedule for a team."""
    validate_id_param(id)
    return await get_team_schedule_data(id)


@router.get("/events/matches")
async def VLR_event_matches(
    event_id: str = Query(..., description="VLR.GG event ID"),
):
    """Get match list for a specific event."""
    validate_id_param(event_id, "event_id")
    return await get_event_matches_data(event_id)


@router.get("/event/{event_id}")
async def VLR_event_detail(
    event_id: str,
    stage: str | None = Query(None, description="Event stage slug"),
):
    """Get event overview, stage tabs, groups, brackets, teams, and prizes."""
    validate_id_param(event_id, "event_id")
    return await get_event_detail_data(event_id, stage)


@router.get("/event/{event_id}/stats")
async def VLR_event_stats(
    event_id: str,
    sort: str = Query("rating"),
    sort_dir: str = Query("desc", alias="dir"),
    side: str = Query("all"),
    role: str = Query("all"),
    agent: str = Query("all"),
    map_id: str = Query("all"),
    min_rounds: int = Query(0),
    exclude_series: str | None = Query(None, alias="exclude"),
):
    validate_id_param(event_id, "event_id")
    return await get_event_stats_data(
        event_id,
        sort=sort,
        direction=sort_dir,
        side=side,
        role=role,
        agent=agent,
        map_id=map_id,
        min_rounds=min_rounds,
        exclude=exclude_series,
    )


@router.get("/event/{event_id}/agents")
async def VLR_event_agents(
    event_id: str,
    exclude_series: str | None = Query(None, alias="exclude"),
):
    validate_id_param(event_id, "event_id")
    return await get_event_agents_data(event_id, exclude_series)


@router.get("/event/{event_id}/news")
async def VLR_event_news(event_id: str):
    validate_id_param(event_id, "event_id")
    return await get_event_news_data(event_id)


@router.get("/event/{event_id}/pickem")
async def VLR_event_pickem(event_id: str):
    validate_id_param(event_id, "event_id")
    return await get_event_pickem_data(event_id)


@router.get("/health")
async def health():
    return await get_health_data()
