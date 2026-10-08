# DerbyAuction launch review

## Changes and rationale

The only delivered change is this `ADAPTATION.md`: it records the required launch
configuration, audit dispositions and local verification. No Solidity or project
test changes are needed. The existing contract already meets the contracts-only
factory requirements, and this review reproduced no critical or high issue that
would justify changing the approved code.

`src/DerbyAuction.sol`, `src/SwarmDerby.sol`, `src/DerbyOdds.sol`, both existing test
files, build configuration and dependencies remain unchanged. Function signatures,
events, errors, constants and payout math are preserved. The accepted 19:00 UTC
extension cap, settlement-time fee/studio selection, and post-grace race between
`payBonus` and `reclaim` remain in force.

## Deployment handoff

Launch kind: `evm_contracts`. Target: Robinhood Chain, chain id **4663**.
Deploy exactly **DerbyAuction**, from `src/DerbyAuction.sol`.

| Constructor argument, in order | Value |
| --- | --- |
| `owner_` | `$owner` |
| `imd_` | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| `derby_` | `0xBa58BC6b5aCf8043DAEa2Bf1BF6C1c09cF84b03C` |
| `studio_` | `$owner` |
| `buildFee_` | `0` |

`$owner` is resolved by the launch service to the requester-supplied owner; no wallet
has been invented for deployment. The constructor is nonpayable, accepts four
addresses and one uint256, and fully configures the contract with zero ETH and no
initialization call. Ownership comes from `owner_`, not the factory's `msg.sender`.
It performs no external calls or dependency code checks. Runtime bid processing
retains its token-code and exact-receipt checks.

SwarmDerby and IMD are existing dependencies, not additional deployments. No token,
distributor, pool, proxy or deployment script is added. `launch.json` belongs to the
following manifest assignment and is not written here. This task did not broadcast
or deploy on a live chain.

## Imported audit findings

All five supplied findings are informational. No defect fix is requested by their
reproductions, and none requires an ABI or behavior change.

| Finding (id prefix) | Reproduction and disposition |
| --- | --- |
| Coverage, no critical/high/medium (`55686eab`) | Read DerbyAuction in full, its game dependency surface, and the existing tests. Independently reran the 94 tests and checked factory deployment, runtime size and forbidden opcodes. No critical or high finding reproduced. Historical live/fork evidence from the imported audit was not independently reproduced; see the RPC limitation below. |
| Owner fee and veto trust (`4f269170`) | Reproduced: a 2 IMD bid settled with studio = owner and fee = 1 IMD leaves 1 IMD with the owner after veto and returns 1 IMD to the bidder. Existing veto/reclaim tests also protect inherited carry. Retained as the documented owner trust assumption; the launch fee is zero. |
| Carry has no exit (`f34aa5b0`) | Reproduced: an empty board carries its whole bonus; a later winning auction settled at its theme-day start takes none of that carry; empty settlements and passage of a year do not release it. Source review confirms only a winning settlement before its theme day consumes carry. Retained as the documented rollover design, with no sweep added. |
| Failed winner prize becomes carry (`0d586eac`) | Reproduced with the existing token failure model: the blocked top-three winner gets no refund credit, other winners are paid, and unblocking later does not permit withdrawal or repeat payout. Retained as the documented payout rule and existing game's behavior. |
| External token owner/liveness (`f36a58cf`) | Reproduced the local failure consequences: failed pulls roll back bids; settlement and veto credit refused transfers; failed withdrawal preserves the credit; withdrawal succeeds when transfers resume. Existing tests cover reclaim credits and failed-tip rollback. The live token's precise admin powers and current owner were not independently verified. Retained as an external dependency assumption rather than an auction code defect. |

The earlier medium and three low findings from audit job
`928b670b-477f-4132-875c-7c0b872ddfcd` against commit `f797a19` are already fixed in
the supplied code. Their existing regression tests all pass:

- Settlement-based reclaim grace: `test_lateSettleKeepsTheFullReclaimGraceForTheBoard`.
- Late settlement cannot consume carry: `test_settleOnOrAfterThemeDayKeepsCarryForLaterBoards`.
- Failed studio payment is credited: `test_failedStudioPaymentIsCreditedAndSettlementGoesOn`.
- Extended auction remains the open day: `test_openDayNamesTheExtendedDayUntilItCloses`.

## Verification

Using the unchanged project configuration, Forge **1.8.3** and Solidity **0.8.26**:

- `forge build`: successful; existing lint warnings remain. Manual review and the
  existing reentrancy, maximum-bid, rounding and ownership tests did not reproduce
  a critical or high auction defect from those warnings.
- `forge test`: **94 passed, 0 failed, 0 skipped** (40 auction, 54 game); all three
  fuzz tests ran 256 cases. Both project test files retain chain id 31337 for their
  etched ArbSys mock, as required for later Foundry versions.
- `forge test --match-path 'test/scratch/LaunchReview.t.sol' --match-test '^test_reproduce' -vv`:
  **5 passed**. Four checks reproduce the informational behaviors above. The fifth
  rehearses zero-value CREATE2 on an empty local chain with id 4663 using the exact
  pinned dependency addresses and a clearly labeled local test owner. It deploys
  no token or game fixture, checks the predicted address, all constructor settings,
  absence of dependency calls, and owner access independent of the factory.
  DerbyAuction runtime is **9,520 bytes**, below the 24,576-byte limit; init code
  fits the 49,152-byte limit. An instruction-aware scan skips PUSH data and finds
  no DELEGATECALL, CALLCODE or SELFDESTRUCT.

Scratch checks are local scaffolding under `test/scratch/`, which the assignment
removes before submission; they introduce no delivered dependencies or contracts.
No Slither, Mythril, or extended fuzz campaign was run.

Read-only RPC attempts to `https://rpc.mainnet.chain.robinhood.com` returned HTTP
403 for chain id, dependency code, IMD symbol, decimals and owner reads. Consequently
this adaptation does not claim fresh live identity verification or a fork replay.
The pinned constructor addresses are preserved exactly; live dependency identity,
token privileges and deployment simulation remain for the launch service's review.
