import { EXPLORER_URL, IMD_SYMBOL } from "../config";
import { fmtAmount, fmtUsd, short } from "../lib/format";
import { STATUS_TEXT, usdValue, type Pricing, type SwarmToken } from "../lib/sweep";

type Props = {
  tokens: SwarmToken[];
  pricing: Pricing | null;
  selected: Set<string>;
  onToggle: (address: string) => void;
  onClaim: (token: SwarmToken) => void;
  claiming: string | null;
  busy: boolean;
  connected: boolean;
  loading: boolean;
};

function StatusCell({ t }: { t: SwarmToken }) {
  if (t.result?.kind === "sold") {
    return (
      <>
        <span className="pill pill-ok">Sold</span>
        <span className="note">
          {fmtAmount(t.result.imdOut)} {IMD_SYMBOL} gross
        </span>
      </>
    );
  }
  if (t.result?.kind === "unsold") {
    return (
      <>
        <span className="pill pill-bad">Unsold</span>
        <span className="note">{t.result.reason}</span>
      </>
    );
  }
  if (t.sellable) return <span className="pill pill-route">{t.routeLabel ?? "Route found"}</span>;
  const launched = t.launch ? `Launch ${t.launch.id}, Uniswap v4 pool. ` : "";
  return (
    <>
      <span className="pill pill-muted">No sell route found</span>
      <span className="note">
        {launched}
        {t.routeLabel ? `${t.routeLabel}: ${STATUS_TEXT[t.status] ?? "not sellable"}` : (STATUS_TEXT[t.status] ?? "Not sellable")}
        {t.status === 1 && t.quoteSource === "pool" ? ", though its pool would buy it" : ""}
        {t.status === 1 && t.quoteSource === null && t.launch ? ", and its pool holds no IMD to buy it with" : ""}
      </span>
    </>
  );
}

export function TokenList({ tokens, pricing, selected, onToggle, onClaim, claiming, busy, connected, loading }: Props) {
  return (
    <div className="list" role="region" aria-labelledby="tokens-heading">
      <h2 id="tokens-heading" className="h3">
        Swarm tokens in this wallet
      </h2>
      <table className="tokens">
        <thead>
          <tr>
            <th className="col-pick">
              <span className="sr-only">Select</span>
            </th>
            <th>Token</th>
            <th className="num">Balance</th>
            <th className="num">Value</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {!connected && (
            <tr className="empty">
              <td colSpan={5}>Connect a wallet to list the swarm-launched tokens it holds.</td>
            </tr>
          )}
          {connected && loading && (
            <tr className="empty">
              <td colSpan={5}>Reading your wallet…</td>
            </tr>
          )}
          {connected && !loading && tokens.length === 0 && (
            <tr className="empty">
              <td colSpan={5}>No swarm-launched tokens in this wallet. Nothing to sell.</td>
            </tr>
          )}
          {tokens.map((t) => {
            const quoted = t.quoteSource !== null;
            const usd = quoted ? usdValue(t.expectedImd, pricing) : null;
            const pickable = t.sellable && !busy && t.result === undefined;
            const id = `pick-${t.address}`;
            return (
              <tr key={t.address} className={t.sellable || t.result ? "" : "dim"} data-result={t.result?.kind ?? ""}>
                <td className="col-pick">
                  {t.sellable && t.result === undefined && (
                    <input
                      id={id}
                      type="checkbox"
                      checked={selected.has(t.address.toLowerCase())}
                      onChange={() => onToggle(t.address)}
                      disabled={!pickable}
                      aria-label={`Select ${t.symbol}`}
                    />
                  )}
                </td>
                <td data-label="Token">
                  <label htmlFor={t.sellable ? id : undefined} className="token-name">
                    {t.symbol}
                  </label>
                  <a className="mono addr" href={`${EXPLORER_URL}/token/${t.address}`} target="_blank" rel="noreferrer">
                    {short(t.address)}
                  </a>
                </td>
                <td className="num" data-label="Balance">
                  {fmtAmount(t.balance, t.decimals)}
                  {t.heldRefund > 0n && (
                    <span className="note">
                      {fmtAmount(t.heldRefund, t.decimals)} held as refund{" "}
                      <button className="btn btn-small" onClick={() => onClaim(t)} disabled={busy || claiming !== null}>
                        {claiming === t.address ? "Claiming…" : "Claim refund"}
                      </button>
                    </span>
                  )}
                </td>
                <td className="num" data-label="Value">
                  {quoted ? (
                    <>
                      <span className="value-usd">{pricing ? fmtUsd(usd) : "USD n/a"}</span>
                      <span className="note">
                        {fmtAmount(t.expectedImd)} {IMD_SYMBOL}
                        {t.quoteSource === "pool" ? " if registered" : ""}
                      </span>
                    </>
                  ) : (
                    <span className="note">No buyer in the pool</span>
                  )}
                </td>
                <td data-label="Status" className="status">
                  <StatusCell t={t} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
