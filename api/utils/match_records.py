"""Canonical, additive records shared by every V2 match-list endpoint."""

from datetime import UTC, datetime

from utils.html_parsers import (
    build_full_url,
    extract_text_content,
    normalize_image_url,
    parse_href_id_slug,
)


def normalize_match_status(status_text: str, relative_time: str = "") -> str:
    """Map VLR display text to the stable match-list status vocabulary."""
    value = f"{status_text} {relative_time}".casefold()
    if "live" in value:
        return "live"
    if "completed" in value or "final" in value or "ago" in value:
        return "completed"
    if "upcoming" in value or relative_time:
        return "scheduled"
    return "unknown"


def rfc3339_utc(value: str) -> str:
    """Normalize a trustworthy VLR UTC value to RFC3339, or return empty."""
    if not value:
        return ""
    if value.endswith("Z"):
        return value
    try:
        return (
            datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
            .replace(tzinfo=UTC)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except ValueError:
        return ""


def match_team(
    *,
    team_id: str = "",
    name: str = "",
    tag: str = "",
    country_code: str = "",
    logo: str = "",
    score: str = "",
    is_winner: bool = False,
) -> dict:
    """Return the shared team shape used inside a canonical match record."""
    return {
        "id": team_id,
        "name": name or "TBD",
        "tag": tag,
        "country_code": country_code,
        "logo": logo,
        "score": score,
        "is_winner": is_winner,
    }


def build_match_record(
    *,
    source: str,
    match_id: str = "",
    url: str = "",
    stats_match_id: str = "",
    status: str = "unknown",
    status_text: str = "",
    scheduled_at: str = "",
    date: str = "",
    time: str = "",
    relative_time: str = "",
    event_id: str = "",
    event_name: str = "",
    event_stage: str = "",
    event_stage_slug: str = "",
    event_series: str = "",
    event_url: str = "",
    event_logo: str = "",
    teams: list[dict] | None = None,
    note: str = "",
    page: int | None = None,
) -> dict:
    """Build the shared V2 match record while leaving legacy aliases intact."""
    normalized_teams = list(teams or [])[:2]
    while len(normalized_teams) < 2:
        normalized_teams.append(match_team())

    return {
        "source": source,
        "match_id": match_id,
        "stats_match_id": stats_match_id,
        "url": build_full_url(url),
        "status": status,
        "status_text": status_text,
        "scheduled_at": rfc3339_utc(scheduled_at),
        "display": {
            "date": date,
            "time": time,
            "relative": relative_time,
        },
        "event": {
            "id": event_id,
            "name": event_name,
            "stage": event_stage,
            "stage_slug": event_stage_slug,
            "series": event_series,
            "url": build_full_url(event_url),
            "logo": event_logo,
        },
        "teams": normalized_teams,
        "note": note,
        "page": page,
    }


def parse_history_match_record(
    item,
    *,
    source: str,
    context_team_id: str = "",
    page: int | None = None,
) -> dict:
    """Parse the canonical record from a team/player history card."""
    href = item.attributes.get("href", "")
    match_id, _ = parse_href_id_slug(href)

    result_elem = item.css_first(".m-item-result")
    result_class = result_elem.attributes.get("class", "") if result_elem else ""
    result = (
        "win"
        if "mod-win" in result_class
        else "loss"
        if "mod-loss" in result_class
        else ""
    )
    scores = [extract_text_content(span) for span in result_elem.css("span")] if result_elem else []
    while len(scores) < 2:
        scores.append("")

    team_elems = item.css(".m-item-team")
    logo_elems = item.css(".m-item-logo img")
    teams = []
    for index in range(2):
        team_elem = team_elems[index] if index < len(team_elems) else None
        logo_elem = logo_elems[index] if index < len(logo_elems) else None
        teams.append(
            match_team(
                team_id=context_team_id if index == 0 else "",
                name=extract_text_content(
                    team_elem.css_first(".m-item-team-name") if team_elem else None
                ),
                tag=extract_text_content(
                    team_elem.css_first(".m-item-team-tag") if team_elem else None
                ),
                logo=normalize_image_url(
                    logo_elem.attributes.get("src", "") if logo_elem else ""
                ),
                score=scores[index],
                is_winner=(result == "win" and index == 0)
                or (result == "loss" and index == 1),
            )
        )

    event_elem = item.css_first(".m-item-event")
    event_divs = event_elem.css("div") if event_elem else []
    event_name_elem = event_divs[-1] if event_divs else None
    event_name = extract_text_content(event_name_elem)
    event_context = event_elem.text(deep=False, strip=True) if event_elem else ""
    event_parts = [part.strip() for part in event_context.split("⋅") if part.strip()]
    event_stage = event_parts[0] if event_parts else ""
    event_series = event_parts[-1] if len(event_parts) > 1 else ""
    event_logo_elem = item.css_first(".m-item-thumb img")

    date_elem = item.css_first(".m-item-date")
    date_divs = date_elem.css("div") if date_elem else []
    date_node = date_divs[-1] if date_divs else None
    date = extract_text_content(date_node)
    time = date_elem.text(deep=False, strip=True) if date_elem else ""

    return build_match_record(
        source=source,
        match_id=match_id,
        url=href,
        stats_match_id=(
            result_elem.attributes.get("data-match-id", "") if result_elem else ""
        ),
        status="completed" if result else "unknown",
        status_text=result,
        date=date,
        time=time,
        event_name=event_name,
        event_stage=event_stage,
        event_series=event_series,
        event_logo=normalize_image_url(
            event_logo_elem.attributes.get("src", "") if event_logo_elem else ""
        ),
        teams=teams,
        page=page,
    )
