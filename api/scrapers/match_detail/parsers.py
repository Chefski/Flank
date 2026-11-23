"""
HTML parsers for VLR.GG match detail page components.

Covers header parsing, per-map game stats, head-to-head history,
performance tab (kill matrix + advanced), and economy tab.
"""
import logging
import re
from datetime import UTC, datetime
from urllib.parse import urlparse

from utils.html_parsers import (
    HTMLParser,
    build_full_url,
    extract_text_content,
    normalize_image_url,
    parse_href_id_slug,
)
from utils.id_mapper import id_mapper

logger = logging.getLogger(__name__)

_ROUND_METHODS = {
    "boom": "spike_exploded",
    "defuse": "spike_defused",
    "elim": "elimination",
    "time": "time_expired",
}


def _class_modifier(node, prefix: str = "mod-") -> str:
    if node is None:
        return ""
    return next(
        (
            part.removeprefix(prefix)
            for part in node.attributes.get("class", "").split()
            if part.startswith(prefix)
        ),
        "",
    )


def _scheduled_at(value: str) -> str:
    if not value:
        return ""
    try:
        return (
            datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
            .replace(tzinfo=UTC)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except ValueError:
        return ""


def _media_platform(url: str, name: str = "") -> str:
    host = urlparse(url).netloc.lower().removeprefix("www.")
    haystack = f"{host} {name}".lower()
    for token, platform in (
        ("twitch", "twitch"),
        ("youtu", "youtube"),
        ("bilibili", "bilibili"),
        ("douyu", "douyu"),
        ("huya", "huya"),
        ("afreeca", "afreecatv"),
        ("soop", "soop"),
        ("chzzk", "chzzk"),
        ("kick", "kick"),
    ):
        if token in haystack:
            return platform
    return host.split(".", 1)[0] if host else ""


# ---------------------------------------------------------------------------
# Header section parsers
# ---------------------------------------------------------------------------

def _parse_event_info(html: HTMLParser) -> dict:
    """Extract the canonical event identity, stage, series, and logo."""
    event_id = ""
    event_name = ""
    event_series = ""
    event_logo = ""
    event_url = ""
    stage = ""

    event_link = html.css_first(".match-header-event")
    if event_link:
        href = event_link.attributes.get("href", "")
        event_id, _ = parse_href_id_slug(href)
        event_url = build_full_url(href)
        parts = [part for part in urlparse(href).path.split("/") if part]
        if len(parts) >= 4:
            stage = parts[-1]

        series_elem = event_link.css_first(".match-header-event-series")
        if series_elem:
            event_series = extract_text_content(series_elem)

        wrapper = series_elem.parent if series_elem else None
        if wrapper:
            for node in wrapper.css("div"):
                if "match-header-event-series" not in node.attributes.get("class", ""):
                    event_name = node.text(deep=False, strip=True)
                    if event_name:
                        break
        if not event_name:
            combined = extract_text_content(event_link)
            event_name = combined.removesuffix(event_series).strip()

    if not event_name:
        super_elem = html.css_first(".match-header-super")
        first_div = super_elem.css_first("div") if super_elem else None
        legacy_link = first_div.css_first("a") if first_div else None
        event_name = extract_text_content(legacy_link or first_div)
        if legacy_link and not event_url:
            href = legacy_link.attributes.get("href", "")
            event_id, _ = parse_href_id_slug(href)
            event_url = build_full_url(href)
        if super_elem and not event_series:
            event_series = extract_text_content(
                super_elem.css_first(".match-header-event-series")
            )

    logo_elem = html.css_first(".match-header-event img")
    if logo_elem:
        src = logo_elem.attributes.get("src", "")
        event_logo = normalize_image_url(src)

    return {
        "id": event_id,
        "name": event_name,
        "series": event_series,
        "stage": stage,
        "url": event_url,
        "logo": event_logo,
    }


def _parse_match_header(html: HTMLParser) -> dict:
    """Extract exact scheduling, patch, status, format, notes, and vetoes."""
    date = ""
    utc_timestamp = ""
    patch = ""
    status = ""
    match_format = ""
    map_vetos = ""
    notes: list[str] = []

    date_elem = html.css_first(".match-header-date")
    if date_elem:
        moment_nodes = date_elem.css(".moment-tz-convert")
        date = " ".join(
            value
            for value in (extract_text_content(node) for node in moment_nodes[:2])
            if value
        )
        if not date:
            date = extract_text_content(date_elem)
        utc_timestamp = next(
            (
                node.attributes["data-utc-ts"]
                for node in moment_nodes
                if node.attributes.get("data-utc-ts")
            ),
            "",
        )
        patch_match = re.search(r"\bPatch\s+([^\s]+)", extract_text_content(date_elem))
        if patch_match:
            patch = patch_match.group(1)

    for note_elem in html.css(".match-header-note"):
        note = extract_text_content(note_elem)
        if not note:
            continue
        if re.search(r"\b(?:ban|pick|remains)\b", note, re.IGNORECASE):
            map_vetos = note
        else:
            notes.append(note)

    for vs_note_elem in html.css(".match-header-vs-note"):
        value = extract_text_content(vs_note_elem)
        if not value:
            continue
        if re.fullmatch(r"Bo\d+", value, re.IGNORECASE):
            match_format = value
        elif not status:
            status = value

    return {
        "date": date,
        "utc_timestamp": utc_timestamp,
        "scheduled_at": _scheduled_at(utc_timestamp),
        "patch": patch,
        "map_vetos": map_vetos,
        "notes": notes,
        "status": status,
        "format": match_format,
    }


def _is_live(html: HTMLParser) -> bool:
    """Return True if the match header indicates the match is currently LIVE."""
    vs_note_elem = html.css_first(".match-header-vs-note")
    if not vs_note_elem:
        return False
    return "LIVE" in extract_text_content(vs_note_elem).upper()


def _parse_teams(html: HTMLParser) -> list[dict]:
    """
    Extract both team entries from the match header.

    Returns a two-element list. Each entry contains name, tag, logo,
    score, and is_winner flag.
    """
    teams: list[dict] = []

    for mod in ("mod-1", "mod-2"):
        team_id = ""
        team_url = ""
        link_elem = html.css_first(f".match-header-link.{mod}")
        if link_elem:
            href = link_elem.attributes.get("href", "")
            team_id, _ = parse_href_id_slug(href)
            team_url = build_full_url(href)

        name_elem = html.css_first(f".match-header-link-name.{mod}")
        name = ""
        tag = ""
        if name_elem:
            full_text = name_elem.text()
            lines = [ln.strip() for ln in full_text.splitlines() if ln.strip()]
            if lines:
                name = lines[0]
            if len(lines) > 1:
                tag = lines[1]

        teams.append(
            {
                "id": team_id,
                "name": name,
                "tag": tag,
                "url": team_url,
                "logo": "",
                "score": "",
                "is_winner": False,
            }
        )
        id_mapper.register_team(name, team_id)

    vs_elem = html.css_first(".match-header-vs")
    if vs_elem:
        logos = vs_elem.css("img")
        for idx, img in enumerate(logos[:2]):
            src = img.attributes.get("src", "")
            if src:
                teams[idx]["logo"] = normalize_image_url(src)

    score_elems = html.css(".match-header-vs-score span")
    winner_idx = -1

    scored_spans = [
        (span.attributes.get("class") or "", span.text(strip=True))
        for span in score_elems
        if span.text(strip=True).isdigit()
    ]

    if len(scored_spans) >= 2:
        cls0, val0 = scored_spans[0]
        cls1, val1 = scored_spans[1]
        teams[0]["score"] = val0
        teams[1]["score"] = val1
        if "match-header-vs-score-winner" in cls0:
            winner_idx = 0
        elif "match-header-vs-score-winner" in cls1:
            winner_idx = 1

    if winner_idx >= 0:
        teams[winner_idx]["is_winner"] = True

    return teams


def _external_link(entry) -> str:
    """Return the outbound URL of a watch-module entry.

    vlr.gg renders each stream/VOD as a ``.sm-btn`` / ``.sm-vod`` block whose
    clickable body is a plain ``<div class="sm-body js-stream-embed-btn">``
    (it opens an inline player via JS) plus a sibling
    ``<a class="sm-ext">`` holding the real outbound URL.
    """
    anchor = entry.css_first("a.sm-ext") or entry.css_first("a[href]")
    if anchor:
        return anchor.attributes.get("href", "") or ""
    return ""


def _parse_streams_vods(html: HTMLParser) -> tuple[list[dict], list[dict]]:
    """Extract stream buttons and VOD links from the match page.

    Current markup uses the ``sm-*`` watch module: streams are ``.sm-btn``
    entries inside ``.sm-pane-streams`` and VODs are ``.sm-vod`` entries
    inside ``.sm-pane-vods``. The pre-redesign ``.match-streams-btn`` /
    ``.match-vods`` markup is still parsed as a fallback.
    """
    streams: list[dict] = []
    vods: list[dict] = []

    for btn in html.css(".sm-btn"):
        name_elem = btn.css_first(".sm-name")
        name = extract_text_content(name_elem) if name_elem else extract_text_content(btn)
        href = _external_link(btn)
        if name or href:
            url = build_full_url(href)
            embed = btn.css_first(".js-stream-embed-btn")
            flag = btn.css_first(".flag")
            platform = btn.attributes.get("data-site", "") or _media_platform(url, name)
            streams.append(
                {
                    "name": name,
                    "url": url,
                    "platform": platform,
                    "country_code": _class_modifier(flag),
                    "is_embedded": "mod-embed" in btn.attributes.get("class", ""),
                    "site_id": embed.attributes.get("data-site-id", "") if embed else "",
                }
            )

    for vod in html.css(".sm-vod"):
        name_elem = vod.css_first(".sm-vod-name")
        name = extract_text_content(name_elem) if name_elem else extract_text_content(vod)
        href = _external_link(vod)
        if name or href:
            map_match = re.search(r"\bMap\s+(\d+)\b", name, re.IGNORECASE)
            vods.append(
                {
                    "name": name,
                    "url": build_full_url(href),
                    "platform": _media_platform(href, name),
                    "map_number": int(map_match.group(1)) if map_match else None,
                }
            )

    if streams or vods:
        return streams, vods

    # Legacy markup fallback (.match-streams-btn / .match-vods).
    for btn in html.css(".match-streams-btn"):
        external = btn if btn.tag == "a" else btn.css_first(".match-streams-btn-external")
        href = external.attributes.get("href", "") if external else ""
        label = btn.css_first(".match-streams-btn-embed span")
        name = extract_text_content(label) or extract_text_content(btn)
        if name or href:
            url = build_full_url(href)
            embed = btn.css_first(".js-stream-embed-btn")
            flag = btn.css_first(".flag")
            streams.append(
                {
                    "name": name,
                    "url": url,
                    "platform": _media_platform(url, name),
                    "country_code": _class_modifier(flag),
                    "is_embedded": "mod-embed" in btn.attributes.get("class", ""),
                    "site_id": embed.attributes.get("data-site-id", "") if embed else "",
                }
            )

    vods_container = html.css_first(".match-vods")
    if vods_container:
        for anchor in vods_container.css("a"):
            href = anchor.attributes.get("href", "")
            name = extract_text_content(anchor)
            if name or href:
                map_match = re.search(r"\bMap\s+(\d+)\b", name, re.IGNORECASE)
                vods.append(
                    {
                        "name": name,
                        "url": build_full_url(href),
                        "platform": _media_platform(href, name),
                        "map_number": int(map_match.group(1)) if map_match else None,
                    }
                )

    return streams, vods


# ---------------------------------------------------------------------------
# Per-map game data parsers
# ---------------------------------------------------------------------------

_PLAYER_STAT_FIELDS = {
    "rating2": "rating",
    "acs": "acs",
    "kills": "kills",
    "deaths": "deaths",
    "assists": "assists",
    "kd-diff": "kd_diff",
    "kast": "kast",
    "adr": "adr",
    "hsp": "hs_pct",
    "fb": "fk",
    "fd": "fd",
    "fk-diff": "fk_diff",
}


def _side_text(node, modifier: str) -> str:
    side = node.css_first(f".side.{modifier}") if node else None
    return extract_text_content(side)


def _empty_side_stats() -> dict[str, str]:
    return {field: "" for field in _PLAYER_STAT_FIELDS.values()}


def _player_payload(
    player_cell,
    *,
    agent_image=None,
    side_stats: dict[str, dict[str, str]],
) -> dict:
    link = player_cell.css_first("a") if player_cell else None
    href = link.attributes.get("href", "") if link else ""
    player_id, _ = parse_href_id_slug(href)
    name_node = (
        player_cell.css_first(".ovw-player-name")
        or player_cell.css_first(".text-of")
        if player_cell
        else None
    )
    name = extract_text_content(name_node) or extract_text_content(link)
    flag = player_cell.css_first(".flag") if player_cell else None
    team_tag = ""
    if player_cell:
        team_tag = extract_text_content(
            player_cell.css_first(".ovw-player-tag")
            or player_cell.css_first(".stats-player-country")
        )
    agent = ""
    agent_slug = ""
    if agent_image:
        agent = _agent_from_img(agent_image)
        src = agent_image.attributes.get("src", "")
        agent_slug = (
            urlparse(src).path.rsplit("/", 1)[-1].split(".", 1)[0]
            if src
            else agent.lower()
        )

    return {
        "player_id": player_id,
        "player_url": build_full_url(href),
        "name": name,
        "country": _class_modifier(flag),
        "team_tag": team_tag,
        "agent": agent,
        "agent_slug": agent_slug,
        **side_stats["overall"],
        "attack": side_stats["attack"],
        "defense": side_stats["defense"],
    }


_AGENT_SLUG_NAMES = {"kayo": "KAY/O"}


def _agent_from_img(img) -> str:
    """Agent display name from an agent icon: title, alt, then the src slug.

    vlr.gg has shipped agent icons with no ``title``/``alt`` at all, leaving the
    src as the only clue, so the slug is a real fallback rather than a guard.
    """
    if img is None:
        return ""
    for attr in ("title", "alt"):
        value = (img.attributes.get(attr, "") or "").strip()
        if value:
            return value
    src = img.attributes.get("src", "") or ""
    if "/agents/" not in src:
        return ""
    slug = src.rsplit("/", 1)[-1].rsplit(".", 1)[0].strip().lower()
    if not slug:
        return ""
    return _AGENT_SLUG_NAMES.get(slug, slug.replace("-", " ").title())


def _parse_player_row_div(player_cell, stat_cells: list) -> dict:
    """Parse a single player from the new ovw-cell div-based layout.

    Each player spans a ``mod-player`` cell with the name, then 10 stat cells
    keyed by ``data-col`` (rating2, acs, kills, kd-diff, kast, adr, hsp, fb,
    fd, fk-diff).

    The agent icon lives in its own ``mod-agents`` cell *beside* the player
    cell since late 2026; it used to be nested inside it, so both places are
    read and a player with no agent cell simply leaves the field empty (#247).

    The ``data-col="kills"`` cell is special: it uses ``.mod-kda`` and
    contains kills / deaths / assists inside ``.ovw-kda-stat`` sub-elements.
    """
    agents_cell = player_cell.css_first(".ovw-agents")
    if agents_cell is None:
        for cell in stat_cells:
            if "mod-agents" in (cell.attributes.get("class", "") or ""):
                agents_cell = cell
                break
    agent_image = agents_cell.css_first("img") if agents_cell is not None else None
    side_stats = {
        "overall": _empty_side_stats(),
        "attack": _empty_side_stats(),
        "defense": _empty_side_stats(),
    }
    for cell in stat_cells:
        cls = cell.attributes.get("class", "") or ""
        if "mod-kda" in cls:
            for stat in cell.css(".ovw-kda-stat"):
                output_key = _PLAYER_STAT_FIELDS.get(stat.attributes.get("data-col", ""))
                if output_key:
                    side_stats["overall"][output_key] = _side_text(stat, "mod-both")
                    side_stats["attack"][output_key] = _side_text(stat, "mod-t")
                    side_stats["defense"][output_key] = _side_text(stat, "mod-ct")
            continue

        data_col = cell.attributes.get("data-col", "")
        output_key = _PLAYER_STAT_FIELDS.get(data_col)
        if not output_key:
            continue
        side_stats["overall"][output_key] = (
            _side_text(cell, "mod-both") or extract_text_content(cell)
        )
        side_stats["attack"][output_key] = _side_text(cell, "mod-t")
        side_stats["defense"][output_key] = _side_text(cell, "mod-ct")

    return _player_payload(
        player_cell,
        agent_image=agent_image,
        side_stats=side_stats,
    )


def _parse_map_players(game_elem) -> dict:
    """Parse per-team player stats from the ovw-cell div-based layout.

    VLR now renders player stats as a flat sequence of ``.ovw-cell`` divs.
    Each player starts at a ``.ovw-cell.mod-player`` (name) and continues until
    the next one: an optional ``.ovw-cell.mod-agents`` followed by 10 stat
    cells. The first 5 players are team 1, the next 5 are team 2. Falls back to
    the old ``table.wf-table-inset.mod-overview`` format when present.
    """
    team1_players: list[dict] = []
    team2_players: list[dict] = []

    all_cells = game_elem.css(".ovw-cell")

    def is_player_cell(cell) -> bool:
        return "mod-player" in (cell.attributes.get("class", "") or "")

    # Group cells by the boundaries between ``.mod-player`` cells rather than
    # dividing a flat list. vlr.gg added a separate ``.mod-agents`` cell per
    # player (#247), so the per-player cell count is no longer fixed: a player
    # missing its agent cell would shift every later player's stats by one.
    groups: list[tuple] = []
    for cell in all_cells:
        if is_player_cell(cell):
            groups.append((cell, []))
        elif groups:
            groups[-1][1].append(cell)

    player_count = len(groups)

    def parse_players_from_range(start: int, count: int) -> list[dict]:
        players = []
        for player_cell, stat_group in groups[start:start + count]:
            try:
                players.append(_parse_player_row_div(player_cell, stat_group))
            except Exception as exc:
                logger.debug("Skipping player row due to parse error: %s", exc)
        return players

    if player_count >= 2:
        half = player_count // 2
        team1_players = parse_players_from_range(0, half)
        team2_players = parse_players_from_range(half, player_count - half)

    if not team1_players and not team2_players:
        tables = game_elem.css("table.wf-table-inset.mod-overview")

        def parse_table_rows(table) -> list[dict]:
            players = []
            for row in table.css("tbody tr"):
                cells = row.css("td")
                if not cells or len(cells) < 5:
                    continue
                try:
                    p = _parse_player_row_table(cells)
                    if p["name"]:
                        players.append(p)
                except Exception as exc:
                    logger.debug("Skipping player row: %s", exc)
            return players

        if len(tables) >= 1:
            team1_players = parse_table_rows(tables[0])
        if len(tables) >= 2:
            team2_players = parse_table_rows(tables[1])

    return {"team1": team1_players, "team2": team2_players}


def _parse_player_row_table(cells: list) -> dict:
    """Legacy parser for old table-based player stats (14 <td> cells)."""

    def cell_val(cell, modifier: str = "mod-both") -> str:
        if not cell:
            return ""
        value = _side_text(cell, modifier)
        if value:
            return value
        return extract_text_content(cell) if modifier == "mod-both" else ""

    indices = {
        "rating": 2,
        "acs": 3,
        "kills": 4,
        "deaths": 5,
        "assists": 6,
        "kd_diff": 7,
        "kast": 8,
        "adr": 9,
        "hs_pct": 10,
        "fk": 11,
        "fd": 12,
        "fk_diff": 13,
    }
    side_stats = {
        "overall": _empty_side_stats(),
        "attack": _empty_side_stats(),
        "defense": _empty_side_stats(),
    }
    for output_key, index in indices.items():
        if index >= len(cells):
            continue
        side_stats["overall"][output_key] = cell_val(cells[index])
        side_stats["attack"][output_key] = cell_val(cells[index], "mod-t")
        side_stats["defense"][output_key] = cell_val(cells[index], "mod-ct")

    player_cell = cells[0] if cells else None
    agent_image = cells[1].css_first("img") if len(cells) > 1 else None
    return _player_payload(
        player_cell,
        agent_image=agent_image,
        side_stats=side_stats,
    )


def _parse_map_scores(game_elem) -> dict:
    """
    Extract team scores and CT/T/OT splits from a single game header.
    """
    result = {
        "score": {"team1": "", "team2": ""},
        "score_ct": {"team1": "", "team2": ""},
        "score_t": {"team1": "", "team2": ""},
        "score_ot": {"team1": "", "team2": ""},
    }

    header = game_elem.css_first(".vm-stats-game-header")
    if not header:
        return result

    team_blocks = header.css(".team")
    keys = ["team1", "team2"]

    for idx, block in enumerate(team_blocks[:2]):
        key = keys[idx]

        score_el = block.css_first(".score")
        if score_el:
            val = score_el.text(strip=True)
            try:
                result["score"][key] = int(val)
            except (ValueError, TypeError):
                result["score"][key] = val

        ct_els = block.css(".mod-ct")
        ct_val = ""
        for ct in ct_els:
            txt = ct.text(strip=True)
            if txt and ct.tag != "span":
                ct_val = txt
        if not ct_val:
            for ct in ct_els:
                if ct.tag == "span":
                    ct_val = ct.text(strip=True)
                    break
        result["score_ct"][key] = ct_val

        t_els = block.css(".mod-t")
        t_val = ""
        for t in t_els:
            txt = t.text(strip=True)
            if txt and t.tag != "span":
                t_val = txt
        if not t_val:
            for t in t_els:
                if t.tag == "span":
                    t_val = t.text(strip=True)
                    break
        result["score_t"][key] = t_val

        ot_els = block.css(".mod-ot")
        ot_val = ""
        for ot in ot_els:
            txt = ot.text(strip=True)
            if txt:
                ot_val = txt
                break
        result["score_ot"][key] = ot_val

    return result


def _parse_rounds(game_elem) -> list[dict]:
    """
    Parse round winners, sides, score progression, and ending methods.

    vlr.gg renders every potential round slot, so a map that ended 13-9 still
    shows 24 columns: the unplayed ones carry no ``mod-win`` square. Those are
    skipped rather than reported as played rounds with an empty winner.

    A round icon names how the round was won (``elim``, ``boom``, ``defuse``,
    ``time``); it sits on the winning square, so it is read there. The code is
    exposed both as ``method_code`` and upstream's ``win_type``.
    """
    rounds: list[dict] = []
    rounds_container = game_elem.css_first(".vlr-rounds")
    if not rounds_container:
        return rounds

    for row in rounds_container.css(".vlr-rounds-row"):
        for col in row.css(".vlr-rounds-row-col"):
            cls = col.attributes.get("class", "")
            if "mod-spacing" in cls:
                continue

            sqs = col.css(".rnd-sq")
            if not sqs:
                continue

            winner = ""
            winning_side = ""
            winner_square = None
            for idx, sq in enumerate(sqs):
                sq_cls = sq.attributes.get("class", "")
                if "mod-win" in sq_cls:
                    winner = "team1" if idx == 0 else "team2"
                    winner_square = sq
                    if "mod-ct" in sq_cls:
                        winning_side = "ct"
                    elif "mod-t" in sq_cls:
                        winning_side = "t"
                    break

            # VLR renders placeholder squares for future/unplayed rounds. They do
            # not represent outcomes and must not inflate the round count.
            if winner_square is None:
                continue

            round_text = extract_text_content(col.css_first(".rnd-num"))
            try:
                round_num = int(round_text)
            except (TypeError, ValueError):
                round_num = len(rounds) + 1

            method_icon = winner_square.css_first("img")
            method_src = method_icon.attributes.get("src", "") if method_icon else ""
            method_code = (
                urlparse(method_src).path.rsplit("/", 1)[-1].split(".", 1)[0]
                if method_src
                else ""
            )
            score_text = col.attributes.get("title", "")
            score_match = re.fullmatch(r"(\d+)\s*-\s*(\d+)", score_text)
            score_after = {
                "team1": int(score_match.group(1)) if score_match else None,
                "team2": int(score_match.group(2)) if score_match else None,
            }

            rounds.append(
                {
                    "round_num": round_num,
                    "winner": winner,
                    "side": winning_side,
                    "side_name": (
                        "defense"
                        if winning_side == "ct"
                        else "attack"
                        if winning_side == "t"
                        else ""
                    ),
                    "method": _ROUND_METHODS.get(method_code, method_code),
                    "method_code": method_code,
                    "win_type": method_code,
                    "method_icon": build_full_url(method_src),
                    "score_after": score_after,
                }
            )

    return rounds


def _parse_maps(html: HTMLParser, teams: list[dict] | None = None) -> list[dict]:
    """Parse all per-map game blocks from the base match page."""
    maps: list[dict] = []
    teams = teams or []

    for game_elem in html.css("div.vm-stats-game"):
        game_id = game_elem.attributes.get("data-game-id", "")
        if game_id == "all":
            continue

        map_name = ""
        picked_by = ""
        picked_by_team_id = ""
        pick = None
        map_container = game_elem.css_first(".vm-stats-game-header .map")
        if map_container:
            picked = map_container.css_first(".picked") or game_elem.css_first(".picked")
            picked_text = extract_text_content(picked)
            duration_node = map_container.css_first(".map-duration")
            duration_text = extract_text_content(duration_node)
            name_node = map_container.css_first(".map-name")
            map_name = extract_text_content(name_node or map_container)
            for suffix in (picked_text, duration_text):
                if suffix:
                    map_name = map_name.replace(suffix, "", 1).strip()
            map_name = re.sub(r"\s*\d{1,2}:\d{2}(?::\d{2})?\s*$", "", map_name).strip()
            map_name = re.sub(
                r"\s*(PICK|BAN|DECIDER)\s*$", "", map_name, flags=re.IGNORECASE
            ).strip()

            pick_slot = ""
            if picked:
                pick_modifier = _class_modifier(picked)
                if pick_modifier in {"1", "2"}:
                    team_index = int(pick_modifier) - 1
                    pick_slot = f"team{pick_modifier}"
                    if team_index < len(teams):
                        team = teams[team_index]
                        picked_by = team.get("name", "")
                        picked_by_team_id = team.get("id", "")
                        pick = {
                            "slot": pick_slot,
                            "team_id": picked_by_team_id,
                            "team": picked_by,
                            "team_url": team.get("url", ""),
                        }
                    else:
                        # No parsed teams: read the names the page itself shows.
                        names = [
                            extract_text_content(node)
                            for node in game_elem.css(".vm-stats-game-header .team .team-name")
                        ] or [
                            extract_text_content(node)
                            for node in html.css(".match-header-link-name .wf-title-med")
                        ]
                        if team_index < len(names) and names[team_index]:
                            picked_by = names[team_index]
                            pick = {
                                "slot": pick_slot,
                                "team_id": "",
                                "team": picked_by,
                                "team_url": "",
                            }
                if not picked_by and picked_text and picked_text.lower() not in (
                    "pick",
                    "ban",
                    "decider",
                ):
                    picked_by = picked_text
                    pick = {
                        "slot": pick_slot,
                        "team_id": "",
                        "team": picked_by,
                        "team_url": "",
                    }

        duration = ""
        dur_elem = game_elem.css_first(".map-duration")
        if dur_elem:
            duration = dur_elem.text(strip=True)

        scores = _parse_map_scores(game_elem)
        players = _parse_map_players(game_elem)
        rounds = _parse_rounds(game_elem)
        side_scores = {
            team_key: {
                "total": scores["score"][team_key],
                "attack": scores["score_t"][team_key],
                "defense": scores["score_ct"][team_key],
                "overtime": scores["score_ot"][team_key],
            }
            for team_key in ("team1", "team2")
        }
        has_score = any(
            value not in ("", 0, "0") for value in scores["score"].values()
        )
        numeric_scores = []
        for value in scores["score"].values():
            try:
                numeric_scores.append(int(value))
            except (TypeError, ValueError):
                numeric_scores.append(0)
        high_score, low_score = sorted(numeric_scores, reverse=True)
        is_completed = high_score >= 13 and high_score - low_score >= 2
        map_status = (
            "completed"
            if is_completed
            else "in_progress"
            if rounds or has_score
            else "scheduled"
        )

        maps.append(
            {
                "game_id": game_id,
                "map_number": len(maps) + 1,
                "map_name": map_name,
                "picked_by": picked_by,
                "picked_by_team_id": picked_by_team_id,
                "pick": pick,
                "duration": duration,
                "status": map_status,
                "score": scores["score"],
                "score_ct": scores["score_ct"],
                "score_t": scores["score_t"],
                "score_ot": scores["score_ot"],
                "side_scores": side_scores,
                "players": players,
                "rounds": rounds,
            }
        )

    return maps


# ---------------------------------------------------------------------------
# Head-to-head history parser
# ---------------------------------------------------------------------------

def _parse_head_to_head(
    html: HTMLParser,
    current_teams: list[dict] | None = None,
) -> list[dict]:
    """Parse dedicated head-to-head rows, with legacy history fallback."""
    h2h: list[dict] = []
    current_teams = current_teams or []
    teams_by_logo = {
        logo: team
        for team in current_teams
        for logo in (
            team.get("logo", ""),
            team.get("logo_light", ""),
            team.get("logo_dark", ""),
        )
        if logo
    }
    teams_by_name = {
        value.casefold(): team
        for team in current_teams
        for value in (team.get("name", ""), team.get("tag", ""))
        if value
    }

    container = html.css_first(".match-h2h-matches")
    items = container.css(".wf-module-item") if container else []
    if not items:
        items = html.css(".match-histories-item")

    for row in items:
        result_elem = row.css_first(".match-histories-item-result")
        if result_elem:
            cls = result_elem.attributes.get("class", "") or ""
            is_winner = "mod-win" in cls
            score_rf = extract_text_content(result_elem.css_first(".rf"))
            score_ra = extract_text_content(result_elem.css_first(".ra"))
            score = f"{score_rf} - {score_ra}"

            opp_elem = row.css_first(".match-histories-item-opponent-name")
            opponent = extract_text_content(opp_elem) if opp_elem else ""

            date_elem = row.css_first(".match-histories-item-date")
            date = extract_text_content(date_elem) if date_elem else ""

            href = row.attributes.get("href", "")
            match_id, _ = parse_href_id_slug(href)
            url = build_full_url(href)

            teams = [
                {"name": "", "is_winner": is_winner},
                {"name": opponent, "is_winner": not is_winner},
            ]

            h2h.append(
                {
                    "match_id": match_id,
                    "event": "",
                    "event_series": "",
                    "date": date,
                    "teams": teams,
                    "score": score,
                    "url": url,
                }
            )
        else:
            # Old format: .match-h2h-matches rows
            team_elems = row.css(".match-h2h-matches-team")
            teams = []
            for index, te in enumerate(team_elems):
                cls = te.attributes.get("class", "")
                is_winner = "mod-win" in cls
                logo = normalize_image_url(te.attributes.get("src", ""))
                rendered_name = (
                    extract_text_content(te)
                    or te.attributes.get("alt", "")
                    or te.attributes.get("title", "")
                )
                matched_team = teams_by_logo.get(logo) or teams_by_name.get(
                    rendered_name.casefold()
                )
                if matched_team is None and index < len(current_teams):
                    # Dedicated H2H rows render teams in current-match order,
                    # so position remains stable when historical branding changes.
                    matched_team = current_teams[index]
                matched_team = matched_team or {}
                teams.append(
                    {
                        "id": matched_team.get("id", ""),
                        "name": matched_team.get("name", "") or rendered_name,
                        "logo": logo,
                        "is_winner": is_winner,
                    }
                )

            score_elem = row.css_first(".match-h2h-matches-score")
            score = extract_text_content(score_elem) if score_elem else ""

            event_elem = row.css_first(".match-h2h-matches-event-name")
            event = extract_text_content(event_elem) if event_elem else ""
            series = extract_text_content(
                row.css_first(".match-h2h-matches-event-series")
            )

            date_elem = row.css_first(".match-h2h-matches-date")
            date = extract_text_content(date_elem) if date_elem else ""

            href = row.attributes.get("href", "")
            match_id, _ = parse_href_id_slug(href)
            url = build_full_url(href)

            h2h.append(
                {
                    "match_id": match_id,
                    "event": event,
                    "event_series": series,
                    "date": date,
                    "teams": teams,
                    "score": score,
                    "url": url,
                }
            )

    return h2h


# ---------------------------------------------------------------------------
# Performance tab parsers
# ---------------------------------------------------------------------------

def _performance_table(html: HTMLParser, selector: str):
    """Return a table for the requested game without using aggregate fallback."""
    active_game = html.css_first(".vm-stats-game.mod-active")
    if active_game:
        return active_game.css_first(selector)
    return html.css_first(selector)

def _parse_kill_matrix(html: HTMLParser) -> list[dict]:
    """
    Parse the kill matrix table from the performance tab.
    """
    matrix: list[dict] = []

    table = _performance_table(
        html,
        "table.wf-table-inset.mod-matrix.mod-normal",
    )
    if not table:
        return matrix

    thead_row = table.css_first("thead tr")
    header_row = thead_row or table.css_first("tr")
    opponents: list[str] = []
    if header_row:
        header_cells = header_row.css("th") or header_row.css("td")
        for cell in header_cells:
            team = cell.css_first(".team")
            tag = extract_text_content(cell.css_first(".team-tag"))
            name = extract_text_content(team or cell)
            if tag:
                name = name.removesuffix(tag).strip()
            opponents.append(name)

    rows = table.css("tbody tr")
    if rows and thead_row is None:
        rows = rows[1:]
    for row in rows:
        cells = row.css("td")
        if not cells:
            continue

        player_cell = cells[0]
        player_tag = extract_text_content(player_cell.css_first(".team-tag"))
        player_name = extract_text_content(player_cell.css_first(".team") or player_cell)
        if player_tag:
            player_name = player_name.removesuffix(player_tag).strip()

        kills_vs: dict[str, str] = {}
        matchups = []
        for idx, cell in enumerate(cells[1:], start=1):
            opponent = opponents[idx] if idx < len(opponents) else str(idx)
            stat_squares = cell.css(".stats-sq")
            values = [square.text(deep=False, strip=True) for square in stat_squares]
            kills = values[0] if values else extract_text_content(cell)
            deaths = values[1] if len(values) > 1 else ""
            differential = values[2] if len(values) > 2 else ""
            kills_vs[opponent] = kills
            matchups.append(
                {
                    "opponent": opponent,
                    "opponent_id": "",
                    "opponent_url": "",
                    "kills": kills,
                    "deaths": deaths,
                    "differential": differential,
                }
            )

        matrix.append(
            {
                "player": player_name,
                "player_id": "",
                "player_url": "",
                "team_tag": player_tag,
                "kills_vs": kills_vs,
                "matchups": matchups,
            }
        )

    return matrix


def _parse_advanced_stats(html: HTMLParser) -> list[dict]:
    """
    Parse the advanced stats table from the performance tab.

    Columns: 2K, 3K, 4K, 5K, 1v1, 1v2, 1v3, 1v4, 1v5, Econ, Plants, Defuses
    """
    advanced: list[dict] = []

    table = _performance_table(html, "table.wf-table-inset.mod-adv-stats")
    if not table:
        return advanced

    thead_row = table.css_first("thead tr")
    header_row = thead_row or table.css_first("tr")
    headers: list[str] = []
    if header_row:
        for th in header_row.css("th"):
            headers.append(extract_text_content(th))

    rows = table.css("tbody tr")
    if rows and thead_row is None:
        rows = rows[1:]
    for row in rows:
        cells = row.css("td")
        if not cells:
            continue

        player_tag = extract_text_content(cells[0].css_first(".team-tag"))
        player_name = extract_text_content(cells[0].css_first(".team") or cells[0])
        if player_tag:
            player_name = player_name.removesuffix(player_tag).strip()
        stat_dict: dict[str, str] = {
            "player": player_name,
            "player_id": "",
            "player_url": "",
            "team_tag": player_tag,
            "agent": "",
            "agent_slug": "",
        }

        start_index = 1
        if len(cells) > 1 and cells[1].css_first("img"):
            agent_image = cells[1].css_first("img")
            src = agent_image.attributes.get("src", "")
            stat_dict["agent_slug"] = (
                urlparse(src).path.rsplit("/", 1)[-1].split(".", 1)[0] if src else ""
            )
            stat_dict["agent"] = (
                agent_image.attributes.get("title", "")
                or agent_image.attributes.get("alt", "")
                or stat_dict["agent_slug"].title()
            )
            start_index = 2

        for idx, cell in enumerate(cells[start_index:], start=start_index):
            label = headers[idx] if idx < len(headers) else str(idx)
            square = cell.css_first(".stats-sq")
            stat_dict[label] = (
                square.text(deep=False, strip=True)
                if square
                else extract_text_content(cell)
            )

        advanced.append(stat_dict)

    return advanced


# ---------------------------------------------------------------------------
# Economy tab parser
# ---------------------------------------------------------------------------

def _ecm_group_title(table) -> str:
    """Read the buy-state label of a ``table.ecm`` row group ("On Eco <10k").

    The spend range lives in ``.ecm-gt-r`` *inside* the ``.ecm-gt-t`` label, so
    the range text is re-joined with the label that already contains it.
    """
    gt = table.css_first("th.ecm-gt")
    if gt is None:
        return ""
    band = extract_text_content(gt.css_first(".ecm-gt-r"))
    name = extract_text_content(gt.css_first(".ecm-gt-t") or gt)
    return f"{name.removesuffix(band).strip()} {band}".strip()


def _ecm_labels(table) -> list[str]:
    """Read a ``table.ecm`` table's column labels from its first header row.

    The pistol table labels its columns with ``th.ecm-step``; the buy-state
    tables label them at the *bottom* with ``th.ecm-foot``, and may pad the row
    with an empty ``th.ecm-xt`` spacer, so empty cells are dropped.
    """
    for row in table.css("tr"):
        if row.css("td"):
            continue
        if row.css_first("th.ecm-gt") is not None:
            continue
        labels = [extract_text_content(cell) for cell in row.css("th")]
        labels = [label for label in labels if label]
        if labels:
            return labels
    return []


def _ecm_value(cell) -> str:
    """Read one economy data cell; ``.mod-empty`` cells mean "no data"."""
    score = cell.css_first(".ecm-score")
    return extract_text_content(score) if score is not None else ""


def _parse_economy_groups(scope) -> list[dict]:
    """Parse the economy tab's ``.ecm-groups`` markup, one row per team.

    Each group holds four ``table.ecm`` blocks: the first carries the team names
    with Pistol/Conv./Bonus, then "On Eco", "On Half buy" and "On Full buy"
    tables whose rows either repeat the team name (``th.ecm-team-th.ecm-xt``) or
    omit it and rely on row order to line up with the previous named table.

    Values keep vlr.gg's ``wins/attempts`` form. Buy-state columns are namespaced
    by their group title ("On Full buy 18k+: vs. Eco") because the plain column
    labels repeat across groups.
    """
    economy: list[dict] = []
    by_team: dict[str, dict] = {}
    team_order: list[str] = []

    for table in scope.css("table.ecm"):
        title = _ecm_group_title(table)
        names = [extract_text_content(cell) for cell in table.css("th.ecm-team-th")]
        if names:
            team_order = names
            for name in names:
                if name not in by_team:
                    row = {"Team": name}
                    by_team[name] = row
                    economy.append(row)

        labels = _ecm_labels(table)
        team_index = 0
        for row in table.css("tr"):
            cells = row.css("td")
            if not cells:
                continue
            order = names or team_order
            name = order[team_index] if team_index < len(order) else ""
            team_index += 1
            team_row = by_team.get(name)
            if team_row is None:
                continue
            for label, cell in zip(labels, cells):
                key = f"{title}: {label}" if title else label
                team_row[key] = _ecm_value(cell)

    return economy


def _parse_economy_legacy(html: HTMLParser) -> list[dict]:
    """Parse the pre-redesign economy table (``table.wf-table-inset.mod-econ``)."""
    economy: list[dict] = []

    table = _performance_table(html, "table.wf-table-inset.mod-econ")
    if not table:
        return economy

    thead_row = table.css_first("thead tr")
    header_row = thead_row or table.css_first("tr")
    headers: list[str] = []
    if header_row:
        for th in header_row.css("th"):
            headers.append(extract_text_content(th))

    rows = table.css("tbody tr")
    if rows and thead_row is None:
        rows = rows[1:]
    for row in rows:
        cells = row.css("td")
        if not cells:
            continue

        row_dict: dict[str, str] = {"team_id": ""}
        for idx, cell in enumerate(cells):
            label = headers[idx] if idx < len(headers) else str(idx)
            if idx == 0 and not label:
                label = "Team"
            row_dict[label] = extract_text_content(cell)

        economy.append(row_dict)

    return economy


def _parse_economy(html: HTMLParser) -> list[dict]:
    """Parse the economy table from the economy tab.

    vlr.gg rolled out the ``table.ecm`` economy widget in October 2026 (issue
    #194); ``table.wf-table-inset.mod-econ`` is kept as a fallback for pages
    still serving the old markup. Tab pages embed *every* map's block, so the
    parse is scoped to ``.vm-stats-game.mod-active`` — the requested game — when
    that wrapper exists.
    """
    scope = html.css_first(".vm-stats-game.mod-active") or html
    economy = _parse_economy_groups(scope)
    if economy:
        return economy
    return _parse_economy_legacy(scope)
