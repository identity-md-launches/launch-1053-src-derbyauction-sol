# Swarm Derby: Theme Day build specs (v2, matches the live code)

**Theme Day:** every day an IMD auction picks who designs tomorrow. The winner answers a few
questions, the IMD swarm builds that day's batter and stadium from the answers, and the
winning bid becomes a bonus prize for that day's arcade top 3, paid from the live contract's
own board. No oracle anywhere.

Written against `swarm-derby-contracts@b1a01be` (54 tests; SwarmDerby live at
`0xBa58BC6b5aCf8043DAEa2Bf1BF6C1c09cF84b03C`, IMD launch #871) and
`swarm-derby-site@4ab6185`.

## Build order

| # | Package | Repo | Depends on | Moves money |
|---|---|---|---|---|
| **WP1** | [Theme packs](WP1-theme-packs.md): format, loader, validator, GUS as pack `gus`, remove stale oracle text | site | — | no |
| WP2 | [Daily conditions](WP2-daily-conditions.md): **parked for v1** | — | — | — |
| **WP3** | [Auction contract](WP3-auction-contract.md): `DerbyAuction.sol`, bonus paid from `board(0, day)` | contracts | live SwarmDerby | yes |
| **WP4** | [Auction UI](WP4-auction-ui.md): bid drawer, refunds, "designed by", pay-bonus button | site | WP1, deployed WP3 | yes |
| **WP5** | [Nightly theme job](WP5-theme-build-job.md): one `job.continue` that builds the pack and republishes | site | WP1 | no |
| **WP6** | [Operator runbook](WP6-operator-runbook.md): timeline, budget, escalation | — | all | — |

**Start with WP1.** It moves no money and can't break the live game: a bad or missing pack
falls back to the built-in GUS. WP3 can run alongside it (contracts repo only) but needs the
IMD audit before launch.

## Handing a package to the swarm

1. Commit `specs/` into **both** repos.
2. Code work: `job.continue` on the repo's existing project (keeps the site name; a new
   `job.open` gets a renamed site). Site hosting is part of the same continuation (WP5).
3. Objective: *"Implement specs/WPn-<name>.md exactly, following every rule in
   specs/README.md. Change only the files the spec lists."*
4. IMD allows **at most 8 acceptance criteria per step**. Use the spec's first 7 "Done when"
   items plus: *"every remaining item in specs/WPn 'Done when' passes; report each one."*
5. There is no reject: each send-back is another `job.continue` (0.5 IMD). Dry-run with
   `POST /requests/check` first.

## Global rules

- **R1 Frozen game rules.** Never change `src/SwarmDerby.sol`, `src/DerbyOdds.sol`, or the
  `DerbyOdds` script block in `dev/game.html`. All 54 existing tests keep passing.
- **R2 Looks, not outcomes.** Themes are visual and text only. They never change pitch
  timing, the timing window, swing quality, tiers, distances, prices, caps or payouts.
  (Bots call the contract directly, so anything harder in the browser would only handicap
  people.)
- **R3 Self-contained page.** No CDNs, external scripts or fonts. Network calls: the
  Robinhood Chain RPC and same-origin files under `themes/`. Nothing else.
- **R4 Untrusted text.** Bid strings, theme pack text and chain data render with
  `textContent`, never `innerHTML`. Bid text is **never** shown in the page straight from the
  chain; it only appears through a published (screened) theme pack.
- **R5 Original content.** No existing characters, mascots, logos, artworks or real people.
  No brands other than the winner's own shoutout. No URLs in displayed text.
- **R6 One source.** Edit `dev/game.html`, rebuild from `dev/` with
  `python3 build.py game.html ../index.html` (setup in `dev/build.py`), commit both.
- **R7 Practice always works.** No wallet, no network, no `themes/`: the game plays as now.
- **R8 No secrets** in repos, objectives, uploads or theme files.

## Reference: game hooks (`dev/game.html`)

| Function | Today | Touched by |
|---|---|---|
| `drawSlugger(ctx)` | GUS in `idle`, `mash`, `swing`, `celebrate`, `sad` | WP1 |
| `drawIMDGrandstands(ctx)` | racks + terminal (line 1 is a fake "706 agents online \| 24h: 314 oracles") | WP1 |
| `drawPerspectiveField(ctx)` | grass, dirt, lines, bases via `fieldGeom()` | WP1 |
| `drawPitcherOnCenterMound(ctx)` | the daemon | WP1 |
| `commentaryPool`, `postCommentary(text)` | includes fake "Oracle #77 … Attestation signed", "Verifier …" lines | WP1 |
| footer `CONSENSUS: EIP-712` | stale | WP1 |
| `DERBY_CONFIG`, `live`, `refreshBoard()`, settle flow | chain config, board, `settleNextDay` | WP4 |
