# LimitDesk - spec (prototype, 22 Nov 2026)

Source: agents-trading research, idea 2. Sibling: Agent Spend Controls.

**Problem.** Agents should not market-buy everything. CoW and 1inch Fusion need their APIs. Missing a tiny self-custodial book with an owner kill switch.

**Users.** Builders running trading agents who want on-chain-capped limit and stop orders.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).** One desk per owner (EOA or Safe). Owner escrows WETH or USDC. An authorized agent signs EIP-712 limit or stop orders (sell, buy, amount, limit price, stop trigger, expiry, nonce, and the agent epoch so revoke kills old signatures) within a per-token open-sell cap (max 32 open orders). Anyone may post a valid signature (locks escrow) and anyone may fill in one full-fill path: filler pays the buy token and receives the sell token; proceeds stay in the desk. Limit orders fill only if the Chainlink USD oracle is at or better than the limit, at the signed limit. Stops fill if the oracle is at or below the trigger; a stop-limit also requires the oracle stay at or above the limit, otherwise a market stop fills at the oracle. Owner can cancel, revoke, pause posting/filling, and withdraw unlocked escrow. Web dapp: order list, create/cancel/fill, "Not deployed yet". Out: other tokens, partial fills, solvers, fees, native ETH, other chains.

**Choices for Lef.** WETH/USDC only with feeds fixed at factory deploy; no fees; full fills only; proceeds stay in the desk; ERC-1271 signatures; 2h ETH / 25h USDC heartbeats; no audit yet.

**Competitors.** CoW programmatic orders, 1inch Fusion, TeraSwap.

**Edge.** Self-custodial, no external API, owner revoke/cancel, Chainlink-gated fills.
