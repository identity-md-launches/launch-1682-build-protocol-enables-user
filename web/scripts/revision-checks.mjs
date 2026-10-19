// Run from web/: node --experimental-strip-types --test scripts/revision-checks.mjs
// Client fixtures exercise the real planner/executor; no wallet keys or broadcasts.
import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeEventTopics, encodeAbiParameters, parseEther } from 'viem';
import { planSale, executeSale, claimRefund, feeSplit } from '../src/lib/sweep.ts';
import { setupSteps } from '../src/lib/owner.ts';
import { swarmExitAbi } from '../src/abi/swarmExit.ts';
import { SWARM_EXIT_ADDRESS, IMD_ADDRESS, NATIVE } from '../src/constants.ts';

const account = '0x1000000000000000000000000000000000000001';
const hash = `0x${'ab'.repeat(32)}`;
const token = (n = 1) => ({ address: `0x${String(n).repeat(40)}`, symbol: `TOKEN${n}`, decimals: 18, balance: parseEther('100'), expectedImd: parseEther('100'), quoteSource: 'contract', sellable: true, status: 0, route: { venue: 1, tokenOut: IMD_ADDRESS }, routeLabel: 'Uniswap V2 to IMD', launch: null, heldRefund: 0n });
const makePlan = (tokens = [token()]) => { const items = tokens.map(t => ({token: t, imdOut: t.expectedImd})); const gross = items.reduce((s,i) => s+i.imdOut, 0n); return {items, excluded: [], gross, ...feeSplit(gross)}; };
const sold = (t, imdOut = t.expectedImd) => ({ token: t.address, amountIn: t.balance, imdOut, status: 0 });
const encodedLog = (eventName, args, values, types) => ({address: SWARM_EXIT_ADDRESS, topics: encodeEventTopics({abi: swarmExitAbi, eventName, args}), data: encodeAbiParameters(types.map(type => ({type})), values)});
function fixture({allowance = parseEther('100'), simulate, logs = [], status = 'success'} = {}) {
  const writes = [], simulations = [], allowances = new Map();
  const wallet = {chain: {id:1}, getChainId: async () => 1, getAddresses: async () => [account], writeContract: async a => {writes.push(a); if(a.functionName==='approve') allowances.set(a.address.toLowerCase(), a.args[1]); return hash;}};
  const client = {readContract: async a => {
    if(a.functionName==='allowance') return allowances.get(a.address.toLowerCase()) ?? allowance;
    if(a.functionName==='MAX_TOKENS_PER_SALE') return 50n;
    if(a.functionName==='preview') return a.args[1].map(address => ({...sold(token()), token: address, balance: token().balance, expectedImd: token().expectedImd, sellable: true}));
    throw Error(`Unexpected read ${a.functionName}`);
  }, simulateContract: async a => {simulations.push(a); return simulate ? simulate(a, allowances) : {result: [a.args[0].map(address => sold({...token(),address})), parseEther('100'), parseEther('2'), parseEther('98')]};}, waitForTransactionReceipt: async () => ({status, logs})};
  return {wallet,client,writes,simulations,allowances};
}
const execute = (f, plan = makePlan()) => executeSale(f.wallet, f.client, account, plan, 50, () => {});

test('first-time seller is retained as approval-required estimate, without simulating an unapproved sale', async () => {
  const f=fixture({allowance:0n, simulate:()=>{throw Error('NothingSold');}});
  const p=await planSale(f.client,account,[token()],1n);
  assert.equal(p.items.length,1); assert.equal(p.excluded.length,0);
  assert.equal(p.items[0].approvalRequired,true); assert.equal(p.items[0].estimated,true);
  assert.equal(p.gross,parseEther('100')); assert.equal(f.simulations.length,0);
});

test('mixed approval selection retains full-balance unapproved and partially approved tokens', async () => {
  const a=token(), b=token(2), c=token(3);
  const f=fixture({allowance:0n,simulate:a=>({result:[a.args[0].map(address=>sold({...token(),address})),0n,0n,0n]})});
  f.allowances.set(a.address,a.balance); f.allowances.set(c.address,1n);
  const p=await planSale(f.client,account,[a,b,c],1n);
  assert.equal(p.items.length,3); assert.equal(p.items.filter(i=>i.approvalRequired).length,2);
  assert.deepEqual(f.simulations[0].args[0],[a.address]);
});

test('post-approval quote drop below confirmed minimum never requests a sale signature', async () => {
  const f=fixture({simulate:()=>({result:[[sold(token(),parseEther('10'))],0n,0n,0n]})});
  await assert.rejects(execute(f),/minimum|quote|proceeds/i);
  assert.equal(f.writes.length,0);
});

test('per-token minimum remains 97 IMD from confirmed 100 even when fresh output is 98', async () => {
  const f=fixture({simulate:()=>({result:[[sold(token(),parseEther('98'))],0n,0n,0n]})});
  await execute(f); assert.equal(f.writes[0].args[1][0],parseEther('97'));
});

test('failed final simulation never requests a sale signature', async () => {
  const f=fixture({simulate:()=>{throw Error('NothingSold: no sale route');}});
  await assert.rejects(execute(f),/NothingSold|simulation/i); assert.equal(f.writes.length,0);
});

test('successful mixed simulation removes skipped tokens, retains confirmed minimum for remaining sale', async () => {
  const a=token(), b=token(2);
  const f=fixture({simulate:a=>({result:[a.args[0].map(address=>address===b.address?{...sold(b),status:3,imdOut:0n}:sold(token())),0n,0n,0n]})});
  const results=await execute(f,makePlan([a,b]));
  assert.equal(f.writes.length,1); assert.deepEqual(f.writes[0].args[0],[a.address]);
  assert.equal(f.writes[0].args[1][0],parseEther('97')); assert.equal(results.get(b.address).kind,'unsold');
});

test('all skipped final outcomes never request a sale signature', async () => {
  const f=fixture({simulate:()=>({result:[[{...sold(token()),status:3,imdOut:0n}],0n,0n,0n]})});
  await execute(f); assert.equal(f.writes.length,0);
});

test('RefundHeld survives TokenRefunded in either event order and retains held amount', async () => {
  const t=token();
  const held=encodedLog('RefundHeld',{user:account,token:t.address},[t.balance],['uint256']);
  const refunded=encodedLog('TokenRefunded',{user:account,token:t.address},[t.balance,'0x'],['uint256','bytes']);
  for (const logs of [[held,refunded],[refunded,held]]) {
    const f=fixture({logs}); const result=(await execute(f)).get(t.address);
    assert.equal(result.held,true); assert.equal(result.heldAmount,t.balance); assert.match(result.reason,/claim/i);
  }
});

test('reverted refund claim rejects with a transaction hash', async () => {
  const f=fixture({status:'reverted'});
  await assert.rejects(claimRefund(f.wallet,f.client,account,token().address),e=>{assert.equal(e.hash,hash);return /revert/i.test(e.message);});
});

test('reverted owner setup rejects with a transaction hash', async () => {
  const f=fixture({status:'reverted'});
  const steps=setupSteps(f.wallet,f.client,account,{imdPool:null,imdRouteSet:true,feedSet:false,register:[]});
  await assert.rejects(steps[0].run(),e=>{assert.equal(e.hash,hash);return /revert/i.test(e.message);});
});

test('registered launch with missing route schedules only its route repair', async () => {
  const f=fixture();
  const l={id:1,token:token().address,pair:IMD_ADDRESS,key:{currency0:token().address,currency1:IMD_ADDRESS,fee:12500,tickSpacing:60,hooks:NATIVE}};
  const steps=setupSteps(f.wallet,f.client,account,{imdPool:null,imdRouteSet:true,feedSet:true,register:[],routes:[l]});
  assert.equal(steps.length,1); await steps[0].run(); assert.equal(f.writes[0].functionName,'setTokenRoute');
});

test('reverted approval stops before a sale signature', async () => {
  const f=fixture({allowance:0n,status:'reverted'});
  await assert.rejects(execute(f),/revert/i); assert.deepEqual(f.writes.map(w=>w.functionName),['approve']);
});

test('wallet switching off Ethereum during approvals stops all subsequent writes', async () => {
  const f=fixture({allowance:0n});
  let chainId=1;
  f.wallet.getChainId=async()=>chainId;
  const originalWrite=f.wallet.writeContract;
  f.wallet.writeContract=async a=>{const h=await originalWrite(a);chainId=8453;return h;};
  await assert.rejects(execute(f,makePlan([token(),token(2)])),/Switch your wallet to Ethereum/);
  assert.deepEqual(f.writes.map(w=>w.functionName),['approve']);
});

test('changed active account cannot claim a refund or configure the owner contract', async () => {
  const f=fixture(); f.wallet.getAddresses=async()=>[token(2).address];
  await assert.rejects(claimRefund(f.wallet,f.client,account,token().address),/account changed/i);
  const steps=setupSteps(f.wallet,f.client,account,{imdPool:null,imdRouteSet:true,feedSet:false,register:[]});
  await assert.rejects(steps[0].run(),/account changed/i); assert.equal(f.writes.length,0);
});

test('plans and executes 51 tokens in batches within the contract limit', async () => {
  const tokens=Array.from({length:51},(_,i)=>({...token(),address:`0x${(i+1).toString(16).padStart(40,'0')}`}));
  const f=fixture();
  const p=await planSale(f.client,account,tokens,1n,50);
  assert.equal(p.items.length,51); assert.deepEqual(f.simulations.map(s=>s.args[0].length),[50,1]);
  await execute(f,p); assert.deepEqual(f.writes.map(w=>w.args[0].length),[50,1]);
});

test('failed later batch preserves successful earlier outcomes for the UI', async () => {
  const a=token(),b=token(2);
  const event=encodedLog('TokenSold',{user:account,token:a.address},[a.balance,a.expectedImd],['uint256','uint256']);
  const f=fixture({logs:[event],simulate:args=>{if(args.args[0][0]===b.address)throw Error('NothingSold');return {result:[[sold(a)],0n,0n,0n]};}});
  await assert.rejects(executeSale(f.wallet,f.client,account,makePlan([a,b]),1,()=>{}),e=>{
    assert.equal(e.results.get(a.address).kind,'sold'); assert.equal(e.results.get(b.address).kind,'unsold'); return true;
  });
  assert.equal(f.writes.length,1);
});

test('a below-minimum status in a mixed final simulation stops for renewed confirmation', async () => {
  const a=token(),b=token(2);
  const f=fixture({simulate:()=>({result:[[sold(a),{...sold(b),imdOut:0n,status:6}],0n,0n,0n]})});
  await assert.rejects(execute(f,makePlan([a,b])),/minimum you confirmed/); assert.equal(f.writes.length,0);
});

test('decoded contract reasons survive wrapped viem execution errors', async () => {
  const {errorText}=await import('../src/lib/format.ts');
  assert.equal(errorText({shortMessage:'The contract function reverted.',cause:{data:{errorName:'NothingSold'}}}),'NothingSold');
  assert.match(errorText({shortMessage:'Missing or invalid parameters.',details:'NothingSold: route unavailable'}),/NothingSold: route unavailable/);
});
