"""
Long-lived index of team logos, filled from pages the API already scrapes.

vlr.gg's match-list pages (``/matches``, ``/matches/results``, the homepage)
carry no team IDs or logos at all, only names and flags, so list responses
cannot show logos from the list page alone. Every match page, team page and
rankings page does carry them, and logos are effectively static, so this
index remembers them for ``CACHE_TTL_TEAM_LOGO`` (a day) under two keys:

* ``match id + slot``, which is exact (written from a match page);
* the team name, casefolded, as a secondary key. A name seen with two
  different team IDs is marked ambiguous and never used.

It only stores what scrapers hand it; ``api.team_logo_enrichment`` decides
when to fetch more.
"""

from cachetools import TTLCache

from utils.constants import CACHE_TTL_TEAM_LOGO, TEAM_LOGO_CACHE_SIZE, TEAM_LOGO_MISS_TTL
from utils.html_parsers import normalize_image_url

_AMBIGUOUS = object()
_PLACEHOLDER_NAMES = frozenset({"", "tbd", "tba"})


def _name_key(name) -> str:
    return " ".join(str(name or "").split()).casefold()


def _logo_entry(team: dict) -> dict | None:
    """Normalise a scraper team dict into the cached logo shape."""
    logo = normalize_image_url(team.get("logo") or team.get("logo_light") or "")
    if not logo:
        return None
    light = normalize_image_url(team.get("logo_light") or "") or logo
    dark = normalize_image_url(team.get("logo_dark") or "") or light
    return {
        "id": str(team.get("id") or team.get("team_id") or ""),
        "url": team.get("url") or "",
        "logo": logo,
        "logo_light": light,
        "logo_dark": dark,
    }


class TeamLogoStore:
    def __init__(
        self,
        ttl: int = CACHE_TTL_TEAM_LOGO,
        maxsize: int = TEAM_LOGO_CACHE_SIZE,
        miss_ttl: int = TEAM_LOGO_MISS_TTL,
    ) -> None:
        self._by_match: TTLCache = TTLCache(maxsize=maxsize, ttl=ttl)
        self._by_name: TTLCache = TTLCache(maxsize=maxsize, ttl=ttl)
        self._misses: TTLCache = TTLCache(maxsize=maxsize, ttl=miss_ttl)

    # -- writes ------------------------------------------------------------

    def record_team(self, team: dict, name: str | None = None) -> dict | None:
        """Index one team's logo by name; returns the stored entry."""
        entry = _logo_entry(team)
        key = _name_key(name if name is not None else team.get("name") or team.get("team"))
        if entry is None or key in _PLACEHOLDER_NAMES:
            return entry
        existing = self._by_name.get(key)
        if existing is _AMBIGUOUS:
            return entry
        if existing is not None and existing["id"] and entry["id"] and existing["id"] != entry["id"]:
            self._by_name[key] = _AMBIGUOUS
            return entry
        if existing is not None and not entry["id"]:
            # An ID-less source (rankings) never overrides what is already known.
            return entry
        self._by_name[key] = entry
        return entry

    def record_match(self, match_id, teams: list[dict]) -> None:
        """Index both teams of a scraped match page."""
        match_id = str(match_id or "")
        entries = [self.record_team(team) for team in teams[:2]]
        if match_id and len(entries) == 2 and any(entries):
            self._by_match[match_id] = tuple(entries)
            self._misses.pop(match_id, None)

    def record_miss(self, match_id) -> None:
        self._misses[str(match_id)] = True

    # -- reads -------------------------------------------------------------

    def is_known_miss(self, match_id) -> bool:
        return str(match_id) in self._misses

    def has_match(self, match_id) -> bool:
        return str(match_id) in self._by_match

    def lookup(self, match_id, slot: int, name) -> dict | None:
        """Logo entry for team ``slot`` (0/1) of a match, falling back to its name."""
        entries = self._by_match.get(str(match_id or ""))
        if entries is not None and slot < len(entries) and entries[slot] is not None:
            return entries[slot]
        entry = self._by_name.get(_name_key(name))
        return None if entry is _AMBIGUOUS else entry

    def clear(self) -> None:
        self._by_match.clear()
        self._by_name.clear()
        self._misses.clear()


team_logo_store = TeamLogoStore()
