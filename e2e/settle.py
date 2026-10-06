import json, threading, time, urllib.request, subprocess, os
from playwright.sync_api import sync_playwright
exec(open('e2e/play.py').read().split('url=')[0])  # rpc(), miner, SHIM
CAST = os.environ.get('CAST', 'cast')
def call(sig, *args): return subprocess.check_output([CAST,'call',A['derby'],sig,*args,'--rpc-url',RPC]).decode().strip()
def imd_bal(addr): return int(subprocess.check_output([CAST,'call',A['imd'],'balanceOf(address)(uint256)',addr,'--rpc-url',RPC]).decode().split()[0])
def send(frm, to, sig, *args):
    data=subprocess.check_output([CAST,'calldata',sig,*args]).decode().strip()
    rpc('eth_sendTransaction',[{"from":frm,"to":to,"data":data}])
accts=rpc('eth_accounts'); player, agent, settler = accts[0], accts[1], accts[2]
# the deployer sets the two question hashes once (as after the first real schedule runs)
qa=subprocess.check_output([CAST,'keccak','mock-arcade-question']).decode().strip()
qg=subprocess.check_output([CAST,'keccak','mock-agent-question']).decode().strip()
send(player, A['derby'], 'initQuestions(bytes32,bytes32)', qa, qg); time.sleep(0.5)
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}&imdApi=http://127.0.0.1:8787"
def shim_for(addr):
    return SHIM.replace("if (method === 'eth_requestAccounts') method = 'eth_accounts';",
                        f"if (method === 'eth_requestAccounts' || method === 'eth_accounts') return ['{addr}'];")
with sync_playwright() as p:
    b=p.chromium.launch()
    def page(addr):
        pg=b.new_page(); pg.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); pg.route('**/fonts.g*/**', lambda r: r.abort())
        errs=[]; pg.on('pageerror', lambda e: errs.append(str(e))); pg.add_init_script(shim_for(addr)); pg.goto(url); pg.wait_for_timeout(300); return pg, errs
    # ── the human plays the arcade until at least one homer lands
    hp, herr = page(player)
    hp.click('#walletBtn'); hp.wait_for_function("live.on && !live.busy", timeout=15000)
    hp.evaluate("buyLive('pack')"); hp.wait_for_function("!live.busy && turnsLeft === 5", timeout=20000)
    best=0
    for i in range(5):
        hp.evaluate("oracleModal.classList.add('hidden'); flight=null; gameState=STATES.IDLE; lastRoll=null; startMashPhase(); mashPower=0.9; triggerPitchRelease(); pitchProgress=1.0; executeSwing();")
        hp.wait_for_timeout(150); hp.wait_for_function("!live.busy && lastRoll", timeout=30000)
        r=hp.evaluate("[lastRoll.name, lastRoll.feet]")
        if r[0] in ('HOMER','BOMB','SLAM'): best=max(best, r[1])
    print('human arcade best:', best)
    # ── start the mock IMD API now that the day's boards exist
    api=subprocess.Popen(['node','mock-imd.mjs'], cwd=os.path.dirname(os.path.abspath(__file__)),
        env={**os.environ,'DERBY':A['derby'],'RPC_URL':RPC,'SIGNER_KEY':'0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6'},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    time.sleep(1.5)
    pots_before=[int(call('pot(uint256)(uint256)',str(l)).split()[0]) for l in (0,1)]
    print('pots before:', pots_before)
    # ── a stranger who never played opens the page and settles both leagues
    sp, serr = page(settler)
    sp.click('#walletBtn'); sp.wait_for_timeout(1500)
    sp.click('#lbToggle'); sp.wait_for_function("settle[0].state === 'ready' && settle[1].state === 'ready'", timeout=20000)
    print('arcade tab:', sp.evaluate("document.getElementById('lbSettleNote').textContent"), '|', sp.evaluate("document.getElementById('lbSettleBtn').textContent"))
    bal0=[imd_bal(player), imd_bal(agent), imd_bal(settler)]
    sp.click('#lbSettleBtn'); sp.wait_for_function("settle[0].state === 'none'", timeout=30000)
    sp.click('#lbTabAgent'); sp.wait_for_timeout(100)
    print('agent tab:', sp.evaluate("document.getElementById('lbSettleBtn').textContent"))
    sp.click('#lbSettleBtn'); sp.wait_for_function("settle[1].state === 'none'", timeout=30000)
    bal1=[imd_bal(player), imd_bal(agent), imd_bal(settler)]
    print('paid: arcade winner +%.6f, agent winner +%.6f, settler tip +%.6f IMD' % tuple((x-y)/1e18 for x,y in zip(bal1,bal0)))
    print('pots after:', [int(call('pot(uint256)(uint256)',str(l)).split()[0]) for l in (0,1)])
    print('banner:', sp.evaluate("bannerText.textContent.trim()"), '/', sp.evaluate("bannerSub.textContent.trim()"))
    sp.reload(); sp.wait_for_timeout(300); sp.click('#lbToggle'); sp.wait_for_function("settle[0].state !== 'idle' && settle[1].state !== 'idle'", timeout=20000)
    print('after reload:', sp.evaluate("[settle[0].state, settle[1].state]"), '|', sp.evaluate("document.getElementById('lbSettleNote').textContent"))
    print('errors', herr + serr); api.terminate(); stop=True; b.close()
