"""Normalize scraper payloads into the strict V3 response contract."""

import re
from datetime import UTC, date, datetime

from models.v3 import (
    V3AdvancedPlayerStats,
    V3AgentUsage,
    V3ArticleContent,
    V3Bracket,
    V3BracketRound,
    V3CalendarLinks,
    V3Clutches,
    V3ContentLink,
    V3ContentMedia,
    V3DisplayTime,
    V3EconomyBucket,
    V3EconomyRow,
    V3EventDetail,
    V3EventGroup,
    V3EventMatch,
    V3EventPlayer,
    V3EventPrize,
    V3EventRef,
    V3EventResource,
    V3EventStage,
    V3EventSummary,
    V3EventTeam,
    V3Game,
    V3GameEconomy,
    V3GamePerformance,
    V3GamePlayers,
    V3GroupTeam,
    V3HeadToHead,
    V3Image,
    V3KillMatrixRow,
    V3MapPick,
    V3MapPlayerStats,
    V3MapSideScores,
    V3Match,
    V3MatchDetail,
    V3MatchListMeta,
    V3Matchup,
    V3Money,
    V3MultiKills,
    V3NewsArticle,
    V3NewsAuthor,
    V3NewsSummary,
    V3PageMeta,
    V3Performance,
    V3PlayerRef,
    V3PlayerSideStats,
    V3PlayerStats,
    V3Round,
    V3Score,
    V3StandingTable,
    V3StatsData,
    V3StatsFilters,
    V3Stream,
    V3TeamRef,
    V3TeamSideScore,
    V3Vod,
)

_EMPTY_VALUES = {"", "-", "n/a", "na", "none", "unknown"}


def nullable_text(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return None if text.casefold() in _EMPTY_VALUES else text


def optional_int(value) -> int | None:
    text = nullable_text(value)
    if text is None:
        return None
    normalized = text.replace(",", "").replace("+", "")
    try:
        return int(normalized)
    except ValueError:
        try:
            number = float(normalized)
        except ValueError:
            return None
        return int(number) if number.is_integer() else None


def entity_id(value) -> int | None:
    result = optional_int(value)
    return result if result is not None and result > 0 else None


def optional_float(value) -> float | None:
    text = nullable_text(value)
    if text is None:
        return None
    try:
        return float(text.replace(",", "").replace("+", ""))
    except ValueError:
        return None


def optional_percent(value) -> float | None:
    text = nullable_text(value)
    return optional_float(text.removesuffix("%")) if text else None


def optional_url(value) -> str | None:
    text = nullable_text(value)
    return text if text and text.startswith(("http://", "https://", "webcal://")) else None


def optional_date(value) -> date | None:
    text = nullable_text(value)
    if text is None:
        return None
    try:
        return date.fromisoformat(text)
    except ValueError:
        return None


def optional_datetime(value) -> datetime | None:
    text = nullable_text(value)
    if text is None:
        return None
    if text.isdigit() and len(text) >= 9:
        try:
            return datetime.fromtimestamp(int(text), tz=UTC)
        except (OverflowError, OSError, ValueError):
            return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def _pair(value) -> tuple[int | None, int | None]:
    text = nullable_text(value)
    if text is None:
        return None, None
    parts = re.findall(r"[+-]?\d+", text)
    return (
        optional_int(parts[0]) if parts else None,
        optional_int(parts[1]) if len(parts) > 1 else None,
    )


def _money(value) -> V3Money:
    display = nullable_text(value)
    if display is None:
        return V3Money()
    match = re.search(r"\$\s*([\d,]+)", display)
    return V3Money(
        amount=optional_int(match.group(1)) if match else None,
        currency="USD" if match else None,
        display=display,
    )


def _image(source: dict | None) -> V3Image:
    source = source or {}
    default = optional_url(source.get("logo") or source.get("thumb"))
    return V3Image(
        url=default,
        light_url=optional_url(source.get("logo_light")) or default,
        dark_url=optional_url(source.get("logo_dark")) or default,
    )


def _team(source: dict | None, *, require_id: bool = False) -> V3TeamRef:
    source = source or {}
    team_id = entity_id(source.get("id") or source.get("team_id"))
    if require_id and team_id is None:
        raise ValueError("V3 team references require a stable numeric ID")
    return V3TeamRef(
        id=team_id,
        name=nullable_text(source.get("name") or source.get("team")) or "TBD",
        tag=nullable_text(source.get("tag") or source.get("team_tag") or source.get("Team")),
        country_code=nullable_text(source.get("country_code") or source.get("flag")),
        region=nullable_text(source.get("region")),
        url=optional_url(source.get("url")),
        image=_image(source),
        score=optional_int(source.get("score")),
        is_winner=bool(source.get("is_winner", False)),
    )


def _player(source: dict | None, *, prefix: str = "") -> V3PlayerRef:
    source = source or {}
    return V3PlayerRef(
        id=entity_id(source.get(f"{prefix}id") or source.get(f"{prefix}player_id")),
        name=nullable_text(source.get(f"{prefix}name") or source.get(f"{prefix}player")) or "Unknown",
        url=optional_url(source.get(f"{prefix}url") or source.get(f"{prefix}player_url")),
    )


def _event_ref(source: dict | None) -> V3EventRef:
    source = source or {}
    stage = nullable_text(source.get("stage"))
    stage_slug = nullable_text(source.get("stage_slug"))
    series = nullable_text(source.get("series") or source.get("event_series"))
    if stage_slug is None and stage and "-" in stage and stage == stage.casefold():
        stage_slug = stage
        if series and ":" in series:
            stage, series = [part.strip() or None for part in series.split(":", 1)]
        else:
            stage = None
    return V3EventRef(
        id=entity_id(source.get("id") or source.get("event_id")),
        name=nullable_text(source.get("name") or source.get("event")) or "Unknown",
        stage=stage,
        stage_slug=stage_slug,
        series=series,
        url=optional_url(source.get("url")),
        image=_image(source),
    )


def _match_status(value) -> str:
    status = (nullable_text(value) or "").casefold()
    if status in {"live", "in_progress", "in progress"}:
        return "live"
    if status in {"completed", "final", "finished"}:
        return "completed"
    if "ago" in status:
        return "completed"
    if status in {"scheduled", "upcoming", "pending"}:
        return "scheduled"
    if re.search(r"\b\d+\s*[dhm]\b", status):
        return "scheduled"
    return "unknown"


def adapt_match(source: dict) -> V3Match:
    match_id = entity_id(source.get("match_id"))
    url = optional_url(source.get("url"))
    if match_id is None or url is None:
        raise ValueError("V3 match records require a stable numeric ID and URL")
    raw_source = nullable_text(source.get("source")) or "matches"
    if raw_source not in {"upcoming", "live", "matches", "results", "event", "team", "player"}:
        raw_source = "matches"
    display = source.get("display") or {}
    return V3Match(
        id=match_id,
        stats_id=entity_id(source.get("stats_match_id")),
        source=raw_source,
        url=url,
        status=_match_status(source.get("status")),
        status_text=nullable_text(source.get("status_text")),
        starts_at=optional_datetime(source.get("scheduled_at")),
        display=V3DisplayTime(
            date=nullable_text(display.get("date")),
            time=nullable_text(display.get("time")),
            relative=nullable_text(display.get("relative")),
        ),
        event=_event_ref(source.get("event")),
        teams=[_team(team) for team in (source.get("teams") or [])[:2]],
        note=nullable_text(source.get("note")),
        page=optional_int(source.get("page")),
    )


def adapt_match_list(
    payload: dict,
    *,
    query: str,
    event_id: int | None = None,
) -> tuple[list[V3Match], V3MatchListMeta]:
    records = []
    for segment in payload.get("segments") or []:
        canonical = segment.get("match") if isinstance(segment, dict) else None
        if not isinstance(canonical, dict):
            continue
        try:
            records.append(adapt_match(canonical))
        except ValueError:
            continue
    source_meta = payload.get("meta") or {}
    failed_pages = [
        page for value in source_meta.get("failed_pages", []) if (page := optional_int(value)) is not None
    ]
    return records, V3MatchListMeta(
        query=query,
        page_range=nullable_text(source_meta.get("page_range")),
        total_pages_requested=optional_int(source_meta.get("total_pages_requested")),
        successful_pages=optional_int(source_meta.get("successful_pages")),
        failed_pages=failed_pages,
        event_id=event_id,
    )


def adapt_news_summary(source: dict) -> V3NewsSummary:
    article_id = entity_id(source.get("article_id"))
    url = optional_url(source.get("url") or source.get("url_path"))
    if article_id is None or url is None:
        raise ValueError("V3 news summaries require a stable numeric ID and URL")
    return V3NewsSummary(
        id=article_id,
        slug=nullable_text(source.get("slug")) or "",
        title=nullable_text(source.get("title")) or "Untitled",
        description=nullable_text(source.get("description")),
        published_date=optional_date(source.get("published_date")),
        author_handle=nullable_text(source.get("author")),
        region_code=nullable_text(source.get("region_code")),
        url=url,
    )


def adapt_news_archive(payload: dict) -> tuple[list[V3NewsSummary], V3PageMeta]:
    articles = []
    for source in payload.get("segments") or []:
        try:
            articles.append(adapt_news_summary(source))
        except ValueError:
            continue
    source_meta = payload.get("meta") or {}
    return articles, V3PageMeta(
        page=optional_int(source_meta.get("page")) or 1,
        total_pages=optional_int(source_meta.get("total_pages")),
        has_previous=bool(source_meta.get("has_previous", False)),
        has_next=bool(source_meta.get("has_next", False)),
    )


def adapt_news_article(source: dict) -> V3NewsArticle:
    article_id = entity_id(source.get("article_id"))
    url = optional_url(source.get("url"))
    comments_url = optional_url(source.get("comments_url"))
    if article_id is None or url is None or comments_url is None:
        raise ValueError("V3 news articles require stable identity URLs")
    author = source.get("author") or {}
    event = source.get("event") or {}
    content = source.get("content") or {}
    event_ref = _event_ref(event) if entity_id(event.get("id")) or nullable_text(event.get("name")) else None
    return V3NewsArticle(
        id=article_id,
        slug=nullable_text(source.get("slug")) or "",
        url=url,
        title=nullable_text(source.get("title")) or "Untitled",
        description=nullable_text(source.get("description")),
        published_at=optional_datetime(source.get("published_at")),
        relative_time=nullable_text(source.get("relative_time")),
        author=V3NewsAuthor(
            name=nullable_text(author.get("name")) or "Unknown",
            handle=nullable_text(author.get("handle")),
            url=optional_url(author.get("url")),
            avatar_url=optional_url(author.get("avatar")),
        ),
        event=event_ref,
        content=V3ArticleContent(
            html=str(content.get("html") or ""),
            text=str(content.get("text") or ""),
            links=[
                V3ContentLink(text=nullable_text(link.get("text")), url=url)
                for link in content.get("links") or []
                if (url := optional_url(link.get("url")))
            ],
            media=[
                V3ContentMedia(
                    type="image" if media.get("type") == "image" else "embed",
                    url=url,
                    alt=nullable_text(media.get("alt")),
                )
                for media in content.get("media") or []
                if (url := optional_url(media.get("url")))
            ],
        ),
        comments_url=comments_url,
    )


def _clutch_pair(value) -> tuple[int | None, int | None]:
    return _pair(value)


def adapt_stats(payload: dict) -> V3StatsData:
    filters = payload.get("filters") or {}
    map_id = entity_id(filters.get("map_id"))
    players = []
    for source in payload.get("segments") or []:
        player_id = entity_id(source.get("player_id"))
        player_url = optional_url(source.get("player_url"))
        if player_id is None:
            continue
        usage = source.get("agent_usage") or []
        if not usage:
            usage = [{"agent": agent, "usage": None} for agent in source.get("agents") or []]
        clutches_won, clutches_attempted = _clutch_pair(source.get("clutch_attempts"))
        players.append(
            V3PlayerStats(
                player=V3PlayerRef(
                    id=player_id,
                    name=nullable_text(source.get("player")) or "Unknown",
                    url=player_url,
                ),
                country_code=nullable_text(source.get("country")),
                organization=nullable_text(source.get("org")),
                agents=[
                    V3AgentUsage(
                        agent=nullable_text(agent.get("agent")) or "unknown",
                        usage_percent=optional_percent(agent.get("usage")),
                    )
                    for agent in usage
                ],
                maps_played=optional_int(source.get("maps_played")),
                rounds_played=optional_int(source.get("rounds_played")),
                rating=optional_float(source.get("rating")),
                average_combat_score=optional_float(source.get("average_combat_score")),
                kill_death_ratio=optional_float(source.get("kill_deaths")),
                kast_percent=optional_percent(source.get("kill_assists_survived_traded")),
                average_damage_per_round=optional_float(source.get("average_damage_per_round")),
                kills_per_round=optional_float(source.get("kills_per_round")),
                assists_per_round=optional_float(source.get("assists_per_round")),
                first_kill_death_ratio=optional_float(source.get("first_kill_death_ratio")),
                first_kills_per_round=optional_float(source.get("first_kills_per_round")),
                first_deaths_per_round=optional_float(source.get("first_deaths_per_round")),
                headshot_percent=optional_percent(source.get("headshot_percentage")),
                clutch_success_percent=optional_percent(source.get("clutch_success_percentage")),
                clutches_won=clutches_won,
                clutches_attempted=clutches_attempted,
                maximum_kills=optional_int(source.get("max_kills")),
                kills=optional_int(source.get("kills")),
                deaths=optional_int(source.get("deaths")),
                assists=optional_int(source.get("assists")),
                first_kills=optional_int(source.get("first_kills")),
                first_deaths=optional_int(source.get("first_deaths")),
                maximum_kills_match_id=entity_id(source.get("max_kills_match_id")),
                maximum_kills_game_id=entity_id(source.get("max_kills_game_id")),
                maximum_kills_match_url=optional_url(source.get("max_kills_match_url")),
            )
        )
    return V3StatsData(
        filters=V3StatsFilters(
            tier=nullable_text(filters.get("tier")) or "all",
            region=nullable_text(filters.get("region")) or "all",
            span=nullable_text(filters.get("span")) or "all",
            side=nullable_text(filters.get("side")) or "all",
            role=nullable_text(filters.get("role")) or "all",
            agent=nullable_text(filters.get("agent")) or "all",
            map_id=map_id,
            minimum_rounds=optional_int(filters.get("min_rounds")) or 0,
            minimum_rating=optional_int(filters.get("min_rating")) or 0,
            sort=nullable_text(filters.get("sort")) or "rating",
            direction="asc" if filters.get("dir") == "asc" else "desc",
            from_date=optional_date(filters.get("from")),
            to_date=optional_date(filters.get("to")),
        ),
        players=players,
    )


def adapt_event_summary(source: dict) -> V3EventSummary:
    event_id = entity_id(source.get("event_id"))
    url = optional_url(source.get("url_path"))
    if event_id is None or url is None:
        raise ValueError("V3 event summaries require a stable numeric ID and URL")
    status = (nullable_text(source.get("status")) or "unknown").casefold()
    if status not in {"upcoming", "ongoing", "completed"}:
        status = "unknown"
    return V3EventSummary(
        id=event_id,
        name=nullable_text(source.get("title")) or "Unknown",
        status=status,
        prize=_money(source.get("prize")),
        date_text=nullable_text(source.get("dates")),
        region_code=nullable_text(source.get("region")),
        url=url,
        image=_image(source),
    )


def adapt_event_list(payload: dict, page: int) -> tuple[list[V3EventSummary], V3PageMeta]:
    events = []
    for source in payload.get("segments") or []:
        try:
            events.append(adapt_event_summary(source))
        except ValueError:
            continue
    return events, V3PageMeta(
        page=page,
        total_pages=None,
        has_previous=page > 1,
        has_next=None,
    )


def _event_match(source: dict, *, bracket: bool = False) -> V3EventMatch | None:
    match_id = entity_id(source.get("match_id"))
    url = optional_url(source.get("url"))
    if match_id is None or url is None:
        return None
    teams = [_team(source.get("team1")), _team(source.get("team2"))]
    return V3EventMatch(
        id=match_id,
        url=url,
        starts_at=optional_datetime(source.get("utc_timestamp")),
        date_text=nullable_text(source.get("date")),
        status_text=nullable_text(source.get("status")) if bracket else None,
        series=nullable_text(source.get("series")),
        format=nullable_text(source.get("format")),
        has_stream=bool(source.get("has_stream")) if bracket else None,
        teams=teams,
    )


def _group_team(source: dict) -> V3GroupTeam:
    series_wins, series_losses = _pair(source.get("record"))
    maps_won, maps_lost = _pair(source.get("maps"))
    rounds_won, rounds_lost = _pair(source.get("rounds"))
    state = nullable_text(source.get("state")) or "unknown"
    if state not in {"advanced", "eliminated", "active"}:
        state = "unknown"
    return V3GroupTeam(
        rank=optional_int(source.get("rank")) or 0,
        team=_team(source, require_id=True),
        state=state,
        series_wins=series_wins,
        series_losses=series_losses,
        maps_won=maps_won,
        maps_lost=maps_lost,
        rounds_won=rounds_won,
        rounds_lost=rounds_lost,
        round_differential=optional_int(source.get("round_differential")),
    )


def adapt_event_detail(source: dict) -> V3EventDetail:
    event = source.get("event") or {}
    event_id = entity_id(event.get("event_id"))
    url = optional_url(event.get("url"))
    if event_id is None or url is None:
        raise ValueError("V3 event details require stable identity")
    stages = [
        V3EventStage(
            name=nullable_text(item.get("name")) or "Unknown",
            slug=nullable_text(item.get("slug")),
            date_text=nullable_text(item.get("dates")),
            url=optional_url(item.get("url")),
            active=bool(item.get("active", False)),
        )
        for item in source.get("stages") or []
    ]
    active_source = source.get("active_stage")
    active_stage = None
    if isinstance(active_source, dict):
        active_stage = V3EventStage(
            name=nullable_text(active_source.get("name")) or "Unknown",
            slug=nullable_text(active_source.get("slug")),
            date_text=nullable_text(active_source.get("dates")),
            url=optional_url(active_source.get("url")),
            active=bool(active_source.get("active", True)),
        )
    teams = []
    for item in source.get("teams") or []:
        try:
            team = _team(item, require_id=True)
        except ValueError:
            continue
        teams.append(
            V3EventTeam(
                team=team,
                players=[
                    V3EventPlayer(
                        id=player_id,
                        name=nullable_text(player.get("name")) or "Unknown",
                        country_code=nullable_text(player.get("flag")),
                    )
                    for player in item.get("players") or []
                    if (player_id := entity_id(player.get("id"))) is not None
                ],
                qualification=nullable_text(item.get("qualification")),
                qualification_url=optional_url(item.get("qualification_url")),
            )
        )
    prizes = []
    for item in source.get("prizes") or []:
        team_source = item.get("team") or {}
        prizes.append(
            V3EventPrize(
                placement=nullable_text(item.get("placement")) or "Unknown",
                prize=_money(item.get("amount")),
                team=(
                    _team(team_source)
                    if entity_id(team_source.get("id"))
                    or nullable_text(team_source.get("name"))
                    else None
                ),
            )
        )
    groups = []
    for item in source.get("groups") or []:
        group_matches = [
            match
            for value in item.get("matches") or []
            if (match := _event_match(value)) is not None
        ]
        group_teams = []
        for value in item.get("teams") or []:
            try:
                group_teams.append(_group_team(value))
            except ValueError:
                continue
        groups.append(
            V3EventGroup(
                id=entity_id(item.get("id")),
                name=nullable_text(item.get("name")) or "Unknown",
                teams=group_teams,
                matches=group_matches,
            )
        )
    brackets = []
    for item in source.get("brackets") or []:
        rounds = []
        for round_source in item.get("rounds") or []:
            matches = [
                match
                for value in round_source.get("matches") or []
                if (match := _event_match(value, bracket=True)) is not None
            ]
            rounds.append(
                V3BracketRound(
                    name=nullable_text(round_source.get("name")) or "Unknown",
                    matches=matches,
                )
            )
        brackets.append(V3Bracket(type=nullable_text(item.get("type")) or "main", rounds=rounds))
    calendar = event.get("calendar") or {}
    return V3EventDetail(
        id=event_id,
        name=nullable_text(event.get("name")) or "Unknown",
        series=nullable_text(event.get("series")),
        subtitle=nullable_text(event.get("subtitle")),
        date_text=nullable_text(event.get("dates")),
        prize=_money(event.get("prize")),
        location=nullable_text(event.get("location")),
        region_code=nullable_text(event.get("location_code")),
        url=url,
        image=_image(event),
        calendar=V3CalendarLinks(
            google=optional_url(calendar.get("google")),
            apple=optional_url(calendar.get("apple")),
            subscription=optional_url(calendar.get("subscription")),
            download=optional_url(calendar.get("download")),
        ),
        stages=stages,
        active_stage=active_stage,
        resources=[
            V3EventResource(
                name=nullable_text(item.get("name")) or "Unknown",
                count=optional_int(item.get("count")),
                url=url,
                active=bool(item.get("active", False)),
            )
            for item in source.get("resources") or []
            if (url := optional_url(item.get("url")))
        ],
        teams=teams,
        prizes=prizes,
        standings=[
            V3StandingTable(
                stage=nullable_text(item.get("stage")),
                columns=[str(column) for column in item.get("columns") or []],
                rows=[
                    [nullable_text(row.get(column)) for column in item.get("columns") or []]
                    for row in item.get("rows") or []
                ],
            )
            for item in source.get("standings") or []
        ],
        groups=groups,
        brackets=brackets,
    )


def _player_side_stats(source: dict | None) -> V3PlayerSideStats:
    source = source or {}
    return V3PlayerSideStats(
        rating=optional_float(source.get("rating")),
        average_combat_score=optional_float(source.get("acs")),
        kills=optional_int(source.get("kills")),
        deaths=optional_int(source.get("deaths")),
        assists=optional_int(source.get("assists")),
        kill_death_differential=optional_int(source.get("kd_diff")),
        kast_percent=optional_percent(source.get("kast")),
        average_damage_per_round=optional_float(source.get("adr")),
        headshot_percent=optional_percent(source.get("hs_pct")),
        first_kills=optional_int(source.get("fk")),
        first_deaths=optional_int(source.get("fd")),
        first_kill_differential=optional_int(source.get("fk_diff")),
    )


def _map_player(source: dict) -> V3MapPlayerStats:
    base = _player_side_stats(source).model_dump()
    return V3MapPlayerStats(
        **base,
        player=V3PlayerRef(
            id=entity_id(source.get("player_id")),
            name=nullable_text(source.get("name")) or "Unknown",
            url=optional_url(source.get("player_url")),
        ),
        country_code=nullable_text(source.get("country")),
        team_tag=nullable_text(source.get("team_tag")),
        agent=nullable_text(source.get("agent")),
        agent_slug=nullable_text(source.get("agent_slug")),
        attack=_player_side_stats(source.get("attack")),
        defense=_player_side_stats(source.get("defense")),
    )


def _kill_matrix(source: dict) -> V3KillMatrixRow:
    return V3KillMatrixRow(
        player=V3PlayerRef(
            id=entity_id(source.get("player_id")),
            name=nullable_text(source.get("player")) or "Unknown",
            url=optional_url(source.get("player_url")),
        ),
        team_tag=nullable_text(source.get("team_tag")),
        matchups=[
            V3Matchup(
                opponent=V3PlayerRef(
                    id=entity_id(item.get("opponent_id")),
                    name=nullable_text(item.get("opponent")) or "Unknown",
                    url=optional_url(item.get("opponent_url")),
                ),
                kills=optional_int(item.get("kills")),
                deaths=optional_int(item.get("deaths")),
                differential=optional_int(item.get("differential")),
            )
            for item in source.get("matchups") or []
        ],
    )


def _advanced_stats(source: dict) -> V3AdvancedPlayerStats:
    return V3AdvancedPlayerStats(
        player=V3PlayerRef(
            id=entity_id(source.get("player_id")),
            name=nullable_text(source.get("player")) or "Unknown",
            url=optional_url(source.get("player_url")),
        ),
        team_tag=nullable_text(source.get("team_tag")),
        agent=nullable_text(source.get("agent")),
        agent_slug=nullable_text(source.get("agent_slug")),
        multi_kills=V3MultiKills(
            two=optional_int(source.get("2K")),
            three=optional_int(source.get("3K")),
            four=optional_int(source.get("4K")),
            five=optional_int(source.get("5K")),
        ),
        clutches=V3Clutches(
            one_vs_one=optional_int(source.get("1v1")),
            one_vs_two=optional_int(source.get("1v2")),
            one_vs_three=optional_int(source.get("1v3")),
            one_vs_four=optional_int(source.get("1v4")),
            one_vs_five=optional_int(source.get("1v5")),
        ),
        economy_rating=optional_int(source.get("ECON")),
        plants=optional_int(source.get("PL")),
        defuses=optional_int(source.get("DE")),
    )


def _performance(source: dict | None) -> V3Performance:
    source = source or {}
    return V3Performance(
        kill_matrix=[_kill_matrix(item) for item in source.get("kill_matrix") or []],
        advanced_stats=[_advanced_stats(item) for item in source.get("advanced_stats") or []],
    )


def _economy_bucket(value) -> V3EconomyBucket:
    rounds, wins = _pair(value)
    return V3EconomyBucket(rounds=rounds, wins=wins)


_ECM_GROUPS = {"eco": "on eco", "medium": "on half buy", "full": "on full buy"}


def _ratio(value) -> tuple[int | None, int | None]:
    """Parse vlr.gg's ``wins/attempts`` economy cell."""
    text = nullable_text(value)
    if text is None or "/" not in text:
        return None, None
    return _pair(text)


def _ecm_bucket(source: dict, prefix: str) -> V3EconomyBucket:
    """Sum the "vs. Eco/Half/Full" cells of one ``table.ecm`` buy-state group."""
    rounds = wins = 0
    seen = False
    for key, value in source.items():
        if not key.casefold().startswith(prefix):
            continue
        won, attempted = _ratio(value)
        if won is None or attempted is None:
            continue
        seen = True
        wins += won
        rounds += attempted
    return V3EconomyBucket(rounds=rounds, wins=wins) if seen else V3EconomyBucket()


def _economy_ecm(source: dict) -> V3EconomyRow:
    """Map the October 2026 ``table.ecm`` economy row onto the V3 buckets.

    The redesigned widget reports three buy states (eco <10k, half 10-18k, full
    18k+) as ``wins/attempts`` per opponent buy. They map onto eco, medium and
    full; the retired 5-10k "$" bucket has no equivalent and stays null.
    """
    pistol_wins, pistol_attempts = _ratio(source.get("Pistol"))
    pistol_percent = None
    if pistol_wins is not None and pistol_attempts:
        pistol_percent = round(100 * pistol_wins / pistol_attempts, 1)
    return V3EconomyRow(
        team_id=entity_id(source.get("team_id")),
        team_tag=nullable_text(source.get("Team")),
        pistol_wins=pistol_wins,
        pistol_win_percent=pistol_percent,
        eco=_ecm_bucket(source, _ECM_GROUPS["eco"]),
        low=V3EconomyBucket(),
        medium=_ecm_bucket(source, _ECM_GROUPS["medium"]),
        full=_ecm_bucket(source, _ECM_GROUPS["full"]),
    )


def _economy(source: dict) -> V3EconomyRow:
    if any(key.casefold().startswith(tuple(_ECM_GROUPS.values())) for key in source):
        return _economy_ecm(source)
    pistol = nullable_text(source.get("Pistol"))
    pistol_wins = optional_int(source.get("Pistol Won"))
    if pistol_wins is None and pistol and "%" not in pistol:
        pistol_wins = optional_int(pistol)
    return V3EconomyRow(
        team_id=entity_id(source.get("team_id")),
        team_tag=nullable_text(source.get("Team")),
        pistol_wins=pistol_wins,
        pistol_win_percent=optional_percent(pistol) if pistol and "%" in pistol else None,
        eco=_economy_bucket(source.get("Eco (won)")),
        low=_economy_bucket(source.get("$ (won)")),
        medium=_economy_bucket(source.get("$$ (won)")),
        full=_economy_bucket(source.get("$$$ (won)")),
    )


def _game_status(value) -> str:
    status = (nullable_text(value) or "").casefold()
    if status in {"live", "in_progress", "in progress"}:
        return "in_progress"
    if status in {"completed", "final", "finished"}:
        return "completed"
    if status in {"scheduled", "upcoming", "pending"}:
        return "scheduled"
    return "unknown"


def _game(source: dict) -> V3Game | None:
    game_id = entity_id(source.get("game_id"))
    if game_id is None:
        return None
    side_scores = source.get("side_scores") or {}
    pick_source = source.get("pick") or {}
    pick_team_id = entity_id(pick_source.get("team_id"))
    pick = None
    if pick_team_id is not None or nullable_text(pick_source.get("team")):
        slot = pick_source.get("slot") if pick_source.get("slot") in {"team1", "team2"} else None
        pick = V3MapPick(
            slot=slot,
            team=V3TeamRef(
                id=pick_team_id,
                name=nullable_text(pick_source.get("team")) or "Unknown",
                url=optional_url(pick_source.get("team_url")),
                image=V3Image(),
            ),
        )
    players = source.get("players") or {}
    return V3Game(
        id=game_id,
        number=optional_int(source.get("map_number")) or 0,
        map_name=nullable_text(source.get("map_name")),
        status=_game_status(source.get("status")),
        duration=nullable_text(source.get("duration")),
        pick=pick,
        score=V3Score(
            team1=optional_int((source.get("score") or {}).get("team1")),
            team2=optional_int((source.get("score") or {}).get("team2")),
        ),
        side_scores=V3MapSideScores(
            team1=V3TeamSideScore(
                total=optional_int((side_scores.get("team1") or {}).get("total")),
                attack=optional_int((side_scores.get("team1") or {}).get("attack")),
                defense=optional_int((side_scores.get("team1") or {}).get("defense")),
                overtime=optional_int((side_scores.get("team1") or {}).get("overtime")),
            ),
            team2=V3TeamSideScore(
                total=optional_int((side_scores.get("team2") or {}).get("total")),
                attack=optional_int((side_scores.get("team2") or {}).get("attack")),
                defense=optional_int((side_scores.get("team2") or {}).get("defense")),
                overtime=optional_int((side_scores.get("team2") or {}).get("overtime")),
            ),
        ),
        players=V3GamePlayers(
            team1=[_map_player(item) for item in players.get("team1") or []],
            team2=[_map_player(item) for item in players.get("team2") or []],
        ),
        rounds=[
            V3Round(
                number=optional_int(item.get("round_num")) or 0,
                winner=item.get("winner") if item.get("winner") in {"team1", "team2"} else "unknown",
                side=item.get("side_name") if item.get("side_name") in {"attack", "defense"} else "unknown",
                method=nullable_text(item.get("method")),
                method_code=nullable_text(item.get("method_code")),
                method_icon_url=optional_url(item.get("method_icon")),
                score_after=V3Score(
                    team1=optional_int((item.get("score_after") or {}).get("team1")),
                    team2=optional_int((item.get("score_after") or {}).get("team2")),
                ),
            )
            for item in source.get("rounds") or []
        ],
        url=optional_url(source.get("game_url")),
        performance=_performance(source.get("performance")),
        economy=[_economy(item) for item in source.get("economy") or []],
    )


def adapt_match_detail(source: dict) -> V3MatchDetail:
    match_id = entity_id(source.get("match_id"))
    url = optional_url(source.get("url"))
    if match_id is None or url is None:
        raise ValueError("V3 match details require stable identity")
    performance = source.get("performance") or {}
    economy_by_map = source.get("economy_by_map") or []
    games = [game for item in source.get("maps") or [] if (game := _game(item)) is not None]
    head_to_head = []
    for item in source.get("head_to_head") or []:
        h2h_id = entity_id(item.get("match_id"))
        h2h_url = optional_url(item.get("url"))
        if h2h_id is None or h2h_url is None:
            continue
        score1, score2 = _pair(item.get("score"))
        head_to_head.append(
            V3HeadToHead(
                id=h2h_id,
                url=h2h_url,
                event_name=nullable_text(item.get("event")),
                event_series=nullable_text(item.get("event_series")),
                date_text=nullable_text(item.get("date")),
                teams=[_team(team) for team in (item.get("teams") or [])[:2]],
                score=V3Score(team1=score1, team2=score2),
            )
        )
    return V3MatchDetail(
        id=match_id,
        stats_id=entity_id(source.get("stats_match_id")),
        url=url,
        status=_match_status(source.get("status")),
        starts_at=optional_datetime(source.get("scheduled_at") or source.get("utc_timestamp")),
        date_text=nullable_text(source.get("date")),
        patch=nullable_text(source.get("patch")),
        format=nullable_text(source.get("format")),
        map_vetos=nullable_text(source.get("map_vetos")),
        notes=[text for value in source.get("notes") or [] if (text := nullable_text(value))],
        event=_event_ref(source.get("event")),
        teams=[_team(team) for team in (source.get("teams") or [])[:2]],
        streams=[
            V3Stream(
                name=nullable_text(item.get("name")) or "Stream",
                url=url,
                platform=nullable_text(item.get("platform")),
                country_code=nullable_text(item.get("country_code")),
                embedded=bool(item.get("is_embedded", False)),
                site_id=nullable_text(item.get("site_id")),
            )
            for item in source.get("streams") or []
            if (url := optional_url(item.get("url")))
        ],
        vods=[
            V3Vod(
                name=nullable_text(item.get("name")) or "VOD",
                url=url,
                platform=nullable_text(item.get("platform")),
                map_number=optional_int(item.get("map_number")),
            )
            for item in source.get("vods") or []
            if (url := optional_url(item.get("url")))
        ],
        games=games,
        head_to_head=head_to_head,
        performance=_performance(performance),
        performance_by_game=[
            V3GamePerformance(
                game_id=game_id,
                **_performance(item).model_dump(),
            )
            for item in performance.get("by_map") or []
            if (game_id := entity_id(item.get("game_id"))) is not None
        ],
        economy=[_economy(item) for item in source.get("economy") or []],
        economy_by_game=[
            V3GameEconomy(
                game_id=game_id,
                teams=[_economy(row) for row in item.get("rows") or []],
            )
            for item in economy_by_map
            if (game_id := entity_id(item.get("game_id"))) is not None
        ],
    )
