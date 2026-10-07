#!/usr/bin/env node
// Free readiness check against IMD's public API. Spends nothing.
//
//   node imd-check.mjs
//
// Answers the deploy question: can an evm_contracts launch deploy to Robinhood Chain (4663)
// right now, and which paid actions (job.open for the audit, launch.open) are enabled?
//
// Node 18+ (built-in fetch).

const API = process.env.IMD_API || 'https://api.imd.fun';
const CHAIN = 4663;

const ok = (b) => (b ? 'yes' : 'NO');
async function get(path) {
  const res = await fetch(API + path);
  const body = await res.json().catch(() => ({}));
  return { status: res.status, body };
}

async function main() {
  console.log(`IMD API ${API}`);
  const v = await get('/version');
  console.log(`  control plane commit ${v.body.commit ?? '?'}\n`);

  const caps = await get('/requests/capabilities');
  const chains = caps.body?.launches?.chains || [];
  const rh = chains.find((c) => Number(c.chainId) === CHAIN);
  console.log(`Robinhood Chain open for launches: ${ok(!!rh)}`);
  if (rh) console.log(`  kinds: ${(rh.kinds || []).join(', ')}  ·  evm_contracts: ${ok((rh.kinds || []).includes('evm_contracts'))}`);
  else console.log(`  chains open now: ${chains.map((c) => `${c.name} (${c.chainId})`).join(', ') || 'none listed'}`);
  const actions = caps.body?.actions;
  if (actions) {
    const names = Array.isArray(actions) ? actions.map((a) => a.action || a.name) : Object.keys(actions);
    console.log(`  enabled actions: ${names.join(', ')}`);
  }
  console.log('\nIf evm_contracts is open, deploy with DEPLOY.md step 3.');
}

main().catch((e) => { console.error(`check failed: ${e.message}`); process.exit(1); });
