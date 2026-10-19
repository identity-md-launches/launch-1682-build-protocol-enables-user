// Interaction validation for the SwarmSweep export (run after `npm run build`, from web/:
// `node --experimental-strip-types scripts/interact.mjs`). Serves dist/ on a local port inside this
// process, routes the public RPC to a JSON-RPC mock of SwarmExit and four tokens, injects an
// EIP-6963 wallet, and walks: load, connect, sell all, confirm, approvals, sale, sold/unsold marks.
// Playwright is not a project dependency: set IMD_PLAYWRIGHT to a Playwright index.mjs (for
// example from an npx cache) or have `playwright` importable. Screenshots go to test/scratch/interact.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const OUT = path.join(ROOT, "test/scratch/interact");
fs.mkdirSync(OUT, { recursive: true });
const viem = await import(pathToFileURL(path.join(ROOT, "web/node_modules/viem/_esm/index.js")).href);
const { chromium, webkit } = await import(process.env.IMD_PLAYWRIGHT ? pathToFileURL(process.env.IMD_PLAYWRIGHT).href : "playwright");
const { swarmExitAbi } = await import(pathToFileURL(path.join(ROOT, "web/src/abi/swarmExit.ts")).href);
const { erc20Abi } = await import(pathToFileURL(path.join(ROOT, "web/src/abi/erc20.ts")).href);
const { factoryAbi } = await import(pathToFileURL(path.join(ROOT, "web/src/abi/factory.ts")).href);
const { v4QuoterAbi, stateViewAbi } = await import(pathToFileURL(path.join(ROOT, "web/src/abi/v4.ts")).href);
const { decodeFunctionData, encodeFunctionResult, encodeEventTopics, encodeAbiParameters, encodeErrorResult, parseUnits, getAddress, keccak256, toHex } = viem;

const EXIT = "0x5c3c2a6d7d340db9f8b3e0cbbc8dbbb7ec73bc61";
const IMD = "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7";
const WETH = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
const USER = "0x1000000000000000000000000000000000000001";
const OWNER = "0x0ace1dbe8aab293cd58d5e3ea38814f0ccb74782";
const FACTORY = "0xff03410d0fe5fa8f7f59f743de35e333d9857120";
const STATE_VIEW = "0x7ffe42c4a5deea5b0fec41c94c136cf115597227";
const QUOTER = "0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203";
const HOOK = "0x784ff9a3ac5d88a30bfff6f7f2a270161fbe6000";
const ZERO = "0x0000000000000000000000000000000000000000";
let ownerIsUser = false;
let readFailure = false;
const allowances = new Map();
let enforceAllowances = true;
let rejectNextRoute = false;
let heldSale = false;
let claimReverts = false;
let setupReverts = false;
let finalFailure = false;
let outputDivisor = 1n;
const refunds = new Map();
const T = {
  alpha: "0x1111111111111111111111111111111111111111", // sellable, v4 to IMD
  beta: "0x2222222222222222222222222222222222222222", // sellable, V2 to WETH; fails on chain and is refunded
  gamma: "0x3333333333333333333333333333333333333333", // no route configured
  delta: "0x4444444444444444444444444444444444444444", // route but quote fails
  empty: "0x5555555555555555555555555555555555555555", // zero balance, not listed
  epsilon: "0x6666666666666666666666666666666666666666", // launched, held, not registered: quoted through its pool
};
const meta = {
  [T.alpha]: { symbol: "ALPHA", decimals: 18, balance: parseUnits("12500", 18), expected: parseUnits("100", 18), sellable: true, status: 0, route: [3, "0x000000000004444c5dc75cb358380d2e3de08a90", "0x0000000000000000000000000000000000000000", T.alpha, IMD] },
  [T.beta]: { symbol: "BETA", decimals: 18, balance: parseUnits("3.25", 18), expected: parseUnits("50", 18), sellable: true, status: 0, route: [1, "0x7a250d5630b4cf539739df2c5dacb4c659f2488d", "0x0000000000000000000000000000000000000000", T.beta, WETH] },
  [T.gamma]: { symbol: "GAMMA", decimals: 18, balance: parseUnits("900000", 18), expected: 0n, sellable: false, status: 3, route: [0, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"] },
  [T.delta]: { symbol: "DELTA", decimals: 6, balance: 4200000000n, expected: 0n, sellable: false, status: 5, route: [2, "0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45", "0x61ffe014ba17989e743c5f6cb21bf9697530b21e", T.delta, WETH] },
  [T.empty]: { symbol: "EMPTY", decimals: 18, balance: 0n, expected: 0n, sellable: false, status: 2, route: [0, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"] },
  [T.epsilon]: { symbol: "EPSILON", decimals: 18, balance: parseUnits("77000", 18), expected: 0n, sellable: false, status: 1, unregistered: true, poolQuote: parseUnits("20", 18), route: [0, "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"] },
};
const registered = Object.values(T).filter((t) => !meta[t].unregistered);
// Launch ids 1403.. map to the mock tokens, as the factory's positionOf would report them.
const launchIds = Object.fromEntries(Object.values(T).map((t, i) => [1403 + i, t]));
const tokens = Object.values(T);
const calls = [];
let txCount = 0;
let saleTxHash = null;
const sent = [];

function ethCall({ to, data }) {
  const target = to.toLowerCase();
  if (target === EXIT) {
    const { functionName, args } = decodeFunctionData({ abi: swarmExitAbi, data });
    calls.push(functionName);
    const enc = (result) => encodeFunctionResult({ abi: swarmExitAbi, functionName, result });
    switch (functionName) {
      case "paused": return enc(false);
      case "MAX_TOKENS_PER_SALE": return enc(50n);
      case "minImdOut": return enc(parseUnits("0.001", 18));
      case "preview": return enc(args[1].map((a) => { const t = a.toLowerCase(); const m = meta[t]; return m.unregistered ? { token: getAddress(t), balance: 0n, expectedImd: 0n, sellable: false, status: 1 } : { token: getAddress(t), balance: m.balance, expectedImd: m.expected, sellable: m.sellable, status: m.status }; }));
      case "swarmTokens": if (readFailure) throw Object.assign(new Error("execution reverted: review unavailable read"), {code:3}); return enc(registered.map((t) => getAddress(t)));
      case "owner": return enc(getAddress(ownerIsUser ? USER : OWNER));
      case "imdRoute": return enc({ venue: 3, router: getAddress("0x000000000004444c5dc75cb358380d2e3de08a90"), quoter: ZERO, tokenIn: ZERO, tokenOut: getAddress(IMD), data: "0x" });
      case "ethUsdFeed": return enc(getAddress("0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419"));
      case "heldRefunds": return enc(refunds.get(args[1].toLowerCase()) ?? 0n);
      case "tokenRoute": { const r = meta[args[0].toLowerCase()].route; return enc({ venue: r[0], router: getAddress(r[1]), quoter: getAddress(r[2]), tokenIn: getAddress(r[3]), tokenOut: getAddress(r[4]), data: "0x" }); }
      case "quoteImdInBridge": return enc(parseUnits("0.0001", 18)); // 1 IMD = 0.0001 ETH
      case "ethUsdPrice": return enc([300000000000n, 8]); // $3000
      case "sellAll": {
        if (finalFailure) throw Object.assign(new Error("execution reverted: NothingSold"), {code:3,data:encodeErrorResult({abi:swarmExitAbi,errorName:"NothingSold"})});
        const list = args[0].map((a) => a.toLowerCase());
        const outcomes = list.map((t, i) => enforceAllowances && !(allowances.get(t) > 0n) ? { token: getAddress(t), amountIn: 0n, imdOut: 0n, status: 9 } : meta[t].expected / outputDivisor < args[1][i] ? { token: getAddress(t), amountIn: 0n, imdOut: 0n, status: 6 } : { token: getAddress(t), amountIn: meta[t].balance, imdOut: meta[t].expected / outputDivisor, status: 0 });
        if (outcomes.every(o => o.imdOut === 0n)) throw Object.assign(new Error("execution reverted: NothingSold"), {code:3,data:encodeErrorResult({abi:swarmExitAbi,errorName:"NothingSold"})});
        const gross = outcomes.reduce((s, o) => s + o.imdOut, 0n);
        const tax = (gross * 200n) / 10000n;
        return enc([outcomes, gross, tax, gross - tax]);
      }
      default: throw new Error(`unmocked SwarmExit call ${functionName}`);
    }
  }
  if (target === FACTORY) {
    const { functionName, args } = decodeFunctionData({ abi: factoryAbi, data });
    const enc = (result) => encodeFunctionResult({ abi: factoryAbi, functionName, result });
    if (functionName === "deploymentBlock") return enc(args[0] === 1682n ? 26188854n : 0n);
    if (functionName === "positionOf") {
      const t = launchIds[Number(args[0])];
      if (!t) return enc([ZERO, ZERO, 0, 0, ZERO, 0, 0, ZERO]);
      return enc([getAddress(t), getAddress(IMD), 12500, 60, getAddress(HOOK), -128940, 887220, getAddress(OWNER)]);
    }
  }
  if (target === STATE_VIEW) {
    const { functionName } = decodeFunctionData({ abi: stateViewAbi, data });
    const enc = (result) => encodeFunctionResult({ abi: stateViewAbi, functionName, result });
    if (functionName === "getLiquidity") return enc(parseUnits("1", 22));
  }
  if (target === QUOTER) {
    const { functionName, args } = decodeFunctionData({ abi: v4QuoterAbi, data });
    calls.push("quoter");
    const tokenIn = (args[0].zeroForOne ? args[0].poolKey.currency0 : args[0].poolKey.currency1).toLowerCase();
    const m = meta[tokenIn];
    if (!m || !m.poolQuote) throw new Error("NotEnoughLiquidity");
    return encodeFunctionResult({ abi: v4QuoterAbi, functionName, result: [m.poolQuote, 100000n] });
  }
  if (meta[target]) {
    const { functionName } = decodeFunctionData({ abi: erc20Abi, data });
    calls.push(`erc20.${functionName}`);
    const enc = (result) => encodeFunctionResult({ abi: erc20Abi, functionName, result });
    if (functionName === "symbol") return enc(meta[target].symbol);
    if (functionName === "decimals") return enc(meta[target].decimals);
    if (functionName === "balanceOf") return enc(meta[target].balance);
    if (functionName === "allowance") return enc(allowances.get(target) ?? 0n);
  }
  throw new Error(`unmocked eth_call to ${to}`);
}

function receiptFor(hash) {
  const tx = sent.find((t) => t.hash === hash);
  const logs = [];
  let reverted = false;
  if (tx && tx.to.toLowerCase() === EXIT) {
    const call = decodeFunctionData({abi: swarmExitAbi, data: tx.data});
    if (call.functionName === "claimRefund") {
      reverted = claimReverts;
      if (!reverted) refunds.delete(call.args[0].toLowerCase());
    }
    if (["setSwarmToken", "setTokenRoute"].includes(call.functionName)) reverted = setupReverts;
    if (call.functionName === "setSwarmToken" && !reverted) {
      const t = call.args[0].toLowerCase();
      if (!registered.includes(t)) registered.push(t);
      meta[t].unregistered = false; meta[t].status = 3;
    }
    if (call.functionName === "setTokenRoute" && !reverted) {
      const t = call.args[0].toLowerCase();
      meta[t].route = [3, call.args[2], ZERO, t, IMD];
      meta[t].expected ||= meta[t].poolQuote ?? 0n;
      meta[t].sellable = meta[t].expected > 0n; meta[t].status = meta[t].sellable ? 0 : 5;
    }
  }
  if (tx && meta[tx.to.toLowerCase()]) {
    const call = decodeFunctionData({abi: erc20Abi, data: tx.data});
    if (call.functionName === "approve") allowances.set(tx.to.toLowerCase(), call.args[1]);
  }
  if (tx && tx.to.toLowerCase() === EXIT && decodeFunctionData({abi: swarmExitAbi, data: tx.data}).functionName === "sellAll") {
    const log = (eventName, args, data) => logs.push({ address: EXIT, topics: encodeEventTopics({ abi: swarmExitAbi, eventName, args }), data, blockNumber: "0x10", transactionHash: hash, transactionIndex: "0x0", blockHash: "0x" + "ab".repeat(32), logIndex: toHex(logs.length), removed: false });
    log("TokenSold", { user: USER, token: T.alpha }, encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [meta[T.alpha].balance, meta[T.alpha].expected]));
    if (heldSale) { refunds.set(T.beta, meta[T.beta].balance); log("RefundHeld", {user:USER, token:T.beta}, encodeAbiParameters([{type:"uint256"}], [meta[T.beta].balance])); }
    log("TokenRefunded", { user: USER, token: T.beta }, encodeAbiParameters([{ type: "uint256" }, { type: "bytes" }], [meta[T.beta].balance, "0x"]));
    log("SoldAll", { user: USER }, encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }, { type: "uint256" }], [meta[T.alpha].expected, meta[T.alpha].expected / 50n, meta[T.alpha].expected - meta[T.alpha].expected / 50n]));
  }
  return { transactionHash: hash, transactionIndex: "0x0", blockHash: "0x" + "ab".repeat(32), blockNumber: "0x10", from: USER, to: tx?.to ?? EXIT, cumulativeGasUsed: "0x5208", gasUsed: "0x5208", contractAddress: null, logs, logsBloom: "0x" + "00".repeat(256), status: reverted ? "0x0" : "0x1", effectiveGasPrice: "0x1", type: "0x2" };
}

function rpc({ method, params }) {
  switch (method) {
    case "eth_chainId": return "0x1";
    case "net_version": return "1";
    case "eth_blockNumber": return "0x10";
    case "eth_call": return ethCall(params[0]);
    case "eth_estimateGas": return "0x30000";
    case "eth_gasPrice": return "0x3b9aca00";
    case "eth_maxPriorityFeePerGas": return "0x3b9aca00";
    case "eth_getBlockByNumber": return { number: "0x10", hash: "0x" + "ab".repeat(32), parentHash: "0x" + "ac".repeat(32), timestamp: toHex(Math.floor(Date.now() / 1000)), baseFeePerGas: "0x3b9aca00", gasLimit: "0x1c9c380", gasUsed: "0x0", miner: USER, transactions: [], nonce: "0x0000000000000000", difficulty: "0x0", extraData: "0x", logsBloom: "0x" + "00".repeat(256), mixHash: "0x" + "00".repeat(32), receiptsRoot: "0x" + "00".repeat(32), sha3Uncles: "0x" + "00".repeat(32), size: "0x0", stateRoot: "0x" + "00".repeat(32), totalDifficulty: "0x0", transactionsRoot: "0x" + "00".repeat(32), uncles: [] };
    case "eth_getTransactionReceipt": return receiptFor(params[0]);
    case "eth_getTransactionByHash": { const tx = sent.find((t) => t.hash === params[0]); return tx ? { hash: tx.hash, from: USER, to: tx.to, input: tx.data, nonce: "0x1", blockNumber: "0x10", blockHash: "0x" + "ab".repeat(32), transactionIndex: "0x0", value: "0x0", gas: "0x30000", gasPrice: "0x1", type: "0x2", chainId: "0x1", v: "0x0", r: "0x0", s: "0x0" } : null; }
    case "wallet_sendTransaction":
    case "eth_sendTransaction": { if (params[0].to.toLowerCase() === EXIT && decodeFunctionData({abi:swarmExitAbi,data:params[0].data}).functionName === "setTokenRoute" && rejectNextRoute) { rejectNextRoute=false; throw Object.assign(new Error("User rejected route signature"), {code:4001}); } const hash = keccak256(toHex(`tx-${++txCount}`)); sent.push({ hash, to: params[0].to, data: params[0].data }); if (params[0].to.toLowerCase() === EXIT) saleTxHash = hash; return hash; }
    case "eth_accounts": case "eth_requestAccounts": return [USER];
    case "wallet_switchEthereumChain": return null;
    case "wallet_requestPermissions": return [{parentCapability:"eth_accounts"}];
    default: console.log("unmocked rpc", method); return null;
  }
}

// --- static server for dist, under a subpath so relative URLs are exercised ---
const dist = path.join(ROOT, "dist");
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png" };
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (!p.startsWith("/preview/")) { res.writeHead(404); return res.end(); }
  p = p.slice("/preview/".length) || "index.html";
  const file = path.join(dist, p);
  if (!file.startsWith(dist) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); return res.end("missing " + p); }
  res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/preview/`;

const browser = await (process.argv.includes("--webkit") ? webkit : chromium).launch();
const failures = [];
const check = (cond, msg) => { console.log(`${cond ? "ok  " : "FAIL"} ${msg}`); if (!cond) failures.push(msg); };

async function openPage(width, height, { wallet = true } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, hasTouch: width < 700 });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => { if (m.type() === "error") errors.push(`console: ${m.text()}`); });
  page.on("requestfailed", (r) => { if (!r.url().includes("publicnode") && !r.url().includes("drpc")) errors.push(`requestfailed: ${r.url()}`); });
  await page.route(/https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?.*/, async (route) => {
    const body = JSON.parse(route.request().postData() ?? "{}");
    const answer = (req) => { try { return { jsonrpc: "2.0", id: req.id, result: rpc(req) }; } catch (e) { return { jsonrpc: "2.0", id: req.id, error: { code: e.code ?? -32000, message: String(e.message), data:e.data } }; } };
    const out = Array.isArray(body) ? body.map(answer) : answer(body);
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(out) });
  });
  if (wallet) {
    await page.addInitScript(({ user }) => {
      const listeners = {};
      window.__walletChain = "0x1";
      window.__changeChain = (id) => { window.__walletChain = id; for (const f of (listeners.chainChanged ?? [])) f(id); };
      const provider = {
        isMockWallet: true,
        request: async ({ method, params }) => {
          if (method === "eth_chainId") return window.__walletChain;
          if (method === "wallet_switchEthereumChain") { window.__changeChain(params[0].chainId); return null; }
          if (method === "eth_accounts" && !window.__authorized) return [];
          if (method === "eth_requestAccounts") window.__authorized = true;
          const res = await fetch("https://ethereum-rpc.publicnode.com/", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params ?? [] }) });
          const j = await res.json();
          if (j.error) throw Object.assign(new Error(j.error.message), { code: j.error.code });
          return j.result;
        },
        on: (e, f) => { (listeners[e] ??= []).push(f); },
        removeListener: (e, f) => { listeners[e] = (listeners[e] ?? []).filter(listener => listener !== f); },
      };
      const detail = Object.freeze({ info: { uuid: "0b1d4b6a-2c0e-4c4a-9a1a-000000000001", name: "Mock Wallet", icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 28 28'%3E%3Crect width='28' height='28' rx='6' fill='%23e8732a'/%3E%3C/svg%3E", rdns: "test.mockwallet" }, provider });
      const announce = () => window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail }));
      window.addEventListener("eip6963:requestProvider", announce);
      announce();
      void user;
    }, { user: USER });
  }
  await page.goto(base + "index.html");
  await page.waitForSelector("h1");
  return { ctx, page, errors };
}

if (!process.argv.includes("--revision-only")) {
// ---- 1. first screen at 390, no wallet, keyboard walk ----
{
  const { ctx, page, errors } = await openPage(390, 844, { wallet: false });
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(OUT, "390-first-screen.png") });
  const h1 = await page.locator("h1").boundingBox();
  const sellAll = await page.getByRole("button", { name: "Sell all" }).boundingBox();
  const connect = await page.getByRole("button", { name: "Connect wallet" }).boundingBox();
  check(h1 && h1.y + h1.height < 844, "390: headline on the first screen");
  check(sellAll && sellAll.y + sellAll.height < 844, `390: Sell all on the first screen (bottom ${sellAll && Math.round(sellAll.y + sellAll.height)})`);
  check(connect && connect.y + connect.height < 844, "390: Connect wallet on the first screen");
  check(sellAll && sellAll.height >= 44, `390: Sell all is ${sellAll && sellAll.height}px tall`);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(overflow <= 0, `390: no horizontal overflow (${overflow})`);
  check(await page.getByText("Connect a wallet to list the swarm-launched tokens it holds.").isVisible(), "390: empty state explains what to do");
  // keyboard: Tab reaches Connect, Enter opens the sheet, Escape closes it and returns focus
  await page.keyboard.press("Tab"); await page.keyboard.press("Tab");
  check((await page.evaluate(() => document.activeElement?.textContent)) === "Connect wallet", "keyboard: second Tab stop is Connect wallet");
  await page.keyboard.press("Enter");
  await page.waitForSelector("[role=dialog]");
  check(await page.getByRole("dialog", { name: "Connect a wallet" }).isVisible(), "keyboard: Enter opens the connect sheet");
  check(await page.getByRole("button", { name: "Browser wallet" }).isVisible(), "no extension: generic row reads 'Browser wallet'");
  check(await page.getByRole("button", { name: "Coinbase Wallet" }).isVisible(), "sheet lists Coinbase Wallet");
  const rowH = await page.getByRole("button", { name: "Coinbase Wallet" }).boundingBox();
  check(rowH && rowH.height >= 48, `sheet rows are ${rowH && rowH.height}px high`);
  await page.screenshot({ path: path.join(OUT, "390-connect-sheet.png") });
  const focusInside = await page.evaluate(() => !!document.activeElement?.closest("[role=dialog]"));
  check(focusInside, "sheet: focus moved inside on open");
  await page.keyboard.press("Escape");
  await page.waitForTimeout(100);
  check((await page.locator("[role=dialog]").count()) === 0, "sheet: Escape closes it");
  check((await page.evaluate(() => document.activeElement?.textContent)) === "Connect wallet", "sheet: focus returns to the trigger");
  check(errors.length === 0, `390: no console/page errors (${errors.join("; ")})`);
  await ctx.close();
}

// ---- 2. mobile user agent: open-in rows ----
{
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", hasTouch: true });
  const page = await ctx.newPage();
  await page.goto(base + "index.html");
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await page.waitForSelector("[role=dialog]");
  for (const w of ["MetaMask", "Coinbase Wallet", "Rabby", "Phantom"]) check(await page.getByRole("link", { name: `Open in ${w}` }).isVisible(), `phone: 'Open in ${w}' row`);
  check(await page.getByRole("button", { name: "Coinbase Smart Wallet" }).isVisible(), "phone: Coinbase Smart Wallet row");
  const href = await page.getByRole("link", { name: "Open in MetaMask" }).getAttribute("href");
  check(href?.startsWith("https://link.metamask.io/dapp/127.0.0.1"), `phone: MetaMask link carries this page (${href})`);
  await page.screenshot({ path: path.join(OUT, "390-phone-sheet.png") });
  await ctx.close();
}

// ---- 3. connect with the mock wallet, list, sell all, confirm, result; at 390 and 1440 ----
for (const width of [390, 1440]) {
  calls.length = 0; sent.length = 0; saleTxHash = null; txCount = 0; allowances.clear();
  const height = width < 700 ? 844 : 900;
  const { ctx, page, errors } = await openPage(width, height);
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await page.waitForSelector("[role=dialog]");
  check(await page.getByRole("button", { name: "Mock Wallet" }).isVisible(), `${width}: EIP-6963 wallet listed by its own name`);
  check((await page.getByRole("button", { name: "Browser wallet" }).count()) === 0, `${width}: generic injected row hidden when an extension is named`);
  await page.getByRole("button", { name: "Mock Wallet" }).click();
  await page.waitForSelector("text=ALPHA", { timeout: 15000 });
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(OUT, `${width}-connected.png`), fullPage: true });
  check(await page.getByRole("button", { name: /0x1000…0001/ }).isVisible(), `${width}: header shows the short address and Disconnect`);
  const rows = page.locator("table.tokens tbody tr");
  check((await rows.count()) === 5, `${width}: five held tokens listed (four registered, one only launched), zero balance token hidden (${await rows.count()})`);
  check(calls.includes("quoter"), `${width}: the unregistered token was quoted through its launch pool`);
  check(await page.getByText("20 IMD if registered").isVisible(), `${width}: EPSILON shows its pool quote as 'if registered'`);
  check(await page.getByText("Not registered in SwarmExit yet, though its pool would buy it").isVisible(), `${width}: EPSILON explains it is not registered`);
  check(await page.getByText("1 of your tokens are not registered in SwarmExit yet; the contract owner has to register them before they can be sold here.").isVisible(), `${width}: status line tells the holder about unregistered tokens`);
  check((await page.locator("#owner-heading").count()) === 0, `${width}: owner setup hidden for a non-owner`);
  check(await page.getByText("Uniswap v4 to IMD").isVisible(), `${width}: ALPHA sell route identified`);
  check(await page.getByText("Uniswap V2 to ETH, then IMD").isVisible(), `${width}: BETA sell route identified`);
  check((await page.getByText("No sell route found").count()) === 3, `${width}: GAMMA, DELTA and EPSILON marked 'No sell route found'`);
  const dim = await page.locator("tr.dim").count();
  check(dim === 3, `${width}: three rows greyed out (${dim})`);
  const gammaColor = await page.locator("tr.dim td[data-label=Token] .token-name").first().evaluate((el) => getComputedStyle(el).color);
  const alphaColor = await page.locator("tr:not(.dim) td[data-label=Token] .token-name").first().evaluate((el) => getComputedStyle(el).color);
  check(gammaColor !== alphaColor, `${width}: greyed rows use the secondary text color (${gammaColor} vs ${alphaColor})`);
  check(await page.getByText("$30.00").isVisible(), `${width}: ALPHA USD value shown (100 IMD at $0.30)`);
  check(await page.getByText("$15.00").isVisible(), `${width}: BETA USD value shown`);
  check(await page.getByText("$51.00").isVisible(), `${width}: total USD value shown (100 + 50 sellable + 20 quoted IMD at $0.30)`);
  check(await page.getByText("147 IMD").isVisible(), `${width}: net after 2% fee shown (147 IMD)`);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(overflow <= 0, `${width}: no horizontal overflow when the list is full (${overflow})`);
  // selection: untick BETA, Sell selected becomes available with count 1
  await page.getByRole("checkbox", { name: "Select BETA" }).uncheck();
  check(await page.getByRole("button", { name: "Sell selected (1)" }).isEnabled(), `${width}: Sell selected (1) enabled after unticking BETA`);
  await page.getByRole("button", { name: "Sell selected (1)" }).click();
  await page.waitForSelector("[role=dialog]");
  check(await page.getByRole("dialog", { name: "Sell 1 token for IMD?" }).isVisible(), `${width}: confirmation for the selected token`);
  check(await page.getByText("98 IMD").isVisible(), `${width}: net for one token is 98 IMD`);
  await page.screenshot({ path: path.join(OUT, `${width}-confirm-selected.png`) });
  await page.getByRole("button", { name: "Cancel" }).click();
  await page.waitForTimeout(100);
  check((await page.locator("[role=dialog]").count()) === 0, `${width}: Cancel closes the confirmation`);
  await page.getByRole("checkbox", { name: "Select BETA" }).check();
  // sell all
  await page.getByRole("button", { name: "Sell all" }).click();
  await page.waitForSelector("[role=dialog]");
  check(await page.getByRole("dialog", { name: "Sell 2 tokens for IMD?" }).isVisible(), `${width}: confirmation lists 2 tokens`);
  check(await page.getByText("150 IMD").isVisible(), `${width}: gross 150 IMD`);
  check(await page.getByText("−3 IMD").isVisible(), `${width}: fee 3 IMD`);
  check(await page.getByText("147 IMD").first().isVisible(), `${width}: you receive 147 IMD`);
  check(await page.getByText("0xFC3a…1cFB").isVisible(), `${width}: treasury address shown`);
  await page.screenshot({ path: path.join(OUT, `${width}-confirm-all.png`) });
  await page.getByRole("button", { name: "Sell 2 tokens" }).click();
  await page.waitForSelector("text=See each token", { timeout: 20000 });
  await page.waitForTimeout(500);
  check(sent.length === 3, `${width}: two approvals then one sellAll sent (${sent.length})`);
  check(sent[2] && sent[2].to.toLowerCase() === EXIT, `${width}: last transaction goes to SwarmExit`);
  const sellArgs = sent[2] && decodeFunctionData({ abi: swarmExitAbi, data: sent[2].data });
  check(sellArgs && sellArgs.functionName === "sellAll" && sellArgs.args[0].length === 2, `${width}: sellAll(tokens[2], mins, deadline)`);
  check(sellArgs && sellArgs.args[1][0] === (parseUnits("100", 18) * 9700n) / 10000n, `${width}: per-token minimum is 3% under the simulated output`);
  check(await page.getByText("1 of 2 sold. See each token’s status for skipped sales and refunds.").isVisible(), `${width}: completion notice`);
  const sold = page.locator(".pill-ok", { hasText: "Sold" });
  const unsold = page.locator(".pill-bad", { hasText: "Unsold" });
  check((await sold.count()) === 1 && (await unsold.count()) === 1, `${width}: one Sold and one Unsold mark`);
  const soldColor = await sold.first().evaluate((el) => getComputedStyle(el).color);
  const unsoldColor = await unsold.first().evaluate((el) => getComputedStyle(el).color);
  check(soldColor !== unsoldColor, `${width}: Sold ${soldColor}, Unsold ${unsoldColor}`);
  check(await page.getByText("The sale failed on chain. Your tokens were refunded in the same transaction.").isVisible(), `${width}: refund explained on the unsold row`);
  await page.screenshot({ path: path.join(OUT, `${width}-after-sale.png`), fullPage: true });
  check(errors.length === 0, `${width}: no console/page errors (${errors.join("; ")})`);
  await ctx.close();
}

// ---- 4. 320 reflow ----
{
  const { ctx, page } = await openPage(320, 700);
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await page.getByRole("button", { name: "Mock Wallet" }).click();
  await page.waitForSelector("text=ALPHA", { timeout: 15000 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(overflow <= 0, `320: no horizontal overflow with the list (${overflow})`);
  await page.screenshot({ path: path.join(OUT, "320-connected.png"), fullPage: true });
  await ctx.close();
}

// ---- 5. the owner wallet sees the setup panel ----
{
  ownerIsUser = true;
  const { ctx, page, errors } = await openPage(1440, 900);
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await page.getByRole("button", { name: "Mock Wallet" }).click();
  await page.waitForSelector("text=ALPHA", { timeout: 15000 });
  check(await page.getByRole("heading", { name: "Owner setup" }).isVisible(), "owner: setup panel shown to the owner");
  check((await page.locator(".owner .pill-ok").count()) === 2, "owner: IMD route and feed marked Set");
  check(await page.getByText("3 of 6").isVisible(), "owner: 3 of 6 launched tokens have both registration and route");
  check(await page.getByRole("button", { name: "Set up for this wallet (3 transactions)" }).isEnabled(), "owner: held tokens need one registration and two routes");
  check(await page.getByRole("button", { name: "Complete setup for 3 launched tokens (4 transactions)" }).isEnabled(), "owner: register-all offered");
  await page.screenshot({ path: path.join(OUT, "1440-owner-setup.png"), fullPage: true });
  await page.getByRole("button", { name: "Set up for this wallet (3 transactions)" }).click();
  await page.waitForSelector("text=Done. 3 transactions confirmed.", { timeout: 20000 });
  const reg = sent.slice(-3).map((t) => decodeFunctionData({ abi: swarmExitAbi, data: t.data }));
  check(reg[0]?.functionName === "setSwarmToken" && reg[0].args[0].toLowerCase() === T.epsilon && reg[0].args[1] === true, "owner: setSwarmToken(EPSILON, true) sent");
  check(reg[2]?.functionName === "setTokenRoute" && reg[2].args[1] === 3 && reg[2].args[2].toLowerCase() === "0x000000000004444c5dc75cb358380d2e3de08a90", "owner: setTokenRoute(EPSILON, v4, PoolManager, …) sent");
  check(errors.length === 0, `owner: no console/page errors (${errors.join("; ")})`);
  await ctx.close();
  ownerIsUser = false;
}

}

// Revision reproductions against the actual static export and EIP-6963 wallet.
if (process.argv.includes("--revision-only")) {
  ownerIsUser = true;
  const {ctx, page, errors} = await openPage(390, 844);
  await page.getByRole("button", {name:"Connect wallet"}).click();
  await page.getByRole("button", {name:"Mock Wallet"}).click();
  await page.waitForSelector("text=ALPHA", {timeout:20000});
  const measureContrast = async (selector, pseudo = null) => page.locator(selector).first().evaluate((el, pseudo) => {
    const canvas = document.createElement("canvas"); canvas.width=canvas.height=1;
    const c = canvas.getContext("2d");
    const rgb = color => { c.clearRect(0,0,1,1); c.fillStyle=color; c.fillRect(0,0,1,1); return [...c.getImageData(0,0,1,1).data].slice(0,3); };
    const luminance = values => values.map(n=>n/255).map(n=>n<=0.04045?n/12.92:((n+0.055)/1.055)**2.4).reduce((s,n,i)=>s+n*[0.2126,0.7152,0.0722][i],0);
    const fg=rgb(getComputedStyle(el, pseudo).color), bg=rgb(getComputedStyle(el.closest("table")).backgroundColor);
    const l=[luminance(fg),luminance(bg)].sort((a,b)=>b-a);
    return {fg,bg,ratio:(l[0]+0.05)/(l[1]+0.05)};
  }, pseudo);
  for(const width of [320,390,1440]) {
    await page.setViewportSize({width,height:844});
    for(const [selector,pseudo] of [["tr.dim .token-name",null],["tr.dim .addr",null],["tr.dim [data-label=Balance]",null],...(width<640?[["tr.dim [data-label=Balance]","::before"]]:[])]) {
      const contrast=await measureContrast(selector,pseudo);
      console.log(`Measured ${width} ${selector}${pseudo??""}:`,JSON.stringify(contrast));
      check(contrast.ratio>=4.5,`revision: ${width} unavailable ${selector}${pseudo??""} has 4.5:1 contrast`);
    }
  }
  await page.setViewportSize({width:390,height:844});
  await page.evaluate(()=>window.__changeChain("0x2105"));
  await page.waitForTimeout(300);
  check(await page.getByRole("button",{name:"Sell all",exact:true}).isDisabled(),"revision: Base wallet disables Sell all");
  check(await page.getByRole("button",{name:"Switch to Ethereum",exact:true}).count()===1,"revision: Base wallet offers Switch to Ethereum");
  check(await page.getByText("Switch your wallet to Ethereum to continue.").count()===1,"revision: wrong-network guidance");
  if(await page.getByRole("button",{name:"Set up for this wallet",exact:false}).count()) check(await page.getByRole("button",{name:"Set up for this wallet",exact:false}).isDisabled(),"revision: wrong network disables owner setup");
  await page.screenshot({path:path.join(OUT,"revision-wrong-network.png"),fullPage:true});
  await page.getByRole("button",{name:"Switch to Ethereum",exact:true}).click();
  await page.getByRole("button",{name:"Sell all",exact:true}).waitFor({state:"visible"});
  await page.waitForFunction(()=>!document.querySelector(".actions .btn-primary")?.disabled);
  check(await page.getByRole("button",{name:"Switch to Ethereum",exact:true}).count()===0,"revision: switching back to Ethereum restores the correct network state");
  await ctx.close(); ownerIsUser=false;
  readFailure=true;
  const failed=await openPage(390,844);
  await failed.page.getByRole("button",{name:"Connect wallet"}).click();
  await failed.page.getByRole("button",{name:"Mock Wallet"}).click();
  await failed.page.getByText(/Unable to read the wallet/).waitFor({timeout:30000});
  check(await failed.page.getByText("No swarm-launched tokens in this wallet. Nothing to sell.").count()===0,"revision: failed read never claims an empty wallet");
  check(await failed.page.getByText("Wallet could not be read. Refresh to try again.").count()===1,"revision: table read failure has retry guidance");
  await failed.page.screenshot({path:path.join(OUT,"revision-read-failure.png"),fullPage:true});
  check(errors.length===0 && failed.errors.length===0,"revision: no browser errors");
  readFailure=false;
  await failed.page.getByRole("button",{name:"Refresh",exact:true}).click();
  await failed.page.getByText("ALPHA",{exact:true}).waitFor({timeout:30000});
  readFailure=true;
  await failed.page.getByRole("button",{name:"Refresh",exact:true}).click();
  await failed.page.getByText(/Previous results below are stale\.$/).waitFor({timeout:30000});
  check(await failed.page.getByText("ALPHA",{exact:true}).isVisible(),"revision: failed refresh retains previous tokens");
  check(await failed.page.getByRole("button",{name:"Sell all",exact:true}).isDisabled(),"revision: stale results cannot be sold");
  await failed.ctx.close(); readFailure=false;

  // A successful registration followed by a rejected route must offer just the missing route.
  ownerIsUser=true; rejectNextRoute=true; sent.length=0;
  const gammaRoute=meta[T.gamma].route;
  meta[T.gamma].route=[3,"0x000000000004444c5dc75cb358380d2e3de08a90",ZERO,T.gamma,IMD];
  const owner=await openPage(390,844);
  await owner.page.getByRole("button",{name:"Connect wallet"}).click();
  await owner.page.getByRole("button",{name:"Mock Wallet"}).click();
  await owner.page.getByRole("button",{name:"Set up for this wallet (2 transactions)",exact:true}).waitFor({timeout:30000});
  await owner.page.getByRole("button",{name:"Set up for this wallet (2 transactions)",exact:true}).click();
  await owner.page.getByText(/Stopped at/).waitFor({timeout:30000});
  await owner.page.getByRole("button",{name:"Set up for this wallet (1 transaction)",exact:true}).waitFor({timeout:30000});
  check(registered.includes(T.epsilon) && meta[T.epsilon].route[0]===0,"revision: registration persisted after route rejection");
  check(await owner.page.getByRole("button",{name:"Set up for this wallet (1 transaction)",exact:true}).isEnabled(),"revision: registered token offers one missing route retry");
  await owner.page.screenshot({path:path.join(OUT,"revision-route-retry.png"),fullPage:true});
  await owner.page.getByRole("button",{name:"Set up for this wallet (1 transaction)",exact:true}).click();
  await owner.page.getByText("Done. 1 transaction confirmed.",{exact:true}).waitFor({timeout:30000});
  const ownerCalls=sent.map(t=>decodeFunctionData({abi:swarmExitAbi,data:t.data}));
  check(ownerCalls.filter(c=>c.functionName==="setSwarmToken").length===1,"revision: route retry does not re-register the token");
  check(ownerCalls.at(-1)?.functionName==="setTokenRoute","revision: route retry submits setTokenRoute");
  // A mined-but-reverted configuration stays pending and gets a transaction link.
  setupReverts=true; meta[T.gamma].route=gammaRoute;
  await owner.page.getByRole("button",{name:"Refresh",exact:true}).click();
  await owner.page.getByRole("button",{name:"Set up for this wallet (1 transaction)",exact:true}).waitFor({timeout:30000});
  await owner.page.getByRole("button",{name:"Set up for this wallet (1 transaction)",exact:true}).click();
  await owner.page.getByText(/Owner setup transaction reverted/).waitFor({timeout:30000});
  check(await owner.page.getByRole("link",{name:"View failed transaction",exact:true}).isVisible(),"revision: reverted setup has a transaction link");
  check(meta[T.gamma].route[0]===0,"revision: reverted route remains missing");
  await owner.ctx.close(); ownerIsUser=false; setupReverts=false;

  // RefundHeld is followed by TokenRefunded, as in the deployed contract.
  heldSale=true; refunds.clear(); allowances.clear(); sent.length=0;
  const refund=await openPage(390,844);
  await refund.page.getByRole("button",{name:"Connect wallet"}).click();
  await refund.page.getByRole("button",{name:"Mock Wallet"}).click();
  await refund.page.getByRole("button",{name:"Sell all",exact:true}).waitFor({timeout:30000});
  await refund.page.getByRole("button",{name:"Sell all",exact:true}).click();
  const saleDialog=refund.page.getByRole("dialog");
  await saleDialog.waitFor();
  check(await saleDialog.getByText("Approval required",{exact:true}).count()>=2,"revision: first-time confirmation retains approval-required tokens");
  check(await saleDialog.getByText("Estimated proceeds",{exact:true}).count()>=2,"revision: unapproved amounts are explicitly estimates");
  await saleDialog.getByRole("button",{name:/Sell [0-9]+ tokens?/}).click();
  await refund.page.getByRole("button",{name:"Claim refund",exact:true}).waitFor({timeout:30000});
  check(await refund.page.getByText(/The token blocked its refund/).isVisible(),"revision: held refund status survives TokenRefunded");
  check(await refund.page.getByText(/3.25 held as refund/).isVisible(),"revision: held amount is shown with claim action");
  claimReverts=true;
  await refund.page.getByRole("button",{name:"Claim refund",exact:true}).click();
  await refund.page.getByText(/Unable to claim the refund: Refund claim transaction reverted/).waitFor({timeout:30000});
  check(await refund.page.getByRole("button",{name:"Claim refund",exact:true}).isEnabled(),"revision: reverted refund claim stays retryable");
  check(await refund.page.getByRole("link",{name:"View transaction",exact:true}).count()>=1,"revision: reverted refund claim provides a transaction link");
  await refund.page.screenshot({path:path.join(OUT,"revision-held-refund.png"),fullPage:true});
  claimReverts=false;
  await refund.page.getByRole("button",{name:"Claim refund",exact:true}).click();
  await refund.page.getByText("Refund of BETA claimed.",{exact:false}).waitFor({timeout:30000});
  await refund.page.waitForFunction(() => ![...document.querySelectorAll("button")].some(b => /^Claim/.test(b.textContent.trim())));
  check((await refund.page.getByRole("button",{name:"Claim refund",exact:true}).count())===0,"revision: successful claim clears the outstanding claim after refresh");
  await refund.ctx.close(); heldSale=false;

  // Fresh proceeds cannot lower a confirmed minimum or request a known-reverting sale.
  for (const mode of ["drop","revert"]) {
    sent.length=0; allowances.clear();
    for(const t of tokens) allowances.set(t,meta[t].balance);
    const quote=await openPage(390,844);
    await quote.page.getByRole("button",{name:"Connect wallet"}).click();
    await quote.page.getByRole("button",{name:"Mock Wallet"}).click();
    await quote.page.getByRole("checkbox",{name:"Select ALPHA",exact:true}).waitFor({timeout:30000});
    for(const checkbox of await quote.page.getByRole("checkbox").all()) await checkbox.uncheck();
    await quote.page.getByRole("checkbox",{name:"Select ALPHA",exact:true}).check();
    await quote.page.getByRole("button",{name:"Sell selected (1)",exact:true}).click();
    await quote.page.getByRole("dialog").waitFor();
    if(mode==="drop") outputDivisor=10n; else finalFailure=true;
    await quote.page.getByRole("dialog").getByRole("button",{name:"Sell 1 token",exact:true}).click();
    await quote.page.getByRole("dialog").getByText(/Final sale simulation failed/).waitFor({timeout:30000});
    check((await quote.page.getByRole("dialog").textContent()).includes("NothingSold"),`revision: ${mode} failure displays the contract reason`);
    check(sent.length===0,`revision: ${mode} final simulation requests zero sale signatures`);
    check(await quote.page.getByRole("button",{name:"Refresh quotes",exact:true}).isEnabled(),`revision: ${mode} failure offers refresh`);
    await quote.page.screenshot({path:path.join(OUT,`revision-final-${mode}.png`),fullPage:true});
    if(mode==="drop") {
      await quote.page.getByRole("button",{name:"Refresh quotes",exact:true}).click();
      await quote.page.getByRole("button",{name:"Refresh",exact:true}).waitFor();
      await quote.page.waitForFunction(()=>!document.querySelector(".actions .btn-primary")?.disabled);
      for(const checkbox of await quote.page.getByRole("checkbox").all()) await checkbox.uncheck();
      await quote.page.getByRole("checkbox",{name:"Select ALPHA",exact:true}).check();
      await quote.page.getByRole("button",{name:"Sell selected (1)",exact:true}).click();
      await quote.page.waitForFunction(()=>document.querySelector("[role=dialog] .totals .total dd")?.textContent.includes("9.8 IMD"));
      check((await quote.page.locator("[role=dialog] .totals .total dd").textContent()).includes("9.8 IMD"),"revision: changed 10 IMD quote is presented for a new confirmation (9.8 net)");
    }
    await quote.ctx.close(); outputDivisor=1n; finalFailure=false;
  }
}

await browser.close();
server.close();
console.log(failures.length === 0 ? "\nALL CHECKS PASSED" : `\n${failures.length} CHECK(S) FAILED`);
process.exit(failures.length === 0 ? 0 : 1);
