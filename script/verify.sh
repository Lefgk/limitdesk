#!/usr/bin/env bash
# Verify deployed contracts on Etherscan v2 (one API key works for Ethereum 1 and Base 8453).
#   ./script/verify.sh factory <factoryAddress>
#   ./script/verify.sh desk    <deskAddress> <owner> <weth> <usdc> <ethUsdFeed> <usdcUsdFeed>
# Env: RPC_URL (to detect chain), ETHERSCAN_API_KEY. Key is never echoed.
set -euo pipefail
export PATH="${HOME}/.foundry/bin:${PATH}"
: "${RPC_URL:?set RPC_URL}"
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY (Etherscan v2 key)}"
KIND=${1:?factory|desk}; ADDR=${2:?address}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
case "$CHAIN_ID" in 1) echo "==> Chain: Ethereum mainnet (1)";; 8453) echo "==> Chain: Base (8453)";; *) echo "Unsupported chain $CHAIN_ID" >&2; exit 1;; esac
COMMON=(--chain "$CHAIN_ID" --watch --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID")
case "$KIND" in
  factory)
    WETH=${3:?weth}; USDC=${4:?usdc}; ETHF=${5:?ethUsdFeed}; USDCF=${6:?usdcUsdFeed}
    forge verify-contract "$ADDR" src/LimitDeskFactory.sol:LimitDeskFactory "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address,address)' "$WETH" "$USDC" "$ETHF" "$USDCF")"
    ;;
  desk)
    OWNER=${3:?owner}; WETH=${4:?weth}; USDC=${5:?usdc}; ETHF=${6:?ethUsdFeed}; USDCF=${7:?usdcUsdFeed}
    forge verify-contract "$ADDR" src/LimitDesk.sol:LimitDesk "${COMMON[@]}" \
      --constructor-args "$(cast abi-encode 'constructor(address,address,address,address,address)' "$OWNER" "$WETH" "$USDC" "$ETHF" "$USDCF")"
    ;;
  *) echo "first arg must be factory or desk" >&2; exit 1 ;;
esac
