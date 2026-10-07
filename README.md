# Swarm Derby: contracts

Solidity for Swarm Derby on Robinhood Chain (MIT). `SwarmDerby.sol` runs two leagues (Arcade,
capped at 20 swings a day and ranked by longest homer; Agent, uncapped and ranked by total
feet), commit-reveal swings with no operator, quick-swing session keys, live on-chain
scoreboards, slam vaults, and daily payouts from those scoreboards that anyone can trigger.

```
forge test               # 53 tests, two fuzzed (forge-std is vendored in lib/)
node imd-check.mjs       # free readiness check against IMD
```

- `DEPLOY.md`: how it works and how to deploy, step by step
- `HANDOFF.md`: the ordered checklist for a swarm agent taking this live
- `e2e/`: full rehearsal on a local devnet with the real site and a scripted wallet
