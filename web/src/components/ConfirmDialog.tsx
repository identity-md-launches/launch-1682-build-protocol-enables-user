import { useEffect, useId, useRef } from "react";
import { createPortal } from "react-dom";
import { EXPLORER_URL, IMD_SYMBOL, TREASURY_ADDRESS } from "../config";
import { fmtAmount, fmtUsd, short } from "../lib/format";
import { usdValue, type Plan, type Pricing, type Progress } from "../lib/sweep";
import type { Hash } from "viem";

type Props = {
  plan: Plan;
  pricing: Pricing | null;
  progress: Progress | null;
  error: string | null;
  hash: Hash | null;
  canSell: boolean;
  onConfirm: () => void;
  onRefresh: () => void;
  onClose: () => void;
};

function progressText(p: Progress): string {
  if (p.step === "check") return "Checking the approved sale against your confirmed minimums…";
  if (p.step === "approve") return `Approve ${p.token.symbol} in your wallet (${p.index} of ${p.total})…`;
  if (p.step === "sign") return p.batches > 1 ? `Confirm sale ${p.batch} of ${p.batches} in your wallet…` : "Confirm the sale in your wallet…";
  return p.batches > 1 ? `Waiting for sale ${p.batch} of ${p.batches} to confirm…` : "Waiting for the transaction to confirm…";
}

export function ConfirmDialog({ plan, pricing, progress, error, hash, canSell, onConfirm, onRefresh, onClose }: Props) {
  const titleId = useId();
  const box = useRef<HTMLDivElement>(null);
  const running = progress !== null && error === null;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !running) onClose();
    };
    addEventListener("keydown", onKey);
    document.getElementById("page")?.setAttribute("inert", "");
    box.current?.querySelector<HTMLElement>("button")?.focus();
    return () => {
      removeEventListener("keydown", onKey);
      document.getElementById("page")?.removeAttribute("inert");
    };
  }, [running, onClose]);

  const n = plan.items.length;
  const estimated = plan.items.some(i => i.estimated);
  return createPortal(
    <div className="sheet-bg" onClick={() => !running && onClose()}>
      <div className="sheet sheet-wide" role="dialog" aria-modal="true" aria-labelledby={titleId} ref={box} onClick={(e) => e.stopPropagation()}>
        <div className="sheet-head">
          <h2 id={titleId}>{n === 1 ? "Sell 1 token for IMD?" : `Sell ${n} tokens for IMD?`}</h2>
          <button className="x" aria-label="Close" onClick={onClose} disabled={running}>
            ×
          </button>
        </div>

        {n > 0 ? (
          <table className="plan">
            <thead>
              <tr>
                <th>Token</th>
                <th className="num">Amount</th>
                <th className="num">{IMD_SYMBOL}</th>
              </tr>
            </thead>
            <tbody>
              {plan.items.map(({ token, imdOut, approvalRequired, estimated }) => (
                <tr key={token.address}>
                  <td>{token.symbol}{approvalRequired && <span className="note">Approval required</span>}{estimated && <span className="note">Estimated proceeds</span>}</td>
                  <td className="num">{fmtAmount(token.balance, token.decimals)}</td>
                  <td className="num">{fmtAmount(imdOut)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="plan-note">None of the selected tokens can be sold right now. Each one is listed below with the reason.</p>
        )}

        {plan.excluded.length > 0 && (
          <div className="excluded">
            <p className="plan-note">Left out of this sale:</p>
            <ul>
              {plan.excluded.map(({ token, reason }) => (
                <li key={token.address}>
                  <span className="token-name">{token.symbol}</span> <span className="note">{reason}</span>
                </li>
              ))}
            </ul>
          </div>
        )}

        {n > 0 && (
          <dl className="totals">
            <div>
              <dt>{estimated ? "Estimated gross proceeds" : "Gross proceeds"}</dt>
              <dd>
                {fmtAmount(plan.gross)} {IMD_SYMBOL}
              </dd>
            </div>
            <div>
              <dt>
                Fee 2%, to treasury{" "}
                <a className="mono" href={`${EXPLORER_URL}/address/${TREASURY_ADDRESS}`} target="_blank" rel="noreferrer">
                  {short(TREASURY_ADDRESS)}
                </a>
              </dt>
              <dd>
                −{fmtAmount(plan.fee)} {IMD_SYMBOL}
              </dd>
            </div>
            <div className="total">
              <dt>{estimated ? "You receive (estimated)" : "You receive"}</dt>
              <dd>
                {fmtAmount(plan.net)} {IMD_SYMBOL}
                {pricing && <span className="note">{fmtUsd(usdValue(plan.net, pricing))}</span>}
              </dd>
            </div>
          </dl>
        )}

        <p className="plan-note">
          {estimated && "Tokens needing approval use current pool estimates. "}
          Your wallet asks for any missing approvals, then the sale. You pay the gas. Each token’s minimum is 3% below its displayed gross IMD amount.
          We check the approved batch before asking you to sign its sale. Failed sales return your tokens. If a token blocks the refund, it stays claimable here.
        </p>

        <p className="status-line" role="status" aria-live="polite">
          {!canSell ? "Switch to Ethereum with the wallet that prepared this sale to continue." : error ? error : progress ? progressText(progress) : ""}
          {hash && <> <a href={`${EXPLORER_URL}/tx/${hash}`} target="_blank" rel="noreferrer">View transaction</a></>}
        </p>

        <div className="sheet-actions">
          <button className="btn btn-secondary" onClick={onClose} disabled={running}>
            Cancel
          </button>
          <button className="btn btn-primary" onClick={error || n === 0 ? onRefresh : onConfirm} disabled={running || !canSell}>
            {running ? "Selling…" : error || n === 0 ? "Refresh quotes" : n === 1 ? "Sell 1 token" : `Sell ${n} tokens`}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
