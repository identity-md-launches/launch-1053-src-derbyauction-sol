// Local stand-in for IMD's oracle read API, for the e2e rehearsal only.
// Serves GET /oracle/requests and GET /oracle/requests/:id/attestation with CORS, and signs
// attestations with a test key in exactly the EIP-712 shape the IMD docs describe. The
// "ranking" comes from the contract's own board, standing in for the swarm's log-rank.
import http from 'node:http';
import { ethers } from 'ethers';

const RPC = process.env.RPC_URL || 'http://127.0.0.1:8545';
const DERBY = process.env.DERBY;
const PORT = Number(process.env.PORT || 8787);
const signer = new ethers.Wallet(process.env.SIGNER_KEY); // anvil account #9 in e2e
const provider = new ethers.JsonRpcProvider(RPC);
const derby = new ethers.Contract(DERBY, [
  'function currentDay() view returns (uint256)',
  'function board(uint8 league, uint256 day) view returns (address[] players, uint256[] scores)'
], provider);

const QUESTIONS = [
  { id: 'aaaaaaaa-0000-4000-8000-000000000001', event: 'ArcadeGain', hash: ethers.id('mock-arcade-question') },
  { id: 'aaaaaaaa-0000-4000-8000-000000000002', event: 'AgentFeet', hash: ethers.id('mock-agent-question') }
];
const types = { OracleAttestation: [
  { name: 'requestId', type: 'bytes32' }, { name: 'chainId', type: 'uint256' }, { name: 'questionHash', type: 'bytes32' },
  { name: 'answerType', type: 'uint8' }, { name: 'answer', type: 'bytes' }, { name: 'figure', type: 'uint256' },
  { name: 'fromBlock', type: 'uint64' }, { name: 'toBlock', type: 'uint64' }, { name: 'blockHash', type: 'bytes32' },
  { name: 'panelJobId', type: 'bytes32' }, { name: 'panelSize', type: 'uint16' }, { name: 'quorum', type: 'uint16' },
  { name: 'agreed', type: 'uint16' }, { name: 'issuedAt', type: 'uint64' }, { name: 'expiresAt', type: 'uint64' }
] };
const cache = {};
const uuidToBytes32 = (u) => ethers.zeroPadBytes('0x' + u.replace(/-/g, ''), 32); // 16 raw bytes, left-aligned

async function attest(q, league) {
  if (cache[q.id]) return cache[q.id];
  const day = await derby.currentDay();
  const [players] = await derby.board(league, day);
  const head = await provider.getBlock('latest');
  const now = Math.floor(Date.now() / 1000);
  const message = {
    requestId: uuidToBytes32(q.id), chainId: 4663, questionHash: q.hash, answerType: 'address[]',
    answer: ethers.AbiCoder.defaultAbiCoder().encode(['address[]'], [players.slice(0, 3)]), figure: '0',
    fromBlock: 1, toBlock: head.number - 1, blockHash: head.hash, panelJobId: uuidToBytes32(q.id.replace('aaaaaaaa', 'bbbbbbbb')),
    panelSize: 5, quorum: 4, agreed: 5, issuedAt: now, expiresAt: now + 86400
  };
  const domain = { name: 'IdentityMD Oracle', version: '2', chainId: 4663, verifyingContract: DERBY };
  const signature = await signer.signTypedData(domain, types, { ...message, answerType: 4 });
  cache[q.id] = { requestId: q.id, domain, types, primaryType: 'OracleAttestation', message, signature, signer: signer.address };
  return cache[q.id];
}

http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json');
  const url = new URL(req.url, 'http://x');
  try {
    if (url.pathname === '/oracle/requests') {
      const q = url.searchParams.get('q') || '';
      const requests = QUESTIONS.filter((x) => x.event.includes(q)).map((x) => ({
        id: x.id, status: 'attested', panelSize: 5, quorum: 4,
        question: `Which three addresses have the highest summed value in ${x.event} events emitted by ${DERBY.toLowerCase()} on Robinhood Chain in the window?`
      }));
      return res.end(JSON.stringify({ count: requests.length, attester: signer.address, requests }));
    }
    const m = url.pathname.match(/^\/oracle\/requests\/([^/]+)\/attestation$/);
    if (m) {
      const idx = QUESTIONS.findIndex((x) => x.id === m[1]);
      if (idx < 0) { res.statusCode = 404; return res.end('{"error":"not_attested"}'); }
      return res.end(JSON.stringify(await attest(QUESTIONS[idx], idx)));
    }
    res.statusCode = 404; res.end('{"error":"not_found"}');
  } catch (e) {
    res.statusCode = 500; res.end(JSON.stringify({ error: String(e.message || e) }));
  }
}).listen(PORT, () => console.log(`mock IMD oracle API on :${PORT}, signer ${signer.address}`));
