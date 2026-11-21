import { useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSignTypedData,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { limitDeskAbi, limitDeskFactoryAbi } from "./abi";
import { deployments } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

const ORDER_TYPES = {
  Order: [
    { name: "agent", type: "address" },
    { name: "tokenSell", type: "address" },
    { name: "tokenBuy", type: "address" },
    { name: "amountSell", type: "uint256" },
    { name: "limitPriceX18", type: "uint256" },
    { name: "stopTriggerX18", type: "uint256" },
    { name: "expiry", type: "uint64" },
    { name: "nonce", type: "uint256" },
    { name: "orderType", type: "uint8" },
    { name: "epoch", type: "uint32" },
  ],
} as const;

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [desk, setDesk] = useState<Address | "">("");

  return (
    <div className="wrap">
      <h1>LimitDesk</h1>
      <div className="muted">
        Self-custodial limit and stop orders for AI agents. Owner escrows WETH or USDC; the agent signs EIP-712
        orders within caps; anyone can fill if the Chainlink price and expiry still hold. Prototype — not audited.
        Ethereum, Base and local anvil.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.factory && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the factory address is empty. Core flows stay disabled
            until you deploy (<code>make deploy-mainnet</code> or <code>make deploy-base</code>), which writes the
            address into <code>web/src/deployments.json</code>. You can still paste an existing desk address below after
            connecting.
          </div>
        )}
        {deployments[chainId]?.live && dep.factory && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can afford to lose.
          </div>
        )}
      </div>

      {isConnected && address && (
        <>
          <DeskPicker owner={address} factory={dep.factory} desk={desk} setDesk={setDesk} />
          {desk && isAddress(desk) && <DeskPanel desk={desk} usdc={dep.usdc} weth={dep.weth} account={address} />}
        </>
      )}
    </div>
  );
}

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
}

function DeskPicker(props: {
  owner: Address;
  factory?: Address;
  desk: string;
  setDesk: (v: Address | "") => void;
}) {
  const { owner, factory, desk, setDesk } = props;
  const { data: desks, refetch } = useReadContract({
    address: factory,
    abi: limitDeskFactoryAbi,
    functionName: "desksOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run } = useTx();
  return (
    <div className="card">
      <h2>1. Desk</h2>
      {!factory && (
        <div className="warn">
          <strong>Not deployed yet.</strong> No factory address for this chain. Deploy first (see DEPLOY.md), or set
          VITE_FACTORY_* in web/.env.
        </div>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={async () => {
            if (
              await run("Create desk", () =>
                writeContractAsync({ address: factory!, abi: limitDeskFactoryAbi, functionName: "createDesk" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setDesk(list[list.length - 1]);
            }
          }}
        >
          Create new desk
        </button>
        <label>
          Or use desk address
          <input value={desk} placeholder="0x…" onChange={(e) => setDesk(e.target.value as Address)} />
        </label>
      </div>
      {desks && desks.length > 0 && (
        <div className="row">
          {desks.map((v) => (
            <button key={v} className={v === desk ? "" : "ghost"} onClick={() => setDesk(v)}>
              {short(v)}
            </button>
          ))}
        </div>
      )}
      <div className="muted">{status}</div>
    </div>
  );
}

function DeskPanel({
  desk,
  usdc,
  weth,
  account,
}: {
  desk: Address;
  usdc?: Address;
  weth?: Address;
  account: Address;
}) {
  const { data: owner } = useReadContract({ address: desk, abi: limitDeskAbi, functionName: "owner" });
  const { data: paused, refetch: refetchPaused } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "paused",
  });
  const { data: onchainUsdc } = useReadContract({ address: desk, abi: limitDeskAbi, functionName: "usdc" });
  const { data: onchainWeth } = useReadContract({ address: desk, abi: limitDeskAbi, functionName: "weth" });
  const tokenUsdc = usdc ?? onchainUsdc;
  const tokenWeth = weth ?? onchainWeth;
  const { writeContractAsync, status, run } = useTx();

  const { data: usdcAvail, refetch: refUsdc } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "available",
    args: tokenUsdc ? [tokenUsdc] : undefined,
    query: { enabled: !!tokenUsdc },
  });
  const { data: wethAvail, refetch: refWeth } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "available",
    args: tokenWeth ? [tokenWeth] : undefined,
    query: { enabled: !!tokenWeth },
  });
  const { data: usdcLocked } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "totalLocked",
    args: tokenUsdc ? [tokenUsdc] : undefined,
    query: { enabled: !!tokenUsdc },
  });
  const { data: wethLocked } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "totalLocked",
    args: tokenWeth ? [tokenWeth] : undefined,
    query: { enabled: !!tokenWeth },
  });

  const [depAmt, setDepAmt] = useState("1");
  const [depToken, setDepToken] = useState<"weth" | "usdc">("weth");
  const [agent, setAgent] = useState("");
  const [expiryDays, setExpiryDays] = useState("30");
  const [wethCap, setWethCap] = useState("5");
  const [usdcCap, setUsdcCap] = useState("10000");

  const refresh = () => {
    refUsdc();
    refWeth();
    refetchPaused();
  };

  const tokenAddr = (t: "weth" | "usdc") => (t === "weth" ? tokenWeth : tokenUsdc);
  const decimals = (t: "weth" | "usdc") => (t === "weth" ? 18 : 6);

  return (
    <>
      <div className="card">
        <h2>2. Escrow</h2>
        <div className="muted">
          Desk <code>{desk}</code> · owner <code>{short(owner)}</code> ·{" "}
          {paused ? <span className="bad">PAUSED</span> : <span className="ok">active</span>}
        </div>
        <table>
          <tbody>
            <tr>
              <td>WETH available / locked</td>
              <td>
                {wethAvail !== undefined ? formatUnits(wethAvail, 18) : "…"} /{" "}
                {wethLocked !== undefined ? formatUnits(wethLocked, 18) : "…"}
              </td>
            </tr>
            <tr>
              <td>USDC available / locked</td>
              <td>
                {usdcAvail !== undefined ? formatUnits(usdcAvail, 6) : "…"} /{" "}
                {usdcLocked !== undefined ? formatUnits(usdcLocked, 6) : "…"}
              </td>
            </tr>
          </tbody>
        </table>
        <div className="row">
          <label>
            Token
            <select value={depToken} onChange={(e) => setDepToken(e.target.value as "weth" | "usdc")}>
              <option value="weth">WETH</option>
              <option value="usdc">USDC</option>
            </select>
          </label>
          <label>
            Amount
            <input value={depAmt} onChange={(e) => setDepAmt(e.target.value)} />
          </label>
          <button
            disabled={!tokenAddr(depToken)}
            onClick={async () => {
              const token = tokenAddr(depToken)!;
              const amount = parseUnits(depAmt || "0", decimals(depToken));
              if (
                await run("Approve", () =>
                  writeContractAsync({ address: token, abi: erc20Abi, functionName: "approve", args: [desk, amount] }),
                )
              ) {
                if (
                  await run("Deposit", () =>
                    writeContractAsync({ address: desk, abi: limitDeskAbi, functionName: "deposit", args: [token, amount] }),
                  )
                )
                  refresh();
              }
            }}
          >
            Approve + deposit
          </button>
          <button
            className="ghost"
            disabled={!tokenAddr(depToken) || account.toLowerCase() !== owner?.toLowerCase()}
            onClick={async () => {
              const token = tokenAddr(depToken)!;
              const amount = parseUnits(depAmt || "0", decimals(depToken));
              if (
                await run("Withdraw", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "withdraw",
                    args: [token, account, amount],
                  }),
                )
              )
                refresh();
            }}
          >
            Withdraw
          </button>
        </div>
        <div className="row">
          <button
            className="danger"
            disabled={account.toLowerCase() !== owner?.toLowerCase()}
            onClick={async () => {
              if (await run(paused ? "Unpause" : "Pause", () =>
                writeContractAsync({
                  address: desk,
                  abi: limitDeskAbi,
                  functionName: paused ? "unpause" : "pause",
                }),
              ))
                refresh();
            }}
          >
            {paused ? "Unpause" : "Pause"}
          </button>
        </div>
        <div className="muted">{status}</div>
      </div>

      <div className="card">
        <h2>3. Grant agent</h2>
        <div className="row">
          <label>
            Agent address
            <input value={agent} placeholder="0x…" onChange={(e) => setAgent(e.target.value)} />
          </label>
          <label>
            Expiry (days)
            <input value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)} />
          </label>
          <label>
            WETH open-sell cap
            <input value={wethCap} onChange={(e) => setWethCap(e.target.value)} />
          </label>
          <label>
            USDC open-sell cap
            <input value={usdcCap} onChange={(e) => setUsdcCap(e.target.value)} />
          </label>
        </div>
        <div className="row">
          <button
            disabled={!isAddress(agent) || account.toLowerCase() !== owner?.toLowerCase() || !tokenWeth || !tokenUsdc}
            onClick={async () => {
              const expiry = BigInt(Math.floor(Date.now() / 1000) + Number(expiryDays) * 86400);
              if (
                await run("Grant agent", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "grantAgent",
                    args: [agent as Address, expiry],
                  }),
                )
              ) {
                await run("Set WETH cap", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "setCap",
                    args: [agent as Address, tokenWeth!, parseUnits(wethCap || "0", 18)],
                  }),
                );
                await run("Set USDC cap", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "setCap",
                    args: [agent as Address, tokenUsdc!, parseUnits(usdcCap || "0", 6)],
                  }),
                );
              }
            }}
          >
            Grant + set caps
          </button>
          <button
            className="danger"
            disabled={!isAddress(agent) || account.toLowerCase() !== owner?.toLowerCase()}
            onClick={() =>
              run("Revoke agent", () =>
                writeContractAsync({
                  address: desk,
                  abi: limitDeskAbi,
                  functionName: "revokeAgent",
                  args: [agent as Address],
                }),
              )
            }
          >
            Revoke agent
          </button>
        </div>
        <div className="muted">{status}</div>
      </div>

      {tokenUsdc && tokenWeth && (
        <>
          <PostOrder desk={desk} account={account} usdc={tokenUsdc} weth={tokenWeth} />
          <OrderList desk={desk} account={account} owner={owner} usdc={tokenUsdc} weth={tokenWeth} onChange={refresh} />
        </>
      )}
    </>
  );
}

function PostOrder({ desk, account, usdc, weth }: { desk: Address; account: Address; usdc: Address; weth: Address }) {
  const { writeContractAsync, status, run } = useTx();
  const { signTypedDataAsync } = useSignTypedData();
  const chainId = useChainId();
  const { data: agentInfo } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "agents",
    args: [account],
  });
  const [side, setSide] = useState<"sellWeth" | "sellUsdc">("sellWeth");
  const [kind, setKind] = useState<"limit" | "stop" | "stopLimit">("limit");
  const [amount, setAmount] = useState("1");
  const [limitHuman, setLimitHuman] = useState("3000");
  const [stopHuman, setStopHuman] = useState("2500");
  const [expiryHours, setExpiryHours] = useState("24");
  const [nonce, setNonce] = useState("1");

  const humanToPrice = (human: string, sellWeth: boolean) => {
    const units = parseUnits(human || "0", 6); // USDC per 1 WETH, 6dp
    if (units === 0n) return 0n;
    return sellWeth ? units : 10n ** 36n / units;
  };

  return (
    <div className="card">
      <h2>4. Sign and post an order</h2>
      <div className="muted">
        The connected wallet must be the granted agent. Price is USDC per 1 WETH. A limit sells only at or better than
        that price; a stop fills if the oracle crosses the trigger.
      </div>
      <div className="row">
        <label>
          Pair
          <select value={side} onChange={(e) => setSide(e.target.value as "sellWeth" | "sellUsdc")}>
            <option value="sellWeth">Sell WETH for USDC</option>
            <option value="sellUsdc">Sell USDC for WETH</option>
          </select>
        </label>
        <label>
          Type
          <select value={kind} onChange={(e) => setKind(e.target.value as "limit" | "stop" | "stopLimit")}>
            <option value="limit">Limit</option>
            <option value="stop">Stop (market after trigger)</option>
            <option value="stopLimit">Stop-limit</option>
          </select>
        </label>
        <label>
          Amount ({side === "sellWeth" ? "WETH" : "USDC"})
          <input value={amount} onChange={(e) => setAmount(e.target.value)} />
        </label>
      </div>
      <div className="row">
        {(kind === "limit" || kind === "stopLimit") && (
          <label>
            Limit (USDC per WETH)
            <input value={limitHuman} onChange={(e) => setLimitHuman(e.target.value)} />
          </label>
        )}
        {(kind === "stop" || kind === "stopLimit") && (
          <label>
            Stop trigger (USDC per WETH)
            <input value={stopHuman} onChange={(e) => setStopHuman(e.target.value)} />
          </label>
        )}
        <label>
          Expiry (hours)
          <input value={expiryHours} onChange={(e) => setExpiryHours(e.target.value)} />
        </label>
        <label>
          Nonce
          <input value={nonce} onChange={(e) => setNonce(e.target.value)} />
        </label>
      </div>
      <button
        onClick={async () => {
          const sellWeth = side === "sellWeth";
          const tokenSell = sellWeth ? weth : usdc;
          const tokenBuy = sellWeth ? usdc : weth;
          const amountSell = parseUnits(amount || "0", sellWeth ? 18 : 6);
          const limitPriceX18 = kind === "stop" ? 0n : humanToPrice(limitHuman, sellWeth);
          const stopTriggerX18 = kind === "limit" ? 0n : humanToPrice(stopHuman, sellWeth);
          const expiry = BigInt(Math.floor(Date.now() / 1000) + Number(expiryHours) * 3600);
          const epoch = agentInfo?.[2] ?? 0;
          const order = {
            agent: account,
            tokenSell,
            tokenBuy,
            amountSell,
            limitPriceX18,
            stopTriggerX18,
            expiry,
            nonce: BigInt(nonce || "0"),
            orderType: kind === "limit" ? 0 : 1,
            epoch,
          };
          try {
            const signature = await signTypedDataAsync({
              domain: { name: "LimitDesk", version: "1", chainId, verifyingContract: desk },
              types: ORDER_TYPES,
              primaryType: "Order",
              message: order,
            });
            await run("Post order", () =>
              writeContractAsync({
                address: desk,
                abi: limitDeskAbi,
                functionName: "post",
                args: [order, signature],
              }),
            );
          } catch (e) {
            // run() already formats write errors; signing failures land here
            console.error(e);
          }
        }}
      >
        Sign + post
      </button>
      <div className="muted">{status}</div>
    </div>
  );
}

function OrderList({
  desk,
  account,
  owner,
  usdc,
  weth,
  onChange,
}: {
  desk: Address;
  account: Address;
  owner?: Address;
  usdc: Address;
  weth: Address;
  onChange: () => void;
}) {
  const { writeContractAsync, status, run } = useTx();
  const { data: ids, refetch } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "openOrders",
  });
  const { data: oracleWeth } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "oraclePriceX18",
    args: [weth, usdc],
  });

  return (
    <div className="card">
      <h2>5. Open orders</h2>
      <div className="muted">
        Oracle (USDC per WETH): {oracleWeth !== undefined ? formatUnits(oracleWeth, 6) : "…"}
      </div>
      {!ids?.length && <div className="muted">No open orders.</div>}
      {ids && ids.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Id</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {ids.map((id) => (
              <OrderRow
                key={id}
                id={id}
                desk={desk}
                account={account}
                owner={owner}
                usdc={usdc}
                weth={weth}
                onAct={async (fn, label) => {
                  if (await run(label, fn)) {
                    await refetch();
                    onChange();
                  }
                }}
              />
            ))}
          </tbody>
        </table>
      )}
      <div className="row">
        <button className="ghost" onClick={() => refetch()}>
          Refresh
        </button>
      </div>
      <div className="muted">{status}</div>
    </div>
  );
}

function OrderRow({
  id,
  desk,
  account,
  owner,
  usdc,
  weth,
  onAct,
}: {
  id: `0x${string}`;
  desk: Address;
  account: Address;
  owner?: Address;
  usdc: Address;
  weth: Address;
  onAct: (fn: () => Promise<`0x${string}`>, label: string) => void;
}) {
  const { writeContractAsync } = useWriteContract();
  const { data } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "getOrder",
    args: [id],
  });
  const { data: quote } = useReadContract({
    address: desk,
    abi: limitDeskAbi,
    functionName: "quoteFill",
    args: [id],
  });
  if (!data) return <tr><td colSpan={2}>…</td></tr>;
  const o = data.order;
  const sellWeth = o.tokenSell.toLowerCase() === weth.toLowerCase();
  const amt = formatUnits(o.amountSell, sellWeth ? 18 : 6);
  const humanPx = (px: bigint) => {
    if (px === 0n) return "—";
    return sellWeth ? formatUnits(px, 6) : formatUnits(10n ** 36n / px, 6);
  };
  const canCancel = account.toLowerCase() === owner?.toLowerCase() || account.toLowerCase() === o.agent.toLowerCase();
  return (
    <tr>
      <td>
        <code>{short(id)}</code>
        <div className="muted">
          {o.orderType === 0 ? "Limit" : "Stop"} · sell {amt} {sellWeth ? "WETH" : "USDC"} · limit {humanPx(o.limitPriceX18)}
          {o.stopTriggerX18 > 0n ? ` · stop ${humanPx(o.stopTriggerX18)}` : ""} · agent {short(o.agent)}
          {quote?.[0] ? <span className="ok"> · fillable</span> : <span> · not fillable</span>}
        </div>
      </td>
      <td>
        <button
          disabled={!quote?.[0]}
          onClick={async () => {
            const tokenBuy = sellWeth ? usdc : weth;
            const amountBuy = quote?.[1] ?? 0n;
            const ok = await (async () => {
              try {
                await writeContractAsync({
                  address: tokenBuy,
                  abi: erc20Abi,
                  functionName: "approve",
                  args: [desk, amountBuy],
                });
                return true;
              } catch {
                return false;
              }
            })();
            if (!ok) return;
            onAct(
              () => writeContractAsync({ address: desk, abi: limitDeskAbi, functionName: "fill", args: [id] }),
              "Fill",
            );
          }}
        >
          Fill
        </button>{" "}
        <button
          className="ghost"
          disabled={!canCancel}
          onClick={() =>
            onAct(
              () => writeContractAsync({ address: desk, abi: limitDeskAbi, functionName: "cancel", args: [id] }),
              "Cancel",
            )
          }
        >
          Cancel
        </button>
      </td>
    </tr>
  );
}
