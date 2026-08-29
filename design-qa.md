# Match Detail Visual QA

- Source visual truth: `/var/folders/wf/z4gtsgpn0_vbfyjx5jz7z4pw0000gn/T/codex-clipboard-d6aa0f84-21d5-47ac-829b-03acff24a587.png`
- Implementation screenshot: `/Users/chefski/.codex/visualizations/2026/08/29/01a04db3-4dea-7241-bb6c-1ab5bb2ac075/match-detail-completed-dark-final-raw.png`
- Side-by-side comparison: `/Users/chefski/.codex/visualizations/2026/08/29/01a04db3-4dea-7241-bb6c-1ab5bb2ac075/design-qa-comparison-full.png`
- Viewport: iPhone 17 Pro, iOS 26.5, 402 x 874 points at 3x
- Source dimensions: 1498 x 1069 pixels; selected rightmost frame approximately 505 x 1001 pixels within the concept board
- Implementation dimensions: 1206 x 2622 pixels raw; normalized to 402 x 874 points, then downsampled to 368 x 800 pixels for the side-by-side comparison
- Density normalization: the source is a concept-board frame without native device density metadata. The comparison fits its selected frame to 368 x 730 and centers it beside the 368 x 800 optimized Simulator capture. Pixel-perfect measurements are intentionally not inferred across those different source densities.
- State: target is live; implementation capture is completed because the production `live_score` endpoint returned no matches. Scheduled and completed production states were captured, and the live V3 partial-map fixture passed in the unit suite.

## Full-view comparison evidence

The side-by-side comparison shows the intended hierarchy in both artifacts: native top navigation, a dark edge-to-edge team-color hero, two team identities, central state and score, map context, a simple horizontal section selector, and overview content immediately below. Flank keeps the event identity in the hero and repeats full metadata in the existing Overview card, preserving the app's V3-backed information architecture.

## Focused-region comparison evidence

A separate crop was not needed because this task is explicitly limited to the upper match-detail screen and the full comparison renders that complete region at a readable 368-point-equivalent width on each side. Logos, status, scores, map context, selector labels, typography, and Overview content are legible in the same comparison artifact.

## Findings

No actionable P0, P1, or P2 differences remain.

- Fonts and typography: the implementation intentionally uses San Francisco and Dynamic Type instead of imitating the concept's display treatment. Weight, hierarchy, monospaced scores, wrapping, and scaling remain native and readable. AX XXL switches the hero to a vertical composition without truncating team names.
- Spacing and layout rhythm: the hero and selector are full width, the score is optically centered, tap targets meet the native minimum, and lower cards retain Flank's existing spacing. At narrow widths the six-item selector scrolls horizontally instead of compressing labels.
- Colors and visual tokens: sampled logo colors are restrained before entering the hero, white hero content remains high contrast, live keeps a semantic red treatment, and light/dark system surfaces remain adaptive. The final orange selector/action accents align with Flank's visual language.
- Image quality and asset fidelity: the UI uses real V3 team and event logo URLs. Missing image URLs keep a native shield fallback and safe team-color defaults; no custom logo artwork was introduced. Summary payloads with nil logo URLs successfully hydrate from detail payloads in the observed production matches.
- Copy and content: all visible team, event, stage, series, score, status, map, format, and date content comes from V3 data or existing Flank labels. Team tags and regions are shown only when supplied; observed payloads omitted them, so none were invented.
- Interactions and accessibility: team links, Overview/Maps/Stats/Rounds/Economy/History switching, calendar action, streams, pull-to-refresh, and data-dependent section visibility remain intact. Reduce Motion sets the fluid background speed to zero and disables the selector animation.

## Comparison history

### Pass 1 — blocked

- [P2] Scheduled context displayed `Map 1 · TBD` from a placeholder game instead of the useful scheduled time.
  - Evidence: `match-detail-scheduled-light-pass1.jpg`.
  - Fix: scheduled heroes now prioritize the exact localized start date/time; map context is reserved for live/completed games.
- [P2] The selected selector underline inherited a low-contrast black accent in light mode.
  - Evidence: `match-detail-scheduled-light-pass1.jpg`.
  - Fix: use Flank's orange accent for the selected underline.
- [P2] The existing white prominent calendar treatment lost its label in dark mode.
  - Evidence: `match-detail-scheduled-dark.jpg`.
  - Fix: use the native orange prominent button style in both appearances.

### Pass 2 — passed

- Scheduled light final: `match-detail-scheduled-light.jpg` was superseded by the corrected scheduled hierarchy visible in `match-detail-scheduled-dark-final.jpg`; the same code path is appearance-adaptive.
- Scheduled dark final: `/Users/chefski/.codex/visualizations/2026/08/29/01a04db3-4dea-7241-bb6c-1ab5bb2ac075/match-detail-scheduled-dark-final.jpg`.
- Completed dark final: `/Users/chefski/.codex/visualizations/2026/08/29/01a04db3-4dea-7241-bb6c-1ab5bb2ac075/match-detail-completed-dark-final-raw.png`.
- AX XXL: `/Users/chefski/.codex/visualizations/2026/08/29/01a04db3-4dea-7241-bb6c-1ab5bb2ac075/match-detail-scheduled-dark-axxxl.jpg` and `match-detail-scheduled-dark-axxxl-scrolled.jpg`.
- Missing/placeholder team data: `/Users/chefski/.codex/visualizations/2026/08/29/01a04db3-4dea-7241-bb6c-1ab5bb2ac075/match-detail-missing-team-dark.jpg`.

## Remaining validation caveat

The production live endpoint had zero matches during verification, so there is no honest live-state Simulator screenshot. The shared hero's live branch is exercised by the passing `testLiveMatchDecodesPartialMapData` V3 fixture, but that is data/logic verification rather than visual runtime proof.

## Implementation checklist

- [x] Edge-to-edge team-color hero from real logo assets
- [x] Scheduled, live, completed, and unknown-safe presentation logic
- [x] Real team logos/names and conditional tags/regions
- [x] Central status, score, date/map context
- [x] Native adaptive horizontal section selector
- [x] Existing data-dependent sections and interactions preserved
- [x] Light/dark, AX XXL, Reduce Motion, and missing-data behavior checked
- [x] Final build and tests passed

final result: passed
