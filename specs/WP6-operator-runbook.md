# WP6: Operator runbook

"Operator" = the owner's IMD agent. "Owner" = the person who owns the contract (owner
wallet = the seat owner wallet, never on the operator's server).

## Standing budget (owner sets once)

The operator normally asks before every payment. For the nightly loop the owner grants a
**standing budget**: up to **1.0 IMD per night** (one theme job plus one send-back) from the
job wallet, and nothing else without asking. Anything above that, or any other kind of
payment, goes back to asking.

## Nightly timeline (UTC)

| Time | Who | Step |
|---|---|---|
| 18:00 | operator (anyone can) | `settle(D)` on DerbyAuction for tomorrow's theme day `D` |
| 18:05 | operator | read the winning `Bid`; screen the answers (WP5) |
| 18:15 | operator | send the WP5 `job.continue` |
| ~19:15 | swarm | pack built, site republished |
| by 21:00 | operator | preview to the owner: screenshots, title, shoutout, live link |
| by 23:30 | owner | only if something's wrong: `veto(D)` from the owner wallet |
| 00:00 | — | theme day `D` begins |
| after 00:00 | anyone | `settleNextDay(0)`, `settleNextDay(1)` on SwarmDerby and `payBonus(D−1)` on DerbyAuction (site buttons, or the operator) |

**If the operator goes quiet** (a scheduled turn misses), nothing breaks: the day runs on
`gus`, the auction can be settled by anyone, and the bonus still pays from the board. The
owner just sees no preview that night.

## Money

| Item | Paid in | Per day | From |
|---|---|---|---|
| Theme job (+ optional send-back) | Ethereum IMD | 0.5 (–1.0) | job wallet, standing budget |
| Bonus prize | Robinhood IMD | the whole bid | winner's bid (build fee 0) |
| Arcade + agent pots | Robinhood IMD | from turn sales | SwarmDerby, unchanged |

At ~0.25 IMD net per job, the current job wallet covers roughly 80 nights. The operator
reports the balance weekly and warns when fewer than 14 nights remain.

## Escalate to the owner when

- answers name an existing character, real person or brand, or are offensive;
- a job fails twice or won't publish by 21:00;
- `settle`, `payBonus` or `settleNextDay` reverts unexpectedly;
- the job wallet can't cover 14 more nights.

## One-time setup

1. WP1 built and published (the site serves `themes/`).
2. WP3 built, IMD-audited, launched with `launch.open` `evm_contracts`: owner = seat owner
   wallet, `imd` = `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, `derby` =
   `0xBa58BC6b5aCf8043DAEa2Bf1BF6C1c09cF84b03C`, `studio` = operator address, `buildFee` = 0.
3. WP4 built with the auction address; site republished.
4. Seed day one: the owner or operator places the first 2 IMD bid so the drawer isn't empty.
