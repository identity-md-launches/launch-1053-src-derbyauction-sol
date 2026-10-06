import json, threading, time, urllib.request
from playwright.sync_api import sync_playwright
A=json.load(open('e2e/addrs.json')); RPC='http://127.0.0.1:8545'
def rpc(m,p=[]):
    r=urllib.request.Request(RPC,data=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(),headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(r).read()).get('result')
stop=False
def miner():   # Robinhood makes blocks every ~100ms; the devnet only mines on txs, so tick it
    while not stop:
        try: rpc('evm_mine')
        except Exception: pass
        time.sleep(0.15)
threading.Thread(target=miner,daemon=True).start()

SHIM = """
window.__walletCalls = [];
window.ethereum = {
  isShim: true, _l: {},
  on(ev, fn) { this._l[ev] = fn; },
  async request({ method, params }) {
    window.__walletCalls.push(method);
    if (method === 'eth_requestAccounts') method = 'eth_accounts';
    if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') return null;
    const r = await fetch('http://127.0.0.1:8545', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params: params || [] }) });
    const j = await r.json();
    if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; }
    return j.result;
  }
};"""
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}"
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page()
    errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); pg.route('**/fonts.g*/**', lambda r: r.abort())
    pg.add_init_script(SHIM); pg.goto(url); pg.wait_for_timeout(500)
    st=lambda: pg.evaluate("({live: live.on, turns: turnsLeft, state: gameState, busy: live.busy, session: live.sessionActive, label: buttonLabel.textContent, banner: bannerText.textContent.trim()})")
    pg.click('#walletBtn'); pg.wait_for_function("live.on === true && !live.busy", timeout=15000); print('connected', st())
    # buy a pack: approve + buyPacks
    pg.evaluate("handleUserAction()"); pg.wait_for_function("!live.busy && turnsLeft === 5", timeout=20000); print('bought', st())
    # enable quick swings
    pg.click('#sessionBtn'); pg.wait_for_function("!live.busy && live.sessionActive", timeout=20000); print('session', st(), pg.evaluate("document.getElementById('sessionBtn').textContent.trim()"))
    calls_before = pg.evaluate("window.__walletCalls.filter(m => m === 'eth_sendTransaction').length")
    # contact swing via session key
    t0=time.time()
    pg.evaluate("startMashPhase(); mashPower = 0.9; triggerPitchRelease(); pitchProgress = 1.03; executeSwing();")
    pg.wait_for_function("lastRoll && lastRoll.tx && (gameState === 'RESULT' || gameState === 'BALL_FLIGHT')", timeout=30000)
    roll=pg.evaluate("({...lastRoll})"); print('swing done in %.1fs'%(time.time()-t0), {k:roll[k] for k in ('id','name','feet','q','v','tx')})
    calls_after = pg.evaluate("window.__walletCalls.filter(m => m === 'eth_sendTransaction').length")
    print('wallet popups during swing:', calls_after - calls_before)
    # on-chain check of the SwingResolved event
    rc=rpc('eth_getTransactionReceipt',[roll['tx']])
    print('reveal tx from session key:', rc['from'] == pg.evaluate("live.session.address.toLowerCase()"), 'status', rc['status'])
    pg.wait_for_timeout(2500); print('after flight', st())
    # a clean miss spends a turn on-chain
    pg.evaluate("oracleModal.classList.add('hidden'); startMashPhase(); mashPower = 0.5; triggerPitchRelease(); pitchProgress = 1.6; executeSwing();")
    pg.wait_for_function("!live.busy", timeout=20000); pg.wait_for_timeout(300); print('after whiff', st())
    turns_chain=int(rpc('eth_call',[{"to":A['derby'],"data":"0x"+__import__('subprocess').check_output(['cast','calldata','turns(uint8,address)','0',A['acct']]).decode().strip()[2:]},"latest"]),16)
    print('on-chain turns', turns_chain)
    # toggle back to practice keeps practice card separate
    pg.click('#modeBtn'); pg.wait_for_timeout(300); print('practice', st())
    print('errors', errs)
    stop=True; b.close()
