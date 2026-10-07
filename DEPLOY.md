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

Push this folder to a **public** GitHub repo (without `e2e/Mocks.sol` in `src/`), then pin it:

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
