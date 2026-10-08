# WP1: Theme packs

**Goal:** the game loads a per-day theme pack (batter, pitcher, stadium, colours, weather
visuals, commentary, title) from static files under `themes/`, and falls back to the
built-in look on any problem. Also removes the stale oracle text. Repo: `swarm-derby-site`.
Money: none.

## Files

| Path | Action |
|---|---|
| `dev/game.html` | edit: loader, rendering hooks, text cleanup |
| `index.html` | rebuild (R6) |
| `themes/index.json` | create |
| `themes/gus/…` | create: today's look as a pack |
| `dev/validate-theme.mjs` | create: validator, Node 18+, no npm dependencies |
| `dev/render-gus.mjs` | create: renders GUS's poses to PNG (Playwright allowed, dev only) |
| `README.md` | update "Host": publish `themes/**` too |

## 1. `themes/index.json`

```json
{ "version": 1, "default": "gus", "days": { "2026-10-09": "2026-10-09" } }
```

- `days` maps a UTC date to a folder under `themes/`. Folder names: `^[a-z0-9-]{1,32}$`.
- Missing date → `default`. Keep at most the last 7 dated entries (WP5 prunes).

## 2. `themes/<id>/theme.json`

```json
{
  "version": 1,
  "id": "2026-10-09",
  "title": "Lobster Cup",
  "shoutout": "@alice",
  "winner": "0x…",
  "auctionDay": 20735,
  "batter": {
    "name": "PINCHY",
    "number": "7",
    "sprites": {
      "idle": "batter-idle.png", "mash": "batter-mash.png",
      "swing": ["batter-swing-1.png", "batter-swing-2.png", "batter-swing-3.png"],
      "celebrate": "batter-celebrate.png", "sad": "batter-sad.png"
    }
  },
  "pitcher": { "name": "DAEMON #42", "sprite": "pitcher.png" },
  "stadium": {
    "name": "Tidepool Park",
    "backdrop": "stadium.png",
    "palette": { "grass": "#15803d", "grassStripe": "#166534", "dirt": "#9c633a",
                 "lines": "#ffffff", "wallTrim": "#10b981", "sky": "#020617" }
  },
  "weather": "rain",
  "commentary": { "whiff": ["…"], "foul": ["…"], "pop": ["…"],
                  "homer": ["… {feet} …"], "bomb": ["…"], "slam": ["…"] }
}
```

| Field | Rule |
|---|---|
| `version` | `1` |
| `title` | 1–24 chars |
| `shoutout` | `null` or 1–32 chars |
| `winner`, `auctionDay` | `null` for non-auction packs |
| `batter.name` | 1–12 chars, `A–Z 0–9`, space, `#`, `-` |
| `batter.number` | 1–2 digits |
| `batter.sprites` | all five keys; `swing` exactly 3 frames |
| `pitcher` | optional (omitted = built-in daemon) |
| `stadium.backdrop` | optional (omitted = built-in racks) |
| `stadium.palette` | all six keys, `#rrggbb` |
| `weather` | `clear`, `windy`, `rain`, `snow`, `fog` or `meteor-shower` |
| `commentary` | each key 3–8 lines, 8–90 chars; `{feet}` is the only placeholder |
| all text | no `<`, `>`, `http`, `www.`, control characters |

## 3. Assets

| Asset | Format | Size | Notes |
|---|---|---|---|
| batter (7 files) | PNG, transparent | exactly 128×160 | feet centred at (64, 150); faces the plate like GUS; bat drawn in the sprite |
| swing frames | | | 1 load back, 2 contact, 3 follow-through |
| pitcher | PNG, transparent | exactly 96×96 | centred |
| backdrop | PNG or WebP | exactly 1600×640 | wall above the fence; keep x 380–1220, y 60–480 low-detail (terminal draws on top) |

Each image ≤ 300 KB; pack folder ≤ 1.2 MB; only files named in `theme.json`.

## 4. Loader

1. On start and every 60 s, compute the UTC date; `fetch('themes/index.json')`; load
   `themes/<id>/theme.json`.
2. Validate in the browser with the §2–3 rules; preload images (5 s total timeout) and
   check pixel sizes.
3. Any failure → built-in look, one `console.warn`, game keeps running.
4. Date change → swap between at-bats, never mid-swing.
5. `file://` or no `themes/` → exactly as today (R7).

## 5. Rendering

| Where | With a pack | Without |
|---|---|---|
| `drawSlugger` | sprite for the state at `(homePlateX − 106, homePlateY − 150)`, keeping today's shake/sway/hop transforms; swing frame 1/2/3 as the bat passes ⅓ and ⅔ of its sweep | current code |
| `drawPitcherOnCenterMound` | `pitcher.sprite` centred on the mound | current code |
| `drawIMDGrandstands` | `backdrop` scaled to the wall, then the terminal | current |
| `drawPerspectiveField` | `palette` | current colours |
| weather | overlay only: rain streaks, snow flakes, 15% fog haze, windy drifting leaves, meteor streaks in the sky band; ≤ 150 particles; none with `prefers-reduced-motion`. **Never changes the pitch or timing (R2).** | none |
| commentary | swing results pick a line for the tier, `{feet}` filled | current |
| terminal line 2 | `> SLUGGER ON DECK: <name> #<number>` | `GUS #7` |
| load banner | `TODAY: <title>`; if `shoutout`, `designed by <shoutout>` | none |

## 6. Stale text cleanup (always, with or without a pack)

- Terminal line 1: replace `! 706 agents online | 24h: 314 oracles` with
  `! SWARM DERBY · <pack title or "DAILY DERBY">`.
- `commentaryPool`: remove every line mentioning oracles, verifiers, attestations,
  signatures, quorum, panels or EIP-712. Keep pitcher-daemon banter.
- Footer: remove `CONSENSUS: EIP-712`; show `PAID FROM THE ON-CHAIN BOARD` instead.

## 7. Validator and fixture

- `node dev/validate-theme.mjs themes/<id>` checks §2–3 (pixel sizes read from file headers),
  prints each failure, exits non-zero. `--all` checks `index.json` and every referenced pack.
- `dev/render-gus.mjs` renders today's `drawSlugger` poses, pitcher and racks to the sizes in
  §3 and writes `themes/gus/theme.json` with today's colours, `weather: "clear"`, and the
  cleaned commentary.

## Done when

1. [ ] `node dev/validate-theme.mjs --all` passes.
2. [ ] A broken copy (wrong size, missing sprite, `<script>` in the title, 1.5 MB folder)
       fails with one clear message per problem.
3. [ ] Served over HTTP, the `gus` pack looks the same as today (side-by-side screenshots).
4. [ ] A second test pack mapped to today changes batter, pitcher, backdrop, palette,
       weather overlay, commentary, terminal and banner (screenshots).
5. [ ] `file://` and no-`themes/` both play exactly as before; a pack with a broken image
       falls back without errors.
6. [ ] The stale text in §6 is gone (grep for `oracle`, `attest`, `EIP-712`, `quorum`,
       `Verifier` in displayed strings returns nothing).
7. [ ] Pitch speed, timing window and odds are byte-for-byte unchanged with every weather.
8. [ ] `index.html` rebuilt and makes no requests beyond R3; the live wallet flow
       (`e2e/play.py`, pointed at the new page) still passes; the published site serves
       `themes/`.
