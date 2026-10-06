import json, threading, time, urllib.request
from playwright.sync_api import sync_playwright
exec(open('e2e/play.py').read().split('url=')[0])  # rpc(), miner, SHIM
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}"
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page(); errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); pg.route('**/fonts.g*/**', lambda r: r.abort())
    pg.add_init_script(SHIM); pg.goto(url); pg.wait_for_timeout(300)
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=15000)
    print('start: turns', pg.evaluate("turnsLeft"), 'left today', pg.evaluate("live.swingsLeft"), '| cap HUD', pg.evaluate("document.getElementById('capHud').textContent"))
    for _ in range(5):  # 25 arcade turns, more than the cap
        pg.evaluate("buyLive('pack')"); pg.wait_for_function("!live.busy", timeout=20000)
    pg.click('#sessionBtn'); pg.wait_for_function("!live.busy && live.sessionActive", timeout=20000)
    homers=[]
    for i in range(20):
        good = i % 4 == 0   # a few real contact swings, the rest quick misses
        pg.evaluate("oracleModal.classList.add('hidden'); flight=null; gameState=STATES.IDLE; lastRoll=null; startMashPhase(); mashPower=0.9; triggerPitchRelease(); pitchProgress=%s; executeSwing();" % ('1.0' if good else '1.6'))
        pg.wait_for_timeout(150); pg.wait_for_function("!live.busy && lastRoll", timeout=30000)
        r=pg.evaluate("[lastRoll.name, lastRoll.feet]")
        if r[0] in ('HOMER','BOMB','SLAM'): homers.append(r[1])
    pg.evaluate("refreshLive()"); pg.wait_for_timeout(800)
    print('after 20: turns', pg.evaluate("turnsLeft"), 'left today', pg.evaluate("live.swingsLeft"), '| cap HUD', pg.evaluate("document.getElementById('capHud').textContent"), '| homers', homers)
    pg.evaluate("oracleModal.classList.add('hidden'); gameState=STATES.RESULT; handleUserAction()"); pg.wait_for_timeout(200)
    print('21st swing:', pg.evaluate("bannerText.textContent.trim()"), '/', pg.evaluate("bannerSub.textContent.trim()"), '| button:', pg.evaluate("buttonLabel.textContent"))
    # contract also refuses (e.g. a modified page)
    pg.evaluate("live.derby.connect(live.signer).swing(0, 0, 50, ethers.ZeroHash).catch(e => txError(e))"); pg.wait_for_timeout(800)
    print('contract says:', pg.evaluate("bannerSub.textContent.trim()"))
    # leaderboard tabs
    pg.evaluate("refreshBoard()"); pg.wait_for_timeout(800)
    pg.click('#lbToggle')
    print('ARCADE tab:', pg.evaluate("document.getElementById('lbMetric').textContent"), '|', pg.evaluate("document.getElementById('lbRows').innerText.replace(/\\s+/g,' ').trim()"), '| pot', pg.evaluate("document.getElementById('lbTabPot').textContent"))
    pg.click('#lbTabAgent'); pg.wait_for_timeout(100)
    print('AGENTS tab:', pg.evaluate("document.getElementById('lbMetric').textContent"), '|', pg.evaluate("document.getElementById('lbRows').innerText.replace(/\\s+/g,' ').trim()"), '| pot', pg.evaluate("document.getElementById('lbTabPot').textContent"), '| link shown:', pg.evaluate("document.getElementById('lbAgentLink').style.display !== 'none'"))
    print('expected arcade best:', max(homers or [0]))
    print('errors', errs); stop=True; b.close()
