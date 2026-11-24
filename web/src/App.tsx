import { useState } from "react";
import { useAccount, useChainId, useReadContract, useSignTypedData, useWriteContract } from "wagmi";
import { erc20Abi, formatUnits, isAddress, parseUnits, type Address } from "viem";
import { limitDeskAbi, limitDeskFactoryAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";


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
  const dep = deployments[chainId] ?? {};
  const [desk, setDesk] = useState<Address | "">("");

  return (
    <Shell
      title="LimitDesk"
      tagline="Limit and stop orders for AI agents, without handing over custody. You escrow WETH or USDC in your own desk contract; your agent can only sign WETH/USDC orders within caps you set; anyone can fill an order, but only if the Chainlink price still satisfies it."
      steps={[
        "Create a desk you own and deposit WETH or USDC.",
        "Grant an agent key with an expiry and a cap per token.",
        "The agent signs and posts limit or stop orders (the order amount is locked).",
        "Anyone fills when the oracle price allows. You can pause, revoke or withdraw.",
      ]}
      contractLabel="Desk factory"
      contractOf={(id) => deployments[id]?.factory}
      refs={[
        { label: "USDC", address: dep.usdc },
        { label: "WETH", address: dep.weth },
      ]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. Escrowed tokens can be sold by the agent you grant,
          up to its caps, at prices checked against a Chainlink oracle. Only deposit amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a desk or manage one you already own.</Empty>}

      {isConnected && address && (
        <>
          <DeskPicker owner={address} factory={dep.factory} desk={desk} setDesk={setDesk} />
          {desk && isAddress(desk) && <DeskPanel desk={desk} usdc={dep.usdc} weth={dep.weth} account={address} />}
        </>
      )}
    </Shell>
  );
}

function DeskPicker(props: {
  owner: Address;
  factory?: Address;
  desk: string;
  setDesk: (v: Address | "") => void;
}) {
  const { owner, factory, desk, setDesk } = props;
  const { data: desks, refetch, isLoading } = useReadContract({
    address: factory,
    abi: limitDeskFactoryAbi,
    functionName: "desksOf",
    args: [owner],
    query: { enabled: !!factory },
  });
  const { writeContractAsync, status, run, safe } = useTx();
  return (
    <div className="card">
      <h2>1. Choose a desk</h2>
      <p className="muted">A desk is your own contract. It holds the escrow and enforces the agent caps.</p>
      <div className="field-label">Your desks on this network</div>
      {!factory ? (
        <Empty>No factory on this network, so desks cannot be listed or created here.</Empty>
      ) : isLoading ? (
        <Loading>Looking up your desks…</Loading>
      ) : desks && desks.length > 0 ? (
        <div className="row">
          {desks.map((v) => (
            <button key={v} className={v === desk ? "seg seg-on" : "seg"} aria-pressed={v === desk} onClick={() => setDesk(v)}>
              <code>{short(v)}</code>
              <span className="seg-sub">{v === desk ? "selected" : "select"}</span>
            </button>
          ))}
        </div>
      ) : (
        <Empty>This wallet has no desks yet. Create one below, or paste the address of a desk you want to inspect.</Empty>
      )}
      <div className="row">
        <button
          disabled={!factory}
          onClick={safe(async () => {
            if (
              await run("Create desk", () =>
                writeContractAsync({ address: factory!, abi: limitDeskFactoryAbi, functionName: "createDesk" }),
              )
            ) {
              const r = await refetch();
              const list = r.data ?? [];
              if (list.length) setDesk(list[list.length - 1]);
            }
          })}
        >
          Create new desk
        </button>
        <label>
          Or open a desk by address
          <input value={desk} placeholder="0x…" spellCheck={false} onChange={(e) => setDesk(e.target.value.trim() as Address)} />
        </label>
      </div>
      {desk && !isAddress(desk) && <div className="bad muted">That is not a valid address (0x followed by 40 hex characters).</div>}
      <Hint>
        “Create new desk” deploys a desk contract owned by your connected wallet. One transaction, gas only — no funds
        move.
      </Hint>
      {status}
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
  const { writeContractAsync, status, run, safe } = useTx();
  const grant = useTx();
  const isOwner = account.toLowerCase() === owner?.toLowerCase();

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
        <h2>2. Escrow (owner)</h2>
        <dl className="dl">
          <dt>Desk</dt>
          <dd>
            <Addr value={desk} full />
          </dd>
          <dt>Owner</dt>
          <dd>
            <Addr value={owner} /> {isOwner && <span className="ok">(you)</span>}
          </dd>
          <dt>Orders</dt>
          <dd>{paused === undefined ? "…" : paused ? <span className="bad">Paused</span> : <span className="ok">Active</span>}</dd>
        </dl>
        {owner && !isOwner && (
          <div className="info">
            You are not the owner of this desk. You can read it, deposit into it and fill orders, but withdrawing,
            pausing and agent settings are disabled.
          </div>
        )}
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
            <input value={depAmt} inputMode="decimal" onChange={(e) => setDepAmt(e.target.value)} />
          </label>
          <button
            disabled={!tokenAddr(depToken)}
            onClick={safe(async () => {
              const token = tokenAddr(depToken)!;
              const amount = parseUnits(depAmt || "0", decimals(depToken));
              if (
                await run(`Approve ${depToken.toUpperCase()}`, () =>
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
            })}
          >
            Approve + deposit
          </button>
          <button
            className="ghost"
            disabled={!tokenAddr(depToken) || !isOwner}
            onClick={safe(async () => {
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
            })}
          >
            Withdraw
          </button>
        </div>
        <Hint>
          Deposit asks twice: an approval for exactly this amount, then the deposit, which moves the tokens from your
          wallet into the desk. Withdraw sends available (not locked in an open order) tokens back to your connected
          wallet.
        </Hint>
        <div className="row">
          <button
            className={paused ? "" : "danger"}
            disabled={!isOwner}
            onClick={safe(async () => {
              if (await run(paused ? "Unpause" : "Pause", () =>
                writeContractAsync({
                  address: desk,
                  abi: limitDeskAbi,
                  functionName: paused ? "unpause" : "pause",
                }),
              ))
                refresh();
            })}
          >
            {paused ? "Unpause" : "Pause desk"}
          </button>
        </div>
        <Hint tone="danger">
          Pause stops new orders and fills on this desk until you unpause. Your escrow stays in the desk and you can
          still withdraw.
        </Hint>
        {status}
      </div>

      <div className="card">
        <h2>3. Agent key (owner)</h2>
        <p className="muted">
          The agent can only sign WETH/USDC orders from this desk. It can never withdraw. Caps limit how much of each
          token it may have on sale at once.
        </p>
        <div className="row">
          <label>
            Agent address
            <input value={agent} placeholder="0x…" spellCheck={false} onChange={(e) => setAgent(e.target.value.trim())} />
          </label>
          <label>
            Expiry (days)
            <input value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)} />
          </label>
          <label>
            WETH cap (max on sale)
            <input value={wethCap} onChange={(e) => setWethCap(e.target.value)} />
          </label>
          <label>
            USDC cap (max on sale)
            <input value={usdcCap} onChange={(e) => setUsdcCap(e.target.value)} />
          </label>
        </div>
        <div className="row">
          <button
            disabled={!isAddress(agent) || !isOwner || !tokenWeth || !tokenUsdc}
            onClick={safe(async () => {
              const d = Number(expiryDays);
              if (!Number.isFinite(d) || d <= 0) return grant.fail("Expiry must be a number of days greater than 0.");
              const expiry = BigInt(Math.floor(Date.now() / 1000 + d * 86400));
              const capWeth = parseUnits(wethCap || "0", 18);
              const capUsdc = parseUnits(usdcCap || "0", 6);
              if (
                await grant.run("Grant agent", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "grantAgent",
                    args: [agent as Address, expiry],
                  }),
                )
              ) {
                await grant.run("Set WETH cap", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "setCap",
                    args: [agent as Address, tokenWeth!, capWeth],
                  }),
                );
                await grant.run("Set USDC cap", () =>
                  writeContractAsync({
                    address: desk,
                    abi: limitDeskAbi,
                    functionName: "setCap",
                    args: [agent as Address, tokenUsdc!, capUsdc],
                  }),
                );
              }
            })}
          >
            Grant + set caps
          </button>
          <button
            className="danger"
            disabled={!isAddress(agent) || !isOwner}
            onClick={() =>
              grant.run("Revoke agent", () =>
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
        <Hint>
          “Grant + set caps” is three transactions in a row: grant the key until the expiry, then set the WETH cap,
          then the USDC cap. No funds move. Revoke removes the key at once and invalidates its signed orders.
        </Hint>
        {grant.status}
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
  const { writeContractAsync, status, run, safe, fail } = useTx();
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
  const [nonce, setNonce] = useState(() => String(Date.now()));

  const humanToPrice = (human: string, sellWeth: boolean) => {
    const units = parseUnits(human || "0", 6); // USDC per 1 WETH, 6dp
    if (units === 0n) return 0n;
    return sellWeth ? units : 10n ** 36n / units;
  };

  return (
    <div className="card">
      <h2>4. Sign and post an order (agent)</h2>
      <p className="muted">
        The connected wallet must be the granted agent. Prices are USDC per 1 WETH. A limit sells only at that price
        or better; a stop becomes fillable once the oracle crosses the trigger.
      </p>
      {agentInfo && !agentInfo[0] && (
        <div className="info">
          The connected wallet ({short(account)}) is not an active agent on this desk, so posting will be rejected.
        </div>
      )}
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
        onClick={safe(async () => {
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
          if (amountSell === 0n) return fail("Amount must be greater than 0.");
          if (kind !== "stop" && limitPriceX18 === 0n) return fail("Limit price must be greater than 0.");
          if (kind !== "limit" && stopTriggerX18 === 0n) return fail("Stop trigger must be greater than 0.");
          // A rejected or failed signature is caught by safe() and shown below; nothing is sent.
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
        })}
      >
        Sign + post
      </button>
      <Hint>
        Two wallet prompts: first a free signature of the order (your wallet shows every field), then a transaction
        that posts it on the desk and locks the sell amount from the owner's escrow. Once posted, anyone can fill it
        when the oracle price allows, until it expires or is cancelled.
      </Hint>
      {status}
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
  const { writeContractAsync, status, run, safe } = useTx();
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
      <p className="muted">
        Chainlink oracle price: {oracleWeth !== undefined ? `${formatUnits(oracleWeth, 6)} USDC per WETH` : "…"}
      </p>
      {ids === undefined ? <Loading /> : ids.length === 0 ? <Empty>No open orders on this desk.</Empty> : null}
      {ids && ids.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Order</th>
              <th>Actions</th>
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
                  const ok = await run(label, fn);
                  if (ok) {
                    await refetch();
                    onChange();
                  }
                  return ok;
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
      <Hint>
        Fill is open to anyone: you pay the quoted buy amount from your wallet (approval, then fill) and receive the
        order's sell amount from the desk. It is rejected unless the oracle price satisfies the order. Cancel is for
        the desk owner or the order's agent and unlocks the escrow.
      </Hint>
      {status}
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
  onAct: (fn: () => Promise<`0x${string}`>, label: string) => Promise<boolean>;
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
  if (!data)
    return (
      <tr>
        <td colSpan={2}>…</td>
      </tr>
    );
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
          {quote?.[0] ? (
            <span className="ok">
              {" "}
              · fillable now for {formatUnits(quote[1], sellWeth ? 6 : 18)} {sellWeth ? "USDC" : "WETH"}
            </span>
          ) : (
            <span> · not fillable at the current price</span>
          )}
        </div>
      </td>
      <td>
        <button
          disabled={!quote?.[0]}
          onClick={async () => {
            const tokenBuy = sellWeth ? usdc : weth;
            const amountBuy = quote?.[1] ?? 0n;
            // Wait for the approval to confirm before filling; errors show in the status line.
            const ok = await onAct(
              () => writeContractAsync({ address: tokenBuy, abi: erc20Abi, functionName: "approve", args: [desk, amountBuy] }),
              `Approve ${sellWeth ? "USDC" : "WETH"}`,
            );
            if (!ok) return;
            await onAct(
              () => writeContractAsync({ address: desk, abi: limitDeskAbi, functionName: "fill", args: [id] }),
              "Fill",
            );
          }}
        >
          Approve + fill
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
