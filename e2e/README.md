# End-to-end test (local devnet)

Runs the real game page against the real contract on a local devnet, with a scripted
wallet. Needs Foundry (anvil, cast, forge) and Python Playwright. The devnet uses anvil's
default chain id 31337: on 4663, anvil installs its own ArbSys stub, which has no
`arbBlockHash`, so every reveal would land as a foul.

```
cp e2e/Mocks.sol src/Mocks.sol && forge build          # mocks: ArbSys stand-in + test IMD
anvil --silent &
python3 e2e/setup.py                                   # deploys mocks + SwarmDerby, writes e2e/addrs.json
python3 e2e/play.py                                    # connect, buy, quick swings, swing, miss
python3 e2e/recover.py                                 # reload mid-swing, reveal on return
python3 e2e/recover_unmined.py                         # reload before the commit receipt arrives
python3 e2e/board.py                                   # leaderboard + pot match the contract
python3 e2e/leagues.py                                 # 20-swing cap, arcade vs agent boards
RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=<anvil key #1> DERBY=<addr> MAX_IMD=1 node ../swarm-derby-site/agent-bot.mjs
python3 e2e/settle.py                                  # the day ends; a stranger pays both leagues
```

Check out the site repo next to this one as `../swarm-derby-site/`, or set `SITE=/path/to/index.html`.
The page only accepts `?network=local&derby=…&imd=…&rpc=…` overrides for the local devnet.
Remove `src/Mocks.sol` before deploying.
