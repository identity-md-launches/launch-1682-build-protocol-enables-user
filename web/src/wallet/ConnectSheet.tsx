import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain, type Connector } from "wagmi";
import { chain, WALLET_ADD_CHAIN } from "../chain";
import { WALLET_ICONS } from "./wallet-icons";
import { OPEN_IN, isMobileBrowser } from "./open-in";

export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

const svgUrl = (svg: string) => `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;

/** The connect control and its sheet: the site's own type and colors, the network's structure. */
export function ConnectSheet({ open: forced, mobile: forcedMobile }: { open?: boolean; mobile?: boolean }) {
  const mobile = forcedMobile ?? isMobileBrowser();
  const { address, isConnected, connector: active } = useAccount();
  const chainId = useChainId();
  const { connectors, connect, isPending, variables, error, reset } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(forced ?? false);
  const titleId = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const sheet = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    addEventListener("keydown", onKey);
    document.getElementById("page")?.setAttribute("inert", "");
    sheet.current?.querySelector<HTMLElement>("button, a")?.focus();
    return () => {
      removeEventListener("keydown", onKey);
      document.getElementById("page")?.removeAttribute("inert");
      trigger.current?.focus();
    };
  }, [open]);
  useEffect(() => {
    if (isConnected) setOpen(false);
  }, [isConnected]);

  // EIP-6963 names each installed extension; wagmi's generic injected row is only for a browser
  // where discovery found nothing, and then it is called what it is. Extensions first, then Coinbase.
  const named = connectors.some((c) => c.type === "injected" && c.id !== "injected");
  const listed = [...connectors.filter((c) => c.type === "injected"), ...connectors.filter((c) => c.type !== "injected")].filter(
    (c) => !(c.id === "injected" && named),
  );
  const label = (c: Connector) =>
    c.id === "injected" ? "Browser wallet" : c.id === "coinbaseWalletSDK" && mobile ? "Coinbase Smart Wallet" : c.name;
  const icon = (c: Connector) => c.icon ?? (WALLET_ICONS[c.id] ? svgUrl(WALLET_ICONS[c.id]!) : undefined);

  const onSwitch = async () => {
    try {
      switchChain({ chainId: chain.id });
    } catch {
      /* fall through to addEthereumChain below */
    }
    const provider = (await active?.getProvider?.()) as { request?: (a: { method: string; params: unknown[] }) => Promise<unknown> } | undefined;
    if (provider?.request) {
      try {
        await provider.request({ method: "wallet_addEthereumChain", params: [WALLET_ADD_CHAIN] });
      } catch {
        /* the wallet declined; the control keeps offering the switch */
      }
    }
  };

  if (isConnected && address) {
    const wrong = chainId !== chain.id;
    return (
      <div className="wallet-state">
        {wrong && (
          <button className="btn btn-primary" onClick={onSwitch} disabled={switching}>
            {switching ? "Switching…" : `Switch to ${chain.name}`}
          </button>
        )}
        <button className="btn btn-secondary" onClick={() => disconnect()} aria-label={`Connected as ${short(address)}. Disconnect`}>
          <span className="mono">{short(address)}</span>
          <span aria-hidden="true"> · </span>Disconnect
        </button>
      </div>
    );
  }

  return (
    <>
      <button ref={trigger} className="btn btn-primary" onClick={() => setOpen(true)}>
        Connect wallet
      </button>
      {open &&
        createPortal(
        <div
          className="sheet-bg"
          onClick={() => {
            reset();
            setOpen(false);
          }}
        >
          <div className="sheet" role="dialog" aria-modal="true" aria-labelledby={titleId} ref={sheet} onClick={(e) => e.stopPropagation()}>
            <div className="sheet-head">
              <h2 id={titleId}>Connect a wallet</h2>
              <button className="x" aria-label="Close" onClick={() => setOpen(false)}>
                ×
              </button>
            </div>
            {mobile &&
              OPEN_IN.map((w) => (
                <a key={w.id} className="row-link" href={w.href(location.href)}>
                  <span className="ic">
                    {WALLET_ICONS[w.id] ? <img width={28} height={28} src={svgUrl(WALLET_ICONS[w.id]!)} alt="" /> : w.name[0]}
                  </span>
                  <span>Open in {w.name}</span>
                </a>
              ))}
            {listed
              .filter((c) => !mobile || c.type !== "injected")
              .map((c) => (
                <button key={c.uid} className="row-link" onClick={() => connect({ connector: c })} disabled={isPending}>
                  <span className="ic">{icon(c) ? <img width={28} height={28} src={icon(c)} alt="" /> : label(c)[0]}</span>
                  <span>
                    {label(c)}
                    {isPending && variables?.connector === c ? " · opening…" : ""}
                  </span>
                </button>
              ))}
            <p className="sheet-note" role="status">
              {error ? "The wallet declined the connection. Choose a wallet to try again." : ""}
            </p>
          </div>
        </div>,
          document.body,
        )}
    </>
  );
}
