import json, threading, time, urllib.request
from playwright.sync_api import sync_playwright
exec(open('e2e/play.py').read().split('url=')[0])  # rpc(), miner, SHIM
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}"
with sync_playwright() as p:
    b=p.chromium.launch(); ctx=b.new_context(); pg=ctx.new_page()
    errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.route('**/cdn.tailwindcss.com/**', lambda r: r.abort()); pg.route('**/fonts.g*/**', lambda r: r.abort())
    pg.add_init_script(SHIM); pg.goto(url); pg.wait_for_timeout(300)
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=15000)
    pg.evaluate("buyLive('pack')"); pg.wait_for_function("!live.busy && turnsLeft === 5", timeout=20000)
    print('turns before', pg.evaluate("turnsLeft"), 'session', pg.evaluate("live.sessionActive"))
    # commit a swing, then reload before the reveal
    globals()['stop']=True; time.sleep(0.4)   # freeze block production: the reveal can't happen yet
    pg.evaluate("startMashPhase(); mashPower = 1; triggerPitchRelease(); pitchProgress = 1.0; executeSwing();")
    pg.wait_for_function("JSON.parse(localStorage.getItem(storeKey('pending')) || '[]').some(p => p.swingId != null)", timeout=15000)
    pend=pg.evaluate("JSON.parse(localStorage.getItem(storeKey('pending')))"); print('pending before reload', [(x['swingId'], x['target']) for x in pend])
    pg.reload(); pg.wait_for_timeout(300)
    stop=False; threading.Thread(target=miner,daemon=True).start()   # blocks resume
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=20000)
    pg.wait_for_timeout(500); print('commentary', pg.evaluate("commentaryTicker.textContent.trim()"))
    print('pending after', pg.evaluate("JSON.parse(localStorage.getItem(storeKey('pending')) || '[]').length"), 'turns', pg.evaluate("turnsLeft"))
    print('errors', errs); stop=True; b.close()
