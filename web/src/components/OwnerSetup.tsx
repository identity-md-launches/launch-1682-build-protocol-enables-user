import { useState } from "react";
import type { Address, PublicClient, WalletClient } from "viem";
import { errorText } from "../lib/format";
import type { Launch } from "../lib/launches";
import { routable, setupSteps, type OwnerStep } from "../lib/owner";
import type { WalletState } from "../lib/sweep";

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
  const { setup, launches, tokens } = state;
  const registered = new Set(setup.registered.map((a) => a.toLowerCase()));
  const unregisteredAll = launches.filter((l) => routable(l) && !registered.has(l.token.toLowerCase()));
  const unregisteredHeld = unregisteredAll.filter((l) => tokens.some((t) => same(t.address, l.token) && t.balance > 0n));
  const routesMissing = (!setup.imdRouteSet ? 1 : 0) + (!setup.feedSet ? 1 : 0);

  const run = async (register: Launch[]) => {
    if (!wallet || !client) return;
    const steps: OwnerStep[] = setupSteps(wallet, client, account, { imdPool: setup.imdPool, imdRouteSet: setup.imdRouteSet, feedSet: setup.feedSet, register });
    if (steps.length === 0) return;
    setNote("");
    for (let i = 0; i < steps.length; i += 1) {
      const step = steps[i]!;
      setRunning({ done: i, total: steps.length, label: step.label });
      try {
        await step.run();
      } catch (e) {
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

  const nothing = routesMissing === 0 && unregisteredAll.length === 0;
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
          <span className={`pill ${unregisteredAll.length === 0 ? "pill-ok" : "pill-bad"}`}>
            {launches.filter(routable).length - unregisteredAll.length} of {launches.filter(routable).length}
          </span>{" "}
          swarm tokens registered with their launch pool as the route
        </li>
      </ul>
      {!nothing && (
        <div className="actions">
          {(routesMissing > 0 || unregisteredHeld.length > 0) && (
            <button className="btn btn-primary" onClick={() => void run(unregisteredHeld)} disabled={disabled}>
              {running ? "Sending…" : `Set up for this wallet (${routesMissing + unregisteredHeld.length * 2} transactions)`}
            </button>
          )}
          {unregisteredAll.length > 0 && (
            <button className="btn btn-secondary" onClick={() => void run(unregisteredAll)} disabled={disabled}>
              Register all {unregisteredAll.length} launched tokens ({routesMissing + unregisteredAll.length * 2} transactions)
            </button>
          )}
          {!wallet && <span className="hint">The wallet client is not ready.</span>}
        </div>
      )}
      <p className="status-line" role="status" aria-live="polite">
        {running ? `${running.label} (${running.done + 1} of ${running.total}). Confirm it in your wallet…` : note || (nothing ? "Everything is configured." : "")}
      </p>
    </section>
  );
}
