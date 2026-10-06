# End-to-end test (local devnet)

Runs the real game page against the real contract on a local chain-4663 devnet, with a
scripted wallet. Needs Foundry (anvil, cast, forge) and Python Playwright.

```
cp e2e/Mocks.sol src/Mocks.sol && forge build          # mocks: ArbSys stand-in + test IMD
anvil --chain-id 4663 --silent &
python3 e2e/setup.py                                   # deploys mocks + SwarmDerby, writes e2e/addrs.json
python3 e2e/play.py                                    # connect, buy, quick swings, swing, miss
python3 e2e/recover.py                                 # reload mid-swing, reveal on return
python3 e2e/board.py                                   # leaderboard + pot match the contract
python3 e2e/leagues.py                                 # 20-swing cap, arcade vs agent boards
python3 e2e/settle.py                                  # mock IMD signs both rankings; a stranger settles
RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=<anvil key #1> DERBY=<addr> MAX_IMD=1 node ../swarm-derby-site/agent-bot.mjs
```

Check out the site repo next to this one as `../swarm-derby-site/`, or set `SITE=/path/to/index.html`.
The page only accepts `?network=local&derby=…&imd=…&rpc=…` overrides for the local devnet.
Remove `src/Mocks.sol` before deploying.

`mock-imd.mjs` stands in for IMD's oracle read API and signs real EIP-712 attestations with a
test key (anvil account #9, which setup.py makes the contract's oracle signer). Run it next to
an `ethers` install.
