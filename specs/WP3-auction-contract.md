# WP3: Auction contract (`DerbyAuction.sol`)

**Goal:** a daily English auction for the right to design a Theme Day. The winning bid
becomes that day's arcade bonus: once the live SwarmDerby says the day is closed, anyone
pays the bonus to that day's arcade top 3 straight from `board(0, day)`. No oracle, no
signatures, no schedule. SwarmDerby is not modified. Repo: `swarm-derby-contracts`.
Money: yes. **IMD audit before launch.**

## Files

| Path | Action |
|---|---|
| `src/DerbyAuction.sol` | create |
| `test/DerbyAuction.t.sol` | create (deploys a real `SwarmDerby` for integration tests) |
| `src/SwarmDerby.sol`, `src/DerbyOdds.sol` | **do not touch** (R1) |
| `DEPLOY.md` | add an "Auction" section: constructor args and the `evm_contracts` launch body |

Solidity `0.8.26`, the repo's `foundry.toml`. Mirror SwarmDerby's patterns: `_pull`, `_send`,
`_trySend` (accepts no-return tokens), `code.length` check on the token at first use,
two-step ownership (`transferOwnership` + `acceptOwnership`), checks-effects-interactions.

## Interface it reads from the live SwarmDerby

```solidity
interface ISwarmDerby {
    function currentDay() external view returns (uint256);
    function dayClosed(uint8 league, uint256 day) external view returns (bool);
    function board(uint8 league, uint256 day) external view returns (address[] memory, uint256[] memory);
}
```

Only league `0` (arcade) is used.

## Constants

| Name | Value | Note |
|---|---|---|
| `MIN_BID` | `2e18` | 2 IMD |
| `MIN_INCREMENT_BPS` | `500` | new lead ≥ lead × 1.05 |
| `CLOSE_OFFSET` | `64800` | 18:00 UTC (6 h build buffer) |
| `ANTI_SNIPE` | `300` | 5 min |
| `MAX_EXTENSION` | `3600` | extensions stop at 19:00 UTC (5 h build and veto buffer) |
| `MAX_BUILD_FEE` | `1e18` | |
| `RECLAIM_AFTER` | `7 days` | after the theme day ends |
| `TIP_BPS` | `50` | 0.5% to whoever pays the bonus |
| shares | `6000 / 2500 / 1500` | |

## Days

Auctions are keyed by **theme day** `D` (UTC day number, `timestamp / 86400`), the day the
winner's theme runs and the bonus is played for.

- `start(D) = (D − 2) · 86400 + CLOSE_OFFSET` (18:00 UTC two days before)
- `end(D) = (D − 1) · 86400 + CLOSE_OFFSET`, plus anti-snipe extensions (stored per day), never
  later than `(D − 1) · 86400 + CLOSE_OFFSET + MAX_EXTENSION`
- `openDay() = (block.timestamp − CLOSE_OFFSET) / 86400 + 2`

## Bid answers

```solidity
struct Answers {
    string creature;  // 1–24 bytes
    uint8 vibe;       // 0 hype, 1 chill, 2 grumpy, 3 chaotic
    uint8 stadium;    // 0 moon, 1 beach, 2 cyber-city, 3 volcano, 4 underwater, 5 desert
    uint8 weather;    // 0 clear, 1 windy, 2 rain, 3 snow, 4 fog, 5 meteor-shower
    string title;     // 1–24 bytes
    string shoutout;  // 0–32 bytes
}
```

Strings: bytes `0x20`–`0x7E`, excluding `<` `>` `"` `\`. Otherwise revert `BadAnswers()`.
Answers are stored and emitted for the operator; the page never displays them (R4).

## Constructor

```solidity
constructor(address owner_, IERC20 imd_, ISwarmDerby derby_, address studio_, uint256 buildFee_)
```

`buildFee_ ≤ MAX_BUILD_FEE`. **Launch with `buildFee_ = 0`**: swarm jobs are paid in
Ethereum IMD and the fee would arrive as Robinhood IMD, so v1 pays builds from the
operator's job wallet and the whole bid goes to players. `studio_` may be any nonzero address.

## Functions

| Function | Who | Rules |
|---|---|---|
| `bid(uint256 day, uint256 amount, Answers calldata a)` | anyone | `start ≤ now < end`; `amount ≥ MIN_BID` and ≥ lead × 1.05; answers valid; pull `amount`; then refund the previous leader with `_trySend`, crediting `refunds[prev]` if it fails (a failed refund never blocks a bid); if `end − now < ANTI_SNIPE`, set `end = min(now + ANTI_SNIPE, (D − 1) · 86400 + CLOSE_OFFSET + MAX_EXTENSION)` |
| `settle(uint256 day)` | anyone | `now ≥ end`, once. Winner: `fee = min(buildFee, amount)` to `studio`; `bonus[day] = amount − fee + carry`; `carry = 0`. No bids: just mark settled |
| `veto(uint256 day)` | owner | settled, has a winner, not vetoed, `now < day · 86400`. Refund `bonus[day] − carryIn[day]` to the winner (the carried part goes back to `carry`); zero `bonus[day]` |
| `payBonus(uint256 day)` | anyone | settled, not vetoed, not paid, `bonus[day] > 0`, `derby.dayClosed(0, day)`. Mark paid. Read `board(0, day)`; if empty, move `bonus[day]` to `carry`. Else `tip = bonus · TIP_BPS / 10000` to `msg.sender`; split the rest 60/25/15 to the first three players with `_trySend`; unfilled places, failed sends and dust go to `carry` |
| `reclaim(uint256 day)` | anyone | not paid, not vetoed, `now > (day + 1) · 86400 + RECLAIM_AFTER`: return `bonus[day] − carryIn[day]` to the winner, carried part to `carry` |
| `withdrawRefund()` | bidder | pays `refunds[msg.sender]` |
| `setStudio`, `setBuildFee` | owner | fee ≤ `MAX_BUILD_FEE`; applies to auctions settled later |
| `transferOwnership`, `acceptOwnership` | owner / pending | two-step |
| views | | `auction(day)` (leader, amount, end, settled, vetoed, paid, bonus), `answers(day)`, `openDay()`, `minNextBid(day)`, `carry()`, `refunds(addr)` |

`carryIn[day]` records how much `carry` was folded into that day's bonus, so vetoes and
reclaims only return the winner's own money.

## Events

`Bid(day, bidder, amount, end, creature, vibe, stadium, weather, title, shoutout)`,
`Settled(day, winner, amount, fee, bonus)`, `Vetoed(day, winner, refunded)`,
`BonusPaid(day, winners, amounts, payer, tip, carried)`, `Reclaimed(day, winner, amount)`,
`RefundCredited(bidder, amount)`.

## Known limit (document in DEPLOY.md)

The bonus goes to the arcade board's top 3. The arcade cap is per wallet and bots can play
the arcade league directly, the same as the arcade pot today.

## Done when

1. [ ] Bids below 2 IMD, under +5%, before start, after end, or with bad answers revert.
2. [ ] Outbid refunds land; a failing refund is credited and withdrawable; raising your own
       lead refunds your previous bid.
3. [ ] A bid in the last 5 minutes extends the end, repeatedly, but never past 19:00 UTC; the
       owner can still `veto` the day after the longest extension.
4. [ ] `settle` with fee 0 and with fee 1 IMD splits exactly; settling twice reverts; empty
       auctions settle.
5. [ ] `payBonus` reverts until the real SwarmDerby reports `dayClosed(0, day)`, then pays
       tip + 60/25/15 to that day's arcade top 3 (integration test with real swings).
6. [ ] Agent-league scores never affect the bonus; 1–2 players and an empty board move the
       rest to `carry`, and the next settled auction picks it up.
7. [ ] `veto` (owner only, before the theme day) and `reclaim` (after the grace period, only
       if unpaid) return only the winner's own bid.
8. [ ] Fuzz: after any sequence of bids, settles, vetoes and payouts, the contract's IMD
       balance equals current lead + unpaid bonuses + carry + credited refunds; and all 54
       existing tests still pass.
