import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useAccount, usePublicClient, useWalletClient } from "wagmi";
import { chain } from "./chain";
import { EXPLORER_URL, IMD_SYMBOL, LAUNCH_FACTORY_ADDRESS, SWARM_EXIT_ADDRESS } from "./config";
import { ConnectSheet } from "./wallet/ConnectSheet";
import { TokenList } from "./components/TokenList";
import { ConfirmDialog } from "./components/ConfirmDialog";
import { OwnerSetup } from "./components/OwnerSetup";
import { errorText, fmtAmount, fmtUsd, short } from "./lib/format";
import { claimRefund, executeSale, feeSplit, loadWallet, planSale, SaleExecutionError, usdValue, type Plan, type Progress, type SaleResult, type SwarmToken, type WalletState } from "./lib/sweep";
import { transactionHash } from "./lib/transactions";
import type { WalletLoadStatus } from "./components/TokenList";

type Sale = { plan: Plan; account: string; progress: Progress | null; error: string | null; hash: ReturnType<typeof transactionHash> };

export function App() {
  const { address, isConnected, chainId } = useAccount();
  const client = usePublicClient({ chainId: chain.id });
  const { data: wallet } = useWalletClient();
  const onChain = isConnected && chainId === chain.id;
  const context = `${address?.toLowerCase() ?? ""}:${onChain}`;
  const currentContext = useRef(context);
  currentContext.current = context;
  const readVersion = useRef(0);

  const [state, setState] = useState<WalletState | null>(null);
  const [loadStatus, setLoadStatus] = useState<WalletLoadStatus>("idle");
  const loading = loadStatus === "loading";
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [sale, setSale] = useState<Sale | null>(null);
  const [planning, setPlanning] = useState(false);
  const [claiming, setClaiming] = useState<string | null>(null);
  const [notice, setNotice] = useState<string>("");
  const [noticeHash, setNoticeHash] = useState<ReturnType<typeof transactionHash>>(null);

  const refresh = useCallback(async () => {
    if (!client || !address || !onChain) return;
    const version = ++readVersion.current;
    setLoadStatus("loading");
    setLoadError(null);
    try {
      const next = await loadWallet(client, address);
      if (version !== readVersion.current || currentContext.current !== context) return;
      setState(next);
      setSelected(new Set(next.tokens.filter((t) => t.sellable).map((t) => t.address.toLowerCase())));
      setLoadStatus("success");
    } catch (e) {
      if (version !== readVersion.current || currentContext.current !== context) return;
      setLoadError(`Unable to read the wallet: ${errorText(e)}`);
      setLoadStatus("error");
    }
  }, [client, address, onChain, context]);

  useEffect(() => {
    setState(null);
    setSelected(new Set());
    setLoadStatus("idle");
    setLoadError(null);
    setNotice("");
    setNoticeHash(null);
    if (onChain && address) void refresh();
    return () => { readVersion.current += 1; };
  }, [onChain, address, refresh]);

  const tokens = state?.tokens ?? [];
  const sellable = useMemo(() => tokens.filter((t) => t.sellable && t.result === undefined), [tokens]);
  const chosen = useMemo(() => sellable.filter((t) => selected.has(t.address.toLowerCase())), [sellable, selected]);
  const grossAll = sellable.reduce((s, t) => s + t.expectedImd, 0n);
  const { net: netAll } = feeSplit(grossAll);
  // Every held token with a quote, sellable or not yet registered, counts toward the wallet's value.
  const valueAll = tokens.filter((t) => t.result === undefined && t.quoteSource !== null).reduce((s, t) => s + t.expectedImd, 0n);
  const totalUsd = state?.pricing ? usdValue(valueAll, state.pricing) : null;
  const busy = planning || (sale !== null && sale.progress !== null && sale.error === null);
  const isOwner = !!state && !!address && state.setup.owner.toLowerCase() === address.toLowerCase();

  const toggle = (addr: string) => {
    const k = addr.toLowerCase();
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(k)) next.delete(k);
      else next.add(k);
      return next;
    });
  };

  const startSale = async (list: SwarmToken[]) => {
    if (!client || !address || !state || !onChain || loadStatus !== "success") return;
    setPlanning(true);
    setNotice("");
    setNoticeHash(null);
    try {
      const plan = await planSale(client, address, list, state.minImdOut, state.maxPerSale);
      if (currentContext.current === context) {
        applyResults(new Map(plan.excluded.map(({ token, reason }) => [token.address.toLowerCase(), { kind: "unsold" as const, reason }])));
        setSale({ plan, account: address, progress: null, error: null, hash: null });
      }
    } catch (e) {
      setNotice(`Unable to simulate the sale: ${errorText(e)}`);
    } finally {
      setPlanning(false);
    }
  };

  const applyResults = (results: Map<string, SaleResult>) => setState(s => s ? {
    ...s, tokens: s.tokens.map(t => {
      const result = results.get(t.address.toLowerCase());
      return result ? { ...t, result, heldRefund: result.kind === "unsold" && result.heldAmount !== undefined ? t.heldRefund + result.heldAmount : t.heldRefund } : t;
    }),
  } : s);

  const confirmSale = async () => {
    if (!sale || !client || !wallet || !address || !state || !onChain || sale.account.toLowerCase() !== address.toLowerCase()) return;
    setSale({ ...sale, error: null, hash: null, progress: { step: "check", batch: 1, batches: 1 } });
    let results = new Map<string, Awaited<ReturnType<typeof executeSale>> extends Map<string, infer R> ? R : never>();
    try {
      results = await executeSale(wallet, client, address, sale.plan, state.maxPerSale, (progress) =>
        setSale((s) => (s ? { ...s, progress } : s)),
      );
    } catch (e) {
      if (currentContext.current !== context) { setSale(null); return; }
      if (e instanceof SaleExecutionError) applyResults(e.results);
      setSale((s) => (s ? { ...s, progress: null, error: `Sale not completed: ${errorText(e)}`, hash: transactionHash(e) } : s));
      return;
    }
    if (currentContext.current !== context) { setSale(null); return; }
    const sold = [...results.values()].filter((r) => r.kind === "sold").length;
    applyResults(results);
    setSelected(new Set());
    setSale(null);
    setNotice(sold === results.size ? `Done. ${sold} of ${results.size} sold.` : `${sold} of ${results.size} sold. See each token’s status for skipped sales and refunds.`);
    // Refresh balances in the background, keeping the sold/unsold marks.
    if (client && address) {
      const fresh = await loadWallet(client, address).catch(() => null);
      if (fresh && currentContext.current === context) {
        setState((s) => {
          if (!s) return s;
          const marks = new Map(s.tokens.map((t) => [t.address.toLowerCase(), t.result] as const));
          const merged: SwarmToken[] = fresh.tokens.map((t) => ({ ...t, result: marks.get(t.address.toLowerCase()) }));
          for (const old of s.tokens) if (old.result && !merged.some((t) => t.address.toLowerCase() === old.address.toLowerCase())) merged.push({ ...old, balance: 0n });
          return { ...fresh, tokens: merged };
        });
      }
    }
  };

  const onClaim = async (t: SwarmToken) => {
    if (!wallet || !client || !address || !onChain) return;
    setClaiming(t.address);
    setNoticeHash(null);
    try {
      const hash = await claimRefund(wallet, client, address, t.address);
      if (currentContext.current !== context) return;
      setNoticeHash(hash);
      setNotice(`Refund of ${t.symbol} claimed.`);
      await refresh();
    } catch (e) {
      if (currentContext.current !== context) return;
      setNotice(`Unable to claim the refund: ${errorText(e)}`);
      setNoticeHash(transactionHash(e));
    } finally {
      setClaiming(null);
    }
  };

  const sellDisabled = !onChain || busy || loadStatus !== "success" || state?.paused === true;
  const unregisteredHeld = tokens.filter((t) => t.result === undefined && t.status === 1).length;
  const pricingHint = state?.pricingError ? `USD values unavailable: ${state.pricingError}` : "";

  return (
    <>
      <div id="page">
        <header className="top">
          <a className="brand" href="./" aria-label="SwarmSweep home">
            <img src="./favicon.svg" alt="" width={28} height={28} />
            <span>SwarmSweep</span>
          </a>
          <ConnectSheet />
        </header>

        <main>
          <section className="hero">
            <h1>Sweep swarm tokens into IMD</h1>
            <p>Sell every swarm-launched token in your wallet for ${IMD_SYMBOL} in one transaction. A 2% fee goes to the treasury.</p>
          </section>

          <section className="panel" aria-labelledby="summary-heading">
            <h2 id="summary-heading" className="sr-only">
              Summary and actions
            </h2>
            <dl className="summary">
              <div>
                <dt>Swarm tokens held</dt>
                <dd>{state ? tokens.filter((t) => t.balance > 0n).length : "–"}</dd>
              </div>
              <div>
                <dt>Sellable now</dt>
                <dd>{state ? sellable.length : "–"}</dd>
              </div>
              <div>
                <dt>Total value</dt>
                <dd>{state ? (state.pricing ? fmtUsd(totalUsd) : "USD n/a") : "–"}</dd>
              </div>
              <div>
                <dt>Yours after the 2% fee</dt>
                <dd>{state ? `${fmtAmount(netAll)} ${IMD_SYMBOL}` : "–"}</dd>
              </div>
            </dl>

            <div className="actions">
              <button className="btn btn-primary" onClick={() => startSale(sellable)} disabled={sellDisabled || sellable.length === 0}>
                {planning ? "Checking…" : "Sell all"}
              </button>
              <button
                className="btn btn-secondary"
                onClick={() => startSale(chosen)}
                disabled={sellDisabled || chosen.length === 0}
              >
                Sell selected{chosen.length > 0 ? ` (${chosen.length})` : ""}
              </button>
              <button className="btn btn-secondary" onClick={() => void refresh()} disabled={!onChain || loading || busy}>
                {loading ? "Reading…" : "Refresh"}
              </button>
              {!isConnected && <span className="hint">Connect a wallet to start.</span>}
              {isConnected && !onChain && <span className="hint">Switch your wallet to {chain.name} to continue.</span>}
              {state?.paused && <span className="hint">Selling is paused by the contract owner.</span>}
            </div>

            <p className="status-line" role="status" aria-live="polite">
              {loadError || notice ||
                (state && unregisteredHeld > 0 && !isOwner
                  ? `${unregisteredHeld} of your tokens are not registered in SwarmExit yet; the contract owner has to register them before they can be sold here.`
                  : "") ||
                pricingHint}
              {noticeHash && <> <a href={`${EXPLORER_URL}/tx/${noticeHash}`} target="_blank" rel="noreferrer">View transaction</a></>}
            </p>
          </section>

          {isOwner && state && address && (
            <OwnerSetup state={state} wallet={wallet} client={client} account={address} busy={busy || !onChain || loadStatus !== "success"} onDone={() => void refresh()} />
          )}

          <TokenList
            tokens={tokens}
            pricing={state?.pricing ?? null}
            selected={selected}
            onToggle={toggle}
            onClaim={onClaim}
            claiming={claiming}
            busy={busy || !onChain || loadStatus !== "success"}
            connected={isConnected}
            onChain={onChain}
            loadStatus={loadStatus}
          />
        </main>

        <footer className="foot">
          <p>
            Contract SwarmExit{" "}
            <a className="mono" href={`${EXPLORER_URL}/address/${SWARM_EXIT_ADDRESS}`} target="_blank" rel="noreferrer">
              {short(SWARM_EXIT_ADDRESS)}
            </a>{" "}
            on {chain.name}. Swarm tokens are read from the launch factory{" "}
            <a className="mono" href={`${EXPLORER_URL}/address/${LAUNCH_FACTORY_ADDRESS}`} target="_blank" rel="noreferrer">
              {short(LAUNCH_FACTORY_ADDRESS)}
            </a>
            . Failed sales return your tokens. If a token blocks the refund, it stays claimable here. Prefer a private RPC such as Flashbots
            Protect to avoid sandwiching.
          </p>
        </footer>
      </div>

      {sale && (
        <ConfirmDialog
          plan={sale.plan}
          pricing={state?.pricing ?? null}
          progress={sale.progress}
          error={sale.error}
          hash={sale.hash}
          canSell={onChain && sale.account.toLowerCase() === address?.toLowerCase()}
          onConfirm={() => void confirmSale()}
          onRefresh={() => { setSale(null); void refresh(); }}
          onClose={() => setSale(null)}
        />
      )}
    </>
  );
}
