# Swarm Derby: deploy notes

Robinhood Chain mainnet (chain id 4663) · IMD `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` ·
public RPC `https://rpc.mainnet.chain.robinhood.com` · explorer `https://robinhoodchain.blockscout.com`

## What's in this folder

| | |
|---|---|
| `src/SwarmDerby.sol` | the game: two leagues, turns, swings, scoreboards, slam vaults, settlement |
| `src/DerbyOdds.sol` | the odds table; the browser runs identical math |
| `test/` | 54 Foundry tests (two fuzzed) |
| `e2e/` | full rehearsal on a local devnet with the real page and a scripted wallet |
| `imd-check.mjs` | free readiness check against IMD's API |
| `HANDOFF.md` | ordered go-live checklist for the swarm agent |
| `web/derby-odds.js` | the browser twin of DerbyOdds |

The site is the separate `swarm-derby-site` repo: `index.html`, `agent.md` and `agent-bot.mjs`, hosted together. `HANDOFF.md` is the ordered go-live checklist.

## 0. Readiness check (free)

```
node imd-check.mjs
```

It reports whether `evm_contracts` launches are open on chain 4663 and which actions IMD has
enabled. It spends nothing.

## 1. Test

```
forge test               # forge-std is vendored in lib/
```

## 2. How it works

**Two leagues.** Each has its own turns, daily pots, slam vault, scoreboard and daily payout.

| | Arcade (0) | Agent (1) |
|---|---|---|
| Who | people on the game page | bots / AI agents calling the contract |
| Cap | 20 swings per wallet per UTC day | none |
| Ranked by | longest homer of the day | total homer feet of the day |

On-chain a script and a person look the same. The cap makes out-spending the arcade
expensive; it does not make it impossible (one person can run several wallets).

**Prices.** 1 turn = 0.15 IMD, 5 = 0.5 IMD. The owner can change both with `setPrices`, but
never below 0.01 IMD a turn (0.05 a pack). Every purchase is split 40% burned, 45% to that
league's pot for the current UTC day, 10% to its slam vault, 5% ops. A grand slam (550+ ft)
instantly pays 10% of its league's slam vault.

**A swing, with no server.** The player picks a secret salt and calls
`swing(league, quality, velo, commit)` with `commit = keccak256(abi.encode(salt, player))`.
The roll uses the hash of the block 5 blocks later (~0.5s). The player then calls
`finalize(swingId, salt)`. Not revealed within 255 blocks (~25s) counts as a foul, and
`expire` closes it out. Nobody, including the deployer, can predict or steer a roll. A swing
scores on the UTC day it was committed, the same day its arcade cap slot was used.

**Skill and the odds.** `quality` (1-100, from exit velo and timing) and `velo` (0-100) come
from the client, so a script can always send 100: it plays like a perfect batter. The odds
table is monotone, so a better swing never loses odds, and a perfect swing is a bounded edge
(slam 0.8% at quality 100 against 0.21% at quality 1). Under velo 60 no bomb or slam is
possible.

**Quick swings.** A throwaway browser key signs an EIP-712 `Session(player, session, nonce)`
message, and the player calls `setSession(key, signature)`. The key can then swing, reveal and
buy turns for the player with no wallet popups. Homers, slam payouts, leaderboard credit and
bought turns all go to the player. Nobody can bind an address without that key's signature,
the key can leave with `leaveSession()`, and the player can revoke it with
`setSession(address(0), "")`. The page funds the key with gas sized from live fees.

**Live scoreboards.** `board(league, day)` holds each UTC day's top 10, so the page shows the
leaderboards with one call per league and no indexer. The same board pays the day's prizes.

**Daily payout.** Each UTC day with a purchase or a swing joins its league's queue. When a day
is over and its last swing can no longer be revealed (255 blocks after its target),
anyone calls `settleNextDay(league)`. The oldest open day is paid: 90% of that day's pot plus
rollover goes to the board's top 3 (60 / 25 / 15) after a 0.5% tip to the caller. The other
10%, unfilled places and any prize the token refuses to deliver roll over to the next day. A
day with no homers pays no tip, and its whole pot rolls over. Days settle in order, each
exactly once. `nextSettlement(league)` shows what the next call pays and whether it is ready.

## 3. Deploy through IMD (`launch.open`, `evm_contracts`)

Push this folder to a **public** GitHub repo (without `e2e/Mocks.sol` in `src/`), then pin it.
IMD launches only a Foundry repo with `bytecode_hash = "none"` in `foundry.toml` (already set):

```
POST /requests/import  {"url": "https://github.com/YOU/swarm-derby-contracts", "kind": "contracts"}
```

Dry-run with `POST /requests/check` before paying, and confirm chain 4663 lists
`evm_contracts` in `GET /requests/capabilities`.

```json
{
  "objective": "Deploy SwarmDerby (src/SwarmDerby.sol) unchanged to Robinhood Chain. Deploy only SwarmDerby. Do not create or launch any token, distributor or pool. Constructor arguments in order: owner_ = $owner; imd_ = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127; singlePrice_ = 150000000000000000; packPrice_ = 500000000000000000.",
  "repoUrl": "https://github.com/YOU/swarm-derby-contracts",
  "baseCommit": "COMMIT_FROM_IMPORT",
  "contracts": ["src/SwarmDerby.sol"],
  "onchain": "evm_contracts",
  "chainId": 4663,
  "owner": "0xyour_wallet_lowercase",
  "github": true
}
```

IMD reviews and may adapt the code before deploying: **read the adapt step's diff**. The odds
math must stay identical to the browser engine (`forge test` checks this).

## 4. Point the site at the contract

In the site repo set `DERBY_CONFIG.networks.robinhood.derby` in `dev/game.html`, rebuild
`index.html` with `dev/build.py`, and replace `SWARM_DERBY_ADDRESS` in `agent.md`. Until the
address is set the page stays practice-only.

## 5. Paying out

Nothing to schedule and no oracle. After 00:00 UTC (plus ~25s for the last reveals), the
game page reads `nextSettlement(league)` and shows any visitor a **Pay the winners** button
in the leaderboard. Whoever presses it calls `settleNextDay(league)` from their own wallet and
earns 0.5% of the payout. Agents can do the same from code. If no one does, the day waits in
the queue; nothing expires.

## Known limits

- Rolls mix the player's committed salt with a future L2 block hash; neither the player nor
  Robinhood's sequencer can steer one alone.
- Swing quality is reported by the client. Scripts play as perfect batters; the odds table
  bounds what that is worth, and the arcade cap applies to everyone.
- The arcade cap is per wallet. Multiple wallets get around it at full price.
- The owner can change prices (never below 0.01 IMD a turn), withdraw the 5% ops share and
  move ownership in two steps (`transferOwnership`, then `acceptOwnership` from the new
  address). The owner cannot touch pots or vaults, and ownership cannot be renounced.
- A purchase pays the price in force when it lands, so a price change also applies to a buy
  already sent from the page. Change prices only when nobody is buying.
- The Robinhood IMD token's owner can block addresses or stop transfers. Blocking the derby
  or `0xdead` stops purchases, payouts and ops withdrawals. A blocked player's slam prize
  stays in the vault, and a blocked winner's daily prize rolls over.
- The constructor accepts any non-zero token address, so a deploy rehearsal on an empty
  chain works. If the address has no code (e.g. the Ethereum IMD), every purchase reverts
  `NotAContract()`. Check `imd()` on the explorer right after the deploy.
- A session key's consent signature has no deadline: it stays usable until the key is bound
  once.

## Auction

`src/DerbyAuction.sol` implements WP3; it does not modify or deploy SwarmDerby. IMD audit job
`928b670b` (on commit `f797a19`) found 1 medium, 3 low and 3 info items. The medium and the
three lows are fixed: the reclaim grace starts no earlier than settlement, a late settle takes
no carry, a studio that cannot be paid is credited, and `openDay()` names a day that is still
extended. The info items are operating notes under **Known limits**. Nothing is deployed yet.

Constructor arguments, in order:

| Argument | Launch value |
|---|---|
| `owner_` | `$owner`, the actual owner supplied to the launch request |
| `imd_` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (Robinhood IMD) |
| `derby_` | `0xBa58BC6b5aCf8043DAEa2Bf1BF6C1c09cF84b03C` (existing SwarmDerby from the WP3 specs) |
| `studio_` | `$owner`; any nonzero address is allowed and the owner can change it later |
| `buildFee_` | `0` |

Launch with fee **zero**: swarm build jobs are paid in Ethereum IMD, whereas this fee would
arrive as Robinhood IMD. The operator's job wallet pays for builds, and the whole winning
bid funds the arcade bonus. The maximum configurable fee is `1000000000000000000` (1 IMD).
Fees and studio changes apply when an auction settles, including auctions already bid on.

The constructor validates nonzero addresses and the fee cap, then stores the arguments;
it calls neither IMD nor SwarmDerby and works in the launch harness on an empty chain.
The first bid checks the token's code and requires receipt of the full bid. Transfers accept
standard boolean returns or no return data. This is for the exact-transfer, non-rebasing IMD
token; fee-on-transfer deposits are rejected. The addresses above are supplied by this repo's
deployment notes and specs, and were not verified against a live RPC in this package. The
deployer must verify the target chain and the configured token and derby before launch.

Use the existing contracts import and readiness-check flow with this `evm_contracts` body.
Replace the repo, pinned commit, and owner placeholders with the actual launch values:

```json
{
  "objective": "Deploy only DerbyAuction (src/DerbyAuction.sol) to Robinhood Chain after the IMD audit. Do not deploy or modify SwarmDerby or create a token, distributor or pool. Constructor arguments in order: owner_ = $owner; imd_ = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127; derby_ = 0xBa58BC6b5aCf8043DAEa2Bf1BF6C1c09cF84b03C; studio_ = $owner; buildFee_ = 0.",
  "repoUrl": "https://github.com/YOU/swarm-derby-contracts",
  "baseCommit": "COMMIT_FROM_IMPORT",
  "contracts": ["src/DerbyAuction.sol"],
  "onchain": "evm_contracts",
  "chainId": 4663,
  "owner": "ACTUAL_OWNER_ADDRESS",
  "github": true
}
```

Auctions use UTC theme-day numbers. They start at 18:00 two days before the theme day and
end at 18:00 the day before it, with repeatable five-minute anti-snipe extensions. Extensions
stop at 19:00 UTC (`MAX_EXTENSION`), so at least five hours remain for the build and the veto.
Answers are operator input; the page must only display text from screened, published theme
packs.

Anyone can settle an ended auction and pay its bonus once `dayClosed(0, day)` is true;
SwarmDerby's own pot need not have been settled. A nonempty arcade board pays the caller
0.5%, then splits the remainder 60/25/15 among its first three players. Missing places,
failed prize transfers, rounding dust, and an empty board's entire bonus become carry.
The next auction settled **with a winner** before its theme day begins takes that carry;
empty auctions and auctions settled late leave it alone. Outbid refunds and a studio fee
that cannot be sent become credits in `refunds`, withdrawn by their owners using
`withdrawRefund()`. A failed caller tip reverts the payout so another caller can retry.

The owner can veto a settled auction before its theme day begins, set the studio and fee,
and transfer ownership in two steps. Anyone can reclaim an unpaid bonus strictly after
seven days following the theme day's end or the settlement, whichever is later. Veto and
reclaim return the winner's bid **less any fee already paid**, with failed refunds credited;
they return inherited carry to the carry pool. Neither operation gives carried prize money
to the bidder. Reclaim marks the auction terminal (`paid`); veto marks it `vetoed`. There is
no owner sweep of player funds.

**Known limits:**

- The bonus goes to the arcade board's top 3. The arcade cap is per wallet, and bots can
  play the arcade league directly, the same as the arcade pot today.
- Settle each auction before midnight UTC. After that the owner cannot veto it and it takes
  no carry. `settle` pays no tip, so the operator (or the site's `SETTLE` button) settles.
- Pay each bonus after its day closes, also on an empty board, which earns no tip. Seven
  days after the later of the theme day's end and the settlement, the winner can reclaim an
  unpaid bonus, and from then on `payBonus` and `reclaim` race.
- Owner trust: `settle` reads `buildFee` and `studio`, so a fee change applies to bids
  already made, and a veto or reclaim returns the bid less the fee already paid. The launch
  fee is 0.

Local checks (scratch outputs avoid changing configuration):

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

`test/DerbyAuction.t.sol` covers WP3's eight Done-when items and the audit fixes, including
real SwarmDerby commit/reveal swings and a randomized conservation check after bids,
settlement, veto, bonus payout, reclaim and refund withdrawal. Forge 1.8.3 with Solidity
0.8.26 passes **94 tests, 0 failed** (40 auction tests and the 54 SwarmDerby tests). Each
fuzz test runs 256 cases.

**Chain id in tests:** Foundry 1.8.5 and later
[intercept `arbBlockNumber`](https://github.com/foundry-rs/foundry/blob/v1.8.5/crates/evm/evm/src/inspectors/stack.rs#L2087)
on chain 4663, which bypasses an etched ArbSys mock. Both test files therefore select chain
id 31337 before they etch MockArbSys. That is the only change to `test/SwarmDerby.t.sol`.

WP3 Done-when evidence (function names in `test/DerbyAuction.t.sol`):

| Item | Tests |
|---|---|
| 1. Bid amount, increment, time and answers | `test_bidMinimumAndIncrementRoundUp`, `test_openDayAndBidTimeBoundaries`, `test_openDayNamesTheExtendedDayUntilItCloses`, `test_answerLengthsAndEnums`, `test_everyForbiddenByteRejectedInEveryString` |
| 2. Outbid, failed and self-raise refunds | `test_outbidAndSelfRaiseRefundPreviousBid`, `test_failedRefundAccumulatesAndWithdrawsOnlyOnce`, `test_falseAndMalformedRefundsDoNotBlockBids` |
| 3. Repeated anti-sniping, stopped at 19:00 UTC | `test_antiSnipeExtendsRepeatedlyAndKeepsOtherDaysIndependent`, `test_antiSnipeStopsAtOneHourSoVetoStaysOpen` |
| 4. Zero/1 IMD fees, repeat and empty settlement | `test_settleZeroFeeExactlyAndOnlyOnce`, `test_settleOneIMDFeeAndSettingsApplyOnlyAtSettlement`, `test_emptyAuctionSettlesWithoutTakingCarry`, `test_failedStudioPaymentIsCreditedAndSettlementGoesOn` |
| 5. Real closure, tip and top-three split | `test_realSwingsPayOnlyAfterArcadeDayClosedAndOnlyTopThree` |
| 6. Agent isolation, short/empty boards and carry | `test_agentScoresAndOtherDaysNeverAffectArcadeBonus`, `test_onePlayerCarriesUnfilledSharesIntoNextAuction`, `test_twoPlayersCarryUnfilledShareIntoNextAuction`, `test_emptyArcadeWithAgentPlayersCarriesEverythingWithoutTip`, `test_failedPrizeAndRoundingDustCarryWithoutBlockingOthers`, `test_settleOnOrAfterThemeDayKeepsCarryForLaterBoards` |
| 7. Veto/reclaim restrictions and carry protection | `test_vetoOwnerOnlyBeforeThemeDayReturnsOwnNetBidNotCarry`, `test_vetoRejectsUnsettledEmptyAndThemeDayBoundary`, `test_reclaimGraceBoundaryReturnsOwnNetBidNotCarryToWinner`, `test_reclaimRejectsUnsettledEmptyAndAlreadyPaidAuctions`, `test_lateSettleKeepsTheFullReclaimGraceForTheBoard` |
| 8. Conservation, the SwarmDerby regression suite and constructor isolation | `testFuzz_conservationAcrossAuctionSequences`, `test_constructorStoresArgumentsWithoutAnyDependencyCalls`, plus all 54 tests in `test/SwarmDerby.t.sol` |
