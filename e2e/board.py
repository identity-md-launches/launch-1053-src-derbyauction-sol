import json, threading, time, urllib.request, subprocess
from playwright.sync_api import sync_playwright
exec(open('e2e/play.py').read().split('url=')[0])  # rpc(), miner thread, SHIM
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}"
def cast_call(sig, *args):
    return subprocess.check_output(['cast','call',A['derby'],sig,*args,'--rpc-url',RPC]).decode().strip()
with sync_playwright() as p:
    b=p.chromium.launch()
    # ── a visitor with no wallet sees the (empty) live board
    v=b.new_page(); v.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); v.route('**/fonts.g*/**', lambda r: r.abort())
    v.goto(url); v.wait_for_function("chainBoard.loaded", timeout=10000)
    print('visitor, empty day:', v.evaluate("document.getElementById('lbRows').innerText.trim()"), '| pot', v.evaluate("document.getElementById('lbPot').textContent"))
    # ── a player buys and swings until a few homers land
    pg=b.new_page(); errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); pg.route('**/fonts.g*/**', lambda r: r.abort())
    pg.add_init_script(SHIM); pg.goto(url); pg.wait_for_timeout(300)
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=15000)
    for _ in range(2):
        pg.evaluate("buyLive('pack')"); pg.wait_for_function("!live.busy", timeout=20000)
    print('turns after 2 packs:', pg.evaluate("turnsLeft"))
    pg.click('#sessionBtn'); pg.wait_for_function("!live.busy && live.sessionActive", timeout=20000)
    results=[]
    for i in range(8):
        pg.evaluate("oracleModal.classList.add('hidden'); flight=null; gameState=STATES.IDLE; startMashPhase(); mashPower = 0.9; triggerPitchRelease(); pitchProgress = 1.0 + (Math.random()-0.5)*0.2; executeSwing();")
        try:
            pg.wait_for_function("!live.busy && lastRoll && lastRoll.tx", timeout=30000)
        except Exception:
            print('STUCK at swing', i, pg.evaluate("({state: gameState, busy: live.busy, turns: turnsLeft, banner: bannerText.textContent.trim(), sub: bannerSub.textContent.trim(), c: commentaryTicker.textContent.trim(), lr: lastRoll})")); raise
        results.append(pg.evaluate("[lastRoll.name, lastRoll.feet]")); pg.evaluate("lastRoll = null")
        pg.wait_for_timeout(200)
    homer_ft=max([f for n,f in results if n in ('HOMER','BOMB','SLAM')] or [0])
    print('swings:', results, '| longest homer', homer_ft)
    pg.evaluate("refreshBoard()"); pg.wait_for_timeout(800)
    day=cast_call('currentDay()(uint256)').split()[0]
    print('contract arcade board:', cast_call('board(uint8,uint256)(address[],uint256[])', '0', day).replace('\n',' '))
    print('contract arcade pot:', cast_call('pot(uint256)(uint256)', '0').split()[0])
    print('page rows (player):', pg.evaluate("document.getElementById('lbRows').innerText.replace(/\\s+/g,' ').trim()"), '| pot', pg.evaluate("document.getElementById('lbPot').textContent"))
    v.evaluate("refreshBoard()"); v.wait_for_timeout(800)
    print('page rows (visitor):', v.evaluate("document.getElementById('lbRows').innerText.replace(/\\s+/g,' ').trim()"))
    print('note:', pg.evaluate("document.getElementById('lbSourceNote').textContent"))
    # out of turns: the decoded error message
    while pg.evaluate("turnsLeft") > 0:
        pg.evaluate("oracleModal.classList.add('hidden'); startMashPhase(); mashPower=0.5; triggerPitchRelease(); pitchProgress=1.6; executeSwing();")
        pg.wait_for_function("!live.busy", timeout=20000); pg.wait_for_timeout(150)
    pg.evaluate("live.derby.connect(live.signer).swing(0, 0, 0, ethers.ZeroHash).catch(e => txError(e))"); pg.wait_for_timeout(800)
    print('no-turns message:', pg.evaluate("bannerSub.textContent.trim()"))
    print('errors', errs); stop=True; b.close()
