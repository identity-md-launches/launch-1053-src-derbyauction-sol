#!/usr/bin/env node
// Free readiness check against IMD's public API. Spends nothing.
//
//   node imd-check.mjs [SWARM_DERBY_ADDRESS]
//
// Answers the deploy questions:
//   1. Can an evm_contracts launch deploy to Robinhood Chain (4663) right now?
//   2. Does IMD have an RPC for 4663, so the oracle can read our events?
//   3. Which address signs oracle attestations (the contract's oracleSigner)?
//   4. Would IMD accept our two daily ranking questions? (dry-run via /requests/check)
//
// Node 18+ (built-in fetch). Note: a check counts toward IMD's quote rate limit (30/min).

const API = process.env.IMD_API || 'https://api.imd.fun';
const CHAIN = 4663;
const derby = (process.argv[2] || '0x0000000000000000000000000000000000000000').toLowerCase();

const ok = (b) => (b ? 'yes' : 'NO');
async function get(path) {
  const res = await fetch(API + path);
  const body = await res.json().catch(() => ({}));
  return { status: res.status, body };
}
async function post(path, json) {
  const res = await fetch(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(json) });
  const body = await res.json().catch(() => ({}));
  return { status: res.status, body };
}

const QUESTIONS = [
  { league: 'arcade', event: 'ArcadeGain(address indexed player, uint256 gain)', arg: 'gain' },
  { league: 'agent', event: 'AgentFeet(address indexed player, uint256 feet)', arg: 'feet' }
];

async function main() {
  console.log(`IMD API ${API}`);
  const v = await get('/version');
  console.log(`  control plane commit ${v.body.commit ?? '?'}\n`);

  // 1. launch support
  const caps = await get('/requests/capabilities');
  const chains = caps.body?.launches?.chains || [];
  const rh = chains.find((c) => Number(c.chainId) === CHAIN);
  console.log(`1. Robinhood Chain open for launches: ${ok(!!rh)}`);
  if (rh) console.log(`   kinds: ${(rh.kinds || []).join(', ')}  ·  evm_contracts: ${ok((rh.kinds || []).includes('evm_contracts'))}`);
  else console.log(`   chains open now: ${chains.map((c) => `${c.name} (${c.chainId})`).join(', ') || 'none listed'}`);
  const actions = caps.body?.actions;
  if (actions) {
    const names = Array.isArray(actions) ? actions.map((a) => a.action || a.name) : Object.keys(actions);
    console.log(`   enabled actions: ${names.join(', ')}`);
  }

  // 2. RPC for the oracle
  const rpc = await get(`/reads/rpcs/${CHAIN}`);
  console.log(`\n2. IMD has an RPC configured for ${CHAIN}: ${ok(rpc.status === 200)}${rpc.status === 200 ? '' : ` (HTTP ${rpc.status})`}`);

  // 3. attester
  const reqs = await get('/oracle/requests?limit=1');
  console.log(`\n3. Oracle attester (use as oracleSigner_): ${reqs.body.attester ?? 'not returned'}`);

  // 4. dry-run both daily questions
  console.log(`\n4. Dry-run of the daily ranking questions for ${derby}:`);
  for (const q of QUESTIONS) {
    const input = {
      question: `Which three player addresses have the highest total ${q.arg}, where total ${q.arg} is the sum of the uint256 ${q.arg} field over all ${q.event} events emitted by contract ${derby} on Robinhood Chain (chain id 4663) during the 24 hours before this request opened? Rank by total ${q.arg}, highest first; break ties by the earlier block number of the player's most recent such event in that period; return fewer than three addresses if fewer players emitted the event.`,
      panelSize: 5, answerType: 'address[]', evidence: 'chain', chainId: CHAIN, head: 3
    };
    const r = await post('/requests/check', { action: 'oracle.request', input });
    const blockers = r.body.blockers || [];
    console.log(`\n   ${q.league}: HTTP ${r.status} · blockers: ${blockers.length ? JSON.stringify(blockers) : 'none'}`);
    if (r.body.suggestions?.length) console.log(`   suggestions: ${JSON.stringify(r.body.suggestions)}`);
    if (r.body.request) console.log(`   drafted request: ${JSON.stringify(r.body.request)}`);
  }
  console.log('\nIf 1, 2 and 4 are clean, deploy with DEPLOY.md step 3 and create the schedules in step 5.');
}

main().catch((e) => { console.error(`check failed: ${e.message}`); process.exit(1); });
