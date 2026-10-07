import json, subprocess, time, urllib.request
RPC='http://127.0.0.1:8545'
def rpc(m, p=[]):
    r=urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), headers={'Content-Type':'application/json'})
    out=json.loads(urllib.request.urlopen(r).read()); 
    if 'error' in out: raise Exception(out['error'])
    return out['result']
def art(f,c): return json.load(open(f'out/{f}/{c}.json'))
acct=rpc('eth_accounts')[0]
def deploy(bytecode):
    h=rpc('eth_sendTransaction',[{"from":acct,"data":bytecode,"gas":hex(8_000_000)}])
    for _ in range(100):
        rc=rpc('eth_getTransactionReceipt',[h])
        if rc: return rc['contractAddress']
        time.sleep(0.1)
arbsys=art('Mocks.sol','LiveArbSys')['deployedBytecode']['object']
rpc('anvil_setCode',['0x0000000000000000000000000000000000000064', arbsys])
imd=deploy(art('Mocks.sol','MockIMD')['bytecode']['object'])
enc=subprocess.check_output(['cast','abi-encode','c(address,address,uint256,uint256)',
    acct, imd, str(15*10**16), str(5*10**17)]).decode().strip()
derby=deploy(art('SwarmDerby.sol','SwarmDerby')['bytecode']['object']+enc[2:])
# mint 10 IMD to player
data=subprocess.check_output(['cast','calldata','mint(address,uint256)',acct,str(10*10**18)]).decode().strip()
rpc('eth_sendTransaction',[{"from":acct,"to":imd,"data":data}])
# an agent wallet (anvil account #1) with IMD for the agent league
agent=rpc('eth_accounts')[1]
data=subprocess.check_output(['cast','calldata','mint(address,uint256)',agent,str(10*10**18)]).decode().strip()
rpc('eth_sendTransaction',[{"from":acct,"to":imd,"data":data}])
json.dump({"acct":acct,"imd":imd,"derby":derby}, open('e2e/addrs.json','w'))
print(acct, imd, derby)
