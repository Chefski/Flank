"""Strict response models for the stable V3 API contract."""

from datetime import date, datetime
from typing import Generic, Literal, TypeVar

from pydantic import AnyHttpUrl, AnyUrl, BaseModel, ConfigDict, Field


class V3Model(BaseModel):
    """Base for V3 models: undeclared output is a contract violation."""

    model_config = ConfigDict(extra="forbid")


DataT = TypeVar("DataT")
MetaT = TypeVar("MetaT")


class V3Response(V3Model, Generic[DataT, MetaT]):
    api_version: Literal["3"] = "3"
    data: DataT
    meta: MetaT


class V3Meta(V3Model):
    source: Literal["vlr.gg"] = "vlr.gg"


class V3EntityMeta(V3Meta):
    id: int


class V3PageMeta(V3Meta):
    page: int
    total_pages: int | None = None
    has_previous: bool | None = None
    has_next: bool | None = None


class V3MatchListMeta(V3Meta):
    query: Literal["upcoming", "upcoming_extended", "live_score", "results", "event"]
    page_range: str | None = None
    total_pages_requested: int | None = None
    successful_pages: int | None = None
    failed_pages: list[int]
    event_id: int | None = None


class V3Money(V3Model):
    amount: int | None = None
    currency: Literal["USD"] | None = None
    display: str | None = None


class V3Image(V3Model):
    url: AnyHttpUrl | None = None
    light_url: AnyHttpUrl | None = None
    dark_url: AnyHttpUrl | None = None


class V3TeamRef(V3Model):
    id: int | None = None
    name: str
    tag: str | None = None
    country_code: str | None = None
    region: str | None = None
    url: AnyHttpUrl | None = None
    image: V3Image
    score: int | None = None
    is_winner: bool = False


class V3PlayerRef(V3Model):
    id: int | None = None
    name: str
    url: AnyHttpUrl | None = None


class V3EventRef(V3Model):
    id: int | None = None
    name: str
    stage: str | None = None
    stage_slug: str | None = None
    series: str | None = None
    url: AnyHttpUrl | None = None
    image: V3Image


class V3DisplayTime(V3Model):
    date: str | None = None
    time: str | None = None
    relative: str | None = None


class V3Match(V3Model):
    id: int
    stats_id: int | None = None
    source: Literal["upcoming", "live", "matches", "results", "event", "team", "player"]
    url: AnyHttpUrl
    status: Literal["scheduled", "live", "completed", "unknown"]
    status_text: str | None = None
    starts_at: datetime | None = None
    display: V3DisplayTime
    event: V3EventRef
    teams: list[V3TeamRef] = Field(min_length=2, max_length=2)
    note: str | None = None
    page: int | None = None


class V3AgentUsage(V3Model):
    agent: str
    usage_percent: float | None = None


class V3StatsFilters(V3Model):
    tier: str
    region: str
    span: str
    side: str
    role: str
    agent: str
    map_id: int | None = None
    minimum_rounds: int
    minimum_rating: int
    sort: str
    direction: Literal["asc", "desc"]
    from_date: date | None = None
    to_date: date | None = None


class V3PlayerStats(V3Model):
    player: V3PlayerRef
    country_code: str | None = None
    organization: str | None = None
    agents: list[V3AgentUsage]
    maps_played: int | None = None
    rounds_played: int | None = None
    rating: float | None = None
    average_combat_score: float | None = None
    kill_death_ratio: float | None = None
    kast_percent: float | None = None
    average_damage_per_round: float | None = None
    kills_per_round: float | None = None
    assists_per_round: float | None = None
    first_kill_death_ratio: float | None = None
    first_kills_per_round: float | None = None
    first_deaths_per_round: float | None = None
    headshot_percent: float | None = None
    clutch_success_percent: float | None = None
    clutches_won: int | None = None
    clutches_attempted: int | None = None
    maximum_kills: int | None = None
    kills: int | None = None
    deaths: int | None = None
    assists: int | None = None
    first_kills: int | None = None
    first_deaths: int | None = None
    maximum_kills_match_id: int | None = None
    maximum_kills_game_id: int | None = None
    maximum_kills_match_url: AnyHttpUrl | None = None


class V3StatsData(V3Model):
    filters: V3StatsFilters
    players: list[V3PlayerStats]


class V3NewsSummary(V3Model):
    id: int
    slug: str
    title: str
    description: str | None = None
    published_date: date | None = None
    author_handle: str | None = None
    region_code: str | None = None
    url: AnyHttpUrl


class V3NewsAuthor(V3Model):
    name: str
    handle: str | None = None
    url: AnyHttpUrl | None = None
    avatar_url: AnyHttpUrl | None = None


class V3ContentLink(V3Model):
    text: str | None = None
    url: AnyHttpUrl


class V3ContentMedia(V3Model):
    type: Literal["image", "embed"]
    url: AnyHttpUrl
    alt: str | None = None


class V3ArticleContent(V3Model):
    html: str
    text: str
    links: list[V3ContentLink]
    media: list[V3ContentMedia]


class V3NewsArticle(V3Model):
    id: int
    slug: str
    url: AnyHttpUrl
    title: str
    description: str | None = None
    published_at: datetime | None = None
    relative_time: str | None = None
    author: V3NewsAuthor
    event: V3EventRef | None = None
    content: V3ArticleContent
    comments_url: AnyHttpUrl


class V3EventSummary(V3Model):
    id: int
    name: str
    status: Literal["upcoming", "ongoing", "completed", "unknown"]
    prize: V3Money
    date_text: str | None = None
    region_code: str | None = None
    url: AnyHttpUrl
    image: V3Image


class V3CalendarLinks(V3Model):
    google: AnyUrl | None = None
    apple: AnyUrl | None = None
    subscription: AnyUrl | None = None
    download: AnyUrl | None = None


class V3EventStage(V3Model):
    name: str
    slug: str | None = None
    date_text: str | None = None
    url: AnyHttpUrl | None = None
    active: bool


class V3EventResource(V3Model):
    name: str
    count: int | None = None
    url: AnyHttpUrl
    active: bool


class V3EventPlayer(V3Model):
    id: int
    name: str
    country_code: str | None = None


class V3EventTeam(V3Model):
    team: V3TeamRef
    players: list[V3EventPlayer]
    qualification: str | None = None
    qualification_url: AnyHttpUrl | None = None


class V3EventPrize(V3Model):
    placement: str
    prize: V3Money
    team: V3TeamRef | None = None


class V3StandingTable(V3Model):
    stage: str | None = None
    columns: list[str]
    rows: list[list[str | None]]


class V3GroupTeam(V3Model):
    rank: int
    team: V3TeamRef
    state: Literal["advanced", "eliminated", "active", "unknown"]
    series_wins: int | None = None
    series_losses: int | None = None
    maps_won: int | None = None
    maps_lost: int | None = None
    rounds_won: int | None = None
    rounds_lost: int | None = None
    round_differential: int | None = None


class V3EventMatch(V3Model):
    id: int
    url: AnyHttpUrl
    starts_at: datetime | None = None
    date_text: str | None = None
    status_text: str | None = None
    series: str | None = None
    format: str | None = None
    has_stream: bool | None = None
    teams: list[V3TeamRef] = Field(min_length=2, max_length=2)


class V3EventGroup(V3Model):
    id: int | None = None
    name: str
    teams: list[V3GroupTeam]
    matches: list[V3EventMatch]


class V3BracketRound(V3Model):
    name: str
    matches: list[V3EventMatch]


class V3Bracket(V3Model):
    type: str
    rounds: list[V3BracketRound]


class V3EventDetail(V3Model):
    id: int
    name: str
    series: str | None = None
    subtitle: str | None = None
    date_text: str | None = None
    prize: V3Money
    location: str | None = None
    region_code: str | None = None
    url: AnyHttpUrl
    image: V3Image
    calendar: V3CalendarLinks
    stages: list[V3EventStage]
    active_stage: V3EventStage | None = None
    resources: list[V3EventResource]
    teams: list[V3EventTeam]
    prizes: list[V3EventPrize]
    standings: list[V3StandingTable]
    groups: list[V3EventGroup]
    brackets: list[V3Bracket]


class V3Score(V3Model):
    team1: int | None = None
    team2: int | None = None


class V3TeamSideScore(V3Model):
    total: int | None = None
    attack: int | None = None
    defense: int | None = None
    overtime: int | None = None


class V3MapSideScores(V3Model):
    team1: V3TeamSideScore
    team2: V3TeamSideScore


class V3PlayerSideStats(V3Model):
    rating: float | None = None
    average_combat_score: float | None = None
    kills: int | None = None
    deaths: int | None = None
    assists: int | None = None
    kill_death_differential: int | None = None
    kast_percent: float | None = None
    average_damage_per_round: float | None = None
    headshot_percent: float | None = None
    first_kills: int | None = None
    first_deaths: int | None = None
    first_kill_differential: int | None = None


class V3MapPlayerStats(V3PlayerSideStats):
    player: V3PlayerRef
    country_code: str | None = None
    team_tag: str | None = None
    agent: str | None = None
    agent_slug: str | None = None
    attack: V3PlayerSideStats
    defense: V3PlayerSideStats


class V3Round(V3Model):
    number: int
    winner: Literal["team1", "team2", "unknown"]
    side: Literal["attack", "defense", "unknown"]
    method: str | None = None
    method_code: str | None = None
    method_icon_url: AnyHttpUrl | None = None
    score_after: V3Score


class V3Matchup(V3Model):
    opponent: V3PlayerRef
    kills: int | None = None
    deaths: int | None = None
    differential: int | None = None


class V3KillMatrixRow(V3Model):
    player: V3PlayerRef
    team_tag: str | None = None
    matchups: list[V3Matchup]


class V3MultiKills(V3Model):
    two: int | None = None
    three: int | None = None
    four: int | None = None
    five: int | None = None


class V3Clutches(V3Model):
    one_vs_one: int | None = None
    one_vs_two: int | None = None
    one_vs_three: int | None = None
    one_vs_four: int | None = None
    one_vs_five: int | None = None


class V3AdvancedPlayerStats(V3Model):
    player: V3PlayerRef
    team_tag: str | None = None
    agent: str | None = None
    agent_slug: str | None = None
    multi_kills: V3MultiKills
    clutches: V3Clutches
    economy_rating: int | None = None
    plants: int | None = None
    defuses: int | None = None


class V3Performance(V3Model):
    kill_matrix: list[V3KillMatrixRow]
    advanced_stats: list[V3AdvancedPlayerStats]


class V3GamePerformance(V3Performance):
    game_id: int


class V3EconomyBucket(V3Model):
    rounds: int | None = None
    wins: int | None = None


class V3EconomyRow(V3Model):
    team_id: int | None = None
    team_tag: str | None = None
    pistol_wins: int | None = None
    pistol_win_percent: float | None = None
    eco: V3EconomyBucket
    low: V3EconomyBucket
    medium: V3EconomyBucket
    full: V3EconomyBucket


class V3GameEconomy(V3Model):
    game_id: int
    teams: list[V3EconomyRow]


class V3MapPick(V3Model):
    slot: Literal["team1", "team2"] | None = None
    team: V3TeamRef | None = None


class V3GamePlayers(V3Model):
    team1: list[V3MapPlayerStats]
    team2: list[V3MapPlayerStats]


class V3Game(V3Model):
    id: int
    number: int
    map_name: str | None = None
    status: Literal["scheduled", "in_progress", "completed", "unknown"]
    duration: str | None = None
    pick: V3MapPick | None = None
    score: V3Score
    side_scores: V3MapSideScores
    players: V3GamePlayers
    rounds: list[V3Round]
    url: AnyHttpUrl | None = None
    performance: V3Performance
    economy: list[V3EconomyRow]


class V3Stream(V3Model):
    name: str
    url: AnyHttpUrl
    platform: str | None = None
    country_code: str | None = None
    embedded: bool
    site_id: str | None = None


class V3Vod(V3Model):
    name: str
    url: AnyHttpUrl
    platform: str | None = None
    map_number: int | None = None


class V3HeadToHead(V3Model):
    id: int
    url: AnyHttpUrl
    event_name: str | None = None
    event_series: str | None = None
    date_text: str | None = None
    teams: list[V3TeamRef] = Field(min_length=2, max_length=2)
    score: V3Score


class V3MatchDetail(V3Model):
    id: int
    stats_id: int | None = None
    url: AnyHttpUrl
    status: Literal["scheduled", "live", "completed", "unknown"]
    starts_at: datetime | None = None
    date_text: str | None = None
    patch: str | None = None
    format: str | None = None
    map_vetos: str | None = None
    notes: list[str]
    event: V3EventRef
    teams: list[V3TeamRef] = Field(min_length=2, max_length=2)
    streams: list[V3Stream]
    vods: list[V3Vod]
    games: list[V3Game]
    head_to_head: list[V3HeadToHead]
    performance: V3Performance
    performance_by_game: list[V3GamePerformance]
    economy: list[V3EconomyRow]
    economy_by_game: list[V3GameEconomy]
