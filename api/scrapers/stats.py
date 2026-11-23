import asyncio
import logging
import re
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime
from urllib.parse import parse_qs, urlencode, urlparse

from fastapi import HTTPException

from utils.cache_manager import cache_manager
from utils.constants import CACHE_TTL_STATS, STATS_TIERS, VLR_STATS_URL
from utils.error_handling import (
    handle_scraper_errors,
    raise_for_upstream_status,
    validate_stats_map,
    validate_stats_region,
    validate_timespan,
)
from utils.html_parsers import (
    build_full_url,
    extract_text_content,
    parse_href_id_slug,
    parse_html,
)
from utils.http_client import fetch_with_retries, get_http_client

logger = logging.getLogger(__name__)

# vlr.gg emits stable, semantic ``data-col`` attributes on every stats <th> except
# the unlabelled player column. Read cells BY KEY (never by literal index) so a
# future inserted column can never shift the mapping — the positional fragility
# fixed here has broken this scraper three times (upstream issues #4 and #14, both
# "vlr.gg added a column", each re-hardcoded to the new numbers).
# Keys are the CURRENT vlr.gg data-col vocabulary. The October 2026 /stats filter
# revamp renamed two of them: the rating column went from ``rating2`` to
# ``rating``, and first-kill rate from ``fbpr`` to ``fkpr``. The pre-revamp names
# are still read as fallbacks (``_LEGACY_DATA_COLS``) so archived markup parses.
_STATS_FIELD_MAP = {
    "maps": "maps_played",
    "rnd": "rounds_played",
    "rating": "rating",
    "acs": "average_combat_score",
    "kd": "kill_deaths",
    "kast": "kill_assists_survived_traded",
    "adr": "average_damage_per_round",
    "kpr": "kills_per_round",
    "apr": "assists_per_round",
    "fkfd": "first_kill_death_ratio",
    "fkpr": "first_kills_per_round",
    "fdpr": "first_deaths_per_round",
    "hsp": "headshot_percentage",
    "clp": "clutch_success_percentage",
    "cl": "clutch_attempts",
    "kmax": "max_kills",
    "k": "kills",
    "d": "deaths",
    "a": "assists",
    "fk": "first_kills",
    "fd": "first_deaths",
}

# If <thead> is keyed (>=1 data-col) but any of these is absent, the layout changed
# in a way we cannot safely parse -> fail closed rather than emit a keyed ``None``
# that would surface downstream as rating=0 and slip past shape guards.
REQUIRED_STATS_KEYS = frozenset({"rnd", "rating", "acs", "kd", "adr"})

# Pre-revamp data-col names, mapped to their current equivalents. Applied to the
# column map so a header that still says ``rating2``/``fbpr`` parses unchanged, and
# to the public ``sort`` parameter so historical callers keep working.
_LEGACY_DATA_COLS = {"rating2": "rating", "fbpr": "fkpr"}

# Legacy positional indices, used ONLY when <thead> emits no data-col attributes at
# all (pre-revamp markup / archived pages). Player is td[0], agents td[1].
_LEGACY_STATS_INDICES = {
    "rounds_played": 2,
    "rating": 3,
    "average_combat_score": 4,
    "kill_deaths": 5,
    "kill_assists_survived_traded": 6,
    "average_damage_per_round": 7,
    "kills_per_round": 8,
    "assists_per_round": 9,
    "first_kills_per_round": 10,
    "first_deaths_per_round": 11,
    "headshot_percentage": 12,
    "clutch_success_percentage": 13,
    "clutch_attempts": 14,
}

# Session priming state. vlr.gg binds /stats filter state to a ``PHPSESSID`` cookie:
# the FIRST request on a cold client returns the unfiltered global list regardless
# of ``region=``. The singleton httpx.AsyncClient shares cookies across concurrent
# requests, so the one-time prime is guarded by a lock + module flag.
_prime_lock = asyncio.Lock()
_primed = False

STATS_TIER_FILTERS = frozenset({"all", *STATS_TIERS})
STATS_SIDES = frozenset({"all", "t", "ct"})
STATS_ROLES = frozenset({"all", "controller", "initiator", "sentinel", "duelist"})
STATS_RATINGS = frozenset({0, 1300, 1400, 1500, 1550, 1650, 1750, 1850})
STATS_SORTS = frozenset(_STATS_FIELD_MAP)
DEFAULT_STATS_SORT = "rating"
STATS_DIRECTIONS = frozenset({"asc", "desc"})
_SAFE_SLUG = re.compile(r"^[a-z0-9-]+$")
_LEGACY_SPANS = {"30": "30d", "60": "60d", "90": "90d", "all": "all"}


@dataclass(frozen=True)
class StatsFilters:
    """Normalized vlr.gg /stats filters used by the request and cache key."""

    tier: str
    region: str
    span: str
    from_date: str | None
    to_date: str | None
    side: str
    role: str
    agent: str
    map_id: str
    min_rounds: int
    min_rating: int
    sort: str
    direction: str
    event_id: str = "all"

    def upstream_query(self) -> dict[str, str | int]:
        """The normalized logical filter set: cache key and echo-validation input."""
        query: dict[str, str | int] = {
            "sort": self.sort,
            "dir": self.direction,
            "tier": self.tier,
            "region": self.region,
            "span": self.span,
            "side": self.side,
            "role": self.role,
            "agent": self.agent,
            "map_id": self.map_id,
            "min_rounds": self.min_rounds,
            "min_rating": self.min_rating,
        }
        if self.event_id != "all":
            query["event_id"] = self.event_id
        if self.span == "custom":
            query["from"] = self.from_date or ""
            query["to"] = self.to_date or ""
        return query

    def query_pairs(self) -> list[tuple[str, str | int]]:
        """Encode the filters the way the revamped ``form.st-filter`` submits them.

        The region and tier groups are checkbox arrays (``region[]`` / ``tier[]``).
        The tier group is not optional: omit it and vlr.gg applies its own default
        of VCT alone (the form's ``data-defaults`` say tier=vct), narrowing the
        ladder to VCT events, so ``all`` sends every tier explicitly.

        Built as an explicit pair list rather than ``urlencode(..., doseq=True)``
        so that only the array-valued filters can repeat.
        """
        tiers = STATS_TIERS if self.tier == "all" else (self.tier,)
        pairs: list[tuple[str, str | int]] = [
            ("event_group_id", "all"),
            ("event_id", self.event_id),
            ("region[]", self.region),
            *(("tier[]", tier) for tier in tiers),
            ("country", "all"),
            ("span", self.span),
        ]
        if self.span == "custom":
            pairs += [("from", self.from_date or ""), ("to", self.to_date or "")]
        pairs += [
            ("side", self.side),
            ("role", self.role),
            ("agent", self.agent),
            ("map_id", self.map_id),
            ("min_rounds", self.min_rounds),
            ("min_rating", self.min_rating),
            ("sort", self.sort),
            ("dir", self.direction),
        ]
        return pairs

    def response_metadata(self) -> dict:
        metadata = asdict(self)
        metadata["from"] = metadata.pop("from_date")
        metadata["to"] = metadata.pop("to_date")
        metadata["dir"] = metadata.pop("direction")
        return metadata


def _bad_filter(name: str, value, valid: str) -> None:
    raise HTTPException(
        status_code=400,
        detail=f"Invalid stats {name} '{value}'. Valid values: {valid}",
    )


def _normalize_span(timespan: str | None, span: str | None) -> str:
    """Accept the historical API timespan and the current vlr.gg span name."""
    normalized_timespan = None
    if timespan is not None:
        validate_timespan(timespan)
        normalized_timespan = _LEGACY_SPANS[timespan]

    if span is None:
        if normalized_timespan is None:
            raise HTTPException(
                status_code=400,
                detail="One of 'timespan' or 'span' is required for stats",
            )
        return normalized_timespan

    normalized_span = _LEGACY_SPANS.get(span, span)
    valid_spans = {"30d", "60d", "90d", "custom", "all"}
    if normalized_span not in valid_spans:
        if not normalized_span.isdigit():
            _bad_filter("span", span, "30d, 60d, 90d, custom, 2020-current year, all")
        year = int(normalized_span)
        if year < 2020 or year > datetime.now(UTC).year:
            _bad_filter("span", span, "30d, 60d, 90d, custom, 2020-current year, all")

    if normalized_timespan is not None and normalized_timespan != normalized_span:
        raise HTTPException(
            status_code=400,
            detail=(
                "Conflicting stats window parameters: "
                f"timespan='{timespan}' resolves to '{normalized_timespan}' "
                f"but span='{span}' resolves to '{normalized_span}'"
            ),
        )
    return normalized_span


def _normalize_date_range(
    span: str,
    from_date: str | None,
    to_date: str | None,
) -> tuple[str | None, str | None]:
    if span != "custom":
        if from_date is not None or to_date is not None:
            raise HTTPException(
                status_code=400,
                detail="Stats 'from' and 'to' are only valid when span='custom'",
            )
        return None, None

    if not from_date or not to_date:
        raise HTTPException(
            status_code=400,
            detail="Stats span='custom' requires both 'from' and 'to' dates",
        )
    try:
        start = date.fromisoformat(from_date)
        end = date.fromisoformat(to_date)
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail="Stats 'from' and 'to' must use YYYY-MM-DD format",
        ) from exc

    earliest = date(2020, 1, 1)
    today = datetime.now(UTC).date()
    if start < earliest or end > today or start > end:
        raise HTTPException(
            status_code=400,
            detail=(
                "Invalid stats date range: dates must be between "
                f"{earliest.isoformat()} and {today.isoformat()}, with 'from' <= 'to'"
            ),
        )
    return start.isoformat(), end.isoformat()


def _normalize_slug(name: str, value: str) -> str:
    normalized = value.lower()
    if not _SAFE_SLUG.fullmatch(normalized):
        _bad_filter(name, value, "'all' or a lowercase vlr.gg slug")
    return normalized


def _normalize_min_rating(value) -> int:
    """Accept vlr.gg's x1000 integer scale (1550) or the 0-2 rating scale (1.55)."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        _bad_filter("min_rating", value, ", ".join(map(str, sorted(STATS_RATINGS))))
    if number < 10:
        number *= 1000
    rating = int(round(number))
    # vlr.gg only honours its radio values; anything else silently snaps to 0.
    if rating not in STATS_RATINGS:
        _bad_filter(
            "min_rating",
            value,
            ", ".join(map(str, sorted(STATS_RATINGS)))
            + " (or the same on the 0-2 scale, e.g. 1.55)",
        )
    return rating


def _normalize_map(map_id: str, map_name: str) -> str:
    """Merge the numeric ``map_id`` filter with the map-name filter."""
    map_id = (map_id or "all").lower()
    if map_id != "all" and not map_id.isdigit():
        _bad_filter("map_id", map_id, "'all' or a numeric vlr.gg map ID")
    from_name = validate_stats_map(map_name)
    if from_name == "all":
        return map_id
    if map_id not in ("all", from_name):
        raise HTTPException(
            status_code=400,
            detail=(
                f"Conflicting stats map parameters: map='{map_name}' is map_id "
                f"'{from_name}' but map_id='{map_id}' was also given"
            ),
        )
    return from_name


def normalize_stats_filters(
    region: str,
    timespan: str | None = None,
    event_id: str | None = None,
    map_name: str = "all",
    min_rounds: int = 200,
    min_rating: int | float = 1550,
    *,
    span: str | None = None,
    from_date: str | None = None,
    to_date: str | None = None,
    tier: str = "all",
    side: str = "all",
    role: str = "all",
    agent: str = "all",
    map_id: str = "all",
    sort: str = DEFAULT_STATS_SORT,
    direction: str = "desc",
) -> StatsFilters:
    """Validate and normalize the public stats filter contract.

    The positional parameters follow the upstream signature (region, timespan,
    event_id, map name, min_rounds, min_rating); the vlr.gg filter-form options
    are keyword-only.
    """
    region = validate_stats_region(region.lower())
    effective_span = _normalize_span(timespan.lower() if timespan else None, span.lower() if span else None)
    from_date, to_date = _normalize_date_range(effective_span, from_date, to_date)

    tier = tier.lower()
    side = side.lower()
    role = role.lower()
    sort = sort.lower()
    sort = _LEGACY_DATA_COLS.get(sort, sort)
    direction = direction.lower()
    if event_id in (None, ""):
        event_id = "all"
    event_id = str(event_id)
    if event_id != "all" and not event_id.isdigit():
        raise HTTPException(status_code=400, detail="event_id must be a numeric ID")
    if tier not in STATS_TIER_FILTERS:
        _bad_filter("tier", tier, ", ".join(sorted(STATS_TIER_FILTERS)))
    if side not in STATS_SIDES:
        _bad_filter("side", side, ", ".join(sorted(STATS_SIDES)))
    if role not in STATS_ROLES:
        _bad_filter("role", role, ", ".join(sorted(STATS_ROLES)))
    if sort not in STATS_SORTS:
        _bad_filter("sort", sort, ", ".join(sorted(STATS_SORTS)))
    if direction not in STATS_DIRECTIONS:
        _bad_filter("dir", direction, ", ".join(sorted(STATS_DIRECTIONS)))
    if not 0 <= min_rounds <= 999:
        _bad_filter("min_rounds", min_rounds, "an integer from 0 to 999")
    min_rating = _normalize_min_rating(min_rating)

    agent = _normalize_slug("agent", agent)
    map_id = _normalize_map(map_id, map_name)

    return StatsFilters(
        tier=tier,
        region=region,
        span=effective_span,
        from_date=from_date,
        to_date=to_date,
        side=side,
        role=role,
        agent=agent,
        map_id=map_id,
        min_rounds=min_rounds,
        min_rating=min_rating,
        sort=sort,
        direction=direction,
        event_id=event_id,
    )


def _cell_text(cells: list, index: int | None) -> str:
    """Read a table cell by index without raising on sparse rows or missing keys."""
    if index is None or index >= len(cells):
        return ""
    return extract_text_content(cells[index])


def _build_column_map(html) -> dict | None:
    """Map each <thead> ``data-col`` attribute to its 0-based column index.

    Returns ``{data-col: index}`` when the header is keyed, or ``None`` when it
    carries no data-col attributes (old markup -> positional fallback). Indices are
    counted across all <th>, so they line up with the row's <td> positions; the
    player <th> is unlabelled and is simply absent from the map.
    """
    header = html.css_first("thead tr")
    if header is None:
        return None
    col_map: dict[str, int] = {}
    for index, th in enumerate(header.css("th")):
        data_col = th.attributes.get("data-col")
        if data_col:
            col_map[data_col] = index
    for legacy, current in _LEGACY_DATA_COLS.items():
        if legacy in col_map and current not in col_map:
            col_map[current] = col_map[legacy]
    return col_map or None


def _parse_stats_row(item, col_map: dict | None = None) -> dict:
    """Parse one stats table row.

    With ``col_map`` (from :func:`_build_column_map`) cells are read by semantic
    ``data-col`` key; without it, the legacy positional indices are used. The player
    cell is always positional ``td[0]``. The org selector tries the new
    ``.st-pl-country`` class first and falls back to the pre-revamp
    ``.stats-player-country`` so either markup parses.
    """
    cells = item.css("td")
    player_cell = item.css_first("td.mod-player")

    player_link = player_cell.css_first("a") if player_cell else None
    player_href = player_link.attributes.get("href", "") if player_link else ""
    player_id, _ = parse_href_id_slug(player_href)
    player_name = extract_text_content(player_cell.css_first(".text-of")) if player_cell else ""
    flag = player_cell.css_first(".flag") if player_cell else None
    flag_classes = flag.attributes.get("class", "") if flag else ""
    country = next(
        (part.removeprefix("mod-") for part in flag_classes.split() if part.startswith("mod-")),
        "",
    )
    org_cell = None
    if player_cell:
        org_cell = (
            player_cell.css_first(".st-pl-country")
            or player_cell.css_first(".stats-player-country")
        )
    org = extract_text_content(org_cell) if org_cell else ""
    if not org:
        org = "N/A"

    agents = []
    agent_usage = []
    for agent_node in item.css("td.mod-agents .st-agent"):
        agent_img = agent_node.css_first("img")
        if agent_img is None:
            continue
        src = agent_img.attributes.get("src", "")
        if not src:
            continue
        agent_name = src.split("/")[-1].split(".")[0]
        usage = extract_text_content(agent_node.css_first(".st-agent-n"))
        agents.append(agent_name)
        agent_usage.append({"agent": agent_name, "usage": usage})

    # Archived/legacy rows have bare images without the current .st-agent wrapper.
    if not agents:
        for agent_img in item.css("td.mod-agents img"):
            src = agent_img.attributes.get("src", "")
            if not src:
                continue
            agent_name = src.split("/")[-1].split(".")[0]
            agents.append(agent_name)
            agent_usage.append({"agent": agent_name, "usage": ""})

    row = {
        "player": player_name,
        "player_id": player_id,
        "player_url": build_full_url(player_href),
        "country": country,
        "org": org,
        "agents": agents,
        "agent_usage": agent_usage,
    }
    if col_map is not None:
        for data_col, out_key in _STATS_FIELD_MAP.items():
            row[out_key] = _cell_text(cells, col_map.get(data_col))
    else:
        for out_key, index in _LEGACY_STATS_INDICES.items():
            row[out_key] = _cell_text(cells, index)

    # KMAX links identify the match and individual game where the maximum occurred.
    kmax_index = col_map.get("kmax") if col_map is not None else None
    kmax_cell = cells[kmax_index] if kmax_index is not None and kmax_index < len(cells) else None
    kmax_link = kmax_cell.css_first("a") if kmax_cell else None
    kmax_href = kmax_link.attributes.get("href", "") if kmax_link else ""
    max_kills_match_id, _ = parse_href_id_slug(kmax_href)
    max_kills_game_id = parse_qs(urlparse(kmax_href).query).get("game", [""])[0]
    row.update(
        {
            "max_kills_match_id": max_kills_match_id,
            "max_kills_game_id": max_kills_game_id,
            "max_kills_match_url": build_full_url(kmax_href),
        }
    )
    return row


def _selected_region(html) -> str | None:
    """Return the region vlr.gg actually applied to this response.

    This is the ground truth of which filter the server used. The October 2026
    revamp replaced the ``<select name="region">`` with a ``form.st-filter``
    whose regions are ``<input name="region[]">`` checkboxes, so the applied
    value is now the one carrying ``checked``; a form with nothing ticked means
    no region restriction ("all"). The legacy select is still read as a
    fallback. Returns ``None`` when neither shape is present, so callers skip
    response validation on markup we do not model.
    """
    return _echoed_filter(html, "region")


def _echoed_filter(html, name: str) -> str | None:
    """Read a filter value echoed by vlr.gg, or None when the control is absent.

    Current markup (``form.st-filter``): checkbox groups are ``name[]`` arrays
    whose ticked values were applied (nothing ticked == ``all``); radio groups
    echo the ``checked`` option; hidden/text inputs echo their ``value``.
    Pre-revamp markup used ``<select>`` elements and plain inputs.
    """
    form = html.css_first("form.st-filter")
    if form is not None:
        boxes = form.css(f'input[name="{name}[]"]')
        if boxes:
            checked = sorted(
                box.attributes.get("value") or ""
                for box in boxes
                if "checked" in box.attributes
            )
            return ",".join(checked) if checked else "all"
        inputs = form.css(f'input[name="{name}"]')
        if inputs:
            if any(node.attributes.get("type") == "radio" for node in inputs):
                checked = [node for node in inputs if "checked" in node.attributes]
                return (checked[0].attributes.get("value") or "") if checked else ""
            return inputs[0].attributes.get("value") or ""

    select = html.css_first(f'select[name="{name}"]')
    if select is not None:
        selected = select.css_first("option[selected]")
        if selected is None:
            return None
        value = selected.attributes.get("value")
        return value if value is not None else (extract_text_content(selected) or None)

    if form is None:
        input_node = html.css_first(f'input[name="{name}"]')
        if input_node is not None:
            return input_node.attributes.get("value", "")
    return None


# Filters vlr.gg does not echo faithfully: ticking a role pre-ticks every agent of
# that role, and the event filter is not a form control at all.
_UNECHOED_FILTERS = frozenset({"agent", "event_id"})


def _filter_mismatches(html, filters: StatsFilters) -> dict[str, tuple[str, str]]:
    """Return requested/applied mismatches for controls present in the response."""
    expected = {
        str(key): str(value)
        for key, value in filters.upstream_query().items()
        if key not in _UNECHOED_FILTERS
    }
    mismatches = {}
    for name, requested in expected.items():
        applied = _echoed_filter(html, name)
        if applied is not None and applied != requested:
            mismatches[name] = (requested, applied)
    return mismatches


async def _fetch_stats_page(client, url: str) -> tuple[int, object]:
    """Fetch the stats page, raising on an upstream error status; return (status, tree)."""
    resp = await fetch_with_retries(url, client=client)
    raise_for_upstream_status(resp.status_code, "stats")
    return resp.status_code, parse_html(resp.text)


async def _prime_session(client, *, force: bool = False) -> None:
    """Issue one throwaway GET to the /stats page so vlr.gg sets ``PHPSESSID``.

    Guarded by a lock + module flag so the singleton client primes once per boot,
    not once per call. Raises on failure — a cold response must never be fetched
    (and cached for ``CACHE_TTL_STATS`` seconds) unfiltered. ``force=True`` re-primes
    after a detected region mismatch.
    """
    global _primed
    async with _prime_lock:
        if _primed and not force:
            return
        resp = await fetch_with_retries(f"{VLR_STATS_URL}/", client=client)
        raise_for_upstream_status(resp.status_code, "stats prime")
        _primed = True


@handle_scraper_errors
async def vlr_stats(
    region_key: str,
    timespan: str | None = None,
    event_id: str | None = None,
    map_name: str = "all",
    min_rounds: int = 200,
    min_rating: int | float = 1550,
    *,
    span: str | None = None,
    from_date: str | None = None,
    to_date: str | None = None,
    tier: str = "all",
    side: str = "all",
    role: str = "all",
    agent: str = "all",
    map_id: str = "all",
    sort: str = DEFAULT_STATS_SORT,
    direction: str = "desc",
):
    # Normalize aliases and every filter BEFORE forming the cache key. The defaults
    # intentionally preserve the historical API result set while callers can opt
    # into vlr.gg's current site defaults (min_rounds=100, min_rating=0).
    filters = normalize_stats_filters(
        region_key,
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
        direction=direction,
    )

    async def build():
        url = f"{VLR_STATS_URL}/?{urlencode(filters.query_pairs())}"

        client = get_http_client()
        await _prime_session(client)

        status, html = await _fetch_stats_page(client, url)

        # Response-level validation is the correctness signal (not cookie presence).
        # Validate every filter control the page echoes. On any mismatch, re-prime
        # and refetch once; a second mismatch fails closed rather than caching data
        # under filters vlr.gg silently ignored.
        mismatches = _filter_mismatches(html, filters)
        if mismatches:
            logger.warning(
                "VLR.GG /stats filter mismatch %s; re-priming",
                mismatches,
            )
            await _prime_session(client, force=True)
            status, html = await _fetch_stats_page(client, url)
            mismatches = _filter_mismatches(html, filters)
            if mismatches:
                details = ", ".join(
                    f"{name}: requested '{requested}', applied '{applied}'"
                    for name, (requested, applied) in sorted(mismatches.items())
                )
                raise HTTPException(
                    status_code=502,
                    detail=f"VLR.GG /stats ignored requested filters: {details}",
                )

        col_map = _build_column_map(html)
        if col_map is not None:
            missing = REQUIRED_STATS_KEYS - col_map.keys()
            if missing:
                raise HTTPException(
                    status_code=502,
                    detail=(
                        "VLR.GG /stats column layout changed: required columns "
                        f"{sorted(missing)} missing from header"
                    ),
                )
        elif html.css_first("table") is not None:
            # A table without data-col attributes is genuinely legacy markup. A page
            # with NO table at all is a legitimately-empty result set (vlr.gg renders
            # no table for zero rows, e.g. sparse tier/span windows) — stay quiet.
            logger.warning(
                "VLR.GG /stats header has no data-col attributes; "
                "falling back to legacy positional column indices"
            )

        result = []
        for item in html.css("tbody tr"):
            parsed = _parse_stats_row(item, col_map)
            if parsed["player"]:
                result.append(parsed)

        return {
            "data": {
                "status": status,
                "filters": filters.response_metadata(),
                "segments": result,
            }
        }

    return await cache_manager.get_or_create_async(
        CACHE_TTL_STATS,
        build,
        "stats",
        filters.upstream_query(),
    )
