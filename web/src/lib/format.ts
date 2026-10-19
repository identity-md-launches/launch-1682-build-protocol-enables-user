import { formatUnits } from "viem";

const usdFormat = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const numFormat = new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 });
const bigFormat = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });

/** Token amount for display: up to 4 decimals below 10,000, 2 above, plain digits otherwise. */
export function fmtAmount(value: bigint, decimals = 18): string {
  const n = Number(formatUnits(value, decimals));
  if (!Number.isFinite(n)) return formatUnits(value, decimals);
  if (n !== 0 && n < 0.0001) return "<0.0001";
  return n >= 10_000 ? bigFormat.format(n) : numFormat.format(n);
}

export function fmtUsd(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return "–";
  if (value > 0 && value < 0.01) return "<$0.01";
  return usdFormat.format(value);
}

export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** The one-line reason viem or a wallet gives for a failure. */
export function errorText(e: unknown): string {
  if (e && typeof e === "object") {
    // viem wraps the decoded contract error in an execution error. Prefer that reason over
    // a transport's generic short message, without exposing request dumps or stack traces.
    let cause: unknown = e;
    let details: string | undefined;
    for (let depth = 0; depth < 8 && cause && typeof cause === "object"; depth += 1) {
      const o = cause as { data?: { errorName?: string }; reason?: string; details?: string; cause?: unknown };
      if (o.reason) return o.reason.split("\n")[0]!;
      if (o.data?.errorName) return o.data.errorName;
      if (o.details) details = o.details.split("\n")[0];
      cause = o.cause;
    }
    const o = e as { shortMessage?: string; message?: string };
    const message = (o.shortMessage ?? o.message)?.split("\n")[0];
    if (message) return details && !message.includes(details) ? `${message} ${details}` : message;
  }
  return String(e);
}
