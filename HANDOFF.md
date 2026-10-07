# Handoff: taking Swarm Derby live with the IMD swarm

For the swarm agent (and its operator). Work top to bottom; each step says what to check
before moving on. Long request bodies live in `DEPLOY.md`.

## Before you start

**Decisions that belong to the owner, not the agent:**

1. Which wallet owns the contract (`owner` in the launch). Only it can change prices (never
   below 0.01 IMD a turn), withdraw the 5% ops share and transfer ownership. It can never
   touch pots or vaults.
2. That paid entry + prize pool is allowed where the game will be offered.

**Two different IMD tokens:**

| | Chain | Address | Used for |
|---|---|---|---|
| Paying the swarm | Ethereum mainnet | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | audit, launch, hosting (x402 + Permit2) |
| The game | Robinhood Chain | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` | turns, pots, burns |

**Never** put a private key, seed or salt in a repo, a job objective or an upload. Everything
sent to IMD is public.

**Budget for the swarm work:** audit 0.5 + launch 0.5 + hosting 0.5, all in Ethereum-mainnet
IMD, plus Robinhood ETH for gas and a little Robinhood IMD for the smoke test. Daily payouts
need no IMD services: they come from the contract's own scoreboards.

## 1. Publish the code

Create two **public** GitHub repos from the two folders:

- `swarm-derby-contracts` (Foundry repo at the root)
- `swarm-derby-site` (static site at the root)

Check: `forge test` passes (54), and `python3 dev/build.py dev/game.html ../index.html`
in the site repo reproduces `index.html` exactly.

## 2. Readiness check (free)

```
node imd-check.mjs
```

Continue only if Robinhood Chain (4663) is open for launches with `evm_contracts`.

## 3. Audit (0.5 IMD)

```
POST /requests/import  {"url": "https://github.com/OWNER/swarm-derby-contracts", "kind": "contracts"}
```

Then `job.open` with:

```json
{
  "objective": "Audit SwarmDerby (src/SwarmDerby.sol, src/DerbyOdds.sol): IMD turn purchases and the 40/45/10/5 split into per-day pots, commit-reveal swing randomness using Robinhood Chain (Arbitrum Nitro) block hashes via ArbSys, EIP-712 session-key consent, the 20-swing arcade cap, the on-chain top-10 boards, slam vault payouts, and settleNextDay's in-order daily payout math and rollover.",
  "template": "audit",
  "repoUrl": "https://github.com/OWNER/swarm-derby-contracts",
  "baseCommit": "COMMIT_FROM_IMPORT"
}
```

Read the report at `GET /jobs/:id/report.md`. Fix critical and high findings, rerun
`forge test` and the `e2e/` rehearsal, push, and re-audit if the changes were large.
Any change to `DerbyOdds.sol` must be mirrored in the site's odds engine; the parity test
catches drift.

## 4. Deploy (0.5 IMD)

Import the audited commit again, dry-run with `POST /requests/check`, then `launch.open`
with the body in `DEPLOY.md` step 3 (`onchain: "evm_contracts"`, `chainId: 4663`, owner
from "Before you start", no token).

**Read the adapt step's diff** before the launch goes live. Afterwards check on
`https://robinhoodchain.blockscout.com`:

- `owner()` is the chosen wallet; `imd()` is the Robinhood IMD address
- `singlePrice()` = 0.15e18, `packPrice()` = 0.5e18, `ARCADE_DAILY_CAP()` = 20

## 5. Point the site at the contract

In the site repo: set `DERBY_CONFIG.networks.robinhood.derby` in `dev/game.html`, rebuild
`index.html`, replace `SWARM_DERBY_ADDRESS` in `agent.md`, commit, push.

## 6. Host the site (0.5 IMD)

```
POST /requests/import  {"url": "https://github.com/OWNER/swarm-derby-site", "kind": "site"}
```

If the import reports no build step, `job.open` with:

```json
{
  "objective": "Host the Swarm Derby static site exactly as committed: index.html (self-contained game), agent.md and agent-bot.mjs. No build and no changes to the files.",
  "repoUrl": "https://github.com/OWNER/swarm-derby-site",
  "baseCommit": "COMMIT_FROM_IMPORT",
  "shape": "chain",
  "steps": [{ "skill": "site-content-check" }],
  "ipfs": "swarm-derby",
  "github": false
}
```

(If it reports `site.build: true`, add an `import-site` step before the check.)
Check: `GET /sites/by-label/swarm-derby` resolves, and `swarm-derby.sites.imd.fun` loads the
game with practice mode working and the leaderboard showing the live (empty) board.

## 7. Smoke test with small amounts

On the hosted site, with a fresh wallet holding ~1 Robinhood IMD and a little ETH:

1. Practice mode plays with no wallet.
2. Connect, switch to Live, buy a single try (0.15 IMD): 40% shows up at `0x…dEaD`.
3. Enable quick swings (one wallet signature binds the browser key), swing a few times: no
   wallet popups, the arcade board updates.
4. Run the agent bot with `MAX_IMD=0.5`: it appears on the Agents tab.

## 8. First payout (the next day)

After 00:00 UTC, open the leaderboard: "Pay the winners" appears for each league with a
finished day. Press it (or call `settleNextDay(league)` from code). Check the winners and the
tip on the explorer, and that the button moves on to the next open day or disappears.

## 9. After launch

- `withdrawOps` releases the 5% ops share (Robinhood IMD).
- Once things are stable, move `owner` to a multisig: `transferOwnership(multisig)`, then the
  multisig calls `acceptOwnership()`. Ownership cannot be renounced.
- Site updates: change `dev/game.html`, rebuild, push, and rerun step 6 with
  `job.continue` (`ipfs: true` keeps the same name).
