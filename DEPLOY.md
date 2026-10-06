# Swarm Derby: deploy notes

Robinhood Chain mainnet (chain id 4663) · IMD `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` ·
public RPC `https://rpc.mainnet.chain.robinhood.com` · explorer `https://robinhoodchain.blockscout.com`

## What's in this folder

| | |
|---|---|
| `src/SwarmDerby.sol` | the game: two leagues, turns, swings, scoreboards, slam vaults, settlement |
| `src/DerbyOdds.sol` | the odds table; the browser runs identical math |
| `test/` | 37 Foundry tests (one fuzzed) |
| `e2e/` | full rehearsal on a local devnet with the real page and a scripted wallet |
| `imd-check.mjs` | free readiness check against IMD's API |
| `HANDOFF.md` | ordered go-live checklist for the swarm agent |
| `web/derby-odds.js` | the browser twin of DerbyOdds |

The site is the separate `swarm-derby-site` repo: `index.html`, `agent.md` and `agent-bot.mjs`, hosted together. `HANDOFF.md` is the ordered go-live checklist.

## 0. Readiness check (free)

```
node imd-check.mjs                 # before deploying
node imd-check.mjs 0xYOUR_DERBY    # after, to dry-run the exact daily questions
```

It reports whether `evm_contracts` launches are open on chain 4663, whether IMD has an RPC
for it, the oracle attester address (the contract's `oracleSigner_`), and any blockers IMD
would raise on the two daily ranking questions. It spends nothing.

## 1. Test

```
forge install foundry-rs/forge-std
forge test
```

## 2. How it works

**Two leagues.** Each has its own turns, pot, slam vault, scoreboard and daily payout.

| | Arcade (0) | Agent (1) |
|---|---|---|
| Who | people on the game page | bots / AI agents calling the contract |
| Cap | 20 swings per wallet per UTC day | none |
| Ranked by | longest homer today | total homer feet today |
| Oracle sums | `ArcadeGain(player, gain)` | `AgentFeet(player, feet)` |

`ArcadeGain` fires only when a player beats their own best today, with just the improvement,
so a player's summed gains equal their longest homer. That lets the oracle's summed ranking
(`log-rank`) rank the arcade by longest homer. A test checks the identity.

On-chain a script and a person look the same. The cap makes out-spending the arcade
expensive; it does not make it impossible (one person can run several wallets).

**Prices.** 1 turn = 0.15 IMD, 5 = 0.5 IMD (`setPrices` can change both). Every purchase is
split 40% burned, 45% to that league's pot, 10% to its slam vault, 5% ops.

**A swing, with no server.** The player picks a secret salt and calls
`swing(league, quality, velo, commit)` with `commit = keccak256(abi.encode(salt, player))`.
The roll uses the hash of the block 5 blocks later (~0.5s). The player then calls
`finalize(swingId, salt)`. Not revealed within 240 blocks (~24s) counts as a foul, and
`expire` closes it out. Nobody, including the deployer, can predict or steer a roll.

**Quick swings.** `setSession(key)` lets a throwaway browser key swing and reveal on the
player's turns with no wallet popups. It can only spend turns; homers, slam payouts and
leaderboard credit go to the player. The page funds it with gas sized from live fees.

**Live scoreboards.** `board(league, day)` holds each UTC day's top 10, so the page shows the
leaderboards with one call per league and no indexer. Payouts follow the oracle, not this view.

**Daily payout.** Anyone submits a league's signed IMD attestation to
`settleDay(league, attestation, signature)`, earns 0.5% of that payout, and the top 3 get
60 / 25 / 15 of 90% of that league's pot. 10% rolls over.

## 3. Deploy through IMD (`launch.open`, `evm_contracts`)

Push this folder to a **public** GitHub repo (without `e2e/Mocks.sol` in `src/`), then pin it:

```
POST /requests/import  {"url": "https://github.com/YOU/swarm-derby", "kind": "contracts"}
```

Dry-run with `POST /requests/check` before paying, and confirm chain 4663 lists
`evm_contracts` in `GET /requests/capabilities`.

```json
{
  "objective": "Deploy SwarmDerby (src/SwarmDerby.sol) unchanged to Robinhood Chain. Constructor arguments in order: owner_ = $owner; imd_ = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127; singlePrice_ = 150000000000000000; packPrice_ = 500000000000000000; oracleSigner_ = IMD_ATTESTER_ADDRESS; arcadeQuestion_ = 0x0000000000000000000000000000000000000000000000000000000000000000; agentQuestion_ = 0x0000000000000000000000000000000000000000000000000000000000000000.",
  "repoUrl": "https://github.com/YOU/swarm-derby",
  "baseCommit": "COMMIT_FROM_IMPORT",
  "contracts": ["src/SwarmDerby.sol"],
  "onchain": "evm_contracts",
  "chainId": 4663,
  "owner": "0xyour_wallet_lowercase",
  "github": true
}
```

`IMD_ATTESTER_ADDRESS` is the `attester` field of `GET https://api.imd.fun/oracle/requests`.
IMD reviews and may adapt the code before deploying: **read the adapt step's diff**. The odds
math must stay identical to the browser engine (`forge test` checks this).

## 4. Point the site at the contract

In the site repo set `DERBY_CONFIG.networks.robinhood.derby` in `dev/game.html`, rebuild
`index.html` with `dev/build.py`, and replace `SWARM_DERBY_ADDRESS` in `agent.md`. Until the
address is set the page stays practice-only.

## 5. Daily ranking schedules (IMD), one per league

Pay `schedule.create` twice (0.5 IMD per run each). Arcade:

```json
{
  "label": "Swarm Derby arcade: longest homer",
  "action": "oracle.request",
  "cadence": { "cron": "0 0 * * *", "tz": "UTC" },
  "runs": 30,
  "input": {
    "v": 1,
    "question": "Which three player addresses have the highest total gain, where total gain is the sum of the uint256 gain field over all ArcadeGain(address indexed player, uint256 gain) events emitted by contract SWARM_DERBY_ADDRESS on Robinhood Chain (chain id 4663) during the 24 hours before this request opened? Rank by total gain, highest first; break ties by the earlier block number of the player's most recent such event in that period; return fewer than three addresses if fewer players emitted the event.",
    "chainId": 4663, "window": { "hours": 24 }, "answerType": "address[]", "evidence": "chain",
    "head": 3, "panelSize": 5, "quorum": 4, "validForSeconds": 86400,
    "definitions": {
      "event": "ArcadeGain(address indexed player, uint256 gain) emitted by SWARM_DERBY_ADDRESS",
      "rank": "Sum gain per player across the window, highest first"
    },
    "consumer": { "chainId": 4663, "verifyingContract": "SWARM_DERBY_ADDRESS" }
  }
}
```

Agent: the same body with label `Swarm Derby agents: total feet`,
`"event": "AgentFeet(address indexed player, uint256 feet) emitted by SWARM_DERBY_ADDRESS"`, and
this question:

```
Which three player addresses have the highest total feet, where total feet is the sum of the uint256 feet field over all AgentFeet(address indexed player, uint256 feet) events emitted by contract SWARM_DERBY_ADDRESS on Robinhood Chain (chain id 4663) during the 24 hours before this request opened? Rank by total feet, highest first; break ties by the earlier block number of the player's most recent such event in that period; return fewer than three addresses if fewer players emitted the event.
```

Both wordings passed IMD's ambiguity screen. The tie-break (earlier *most recent* event) matches
the on-chain board, where whoever reached a score first stays ahead. The game page finds each
league's answer by the contract address and event name in the question, so keep both in it.

After each schedule's first run is attested, read both `questionHash` values and call
`initQuestions(arcadeHash, agentHash)` once. Later changes go through a 2-day timelock.

## 6. Paying out

Nothing to run. Each day after the swarm signs, the game page finds the signed ranking through
IMD's public oracle API (`/oracle/requests` and `/oracle/requests/:id/attestation`, both
CORS-open), checks it is valid and unused, and shows any visitor a **Pay the winners** button
in the leaderboard. Whoever presses it submits `settleDay` from their own wallet and earns
0.5% of the payout. Agents can do the same from code. If no one does, the pot simply waits;
nothing expires except the attestation itself (24h), and the next day's run can settle.

## Known limits

- Rolls mix the player's committed salt with a future L2 block hash; neither the player nor
  Robinhood's sequencer can steer one alone.
- The arcade cap is per wallet. Multiple wallets get around it at full price.
- Arcade windows come from a relative 24-hour schedule; a run that fires a little late can
  shift a few minutes of play across days.
- The owner can change prices and, after 2 days' notice, the oracle signer. The owner cannot
  touch pots or vaults. Hand ownership to a multisig, or renounce it.
- Not audited.
