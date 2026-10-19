import { useState } from "react";
import type { Address, Hash, PublicClient, WalletClient } from "viem";
import { errorText } from "../lib/format";
import type { Launch } from "../lib/launches";
import { routable, setupSteps, type OwnerStep } from "../lib/owner";
import type { WalletState } from "../lib/sweep";
import { transactionHash } from "../lib/transactions";
import { EXPLORER_URL } from "../config";

type Props = {
  state: WalletState;
  wallet: WalletClient | undefined;
  client: PublicClient | undefined;
  account: Address;
  busy: boolean;
  onDone: () => void;
};

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** Shown only to the contract owner: what the live contract still lacks, and buttons that set it. */
export function OwnerSetup({ state, wallet, client, account, busy, onDone }: Props) {
  const [running, setRunning] = useState<{ done: number; total: number; label: string } | null>(null);
  const [note, setNote] = useState("");
  const [failedHash, setFailedHash] = useState<Hash | null>(null);
  const { setup, launches, tokens } = state;
  const registered = new Set(setup.registered.map((a) => a.toLowerCase()));
  const routableAll = launches.filter(routable);
  const pendingAll = routableAll.filter(l => !registered.has(l.token.toLowerCase()) || !setup.routes[l.token.toLowerCase()]);
  const pendingHeld = pendingAll.filter(l => tokens.some(t => same(t.address, l.token) && t.balance > 0n));
  const routesMissing = (!setup.imdRouteSet ? 1 : 0) + (!setup.feedSet ? 1 : 0);
  const options = (pending: Launch[]) => ({
    imdPool: setup.imdPool, imdRouteSet: setup.imdRouteSet, feedSet: setup.feedSet,
    register: pending.filter(l => !registered.has(l.token.toLowerCase())),
    routes: pending.filter(l => !registered.has(l.token.toLowerCase()) || !setup.routes[l.token.toLowerCase()]),
  });
  const count = (pending: Launch[]) => (!setup.imdRouteSet && setup.imdPool ? 1 : 0) + (!setup.feedSet ? 1 : 0) + options(pending).register.length + options(pending).routes.length;

  const run = async (pending: Launch[]) => {
    if (!wallet || !client || busy) return;
    const steps: OwnerStep[] = setupSteps(wallet, client, account, options(pending));
    if (steps.length === 0) return;
    setNote("");
    setFailedHash(null);
    for (let i = 0; i < steps.length; i += 1) {
      const step = steps[i]!;
      setRunning({ done: i, total: steps.length, label: step.label });
      try {
        await step.run();
      } catch (e) {
        setFailedHash(transactionHash(e));
        setNote(`Stopped at "${step.label}": ${errorText(e)}. What was sent before it stays set.`);
        setRunning(null);
        onDone();
        return;
      }
    }
    setRunning(null);
    setNote(`Done. ${steps.length} transaction${steps.length === 1 ? "" : "s"} confirmed.`);
    onDone();
  };

  const nothing = routesMissing === 0 && pendingAll.length === 0;
  const disabled = busy || running !== null || !wallet;

  return (
    <section className="panel owner" aria-labelledby="owner-heading">
      <h2 id="owner-heading" className="h3">
        Owner setup
      </h2>
      <p className="hint">
        This wallet owns SwarmExit. The contract sells only tokens it has registered, through the route set for each one. Each item below is one
        transaction from this wallet.
      </p>
      <ul className="checks">
        <li>
          <span className={`pill ${setup.imdRouteSet ? "pill-ok" : "pill-bad"}`}>{setup.imdRouteSet ? "Set" : "Missing"}</span> ETH to IMD route
          {!setup.imdRouteSet && !setup.imdPool && <span className="note">No ETH/IMD pool with liquidity was found, so it cannot be set from here.</span>}
          {!setup.imdRouteSet && setup.imdPool && (
            <span className="note">
              Uniswap v4 ETH/IMD pool, fee {setup.imdPool.fee / 10_000}%, tick spacing {setup.imdPool.tickSpacing}.
            </span>
          )}
        </li>
        <li>
          <span className={`pill ${setup.feedSet ? "pill-ok" : "pill-bad"}`}>{setup.feedSet ? "Set" : "Missing"}</span> Chainlink ETH/USD feed
        </li>
        <li>
          <span className={`pill ${pendingAll.length === 0 ? "pill-ok" : "pill-bad"}`}>
            {routableAll.length - pendingAll.length} of {routableAll.length}
          </span>{" "}
          swarm tokens configured. {routableAll.filter(l => registered.has(l.token.toLowerCase())).length} registered; {routableAll.filter(l => registered.has(l.token.toLowerCase()) && setup.routes[l.token.toLowerCase()]).length} with sale routes.
        </li>
      </ul>
      {!nothing && (
        <div className="actions">
          {(routesMissing > 0 || pendingHeld.length > 0) && (
            <button className="btn btn-primary" onClick={() => void run(pendingHeld)} disabled={disabled || count(pendingHeld) === 0}>
              {running ? "Sending…" : `Set up for this wallet (${count(pendingHeld)} transaction${count(pendingHeld) === 1 ? "" : "s"})`}
            </button>
          )}
          {pendingAll.length > 0 && (
            <button className="btn btn-secondary" onClick={() => void run(pendingAll)} disabled={disabled}>
              Complete setup for {pendingAll.length} launched token{pendingAll.length === 1 ? "" : "s"} ({count(pendingAll)} transaction{count(pendingAll) === 1 ? "" : "s"})
            </button>
          )}
          {!wallet && <span className="hint">The wallet client is not ready.</span>}
        </div>
      )}
      <p className="status-line" role="status" aria-live="polite">
        {running ? `${running.label} (${running.done + 1} of ${running.total}). Confirm it in your wallet…` : note || (nothing ? "Everything is configured." : "")}
        {failedHash && <> <a href={`${EXPLORER_URL}/tx/${failedHash}`} target="_blank" rel="noreferrer">View failed transaction</a></>}
      </p>
    </section>
  );
}
