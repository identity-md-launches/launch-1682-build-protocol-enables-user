/* global ethers */
(() => {
  const cfg = window.SWARM_EXIT_CONFIG;

  const SWARM_EXIT_ABI = [
    "function swarmTokens() view returns (address[])",
    "function previewAll(address user) returns (tuple(address token,uint256 balance,uint256 expectedImd,bool sellable,uint8 status)[])",
    "function preview(address user,address[] tokens) returns (tuple(address token,uint256 balance,uint256 expectedImd,bool sellable,uint8 status)[])",
    "function quoteImdInBridge(uint256 imdAmount) returns (uint256)",
    "function ethUsdPrice() view returns (uint256 price,uint8 decimals)",
    "function paused() view returns (bool)",
    "function minImdOut() view returns (uint256)",
    "function MAX_TOKENS_PER_SALE() view returns (uint256)",
    "function heldRefunds(address user,address token) view returns (uint256)",
    "function claimRefund(address token)",
    "function sellAll(address[] tokens,uint256[] minImdOuts,uint256 deadline) returns (tuple(address token,uint256 amountIn,uint256 imdOut,uint8 status)[] outcomes,uint256 grossImd,uint256 tax,uint256 netImd)",
    "event TokenSold(address indexed user,address indexed token,uint256 amountIn,uint256 imdOut)",
    "event TokenSkipped(address indexed user,address indexed token,uint8 status)",
    "event TokenRefunded(address indexed user,address indexed token,uint256 amount,bytes reason)",
    "event RefundHeld(address indexed user,address indexed token,uint256 amount)",
    "event SoldAll(address indexed user,uint256 grossImd,uint256 tax,uint256 netImd)",
  ];
  const ERC20_ABI = [
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function allowance(address owner,address spender) view returns (uint256)",
    "function approve(address spender,uint256 amount) returns (bool)",
  ];
  const STATUS = [
    "Sellable",
    "Not a swarm token",
    "No balance",
    "No sale route configured",
    "IMD route not configured",
    "No liquidity (quote failed)",
    "Below minimum proceeds",
    "Sale would fail on chain",
    "Price impact too high (not enough liquidity)",
    "Not approved",
  ];
  const STATUS_SOLD = 0;
  const STATUS_SALE_FAILED = 7;
  const TAX_BPS = 200n;

  const $ = (id) => document.getElementById(id);
  const log = (msg) => {
    $("log").textContent += `${new Date().toLocaleTimeString()}  ${msg}\n`;
    $("log").scrollTop = $("log").scrollHeight;
  };
  const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
  const fmt = (v, d = 18, places = 4) => {
    const s = ethers.formatUnits(v, d);
    const n = Number(s);
    if (!Number.isFinite(n)) return s;
    return n.toLocaleString(undefined, { maximumFractionDigits: places });
  };
  const usd = (n) => (n == null ? "–" : n.toLocaleString(undefined, { style: "currency", currency: "USD" }));
  const key = (a) => a.toLowerCase();
  // Contract-returned strings (symbol) are never interpolated into HTML; cells are built with textContent.
  const cell = (cls, text) => {
    const td = document.createElement("td");
    if (cls) td.className = cls;
    if (text != null) td.textContent = text;
    return td;
  };

  let provider, signer, account, exit, rows = [], imdUsd = null, maxPerSale = 50;

  $("contract").value = cfg.swarmExit || "";
  $("slippage").value = String(cfg.slippageBps);

  function contractAddress() {
    const v = $("contract").value.trim();
    if (!ethers.isAddress(v)) throw new Error("Enter the SwarmExit contract address from the launch handoff.");
    return ethers.getAddress(v);
  }

  async function connect() {
    if (!window.ethereum) throw new Error("No injected wallet found. Install MetaMask or a compatible wallet.");
    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    const net = await provider.getNetwork();
    if (Number(net.chainId) !== cfg.chainId) {
      try {
        await provider.send("wallet_switchEthereumChain", [{ chainId: ethers.toBeHex(cfg.chainId) }]);
        provider = new ethers.BrowserProvider(window.ethereum);
      } catch (e) {
        throw new Error(`Switch your wallet to ${cfg.chainName} (chain id ${cfg.chainId}).`);
      }
    }
    signer = await provider.getSigner();
    account = await signer.getAddress();
    $("account").textContent = short(account);
    $("connect").textContent = "Connected";
    $("refresh").disabled = false;
    log(`Connected ${account}`);
    window.ethereum.on?.("accountsChanged", () => location.reload());
    window.ethereum.on?.("chainChanged", () => location.reload());
    await refresh();
  }

  async function loadImdUsd() {
    imdUsd = null;
    try {
      const bridgePerImd = await exit.quoteImdInBridge.staticCall(ethers.parseUnits("1", 18));
      const [price, dec] = await exit.ethUsdPrice();
      const ethUsd = Number(ethers.formatUnits(price, dec));
      imdUsd = Number(ethers.formatUnits(bridgePerImd, 18)) * ethUsd;
      log(`1 IMD ≈ ${usd(imdUsd)} (ETH/USD ${usd(ethUsd)} from Chainlink)`);
    } catch (e) {
      log(`USD pricing unavailable: ${e.shortMessage || e.message}`);
    }
  }

  async function refresh() {
    exit = new ethers.Contract(contractAddress(), SWARM_EXIT_ABI, signer);
    $("sell").disabled = true;
    rows = [];
    render();
    if (await exit.paused()) log("SwarmExit is paused by its owner; selling is disabled.");
    try { maxPerSale = Number(await exit.MAX_TOKENS_PER_SALE()); } catch (_) { maxPerSale = 50; }
    await loadImdUsd();
    const previews = await exit.previewAll.staticCall(account);
    const tokens = previews.map((p) => p.token);
    const heldAmounts = await Promise.all(tokens.map((t) => exit.heldRefunds(account, t).catch(() => 0n)));
    const held = previews.filter((p, i) => p.balance > 0n || heldAmounts[i] > 0n);
    log(`${previews.length} swarm tokens registered, ${held.length} held by this wallet.`);
    for (const p of held) {
      const erc = new ethers.Contract(p.token, ERC20_ABI, provider);
      let symbol = short(p.token), decimals = 18;
      try { [symbol, decimals] = await Promise.all([erc.symbol(), erc.decimals()]); } catch (_) { /* non-standard metadata */ }
      rows.push({
        token: p.token, symbol: String(symbol).slice(0, 32), decimals: Number(decimals), balance: p.balance,
        expectedImd: p.expectedImd, sellable: p.sellable, status: Number(p.status), note: "",
        heldRefund: heldAmounts[tokens.indexOf(p.token)],
      });
    }
    render();
    if (rows.some((r) => r.sellable)) $("sell").disabled = false;
  }

  function render() {
    const body = $("rows");
    body.innerHTML = "";
    if (rows.length === 0) {
      body.innerHTML = `<tr><td colspan="5" class="muted">No swarm-launched tokens in this wallet.</td></tr>`;
    }
    let totalImd = 0n, totalUsd = 0, count = 0;
    for (const r of rows) {
      const value = imdUsd == null || !r.sellable ? null : Number(ethers.formatUnits(r.expectedImd, 18)) * imdUsd;
      if (r.sellable) { totalImd += r.expectedImd; count += 1; if (value != null) totalUsd += value; }
      const tr = document.createElement("tr");
      tr.className = r.sellable ? "" : "unsellable";

      const tokenCell = cell();
      const strong = document.createElement("strong");
      strong.textContent = r.symbol;
      const addr = document.createElement("span");
      addr.className = "addr muted";
      addr.textContent = r.token;
      tokenCell.append(strong, document.createElement("br"), addr);
      tr.appendChild(tokenCell);

      tr.appendChild(cell("num", fmt(r.balance, r.decimals)));
      tr.appendChild(cell("num", r.sellable ? fmt(r.expectedImd) : "–"));
      tr.appendChild(cell("num", r.sellable ? usd(value) : "–"));

      const statusCell = cell();
      const tag = document.createElement("span");
      tag.className = `tag ${r.sellable ? "ok" : "bad"}`;
      tag.textContent = STATUS[r.status] || "Unknown";
      statusCell.appendChild(tag);
      if (r.note) {
        const note = document.createElement("span");
        note.className = "muted";
        note.textContent = r.note;
        statusCell.append(document.createElement("br"), note);
      }
      if (r.heldRefund > 0n) {
        const btn = document.createElement("button");
        btn.className = "secondary";
        btn.textContent = `Claim held refund (${fmt(r.heldRefund, r.decimals)} ${r.symbol})`;
        btn.addEventListener("click", () => claimRefund(r).catch((e) => log(`Error: ${e.shortMessage || e.message}`)));
        statusCell.append(document.createElement("br"), btn);
      }
      tr.appendChild(statusCell);
      body.appendChild(tr);
    }
    $("countSellable").textContent = String(count);
    $("totalImd").textContent = `${fmt(totalImd)} IMD`;
    $("totalUsd").textContent = imdUsd == null ? "unavailable" : usd(totalUsd);
    $("netImd").textContent = `${fmt(totalImd - (totalImd * TAX_BPS) / 10000n)} IMD`;
  }

  function slippageBps() {
    const n = Number($("slippage").value);
    if (!Number.isFinite(n)) throw new Error("Slippage must be a whole number of basis points.");
    return BigInt(Math.round(Math.max(0, Math.min(5000, n))));
  }

  async function claimRefund(r) {
    log(`Claiming held refund of ${r.symbol}…`);
    const tx = await exit.claimRefund(r.token);
    await tx.wait();
    log(`Refund claimed: ${tx.hash}`);
    await refresh();
  }

  async function ensureApprovals(selected) {
    for (const r of selected) {
      const erc = new ethers.Contract(r.token, ERC20_ABI, signer);
      const allowance = await erc.allowance(account, exit.target);
      if (allowance >= r.balance) continue;
      log(`Approving ${fmt(r.balance, r.decimals)} ${r.symbol} (exact balance; the contract never pulls more than the allowance)…`);
      const tx = await erc.approve(exit.target, r.balance);
      await tx.wait();
      log(`Approved ${r.symbol}: ${tx.hash}`);
    }
  }

  const deadline = () => BigInt(Math.floor(Date.now() / 1000) + cfg.deadlineSeconds);

  function markFailed(r, note) {
    r.sellable = false; r.status = STATUS_SALE_FAILED; r.note = note;
  }

  // Dry run with zero minimums. Sales execute one after another and share the IMD pool, so the
  // simulated outputs are the real quote. A token whose sale would fail, or would yield nothing, is
  // highlighted and left out. If the whole call reverts, each token is simulated alone to find the
  // culprit(s), and the batch is simulated again without them.
  async function simulate(batch) {
    const minImdOut = await exit.minImdOut().catch(() => 0n);
    let selected = batch.slice();
    for (let attempt = 0; attempt < 2 && selected.length > 0; attempt += 1) {
      let sim;
      try {
        sim = await exit.sellAll.staticCall(selected.map((r) => r.token), selected.map(() => 0n), deadline());
      } catch (e) {
        log(`Batch simulation reverted (${e.shortMessage || e.reason || e.message}); checking tokens one by one…`);
        const keep = [];
        for (const r of selected) {
          try {
            const one = await exit.sellAll.staticCall([r.token], [0n], deadline());
            const o = one.outcomes[0];
            if (Number(o.status) === STATUS_SOLD && o.imdOut >= minImdOut && o.imdOut > 0n) keep.push(r);
            else markFailed(r, "Simulation shows this sale would not settle; excluded.");
          } catch (err) {
            markFailed(r, `Simulation reverted: ${err.shortMessage || err.reason || err.message}`);
          }
        }
        selected = keep;
        continue;
      }
      const simulated = new Map(sim.outcomes.map((o) => [key(o.token), o]));
      const survivors = [];
      for (const r of selected) {
        const o = simulated.get(key(r.token));
        if (o && Number(o.status) === STATUS_SOLD && o.imdOut >= minImdOut && o.imdOut > 0n) {
          r.expectedImd = o.imdOut;
          r.note = "Expected IMD updated from the simulated sale.";
          survivors.push(r);
        } else {
          markFailed(r, "Simulation shows this sale would fail or yield nothing; excluded.");
        }
      }
      return survivors;
    }
    return selected;
  }

  async function sellAll() {
    $("sell").disabled = true;
    try {
      const bps = slippageBps(); // validated before any transaction is sent
      let selected = rows.filter((r) => r.sellable);
      if (selected.length === 0) throw new Error("Nothing sellable.");
      const batches = [];
      for (let i = 0; i < selected.length; i += maxPerSale) batches.push(selected.slice(i, i + maxPerSale));
      if (batches.length > 1) log(`${selected.length} tokens: selling in ${batches.length} transactions of at most ${maxPerSale}.`);

      for (const batch of batches) {
        log("Simulating the sale…");
        const chosen = await simulate(batch);
        render();
        const excluded = batch.length - chosen.length;
        if (excluded > 0) log(`${excluded} token(s) would fail on chain and were excluded.`);
        if (chosen.length === 0) { log("No token in this batch can be sold right now."); continue; }

        await ensureApprovals(chosen);
        log(`Selling ${chosen.length} token(s) for IMD (minimums ${bps} bps under the simulated outputs)…`);
        const tx = await exit.sellAll(
          chosen.map((r) => r.token),
          chosen.map((r) => (r.expectedImd * (10000n - bps)) / 10000n),
          deadline(),
        );
        log(`Sent ${tx.hash}`);
        const receipt = await tx.wait();
        for (const l of receipt.logs) {
          let parsed; try { parsed = exit.interface.parseLog(l); } catch (_) { continue; }
          if (!parsed) continue;
          if (parsed.name === "TokenSold") log(`Sold ${short(parsed.args.token)} for ${fmt(parsed.args.imdOut)} IMD`);
          if (parsed.name === "TokenSkipped") log(`Skipped ${short(parsed.args.token)}: ${STATUS[Number(parsed.args.status)] || "not sellable"}`);
          if (parsed.name === "TokenRefunded") log(`Refunded ${short(parsed.args.token)}: sale failed on chain, tokens returned`);
          if (parsed.name === "RefundHeld") log(`Refund of ${short(parsed.args.token)} is held by the contract (the token refused the transfer); claim it from the table.`);
          if (parsed.name === "SoldAll") log(`Done. Gross ${fmt(parsed.args.grossImd)} IMD, tax ${fmt(parsed.args.tax)} IMD, received ${fmt(parsed.args.netImd)} IMD`);
        }
      }
      await refresh();
    } catch (e) {
      log(`Error: ${e.shortMessage || e.reason || e.message}`);
      $("sell").disabled = !rows.some((r) => r.sellable);
    }
  }

  $("connect").addEventListener("click", () => connect().catch((e) => log(`Error: ${e.message}`)));
  $("refresh").addEventListener("click", () => refresh().catch((e) => log(`Error: ${e.shortMessage || e.message}`)));
  $("sell").addEventListener("click", sellAll);
})();
