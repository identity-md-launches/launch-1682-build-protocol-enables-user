import { useCallback, useEffect, useMemo, useState } from "react";
import { useAccount, useChainId, usePublicClient, useWalletClient } from "wagmi";
import { chain } from "./chain";
import { EXPLORER_URL, IMD_SYMBOL, SWARM_EXIT_ADDRESS } from "./config";
import { ConnectSheet } from "./wallet/ConnectSheet";
import { TokenList } from "./components/TokenList";
import { ConfirmDialog } from "./components/ConfirmDialog";
import { errorText, fmtAmount, fmtUsd, short } from "./lib/format";
import { claimRefund, executeSale, feeSplit, loadWallet, planSale, usdValue, type Plan, type Progress, type SwarmToken, type WalletState } from "./lib/sweep";

type Sale = { plan: Plan; progress: Progress | null; error: string | null };

export function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const client = usePublicClient();
  const { data: wallet } = useWalletClient();
  const onChain = isConnected && chainId === chain.id;

  const [state, setState] = useState<WalletState | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [sale, setSale] = useState<Sale | null>(null);
  const [planning, setPlanning] = useState(false);
  const [claiming, setClaiming] = useState<string | null>(null);
  const [notice, setNotice] = useState<string>("");

  const refresh = useCallback(async () => {
    if (!client || !address) return;
    setLoading(true);
    setLoadError(null);
    try {
      const next = await loadWallet(client, address);
      setState(next);
      setSelected(new Set(next.tokens.filter((t) => t.sellable).map((t) => t.address.toLowerCase())));
    } catch (e) {
      setLoadError(`Unable to read the wallet: ${errorText(e)}`);
    } finally {
      setLoading(false);
    }
  }, [client, address]);

  useEffect(() => {
    if (onChain && address) void refresh();
    else {
      setState(null);
      setSelected(new Set());
    }
  }, [onChain, address, refresh]);

  const tokens = state?.tokens ?? [];
  const sellable = useMemo(() => tokens.filter((t) => t.sellable && t.result === undefined), [tokens]);
  const chosen = useMemo(() => sellable.filter((t) => selected.has(t.address.toLowerCase())), [sellable, selected]);
  const grossAll = sellable.reduce((s, t) => s + t.expectedImd, 0n);
  const { net: netAll } = feeSplit(grossAll);
  const totalUsd = state?.pricing ? usdValue(grossAll, state.pricing) : null;
  const busy = planning || (sale !== null && sale.progress !== null && sale.error === null);

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
    if (!client || !address || !state) return;
    setPlanning(true);
    setNotice("");
    try {
      const plan = await planSale(client, address, list, state.minImdOut);
      setSale({ plan, progress: null, error: null });
    } catch (e) {
      setNotice(`Unable to simulate the sale: ${errorText(e)}`);
    } finally {
      setPlanning(false);
    }
  };

  const confirmSale = async () => {
    if (!sale || !client || !wallet || !address || !state) return;
    setSale({ ...sale, error: null, progress: { step: "sign", batch: 1, batches: 1 } });
    let results = new Map<string, Awaited<ReturnType<typeof executeSale>> extends Map<string, infer R> ? R : never>();
    try {
      results = await executeSale(wallet, client, address, sale.plan, state.maxPerSale, (progress) =>
        setSale((s) => (s ? { ...s, progress } : s)),
      );
    } catch (e) {
      setSale((s) => (s ? { ...s, progress: null, error: `Sale not completed: ${errorText(e)}` } : s));
      return;
    }
    const sold = [...results.values()].filter((r) => r.kind === "sold").length;
    setState((s) =>
      s ? { ...s, tokens: s.tokens.map((t) => (results.has(t.address.toLowerCase()) ? { ...t, result: results.get(t.address.toLowerCase()) } : t)) } : s,
    );
    setSelected(new Set());
    setSale(null);
    setNotice(sold === results.size ? `Done. ${sold} of ${results.size} sold.` : `Done. ${sold} of ${results.size} sold; the rest stayed in your wallet.`);
    // Refresh balances in the background, keeping the sold/unsold marks.
    if (client && address) {
      const fresh = await loadWallet(client, address).catch(() => null);
      if (fresh) {
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
    if (!wallet || !client || !address) return;
    setClaiming(t.address);
    try {
      await claimRefund(wallet, client, address, t.address);
      setNotice(`Refund of ${t.symbol} claimed.`);
      await refresh();
    } catch (e) {
      setNotice(`Unable to claim the refund: ${errorText(e)}`);
    } finally {
      setClaiming(null);
    }
  };

  const sellDisabled = !onChain || busy || loading || state?.paused === true;

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
                <dt>Sellable tokens</dt>
                <dd>{state ? sellable.length : "–"}</dd>
              </div>
              <div>
                <dt>Total value</dt>
                <dd>{state ? (state.pricing ? fmtUsd(totalUsd) : "USD n/a") : "–"}</dd>
              </div>
              <div>
                <dt>You receive, after the 2% fee</dt>
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
              {notice || loadError || (state?.pricingError ? "USD values unavailable: the IMD route or price feed is not configured yet." : "")}
            </p>
          </section>

          <TokenList
            tokens={tokens}
            pricing={state?.pricing ?? null}
            selected={selected}
            onToggle={toggle}
            onClaim={onClaim}
            claiming={claiming}
            busy={busy}
            connected={onChain}
            loading={loading}
          />
        </main>

        <footer className="foot">
          <p>
            Contract SwarmExit{" "}
            <a className="mono" href={`${EXPLORER_URL}/address/${SWARM_EXIT_ADDRESS}`} target="_blank" rel="noreferrer">
              {short(SWARM_EXIT_ADDRESS)}
            </a>{" "}
            on {chain.name}. Tokens never rest in the contract: a failed sale is refunded in the same transaction. Prefer a private RPC
            such as Flashbots Protect to avoid sandwiching.
          </p>
        </footer>
      </div>

      {sale && (
        <ConfirmDialog
          plan={sale.plan}
          pricing={state?.pricing ?? null}
          progress={sale.progress}
          error={sale.error}
          onConfirm={() => void confirmSale()}
          onClose={() => setSale(null)}
        />
      )}
    </>
  );
}
