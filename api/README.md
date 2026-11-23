# vlrggapi

## Important Notice

> **`https://vlrggapi.vercel.app/` is currently down because it exceeded free-tier limits.**
> Please self-host the API for now, or wait while I look into another solution.

An Unofficial REST API for [vlr.gg](https://www.vlr.gg/), a site for Valorant Esports match and news coverage.

Based on the original API created by [Andre Saddler](https://github.com/axsddlr/) and expanded and improved by [Chefski](https://github.com/Chefski/).

## Quick Start

- **Public base URL:** `https://vlrggapi.vercel.app`
- **Local base URL:** `http://127.0.0.1:3001`
- **Interactive docs:** `/`
- **Version info:** `/version`

```bash
curl https://vlrggapi.vercel.app/v3/news
curl "https://vlrggapi.vercel.app/v3/matches?q=live_score"
curl https://vlrggapi.vercel.app/v3/events/2978
curl "http://127.0.0.1:3001/v2/player?id=9&timespan=all"
```

## Highlights

- **Typed V3 API** - strict response schemas with native numbers, stable IDs, RFC3339 timestamps, and explicit nulls
- **Backwards compatibility** - V2 and original unversioned endpoints remain available
- **Deep match coverage** - detailed match, player, team, and event match endpoints
- **Appearance-aware logos** - light and dark VLR.GG assets with backwards-compatible defaults
- **Operational guardrails** - async HTTP, rate limiting, and bounded expensive scrapes

## What's New

### Match Details, Player Profiles & Team Profiles

New endpoints provide deep coverage of individual matches, players, and teams:

- **Match details** — per-map player stats (K/D/A, ACS, rating), round-by-round data, kill matrix, economy breakdown, head-to-head history, map veto data
- **Player profiles** — agent stats (17 metrics), current/past teams, event placements, total winnings, match history
- **Team profiles** — roster with roles/captain status, VLR rating/rank, event placements, total winnings, match history, roster transactions
- **Event matches** — full match list for any event with scores and VOD links
- **Event detail** — event info with prize pool breakdown, participating team rosters, and group/stage standings tables
- **Search** — cross-entity search for teams, players, and events by name or keyword

### V2 API

- **Standardized responses** — all V2 endpoints return `{"status": "success", "data": {...}}`
- **Input validation** — invalid parameters return HTTP 400 with clear error messages
- **Per-endpoint caching** — in-memory TTL cache reduces load on vlr.gg
- **Async HTTP** — scrapers use `httpx` for non-blocking I/O

### Typed V3 API

- **Strict contracts** — every response model rejects undocumented fields and is fully represented in OpenAPI
- **Native types** — entity IDs, scores, rankings, statistics, percentages, and prize amounts are numbers rather than display strings
- **Predictable absence** — unavailable optional values are `null`, not empty strings or placeholder text
- **Canonical time** — machine-readable dates and datetimes use ISO 8601/RFC3339; upstream display text remains available where useful
- **Consistent envelopes** — covered resources return `{ "api_version": "3", "data": ..., "meta": ... }`

## API Versions

V3 is recommended for the typed resources listed below. V2 remains the compatibility API and continues to cover player, team, search, rankings, and experimental event subresources. The original endpoints (`/news`, `/match`, etc.) are preserved unchanged.

| Feature | Original | V2 | V3 |
|---|---|---|---|
| Response shape | Varies per endpoint | `{"status": "success", "data": {...}}` | `{"api_version": "3", "data": ..., "meta": ...}` |
| Contract | Legacy display strings | Backwards-compatible additive fields | Strict typed models and concrete OpenAPI schemas |
| Missing optional values | Usually empty strings | Usually empty strings | `null` |
| Input validation | None | HTTP 400 on invalid params | HTTP 400/422 on invalid params |
| Caching | None | Per-endpoint TTL cache | Shares the V2 scraper cache |

Interactive Swagger docs are available at `/`.

## Operational Notes

- **Recommended base path** - use `/v3` for covered resources and `/v2` where no V3 route exists
- **Current version endpoint** - `GET /version` returns the current API version and default API
- **Rate limit** - endpoint tiers allow 200 cheap, 60 moderate, or 20 expensive requests per minute per client
- **Error handling** - V2 and V3 return HTTP errors for invalid input and propagate upstream failures with HTTP error codes
- **Deployment targets** - Vercel for the hosted API, Docker for containerized self-hosting
- **Edge caching** - successful GETs send `s-maxage`/`stale-while-revalidate` derived from the cache TTLs below
- **Daily parse check** - `.github/workflows/selector-check.yml` validates selectors and the Flank endpoint contract (`tests/test_live_contract.py`) against live vlr.gg every day

## V3 Endpoint Overview

V3 provides typed contracts over the news, statistics, event, match-list, and
match-detail data exposed by VLR.GG. It does not change the existing V2 or
unversioned response shapes.

| Route | Purpose |
|---|---|
| `GET /v3/news?page=1` | Paginated news archive |
| `GET /v3/news/{article_id}` | Full article content, links, and media |
| `GET /v3/stats?region=all` | Filterable global player statistics |
| `GET /v3/matches?q=upcoming` | Upcoming, live, or completed match lists |
| `GET /v3/matches/{match_id}` | Full match, maps, rounds, economy, streams, VODs, and history |
| `GET /v3/events?q=upcoming&page=1` | Event browser |
| `GET /v3/events/{event_id}` | Event details, stages, teams, prizes, groups, and brackets |
| `GET /v3/events/{event_id}/matches` | Canonical event match list |
| `GET /v3/events/{event_id}/stats` | Typed event player statistics |

Every successful response follows this envelope:

```json
{
  "api_version": "3",
  "data": {
    "id": 715117,
    "status": "completed",
    "starts_at": "2026-07-29T19:00:00Z",
    "round_number": null
  },
  "meta": {
    "source": "vlr.gg",
    "id": 715117
  }
}
```

Fields that VLR.GG does not expose reliably remain `null`; V3 does not invent
IDs or timestamps. See the interactive Swagger docs at `/` for each complete
schema and its query parameters.

## V2 Endpoint Overview

| Route | Query Params | Cache |
|---|---|---|
| `GET /v2/news` | `page` | 10 min |
| `GET /v2/news/{article_id}` | — | 10 min |
| `GET /v2/match` | `q` (upcoming/upcoming_extended/live_score/results), `num_pages`, `from_page`, `to_page`, `max_retries`, `request_delay`, `timeout` | 30s–60s |
| `GET /v2/match/details` | `match_id` | 5 min |
| `GET /v2/rankings` | `region` | 1 hr |
| `GET /v2/stats` | `region`; `timespan` or `span`; tier/date/side/role/agent/map/threshold/sort filters | 30 min |
| `GET /v2/events` | `q` (upcoming/completed/live), `page` | 30 min |
| `GET /v2/event/{id}` | `event_id` (path), `stage` | 30 min |
| `GET /v2/event/{id}/stats` | side/role/agent/map/rounds/sort/stage exclusion filters | 10 min |
| `GET /v2/event/{id}/agents` | `exclude` subseries IDs | 30 min |
| `GET /v2/event/{id}/news` | — | 10 min |
| `GET /v2/event/{id}/pickem` | — | 5 min |
| `GET /v2/events/matches` | `event_id` | 10 min |
| `GET /v2/search` | `q` | 5 min |
| `GET /v2/player` | `id`, `q` (profile/matches), `timespan`, `page` | 30 min / 10 min |
| `GET /v2/team` | `id`, `q` (profile/matches/transactions/stats), `page` | 30 min / 10 min / 1 hr / 10 min |
| `GET /v2/health` | — | none |

See section below for full descriptions and response examples.

## V2 Endpoints

All examples are collapsed — click to expand.

Team and event identities returned by live scores, rankings, match details, and
team profiles include light and dark fields. The existing `logo` fields remain
aliases for their light variants. When VLR.GG does not provide a distinct dark
asset, the dark field falls back to the light URL.

### `GET /v2/news`
**Params:** `page` (1–500, default 1) | **Cache:** 10 min

```
GET /v2/news?page=1
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [
      {
        "article_id": "725612",
        "slug": "timeline-americas-lcq-grand-final-postponed-after-nearly-12-hours",
        "title": "Article title",
        "description": "Article summary",
        "date": "July 30, 2026",
        "published_date": "2026-07-30",
        "author": "author_name",
        "region_code": "mx",
        "url": "https://www.vlr.gg/725612/...",
        "url_path": "https://www.vlr.gg/725612/..."
      }
    ],
    "meta": { "page": 1, "total_pages": 126, "has_previous": false, "has_next": true }
  }
}
```
</details>

### `GET /v2/news/{article_id}`
**Params:** numeric VLR article ID (path) | **Cache:** 10 min

```
GET /v2/news/725612
```

Numeric VLR pages that are matches or forum threads return `404`; only pages
with VLR's article structure are accepted. `content.html` preserves upstream
VLR markup with absolute links and media URLs; sanitize it for your rendering
environment. Use `content.text` when formatted markup is unnecessary.

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [{
      "article_id": "725612",
      "slug": "timeline-americas-lcq-grand-final-postponed-after-nearly-12-hours",
      "url": "https://www.vlr.gg/725612/...",
      "title": "[TIMELINE] Americas LCQ grand final postponed after nearly 12 hours",
      "description": "The best-of-five grand final ...",
      "published_at": "2026-07-30T02:17:33+01:00",
      "relative_time": "9 hours ago",
      "author": {
        "name": "Joseph Paldino", "handle": "ChickenJoe",
        "url": "https://www.vlr.gg/user/ChickenJoe", "avatar": "https://owcdn.net/img/..."
      },
      "event": {
        "id": "3063", "name": "VCL 26: Americas Last Chance Qualifier",
        "url": "https://www.vlr.gg/event/3063/...", "logo": "https://owcdn.net/img/..."
      },
      "content": {
        "html": "<p>Formatted article body ...</p>",
        "text": "Readable article body ...",
        "links": [{ "text": "Americas Play-Ins", "url": "https://www.vlr.gg/event/2977/..." }],
        "media": [{ "type": "embed", "url": "https://clips.twitch.tv/embed?...", "alt": "" }]
      },
      "comments_url": "https://www.vlr.gg/725612/...#comments"
    }],
    "meta": { "article_id": "725612" }
  }
}
```
</details>

### `GET /v2/match`
**Params:** `q` (required: upcoming/upcoming_extended/live_score/results), `num_pages`, `from_page`, `to_page`, `max_retries`, `request_delay`, `timeout`
**Cache:** 30s (live_score), 5min (upcoming), 60s (results)

```
GET /v2/match?q=upcoming
```

<details><summary>Response (upcoming)</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [
      {
        "team1": "G2 Esports", "team2": "Leviatán",
        "flag1": "flag_us", "flag2": "flag_cl",
        "time_until_match": "51m from now",
        "match_series": "Regular Season: Week 3",
        "match_event": "Champions Tour 2024: Americas Stage 1",
        "unix_timestamp": "2024-04-24 21:00:00",
        "match_page": "https://www.vlr.gg/..."
      }
    ]
  }
}
```
</details>

Every match-list segment also includes a shared `match` record, whether it came
from the global schedule/results, an event, a team, or a player:

```json
{
  "match": {
    "source": "matches",
    "match_id": "698903",
    "stats_match_id": "",
    "url": "https://www.vlr.gg/698903/...",
    "status": "scheduled",
    "status_text": "Upcoming",
    "scheduled_at": "",
    "display": { "date": "Thu, July 30, 2026", "time": "12:00 PM", "relative": "45m" },
    "event": {
      "id": "", "name": "VCT 2026: Pacific Stage 2", "stage": "Group Stage", "stage_slug": "",
      "series": "Week 3", "url": "", "logo": "https://owcdn.net/img/..."
    },
    "teams": [
      { "id": "", "name": "FULL SENSE", "tag": "", "country_code": "th", "logo": "", "score": "", "is_winner": false },
      { "id": "", "name": "ZETA DIVISION", "tag": "", "country_code": "jp", "logo": "", "score": "", "is_winner": false }
    ],
    "note": "",
    "page": 1
  }
}
```

`data.meta.record_schema` is `match-list` on all of these responses. Stable
IDs are filled whenever VLR exposes them in that source; unavailable values are
empty for V2 compatibility. `scheduled_at` is RFC3339 only when VLR supplies a
trustworthy UTC value (currently live records, whose detail page is already
fetched). Otherwise use the raw `match.display` values or request
`/v2/match/details`. The legacy `unix_timestamp` alias is preserved but may be
an estimated formatted date rather than a Unix timestamp.

### `GET /v2/rankings`
**Params:** `region` (required — see [Region Codes](#region-codes)) | **Cache:** 1 hr

```
GET /v2/rankings?region=na
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [
      {
        "rank": "1", "team": "Sentinels", "country": "United States",
        "last_played": "22h ago", "record": "7-3", "earnings": "$295,500",
        "logo": "//owcdn.net/img/light-logo-id.png",
        "logo_light": "//owcdn.net/img/light-logo-id.png",
        "logo_dark": "//owcdn.net/img/dark-logo-id.png"
      }
    ]
  }
}
```
</details>

### `GET /v2/stats`
**Params:** `region` (required), plus one of legacy `timespan` (30/60/90/all) or current `span` (30d/60d/90d/custom/2020-current year/all) | **Cache:** 30 min

**Regions** (the `/stats` page taxonomy, distinct from `/rankings`): `all`, `americas`, `emea`, `pacific`, `china`, `intl`. Deprecated aliases are still accepted and normalized: `na`/`br` → `americas`, `eu` → `emea`, `ap`/`kr`/`jp`/`oce` → `pacific`, `cn` → `china`.

The full VLR filter contract is supported: `tier` (all/vct/vcl/t3/gc/cg/off), `from` and `to` for a custom span, `side` (all/t/ct), `role`, `agent`, `map_id`, `min_rounds`, `min_rating`, `sort`, and `dir` (asc/desc). Historical API defaults remain `tier=all`, `min_rounds=200`, and `min_rating=1550`; pass `min_rounds=100&min_rating=0` to match the website defaults.

```
GET /v2/stats?region=americas&timespan=30
GET /v2/stats?region=emea&span=custom&from=2026-01-01&to=2026-06-30&tier=vct&side=ct&role=sentinel&agent=killjoy&map_id=12&min_rounds=100&min_rating=0&sort=kmax&dir=desc
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "filters": {
      "tier": "all", "region": "americas", "span": "30d",
      "from": null, "to": null, "side": "all", "role": "all",
      "agent": "all", "map_id": "all", "min_rounds": 200,
      "min_rating": 1550, "sort": "rating2", "dir": "desc"
    },
    "segments": [
      {
        "player": "player_name", "player_id": "1234",
        "player_url": "https://www.vlr.gg/player/1234/player_name",
        "country": "us", "org": "ORG", "agents": ["jett"],
        "agent_usage": [{ "agent": "jett", "usage": "100%" }],
        "maps_played": "18", "rounds_played": "376",
        "rating": "1.18", "average_combat_score": "235.2",
        "kill_deaths": "1.19", "kill_assists_survived_traded": "72%",
        "average_damage_per_round": "158.4", "kills_per_round": "0.81",
        "assists_per_round": "0.29", "first_kill_death_ratio": "1.46",
        "first_kills_per_round": "0.19",
        "first_deaths_per_round": "0.13", "headshot_percentage": "26%",
        "clutch_success_percentage": "28%", "clutch_attempts": "9/57",
        "max_kills": "31", "max_kills_match_id": "5555",
        "max_kills_game_id": "7777",
        "max_kills_match_url": "https://www.vlr.gg/5555/example/?game=7777",
        "kills": "304", "deaths": "255", "assists": "109",
        "first_kills": "72", "first_deaths": "49"
      }
    ]
  }
}
```
</details>

### `GET /v2/events`
Browse events — use to discover event IDs for detail/matches lookups.
**Params:** `q` (optional: upcoming/completed/live), `page` | **Cache:** 30 min

```
GET /v2/events?q=upcoming
GET /v2/events?q=live
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [
      {
        "title": "VCT 2025: Pacific Stage 2", "status": "ongoing",
        "prize": "$250,000", "dates": "Jul 15—Aug 31", "region": "kr",
        "url_path": "https://www.vlr.gg/event/..."
      }
    ]
  }
}
```
</details>

### `GET /v2/match/details`
**Params:** `match_id` (required) | **Cache:** 5 min (30s for live)

```
GET /v2/match/details?match_id=595657
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [{
      "match_id": "595657",
      "url": "https://www.vlr.gg/595657",
      "stats_match_id": "102630",
      "event": {
        "id": "2683", "name": "VCT 2026: Pacific Kickoff",
        "series": "Main Event: Lower Round 4", "stage": "main-event",
        "url": "https://www.vlr.gg/event/2683/vct-2026-pacific-kickoff/main-event"
      },
      "date": "Thursday, February 12 8:00 AM GMT",
      "utc_timestamp": "2026-02-12 03:00:00",
      "scheduled_at": "2026-02-12T03:00:00Z",
      "patch": "12.0", "status": "completed", "format": "Bo3",
      "map_vetos": "PRX ban Abyss; KRX ban Pearl; PRX pick Haven; KRX pick Corrode; PRX ban Bind; KRX ban Split; Breeze remains",
      "notes": [],
      "teams": [
        { "id": "8185", "name": "KIWOOM DRX", "score": "1", "is_winner": false, "url": "https://www.vlr.gg/team/8185/kiwoom-drx" },
        { "id": "624", "name": "Paper Rex", "score": "2", "is_winner": true, "url": "https://www.vlr.gg/team/624/paper-rex" }
      ],
      "streams": [{ "name": "English", "url": "https://www.twitch.tv/valorant_pacific", "platform": "twitch", "country_code": "us", "is_embedded": true, "site_id": "..." }],
      "vods": [{ "name": "Map 1", "url": "https://www.youtube.com/watch?v=...", "platform": "youtube", "map_number": 1 }],
      "maps": [{
        "game_id": "244645", "map_number": 1, "map_name": "Haven",
        "picked_by": "Paper Rex", "picked_by_team_id": "624", "status": "completed",
        "side_scores": {
          "team1": { "total": 11, "attack": "4", "defense": "7", "overtime": "" },
          "team2": { "total": 13, "attack": "5", "defense": "8", "overtime": "" }
        },
        "players": { "team1": [{
          "player_id": "28400", "name": "HYUNMIN", "country": "kr", "team_tag": "KRX",
          "agent": "Waylay", "agent_slug": "waylay", "rating": "1.05",
          "attack": { "rating": "0.86", "kills": "7" },
          "defense": { "rating": "1.24", "kills": "13" }
        }], "team2": [] },
        "rounds": [{
          "round_num": 1, "winner": "team2", "side": "ct", "side_name": "defense",
          "method": "elimination", "method_code": "elim",
          "score_after": { "team1": 0, "team2": 1 }
        }],
        "performance": {
          "kill_matrix": [{
            "player": "free1ng", "player_id": "1916", "kills_vs": { "Jinggg": "3" },
            "matchups": [{ "opponent": "Jinggg", "opponent_id": "7378", "kills": "3", "deaths": "3", "differential": "+0" }]
          }],
          "advanced_stats": [{ "player": "free1ng", "player_id": "1916", "agent": "Tejo", "2K": "3", "1v2": "1" }]
        },
        "economy": [{ "team_id": "8185", "Team": "KRX", "Pistol Won": "0", "Eco (won)": "4 (0)" }]
      }],
      "head_to_head": [{
        "match_id": "542278", "event": "Champions 2025", "event_series": "LR3",
        "date": "2025/10/03", "score": "2 0", "url": "https://www.vlr.gg/542278/..."
      }]
    }]
  }
}
```
</details>

`performance.by_map` and `economy_by_map` remain available for compatibility.
Scheduled maps are returned with empty rounds, performance, and economy data.

### `GET /v2/event/{event_id}`
Event detail: metadata and calendar links, resource navigation, stage tabs, current `event-group` standings/schedules, brackets, prizes, and teams. Use a stage slug returned in `stages` to select a different stage.
**Params:** `event_id` (path, required — from `/v2/events`), `stage` (optional) | **Cache:** 30 min

```
GET /v2/event/2124
GET /v2/event/2978?stage=group-stage
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "segments": {
      "event": {
        "event_id": "2124", "url": "https://www.vlr.gg/event/2124",
        "name": "VCT 2026: Americas Stage 1", "series": "Valorant Champions Tour 2026",
        "dates": "Apr 15 - May 10, 2026", "prize": "$250,000 USD",
        "location": "Los Angeles, USA", "location_code": "us", "logo": "https://owcdn.net/img/...",
        "calendar": { "google": "https://calendar.google.com/...", "apple": "webcal://...", "subscription": "https://www.vlr.gg/event/ical/2124", "download": "https://www.vlr.gg/event/ical/2124" }
      },
      "resources": [{ "name": "Matches", "count": "66", "url": "https://www.vlr.gg/event/matches/2124/...", "active": false }],
      "stages": [{ "name": "Group Stage", "dates": "Apr 15-May 1", "slug": "group-stage", "url": "https://www.vlr.gg/event/2124/.../group-stage", "active": true }],
      "active_stage": { "name": "Group Stage", "slug": "group-stage", "active": true },
      "groups": [{
        "id": "2648", "name": "Group Alpha",
        "teams": [{ "rank": 1, "id": "120", "name": "100 Thieves", "state": "advanced", "record": "5-0", "maps": "10/2", "rounds": "150/120", "round_differential": "+30" }],
        "matches": [{ "match_id": "701027", "series": "Week 1", "format": "Bo3", "team1": { "name": "100T", "score": "2", "is_winner": true }, "team2": { "name": "C9", "score": "0", "is_winner": false } }]
      }],
      "brackets": [{ "type": "upper", "rounds": [{ "name": "Upper Final", "matches": [{ "match_id": "701100", "utc_timestamp": "1786003200", "team1": { "id": "120", "name": "100 Thieves", "score": "3" }, "team2": { "id": "200", "name": "Cloud9", "score": "1" } }] }] }],
      "prizes": [
        { "placement": "1st", "amount": "$100,000", "team": { "id": "120", "name": "100 Thieves", "logo": "...", "region": "United States" } },
        { "placement": "2nd", "amount": "$60,000", "team": { "id": "2355", "name": "KRÜ Esports", "logo": "...", "region": "Chile" } }
      ],
      "teams": [{
        "id": "120", "name": "100 Thieves", "logo": "https://owcdn.net/img/...", "url": "https://www.vlr.gg/team/120/100-thieves",
        "players": [{ "id": "9", "name": "Asuna", "flag": "us" }],
        "qualification": "NA Circuit Points", "qualification_url": "https://www.vlr.gg/event/..."
      }],
      "standings": [{
        "stage": "Group Stage", "columns": ["Team", "W", "L", "RD", "MRD"],
        "rows": [{ "Team": "100 Thieves", "W": "4", "L": "1", "RD": "+42", "MRD": "+12" }]
      }]
    }
  }
}
```
</details>

### Event subresources

The event navigation on VLR.GG is exposed directly:

```
GET /v2/event/2978/stats?side=ct&role=sentinel&agent=killjoy&map_id=12&min_rounds=100&sort=kmax&dir=desc&exclude=39139.39140
GET /v2/event/2978/agents?exclude=39139.39140
GET /v2/event/2978/news
GET /v2/event/2978/pickem
```

- `stats` returns the same complete player columns as `/v2/stats`, scoped to the event, plus available stage/subseries IDs.
- `agents` returns global and per-map pick rates plus each team's agent composition by map.
- `news` returns canonical article IDs, titles, dates, and URLs.
- `pickem` returns public fixture groups, known winners, lock state, leaderboard distribution, and group/leaderboard URLs. It does not expose authenticated picks or group operations.

### `GET /v2/search`
Cross-entity search for players, teams, and events.
**Params:** `q` (required) | **Cache:** 5 min

```
GET /v2/search?q=tenz
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "segments": {
      "query": "tenz",
      "results": {
        "players": [{ "id": "9", "name": "TenZ", "img": "https://owcdn.net/img/...", "description": "", "tag": "" }],
        "teams": [{ "id": "16647", "name": "TenZ and Friends", "img": "https://...", "description": "", "tag": "(inactive)" }],
        "events": []
      }
    }
  }
}
```
</details>

### `GET /v2/player`
**Params:** `id` (required), `q` (profile/matches, default: profile), `timespan` (30d/60d/90d/all, default: 90d), `page` (1-based, default: 1) | **Cache:** varies

```
GET /v2/player?id=9&q=profile&timespan=all
GET /v2/player?id=9&q=matches&page=1
```

<details><summary>Profile response</summary>

```json
{
  "status": "success",
  "data": {
    "info": { "name": "TenZ", "real_name": "Tyson Ngo", "avatar": "https://owcdn.net/img/...", "country": "Canada", "socials": [{ "platform": "twitter", "url": "..." }] },
    "current_teams": [{ "name": "Sentinels", "tag": "SEN", "status": "Active" }],
    "past_teams": [{ "name": "Cloud9", "tag": "C9", "dates": "2020–2021" }],
    "agent_stats": [{ "agent": "Jett", "use_count": 150, "use_pct": "42%", "rounds": 3200, "rating": "1.15", "acs": "245.3", "kd": "1.18", "adr": "162.1", "kast": "71%", "kpr": "0.82", "apr": "0.28", "fkpr": "0.20", "fdpr": "0.14", "kills": 2624, "deaths": 2224, "assists": 896, "fk": 640, "fd": 448 }],
    "event_placements": [{ "event": "Champions 2024", "placement": "1st", "prize": "$100,000", "team": "Sentinels" }],
    "total_winnings": "$177,650"
  }
}
```
</details>

<details><summary>Matches response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [{
      "match_id": "698899", "event": "VCT 26: PAC Stage 2", "score": "0:2", "result": "loss",
      "match": { "source": "player", "match_id": "698899", "status": "completed", "teams": [{ "name": "..." }, { "name": "..." }], "event": { "name": "VCT 26: PAC Stage 2", "stage": "Group Stage", "series": "W2" } }
    }],
    "meta": { "page": 1, "record_schema": "match-list", "player_id": "9" }
  }
}
```
</details>

### `GET /v2/team`
**Params:** `id` (required), `q` (profile/matches/transactions/stats, default: profile), `page` (1-based, default: 1) | **Cache:** varies

```
GET /v2/team?id=2&q=profile
GET /v2/team?id=2&q=matches&page=1
GET /v2/team?id=2&q=transactions
GET /v2/team?id=2&q=stats
```

<details><summary>Profile response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [{
      "id": "2", "name": "Sentinels", "tag": "SEN",
      "logo": "https://owcdn.net/img/light-logo-id.png",
      "logo_light": "https://owcdn.net/img/light-logo-id.png",
      "logo_dark": "https://owcdn.net/img/dark-logo-id.png",
      "country_name": "United States",
      "social_links": [{ "platform": "twitter", "url": "..." }],
      "rating": { "rank": "1", "rating": "1850" },
      "roster": [{ "alias": "TenZ", "real_name": "Tyson Ngo", "role": "Duelist", "is_captain": false, "avatar": "..." }],
      "event_placements": [{ "event": "Champions 2024", "placement": "1st", "prize": "$100,000" }],
      "total_winnings": "$1,194,000"
    }]
  }
}
```
</details>

<details><summary>Matches response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [{
      "match_id": "701063", "event": "Seeding", "score": "2:0", "result": "win",
      "match": { "source": "team", "match_id": "701063", "status": "completed", "teams": [{ "name": "..." }, { "name": "..." }], "event": { "name": "VCT 26: CN Stage 2", "stage": "Group Stage", "series": "Seeding" } }
    }],
    "meta": { "page": 1, "record_schema": "match-list", "team_id": "2" }
  }
}
```
</details>

<details><summary>Transactions response</summary>

```json
{
  "status": "success",
  "data": {
    "transactions": [{ "date": "Jan 15, 2024", "action": "join", "player": "TenZ", "position": "Duelist" }]
  }
}
```
</details>

<details><summary>Stats response</summary>

```json
{
  "status": "success",
  "data": {
    "segments": [
      {
        "map": "Bind",
        "games": 86,
        "win_pct": "71%",
        "wins": 61,
        "losses": 25,
        "atk_first": 54,
        "def_first": 32,
        "atk_rwin_pct": "60%",
        "atk_rw": 575,
        "atk_rl": 383,
        "def_rwin_pct": "53%",
        "def_rw": 458,
        "def_rl": 408
      }
    ]
  }
}
```
</details>

### `GET /v2/events/matches`
**Params:** `event_id` (required) | **Cache:** 10 min

```
GET /v2/events/matches?event_id=2095
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "status": 200,
    "segments": [{
      "match_id": "701025", "event_series": "Week 1", "date": "Thu, July 9, 2026",
      "team1": { "name": "Wolves Esports", "score": "2", "is_winner": true },
      "team2": { "name": "Titan Esports Club", "score": "0", "is_winner": false },
      "match": { "source": "event", "match_id": "701025", "status": "completed", "teams": [{ "name": "Wolves Esports", "score": "2" }, { "name": "Titan Esports Club", "score": "0" }], "event": { "id": "2978", "name": "VCT 2026: China Stage 2", "stage": "Group Stage", "series": "Week 1" } }
    }],
    "meta": { "record_schema": "match-list", "event_id": "2978" }
  }
}
```
</details>

### `GET /v2/health`
**Params:** none | **Cache:** none

```
GET /v2/health
```

<details><summary>Response</summary>

```json
{
  "status": "success",
  "data": {
    "https://vlrggapi.vercel.app": { "status": "Healthy", "status_code": 200 },
    "https://vlr.gg": { "status": "Healthy", "status_code": 200 }
  }
}
```
</details>

## Original Endpoints

Preserved for backwards compatibility. Most return `{"data": {"status": int, "segments": [...]}}`. Rankings uses `{"status": int, "data": [...]}`. Response shapes mirror their V2 counterparts — see [V2 Endpoints](#v2-endpoints) for examples.

| Route | Query Params |
|---|---|
| `GET /news` | `page` |
| `GET /news/{article_id}` | — |
| `GET /match` | `q` (upcoming/upcoming_extended/live_score/results), pagination params |
| `GET /match/details` | `match_id` |
| `GET /stats` | Same filters as `/v2/stats` |
| `GET /rankings` | `region` |
| `GET /events` | `q` (upcoming/completed/live), `page` |
| `GET /event/{id}` | `stage` |
| `GET /event/{id}/stats` | Same filters as `/v2/event/{id}/stats` |
| `GET /event/{id}/agents` | `exclude` |
| `GET /event/{id}/news` | — |
| `GET /event/{id}/pickem` | — |
| `GET /events/matches` | `event_id` |
| `GET /search` | `q` |
| `GET /player` | `id`, `timespan` |
| `GET /player/matches` | `id`, `page` |
| `GET /team` | `id` |
| `GET /team/matches` | `id`, `page` |
| `GET /team/transactions` | `id` |
| `GET /health` | — |

<details>
<summary><code>GET /match?q=upcoming</code> — response example</summary>

```json
{
  "data": {
    "status": 200,
    "segments": [
      {
        "team1": "G2 Esports",
        "team2": "Leviatán",
        "flag1": "flag_us",
        "flag2": "flag_cl",
        "time_until_match": "51m from now",
        "match_series": "Regular Season: Week 3",
        "match_event": "Champions Tour 2024: Americas Stage 1",
        "unix_timestamp": "2024-04-24 21:00:00",
        "match_page": "https://www.vlr.gg/..."
      }
    ]
  }
}
```

</details>

<details>
<summary><code>GET /match?q=live_score</code> — response example</summary>

```json
{
  "data": {
    "status": 200,
    "segments": [
      {
        "team1": "Team 1",
        "team2": "Team 2",
        "flag1": "flag_xx",
        "flag2": "flag_xx",
        "team1_logo": "https://.../team-1-light.png",
        "team1_logo_light": "https://.../team-1-light.png",
        "team1_logo_dark": "https://.../team-1-dark.png",
        "team2_logo": "https://.../team-2-light.png",
        "team2_logo_light": "https://.../team-2-light.png",
        "team2_logo_dark": "https://.../team-2-dark.png",
        "score1": "1",
        "score2": "0",
        "team1_round_ct": "7",
        "team1_round_t": "6",
        "team2_round_ct": "5",
        "team2_round_t": "4",
        "map_number": "1",
        "current_map": "Ascent",
        "time_until_match": "LIVE",
        "match_event": "Event name",
        "match_series": "Series name",
        "unix_timestamp": "1713996000",
        "match_page": "https://www.vlr.gg/..."
      }
    ]
  }
}
```

</details>

<details>
<summary><code>GET /match?q=results</code> — response example</summary>

```json
{
  "data": {
    "status": 200,
    "segments": [
      {
        "team1": "Team Vitality",
        "team2": "Gentle Mates",
        "score1": "0",
        "score2": "2",
        "flag1": "flag_eu",
        "flag2": "flag_fr",
        "time_completed": "2h 44m ago",
        "round_info": "Regular Season-Week 4",
        "tournament_name": "Champions Tour 2024: EMEA Stage 1",
        "match_page": "/318931/team-vitality-vs-gentle-mates-...",
        "tournament_icon": "https://owcdn.net/img/..."
      }
    ]
  }
}
```

</details>

<details>
<summary><code>GET /stats?region=americas&timespan=30</code> — response example</summary>

```json
{
  "data": {
    "status": 200,
    "segments": [
      {
        "player": "corey",
        "org": "TTR",
        "rating": "1.18",
        "average_combat_score": "235.2",
        "kill_deaths": "1.19",
        "kill_assists_survived_traded": "72%",
        "average_damage_per_round": "158.4",
        "kills_per_round": "0.81",
        "assists_per_round": "0.29",
        "first_kills_per_round": "0.19",
        "first_deaths_per_round": "0.13",
        "headshot_percentage": "26%",
        "clutch_success_percentage": "28%",
        "clutch_attempts": "9/57"
      }
    ]
  }
}
```

</details>

<details>
<summary><code>GET /rankings?region=na</code> — response example</summary>

Note: `/rankings` uses a different response shape than other endpoints.

```json
{
  "status": 200,
  "data": [
    {
      "rank": "1",
      "team": "Sentinels",
      "country": "United States",
      "last_played": "22h ago",
      "last_played_team": "vs. Evil Geniuses",
      "last_played_team_logo": "//owcdn.net/img/...",
      "record": "7-3",
      "earnings": "$295,500",
      "logo": "//owcdn.net/img/..."
    }
  ]
}
```

</details>

<details>
<summary><code>GET /events?q=upcoming</code> — response example</summary>

```json
{
  "data": {
    "status": 200,
    "segments": [
      {
        "title": "VCT 2025: Pacific Stage 2",
        "status": "ongoing",
        "prize": "$250,000",
        "dates": "Jul 15—Aug 31",
        "region": "kr",
        "thumb": "https://owcdn.net/img/...",
        "url_path": "https://www.vlr.gg/event/..."
      }
    ]
  }
}
```

</details>

<details>
<summary><code>GET /health</code> — response example</summary>

```json
{
  "https://vlrggapi.vercel.app": {
    "status": "Healthy",
    "status_code": 200
  },
  "https://vlr.gg": {
    "status": "Healthy",
    "status_code": 200
  }
}
```

</details>

## Region Codes

| Code | Region |
|---|---|
| `na` | North America |
| `eu` | Europe |
| `ap` | Asia Pacific |
| `la` | Latin America |
| `la-s` | Latin America South |
| `la-n` | Latin America North |
| `oce` | Oceania |
| `kr` | Korea |
| `mn` | MENA |
| `gc` | Game Changers |
| `br` | Brazil |
| `cn` | China |
| `jp` | Japan |
| `col` | Collegiate |

## Validation & Error Handling

V2 endpoints validate input and return HTTP 400 with descriptive error messages:

- **Invalid region** — must be one of the codes listed above
- **Invalid timespan** — must be `30`, `60`, `90`, or `all`
- **Invalid player timespan** — must be `30d`, `60d`, `90d`, or `all`
- **Invalid match query** — must be `upcoming`, `upcoming_extended`, `live_score`, or `results`
- **Invalid event query** — must be `upcoming`, `completed`, or `live`
- **Invalid ID** — `match_id`, `event_id`, player `id`, and team `id` must be positive integers

```json
{
  "detail": "Invalid region 'xyz'. Valid regions: ap, br, cn, col, eu, gc, jp, kr, la, la-n, la-s, mn, na, oce"
}
```

Original endpoints do not validate input (preserved for backwards compatibility).

## Caching

V2 endpoints use an in-memory TTL cache to reduce load on vlr.gg. Cache durations per endpoint:

| Data | TTL |
|---|---|---|
| Live scores | 30 seconds |
| Match detail (live) | 30 seconds |
| Results | 60 seconds |
| Upcoming matches | 5 minutes |
| Match detail | 5 minutes |
| Search | 5 minutes |
| News | 10 minutes |
| Player matches | 10 minutes |
| Team matches | 10 minutes |
| Event matches | 10 minutes |
| Stats | 30 minutes |
| Events | 30 minutes |
| Event detail | 30 minutes |
| Player profile | 30 minutes |
| Team profile | 30 minutes |
| Rankings | 1 hour |
| Team transactions | 1 hour |

Original endpoints share the same scraper caches.

### Shared-cache (CDN) headers

Successful `GET` responses also carry
`Cache-Control: public, max-age=0, s-maxage=<TTL above>, stale-while-revalidate=<SWR>`
so the Vercel edge (or any shared cache) can absorb repeat traffic across cold
starts. `stale-while-revalidate` is half the TTL for live scores and results and
twice the TTL (capped at a day) elsewhere. Match detail uses the live TTL while a
match is live. Errors, 429s and embedded upstream errors get `no-store`, a `304`
gets `private, max-age=0, must-revalidate`, and `/health` is never shared-cached.
See `utils/cache_headers.py`.

### Team logos in V3 match lists

vlr.gg's list pages carry no team logos, so `/v3/matches` and
`/v3/events/{id}/matches` fill `teams[].image` (and the team `id`/`url`) from a
24-hour logo index fed by every match, team, rankings and live-score page the API
scrapes. Missing entries are filled by fetching at most 10 match pages per
request (4 at a time across all requests, waiting at most 2.5 s). A list that
still has gaps is edge-cached for 15 seconds instead of its usual TTL, so it fills
in after a request or two. See `utils/team_logos.py` and
`api/team_logo_enrichment.py`.

## Installation

### Requirements

- Python `3.11`+ (`.python-version` pins `3.12`, which Vercel uses)
- [uv](https://docs.astral.sh/uv/) — dependencies are declared in `pyproject.toml` and locked in `uv.lock`

```bash
git clone https://github.com/Chefski/vlrggapi/
cd vlrggapi
uv sync
```

### Run locally

```bash
uv run python main.py            # listens on $PORT, default 3001
```

The API will be available at `http://127.0.0.1:3001` and the interactive docs will be at `http://127.0.0.1:3001/`.

### Smoke check

```bash
curl http://127.0.0.1:3001/version
curl "http://127.0.0.1:3001/v2/health"
```

### Docker

```bash
docker compose up --build
```

### Testing

```bash
uv run pytest
uv run ruff check .
```

See [API.md](API.md) for upstream's full V2 reference and [WORKFLOW.md](WORKFLOW.md) for the selector-check workflow.

## Built With

- [FastAPI](https://fastapi.tiangolo.com/)
- [httpx](https://www.python-httpx.org/)
- [Selectolax](https://github.com/rushter/selectolax)
- [cachetools](https://github.com/tkem/cachetools)
- [slowapi](https://github.com/laurentS/slowapi)
- [uvicorn](https://www.uvicorn.org/)

## Contributing

Issues and pull requests are welcome.

Recommended workflow:

1. Branch from `master`.
2. Install dependencies and verify the app starts locally.
3. Run `python -m pytest tests/ -v`.
4. Open a pull request against `master`.

Open a [pull request](https://github.com/axsddlr/vlrggapi/pull/new/master) or file an [issue](https://github.com/axsddlr/vlrggapi/issues/new).

## License

The MIT License (MIT)
