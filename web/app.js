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
    "function sellAll(address[] tokens,uint256[] minImdOuts,uint256 deadline) returns (tuple(address token,uint256 amountIn,uint256 imdOut,uint8 status)[] outcomes,uint256 grossImd,uint256 tax,uint256 netImd)",
    "event TokenSold(address indexed user,address indexed token,uint256 amountIn,uint256 imdOut)",
    "event TokenRefunded(address indexed user,address indexed token,uint256 amount,bytes reason)",
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
  ];
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

  let provider, signer, account, exit, rows = [], imdUsd = null;

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
    await loadImdUsd();
    const previews = await exit.previewAll.staticCall(account);
    const held = previews.filter((p) => p.balance > 0n);
    log(`${previews.length} swarm tokens registered, ${held.length} held by this wallet.`);
    for (const p of held) {
      const erc = new ethers.Contract(p.token, ERC20_ABI, provider);
      let symbol = short(p.token), decimals = 18;
      try { [symbol, decimals] = await Promise.all([erc.symbol(), erc.decimals()]); } catch (_) { /* non-standard metadata */ }
      rows.push({
        token: p.token, symbol, decimals: Number(decimals), balance: p.balance,
        expectedImd: p.expectedImd, sellable: p.sellable, status: Number(p.status), note: "",
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
      tr.innerHTML = `
        <td><strong>${r.symbol}</strong><br/><span class="addr muted">${r.token}</span></td>
        <td class="num">${fmt(r.balance, r.decimals)}</td>
        <td class="num">${r.sellable ? fmt(r.expectedImd) : "–"}</td>
        <td class="num">${r.sellable ? usd(value) : "–"}</td>
        <td><span class="tag ${r.sellable ? "ok" : "bad"}">${STATUS[r.status] || "Unknown"}</span>${r.note ? `<br/><span class="muted">${r.note}</span>` : ""}</td>`;
      body.appendChild(tr);
    }
    $("countSellable").textContent = String(count);
    $("totalImd").textContent = `${fmt(totalImd)} IMD`;
    $("totalUsd").textContent = imdUsd == null ? "unavailable" : usd(totalUsd);
    $("netImd").textContent = `${fmt(totalImd - (totalImd * TAX_BPS) / 10000n)} IMD`;
  }

  function slippageBps() {
    const v = BigInt(Math.max(0, Math.min(5000, Number($("slippage").value) || 0)));
    return v;
  }

  async function ensureApprovals(selected) {
    for (const r of selected) {
      const erc = new ethers.Contract(r.token, ERC20_ABI, signer);
      const allowance = await erc.allowance(account, exit.target);
      if (allowance >= r.balance) continue;
      log(`Approving ${fmt(r.balance, r.decimals)} ${r.symbol} (exact balance)…`);
      const tx = await erc.approve(exit.target, r.balance);
      await tx.wait();
      log(`Approved ${r.symbol}: ${tx.hash}`);
    }
  }

  async function sellAll() {
    $("sell").disabled = true;
    try {
      let selected = rows.filter((r) => r.sellable);
      if (selected.length === 0) throw new Error("Nothing sellable.");
      await ensureApprovals(selected);

      const bps = slippageBps();
      const deadline = () => BigInt(Math.floor(Date.now() / 1000) + cfg.deadlineSeconds);

      // Dry run with zero minimums. Sales execute one after another and share the WETH/IMD pool, so
      // the simulated outputs are the real quote; isolated per-token quotes overstate later tokens.
      // A token whose sale would fail on chain is highlighted and left out of the real transaction.
      log("Simulating the sale…");
      const sim = await exit.sellAll.staticCall(selected.map((r) => r.token), selected.map(() => 0n), deadline());
      const simulated = new Map(sim.outcomes.map((o) => [o.token.toLowerCase(), o]));
      const failed = new Set();
      for (const r of rows) {
        const o = simulated.get(r.token.toLowerCase());
        if (!o) continue;
        if (Number(o.status) === 0) {
          r.expectedImd = o.imdOut;
          r.note = "Expected IMD updated from the simulated sale.";
        } else {
          failed.add(r.token.toLowerCase());
          r.sellable = false; r.status = 7; r.note = "Simulation reverted inside the swap; excluded from the sale.";
        }
      }
      render();
      selected = selected.filter((r) => !failed.has(r.token.toLowerCase()));
      if (failed.size > 0) log(`${failed.size} token(s) would fail on chain and were excluded.`);
      if (selected.length === 0) throw new Error("No token can be sold right now.");

      log(`Selling ${selected.length} token(s) for IMD (minimums ${bps} bps under the simulated outputs)…`);
      const tx = await exit.sellAll(
        selected.map((r) => r.token),
        selected.map((r) => (r.expectedImd * (10000n - bps)) / 10000n),
        deadline(),
      );
      log(`Sent ${tx.hash}`);
      const receipt = await tx.wait();
      for (const l of receipt.logs) {
        let parsed; try { parsed = exit.interface.parseLog(l); } catch (_) { continue; }
        if (!parsed) continue;
        if (parsed.name === "TokenSold") log(`Sold ${short(parsed.args.token)} for ${fmt(parsed.args.imdOut)} IMD`);
        if (parsed.name === "TokenRefunded") log(`Refunded ${short(parsed.args.token)}: sale failed on chain, tokens returned`);
        if (parsed.name === "SoldAll") log(`Done. Gross ${fmt(parsed.args.grossImd)} IMD, tax ${fmt(parsed.args.tax)} IMD, received ${fmt(parsed.args.netImd)} IMD`);
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
