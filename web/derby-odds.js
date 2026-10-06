/* DerbyOdds — browser twin of contracts/DerbyOdds.sol. Keep the two in lockstep. */
const DerbyOdds = (() => {
  const C0   = [3000, 4500, 6002, 9880, 10000]; // cumulative bps at quality 0: foul, pop, homer, bomb, slam
  const C100 = [1200, 3800, 9200, 9980, 10000]; // cumulative bps at quality 100
  const TIERS = ['WHIFF', 'FOUL', 'POP', 'HOMER', 'BOMB', 'SLAM'];
  const POWER_LINE = 60; // exit-velo score (0-100) needed before a bomb or slam is possible
  const RANGE = { 1: [90, 81], 2: [180, 121], 3: [375, 75], 4: [450, 100], 5: [550, 71] };
  const keccak = (typeof keccak_256 !== 'undefined') ? keccak_256 : require('js-sha3').keccak_256;

  function thresholds(quality) {
    const q = Math.min(100, quality), iq = 100 - q;
    return C0.map((a, i) => Math.floor((a * iq + C100[i] * q) / 100));
  }
  function probabilities(quality, velo = 100) {
    const c = thresholds(quality);
    const p = { foul: c[0], pop: c[1] - c[0], homer: c[2] - c[1], bomb: c[3] - c[2], slam: c[4] - c[3] };
    if (velo < POWER_LINE) { p.homer += p.bomb + p.slam; p.bomb = 0; p.slam = 0; }
    return p;
  }
  const word = (n) => BigInt(n).toString(16).padStart(64, '0');
  function hashWord(seedHex, swingId, salt) {
    const hex = seedHex.replace(/^0x/, '').padStart(64, '0') + word(swingId) + word(salt);
    const bytes = new Uint8Array(hex.match(/../g).map((b) => parseInt(b, 16)));
    return BigInt('0x' + keccak(bytes));
  }
  /** Same as DerbyOdds.roll(seed, swingId, quality, velo) */
  function roll(seedHex, swingId, quality, velo = 100) {
    if (quality === 0) return { tier: 0, name: 'WHIFF', feet: 0 };
    const r = Number(hashWord(seedHex, swingId, 0) % 10000n);
    const c = thresholds(quality);
    let tier = r < c[0] ? 1 : r < c[1] ? 2 : r < c[2] ? 3 : r < c[3] ? 4 : 5;
    if (tier > 3 && velo < POWER_LINE) tier = 3; // under the power line: capped at a regular homer
    const [lo, span] = RANGE[tier];
    const feet = lo + Number(hashWord(seedHex, swingId, 1) % BigInt(span));
    return { tier, name: TIERS[tier], feet };
  }
  /** Exit-velo score 0-100 from the mash meter. */
  const velo = (mashPower) => Math.max(0, Math.min(100, Math.round(mashPower * 100)));
  /** Contact quality from the swing: 0 = miss, else 1-100 (half exit velo, half timing). */
  function quality(mashPower, timingAbs, missAt = 0.38) {
    if (timingAbs > missAt) return 0;
    const v = Math.max(0, Math.min(100, Math.round(mashPower * 100)));
    const c = Math.max(0, Math.min(100, Math.round(100 * (1 - timingAbs / missAt))));
    return Math.max(1, Math.round((v + c) / 2));
  }
  return { thresholds, probabilities, roll, quality, velo, POWER_LINE, TIERS };
})();
if (typeof module !== 'undefined') module.exports = DerbyOdds;
