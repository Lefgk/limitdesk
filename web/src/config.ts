import { http, createConfig } from "wagmi";
import { mainnet, base, foundry } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";
import deploymentsFile from "./deployments.json";

const env = import.meta.env;

export const config = createConfig({
  chains: [base, mainnet, foundry],
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(env.VITE_MAINNET_RPC || undefined),
    [base.id]: http(env.VITE_BASE_RPC || undefined),
    [foundry.id]: http(env.VITE_ANVIL_RPC || "http://127.0.0.1:8545"),
  },
});

const asAddr = (v?: string) => (v && /^0x[0-9a-fA-F]{40}$/.test(v) ? (v as Address) : undefined);

type DeploymentRow = { factory?: string; usdc?: string; weth?: string };
const file = deploymentsFile as Record<string, DeploymentRow>;
const fromFile = (chainId: number): { factory?: Address; usdc?: Address; weth?: Address } => {
  const row = file[String(chainId)] ?? {};
  return { factory: asAddr(row.factory), usdc: asAddr(row.usdc), weth: asAddr(row.weth) };
};

/** Per-chain deployment addresses. Env vars override deployments.json. Empty factory = not deployed yet. */
export const deployments: Record<number, { factory?: Address; usdc?: Address; weth?: Address; live: boolean }> = {
  [mainnet.id]: {
    factory: asAddr(env.VITE_FACTORY_MAINNET) ?? fromFile(mainnet.id).factory,
    usdc: fromFile(mainnet.id).usdc ?? "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    weth: fromFile(mainnet.id).weth ?? "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    live: true,
  },
  [base.id]: {
    factory: asAddr(env.VITE_FACTORY_BASE) ?? fromFile(base.id).factory,
    usdc: fromFile(base.id).usdc ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    weth: fromFile(base.id).weth ?? "0x4200000000000000000000000000000000000006",
    live: true,
  },
  [foundry.id]: {
    factory: asAddr(env.VITE_FACTORY_ANVIL) ?? fromFile(foundry.id).factory,
    usdc: asAddr(env.VITE_USDC_ANVIL) ?? fromFile(foundry.id).usdc,
    weth: asAddr(env.VITE_WETH_ANVIL) ?? fromFile(foundry.id).weth,
    live: false,
  },
};

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
