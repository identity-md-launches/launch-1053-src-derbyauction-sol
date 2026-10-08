# WP2: Daily conditions (parked for v1)

**Status: not built in v1.** The original idea was a market-driven pitcher (an IMD oracle
reading the IMD/ETH pool) that changed pitch speed and the timing window.

Why it's parked:

- **It would only handicap people.** Swing quality is computed in the browser, and bots
  call `swing(league, 100, 100, …)` directly. A harder pitcher makes timing harder on the
  page and does nothing to bots, so it shifts arcade prizes (and the auction bonus) toward
  bots.
- **It needs an oracle the game doesn't use.** The live SwarmDerby pays from its own board
  and has no oracle; adding a 0.5 IMD/day oracle just for flavour isn't worth it yet.

What v1 keeps instead: the theme pack's `weather` and `pitcher` are **visual only** (WP1).

Revisit only if the contract itself ever takes conditions into account for every caller.
