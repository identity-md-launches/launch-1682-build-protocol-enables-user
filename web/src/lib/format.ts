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
    const o = e as { shortMessage?: string; message?: string };
    if (o.shortMessage) return o.shortMessage;
    if (o.message) return o.message.split("\n")[0]!;
  }
  return String(e);
}
