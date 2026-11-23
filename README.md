# LimitDesk

A tiny self-custodial limit and stop order book for AI agents on Ethereum. The owner escrows WETH or USDC into a personal desk. An authorized agent signs EIP-712 orders within owner caps. Anyone can fill if the Chainlink oracle condition and expiry still hold; the owner can cancel, revoke the agent and withdraw.

> Prototype, **not audited**. It targets **Ethereum mainnet (1)** and **Base (8453)**, plus local anvil (31337) for development. The deploy scripts refuse any other chain and **refuse to broadcast on 1/8453 unless `CONFIRM_MAINNET=yes`**. Nothing has been deployed.

See [SPEC.md](SPEC.md) for the problem, competitors and choices, and [DEPLOY.md](DEPLOY.md) for the full deploy runbook.

## Layout
| Path | What |
|---|---|
| `src/LimitDesk.sol` | Per-owner desk: escrow, agent caps, EIP-712 post, one full-fill path, cancel, revoke |
| `src/LimitDeskFactory.sol` | Deploys one desk per owner and indexes them (`desksOf`) |
| `src/MockUSDC.sol`, `src/MockWETH.sol`, `src/MockAggregator.sol` | Local/test mocks. Never deploy to mainnet |
| `test/` | Unit, fuzz and invariant tests (Foundry) |
| `test/fork/` | Fork tests against real USDC, WETH and Chainlink feeds, plus a fork test of `Deploy.s.sol` |
| `script/Deploy.s.sol`, `script/DeployConfig.sol` | Deploy script and per-chain config (USDC, WETH, feeds) |
| `script/deploy.sh`, `script/verify.sh`, `script/deploy-anvil.sh` | Dry-run/broadcast wrapper, Etherscan v2 verify, local deploy |
| `script/dry-run-fork.sh`, `script/write-web-config.sh` | Anvil-fork dry run (port 8625) and dapp-config writer |
| `web/` | Vite + React + wagmi/viem dapp (Ethereum, Base and anvil) |
| `web/src/deployments.json` | Per-chain factory/USDC/WETH addresses written by a successful deploy |
| `docs/slither-report.txt` | Static-analysis output (if slither was run) |
| `Makefile` | One-command test, dapp build, dry-run and deploy targets |

## Contract model
- `grantAgent(agent, expiry)` and `setCap(agent, token, maxOpenSell)` are owner only. Only WETH and USDC are supported.
- `post(order, signature)` verifies the EIP-712 signature (EOA or ERC-1271), checks caps (open + filled in the last 24h) and escrow, locks `amountSell` and lists the order. Anyone may post.
- `fill(orderId)` is the only fill path (full fill). A limit fills if the Chainlink price is at or better than `limitPriceX18`, at max(limit, oracle × (1 − `fillDiscountBps`)); the discount defaults to 1% and the owner can set 0–10%. A stop fills if the price is at or below `stopTriggerX18`; with a limit it also has to stay at or above that limit and the same bounded price applies, otherwise it fills at the oracle. Each agent cap covers open plus filled sell volume per token over a rolling 24h window. On Base, fills refuse prices while the Chainlink sequencer feed reports downtime or within 1h of a restart. The filler pays `tokenBuy` and receives `tokenSell`; proceeds stay in the desk.
- `cancel(orderId)` is owner or the agent. `revokeAgent(agent)` cancels that agent's open orders and bumps its epoch, so old signatures cannot be posted.
- `pause()` blocks post and fill. `withdraw()` is owner only and works while paused (unlocked balance only).
- Ownership uses `Ownable2Step`, so a Safe can be the owner.

Price (`limitPriceX18`, `stopTriggerX18`, oracle) is **tokenBuy native units per 1e18 tokenSell**. Selling 1 WETH for 3,000 USDC is `3000e6`.

## Run the dapp

```bash
cd web
npm install
# optional: cp .env.example .env   # only to override RPCs or factory addresses
npm run dev      # http://localhost:5173
npm run build    # production build
```

The dapp is Vite + React + wagmi/viem, on Ethereum mainnet and Base (and local anvil). Contract addresses come from `web/src/deployments.json`, with optional `VITE_FACTORY_*` / `VITE_USDC_*` / `VITE_WETH_*` overrides in `web/.env`. When the factory address for the selected chain is empty, the page shows a clear **Not deployed yet** state and disables create-desk.

Connect a wallet, switch network, then: create or pick a desk, deposit WETH or USDC, grant an agent and caps, sign and post a limit or stop, inspect open orders, fill or cancel, revoke the agent, or withdraw.

## Tests

Needs Foundry (`forge` / `anvil`; this repo expects `~/.foundry/bin` on `PATH`) and Node 20+.

```bash
forge build
forge test              # unit, fuzz, invariant, and anvil deploy-script tests; fork tests skip without a fork
make dry-run-mainnet    # Deploy.s.sol dry-run + CONFIRM_MAINNET guard, on an anvil mainnet fork at port 8625
```

Fork tests (real Circle USDC, canonical WETH, Chainlink ETH/USD and USDC/USD, plus the deploy-script fork tests):

```bash
anvil --port 8625 --fork-url https://ethereum-rpc.publicnode.com   # Ethereum fork
make test-fork-mainnet
# Base, using Foundry's own fork (no extra anvil):
make test-fork-base
```

## Deploy to Ethereum or Base (not done: needs Lef's wallet and OK)

| Chain | Id | USDC | WETH |
|---|---|---|---|
| Ethereum mainnet | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x4200000000000000000000000000000000000006` |

Once the wallet is set (Foundry keystore account, keystore file, or `DEPLOYER_KEY` in a git-ignored `.env`):

```bash
cp .env.example .env && set -a && source .env && set +a
make dry-run-mainnet                 # local anvil fork on port 8625; sends nothing
CONFIRM_MAINNET=yes make deploy-mainnet
CONFIRM_MAINNET=yes make deploy-base
```

A successful broadcast writes the factory, USDC and WETH addresses into `web/src/deployments.json` and, if `ETHERSCAN_API_KEY` is set, verifies via the Etherscan v2 API. See [DEPLOY.md](DEPLOY.md) for signer options and `./script/verify.sh`.

- `deploy.sh` and `Deploy.s.sol` both print the chain. Each refuses to broadcast on 1 or 8453 without `CONFIRM_MAINNET=yes`, so the guard holds even if someone calls `forge script` directly.
- Never commit `.env`, keys, or `broadcast/`.

## Local end-to-end (anvil, no keys)

```bash
anvil                                   # terminal 1 (chain 31337)
./script/deploy-anvil.sh                # factory + mocks, writes web/src/deployments.json
cd web && npm install && npm run dev
```

The anvil deploy uses anvil's unlocked dev accounts, so no private key is stored anywhere. If port 8545 is busy, run `anvil --port 8625` and set `ANVIL_RPC=http://127.0.0.1:8625` (and `VITE_ANVIL_RPC` for the web app).

## Regenerate ABIs
`forge build && node tools/gen-abi.mjs` writes `web/src/abi.ts`.

## Contact

Support and questions: [lg.playstudio@gmail.com](mailto:lg.playstudio@gmail.com)
