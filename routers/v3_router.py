"""Stable, fully typed V3 API routes."""

from fastapi import APIRouter, HTTPException, Query, Request

from api.team_logo_enrichment import enrich_match_list_logos
from api.v3_adapters import (
    adapt_event_detail,
    adapt_event_list,
    adapt_match_detail,
    adapt_match_list,
    adapt_news_archive,
    adapt_news_article,
    adapt_stats,
)
from models import (
    V3EntityMeta,
    V3EventDetail,
    V3EventSummary,
    V3Match,
    V3MatchDetail,
    V3MatchListMeta,
    V3Meta,
    V3NewsArticle,
    V3NewsSummary,
    V3PageMeta,
    V3Response,
    V3StatsData,
)
from routers.shared_handlers import (
    get_event_detail_data,
    get_event_matches_data,
    get_event_stats_data,
    get_events_data,
    get_match_data,
    get_match_detail_data,
    get_news_article_data,
    get_news_data,
    get_stats_data,
)
from utils.cache_headers import EDGE_TTL_CAP_STATE
from utils.constants import CACHE_TTL_PARTIAL_LOGOS, MAX_MATCH_QUERY_BOUND, MAX_NEWS_PAGE
from utils.error_handling import (
    validate_event_query,
    validate_id_param,
    validate_match_query,
    validate_match_workload,
)

router = APIRouter(prefix="/v3", tags=["v3"])


def _unwrap(scraper_result: dict) -> dict:
    data = scraper_result.get("data")
    if not isinstance(data, dict):
        raise HTTPException(status_code=502, detail="Malformed scraper response")
    status_code = data.get("status")
    if isinstance(status_code, int) and status_code >= 400:
        raise HTTPException(
            status_code=status_code,
            detail=data.get("error", "Upstream request failed"),
        )
    return data


async def _with_team_logos(request: Request, payload: dict) -> dict:
    """Fill list logos from the logo index; shorten the edge TTL while gaps remain."""
    payload, complete = await enrich_match_list_logos(payload)
    if not complete:
        setattr(request.state, EDGE_TTL_CAP_STATE, CACHE_TTL_PARTIAL_LOGOS)
    return payload


def _first_segment(payload: dict, resource: str) -> dict:
    segments = payload.get("segments")
    if not isinstance(segments, list) or not segments or not isinstance(segments[0], dict):
        raise HTTPException(status_code=404, detail=f"{resource} not found")
    return segments[0]


@router.get(
    "/news",
    response_model=V3Response[list[V3NewsSummary], V3PageMeta],
    summary="Typed news archive",
)
async def v3_news(
    page: int = Query(1, description="Archive page number", ge=1, le=MAX_NEWS_PAGE),
):
    articles, meta = adapt_news_archive(_unwrap(await get_news_data(page)))
    return V3Response[list[V3NewsSummary], V3PageMeta](data=articles, meta=meta)


@router.get(
    "/news/{article_id}",
    response_model=V3Response[V3NewsArticle, V3EntityMeta],
    summary="Typed news article",
)
async def v3_news_article(article_id: str):
    validate_id_param(article_id, "article_id")
    numeric_id = int(article_id)
    payload = _unwrap(await get_news_article_data(article_id))
    article = adapt_news_article(_first_segment(payload, "News article"))
    return V3Response[V3NewsArticle, V3EntityMeta](
        data=article,
        meta=V3EntityMeta(id=numeric_id),
    )


@router.get(
    "/stats",
    response_model=V3Response[V3StatsData, V3Meta],
    summary="Typed player statistics",
)
async def v3_stats(
    region: str = Query(..., description="all, americas, emea, pacific, china, or intl"),
    timespan: str | None = Query(None, description="Legacy 30, 60, 90, or all window"),
    span: str | None = Query(None, description="30d, 60d, 90d, custom, year, or all"),
    from_date: str | None = Query(None, alias="from"),
    to_date: str | None = Query(None, alias="to"),
    tier: str = Query("all"),
    side: str = Query("all"),
    role: str = Query("all"),
    agent: str = Query("all"),
    map_id: str = Query("all"),
    min_rounds: int = Query(200, ge=0),
    min_rating: int = Query(1550, ge=0),
    event_id: str | None = Query(None, description="Optional numeric event ID"),
    sort: str = Query("rating"),
    sort_dir: str = Query("desc", alias="dir"),
):
    result = await get_stats_data(
        region,
        timespan,
        event_id,
        span=span,
        from_date=from_date,
        to_date=to_date,
        tier=tier,
        side=side,
        role=role,
        agent=agent,
        map_id=map_id,
        min_rounds=min_rounds,
        min_rating=min_rating,
        sort=sort,
        direction=sort_dir,
    )
    return V3Response[V3StatsData, V3Meta](
        data=adapt_stats(_unwrap(result)),
        meta=V3Meta(),
    )


@router.get(
    "/matches",
    response_model=V3Response[list[V3Match], V3MatchListMeta],
    summary="Typed match list",
)
async def v3_matches(
    request: Request,
    q: str = Query(..., description="upcoming, upcoming_extended, live_score, or results"),
    num_pages: int = Query(1, ge=1, le=MAX_MATCH_QUERY_BOUND),
    from_page: int | None = Query(None, ge=1, le=MAX_MATCH_QUERY_BOUND),
    to_page: int | None = Query(None, ge=1, le=MAX_MATCH_QUERY_BOUND),
    max_retries: int = Query(3, ge=1, le=5),
    request_delay: float = Query(1.0, ge=0.5, le=5.0),
    timeout: int = Query(30, ge=10, le=120),
):
    validate_match_query(q)
    if q in {"upcoming_extended", "results"}:
        validate_match_workload(num_pages, from_page, to_page, max_retries, timeout)
    result = await get_match_data(
        q,
        num_pages,
        from_page,
        to_page,
        max_retries,
        request_delay,
        timeout,
    )
    payload = await _with_team_logos(request, _unwrap(result))
    matches, meta = adapt_match_list(payload, query=q)
    return V3Response[list[V3Match], V3MatchListMeta](data=matches, meta=meta)


@router.get(
    "/matches/{match_id}",
    response_model=V3Response[V3MatchDetail, V3EntityMeta],
    summary="Typed match detail",
)
async def v3_match_detail(match_id: str):
    validate_id_param(match_id, "match_id")
    numeric_id = int(match_id)
    payload = _unwrap(await get_match_detail_data(match_id))
    detail = adapt_match_detail(_first_segment(payload, "Match"))
    return V3Response[V3MatchDetail, V3EntityMeta](
        data=detail,
        meta=V3EntityMeta(id=numeric_id),
    )


@router.get(
    "/events",
    response_model=V3Response[list[V3EventSummary], V3PageMeta],
    summary="Typed event browser",
)
async def v3_events(
    q: str | None = Query(None, description="upcoming, completed, or live"),
    page: int = Query(1, ge=1, le=100),
):
    validate_event_query(q)
    events, meta = adapt_event_list(_unwrap(await get_events_data(q, page)), page)
    return V3Response[list[V3EventSummary], V3PageMeta](data=events, meta=meta)


@router.get(
    "/events/{event_id}/matches",
    response_model=V3Response[list[V3Match], V3MatchListMeta],
    summary="Typed event matches",
)
async def v3_event_matches(request: Request, event_id: str):
    validate_id_param(event_id, "event_id")
    numeric_id = int(event_id)
    matches, meta = adapt_match_list(
        await _with_team_logos(request, _unwrap(await get_event_matches_data(event_id))),
        query="event",
        event_id=numeric_id,
    )
    return V3Response[list[V3Match], V3MatchListMeta](data=matches, meta=meta)


@router.get(
    "/events/{event_id}/stats",
    response_model=V3Response[V3StatsData, V3EntityMeta],
    summary="Typed event player statistics",
)
async def v3_event_stats(
    event_id: str,
    sort: str = Query("rating"),
    sort_dir: str = Query("desc", alias="dir"),
    side: str = Query("all"),
    role: str = Query("all"),
    agent: str = Query("all"),
    map_id: str = Query("all"),
    min_rounds: int = Query(0, ge=0),
    exclude_series: str | None = Query(None, alias="exclude"),
):
    validate_id_param(event_id, "event_id")
    numeric_id = int(event_id)
    result = await get_event_stats_data(
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
    return V3Response[V3StatsData, V3EntityMeta](
        data=adapt_stats(_unwrap(result)),
        meta=V3EntityMeta(id=numeric_id),
    )


@router.get(
    "/events/{event_id}",
    response_model=V3Response[V3EventDetail, V3EntityMeta],
    summary="Typed event detail",
)
async def v3_event_detail(
    event_id: str,
    stage: str | None = Query(None, description="Stage slug returned by this endpoint"),
):
    validate_id_param(event_id, "event_id")
    numeric_id = int(event_id)
    payload = _unwrap(await get_event_detail_data(event_id, stage))
    detail = adapt_event_detail(payload.get("segments") or {})
    return V3Response[V3EventDetail, V3EntityMeta](
        data=detail,
        meta=V3EntityMeta(id=numeric_id),
    )
