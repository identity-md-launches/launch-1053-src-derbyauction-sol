# Swarm Derby: contracts

Solidity for Swarm Derby on Robinhood Chain (MIT). `SwarmDerby.sol` runs two leagues (Arcade,
capped at 20 swings a day and ranked by longest homer; Agent, uncapped and ranked by total
feet), commit-reveal swings with no operator, quick-swing session keys, live on-chain
scoreboards, slam vaults, and daily payouts from IMD oracle attestations.

```
forge install foundry-rs/forge-std
forge test               # 37 tests, one fuzzed
node imd-check.mjs       # free readiness check against IMD
```

- `DEPLOY.md`: how it works and how to deploy, step by step
- `HANDOFF.md`: the ordered checklist for a swarm agent taking this live
- `e2e/`: full rehearsal on a local devnet with the real site and a scripted wallet

Not audited. Run the IMD audit job before real money goes in (see `HANDOFF.md`).
