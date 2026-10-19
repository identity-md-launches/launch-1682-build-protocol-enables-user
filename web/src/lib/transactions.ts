import type { Address, Hash, PublicClient, WalletClient } from "viem";
import { chain } from "../chain.ts";

/** Check the live provider again after asynchronous reads or another wallet prompt. */
export async function assertWalletContext(wallet: WalletClient, account: Address): Promise<void> {
  const [chainId, accounts] = await Promise.all([wallet.getChainId(), wallet.getAddresses()]);
  if (chainId !== chain.id) throw new Error(`Switch your wallet to ${chain.name}, then refresh to try again.`);
  if (accounts[0]?.toLowerCase() !== account.toLowerCase()) throw new Error("The wallet account changed. Refresh before trying again.");
}

export class TransactionRevertedError extends Error {
  readonly hash: Hash;
  constructor(label: string, hash: Hash) {
    super(`${label} transaction reverted. Refresh to check the current state before retrying.`);
    this.hash = hash;
  }
}

export function transactionHash(error: unknown): Hash | null {
  if (error && typeof error === "object" && "hash" in error && typeof error.hash === "string" && /^0x[0-9a-f]{64}$/i.test(error.hash)) return error.hash as Hash;
  return null;
}

export async function confirmedReceipt(client: PublicClient, hash: Hash, label: string) {
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new TransactionRevertedError(label, hash);
  return receipt;
}
