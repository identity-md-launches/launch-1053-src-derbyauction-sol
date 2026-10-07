import json, threading, time, urllib.request
from playwright.sync_api import sync_playwright
exec(open('e2e/play.py').read().split('url=')[0])  # rpc(), miner, SHIM
url=f"file://{__import__('os').path.abspath(__import__('os').environ.get('SITE', '../swarm-derby-site/index.html'))}?network=local&rpc={RPC}&derby={A['derby']}&imd={A['imd']}"
PENDING="JSON.parse(localStorage.getItem(storeKey('pending')) || '[]')"
def reload_before_receipt(pg, keep_hash):
    globals()['stop']=True; time.sleep(0.4)
    rpc('evm_setAutomine',[False])   # the commit waits in the mempool: the page gets no receipt
    pg.evaluate("startMashPhase(); mashPower = 1; triggerPitchRelease(); pitchProgress = 1.0; executeSwing();")
    pg.wait_for_function(f"{PENDING}.some(p => p.tx)", timeout=15000)
    if not keep_hash:   # as if the page closed before the wallet returned the hash
        pg.evaluate(f"localStorage.setItem(storeKey('pending'), JSON.stringify({PENDING}.map(({{tx, ...p}}) => p)))")
    print('pending before reload', [(x.get('swingId'), 'tx' in x) for x in pg.evaluate(PENDING)])
    pg.reload(); pg.wait_for_timeout(300)
    rpc('evm_setAutomine',[True]); rpc('evm_mine')   # the commit lands while the page is closed
    globals()['stop']=False; threading.Thread(target=miner,daemon=True).start()
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=60000)
    pg.wait_for_timeout(500); print('commentary', pg.evaluate("commentaryTicker.textContent.trim()"))
    print('pending after', len(pg.evaluate(PENDING)), 'turns', pg.evaluate("turnsLeft"))
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_context().new_page()
    errs=[]; pg.on('pageerror', lambda e: errs.append(str(e)))
    pg.add_init_script(SHIM); pg.goto(url); pg.wait_for_timeout(300)
    pg.click('#walletBtn'); pg.wait_for_function("live.on && !live.busy", timeout=15000)
    pg.evaluate("buyLive('pack')"); pg.wait_for_function("!live.busy && turnsLeft === 5", timeout=20000)
    print('== with the tx hash'); reload_before_receipt(pg, True)
    print('== without the tx hash'); reload_before_receipt(pg, False)
    print('errors', errs); globals()['stop']=True; b.close()
