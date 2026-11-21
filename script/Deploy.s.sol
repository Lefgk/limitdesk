// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LimitDeskFactory} from "../src/LimitDeskFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MockAggregator} from "../src/MockAggregator.sol";
import {DeployConfig} from "./DeployConfig.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Deploys LimitDeskFactory on Ethereum mainnet (1), Base (8453) or local anvil (31337).
///         - Prints the chain it is on.
///         - Checks canonical USDC (symbol "USDC", 6 decimals) and WETH on live chains.
///         - REFUSES to broadcast on chain 1 / 8453 unless env CONFIRM_MAINNET=yes.
///         - On a live broadcast, writes factory, USDC and WETH into web/src/deployments.json.
///         Dry run (no --broadcast) is always allowed and prints gas estimates.
contract Deploy is Script {
    string internal constant DEPLOYMENTS_PATH = "web/src/deployments.json";

    function run() external returns (LimitDeskFactory factory, address usdc, address weth) {
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        console2.log("==> Chain:", c.name);
        console2.log("    chainId:", block.chainid);

        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (c.isMainnet) {
            _checkUsdc(c.usdc);
            _checkWeth(c.weth);
            if (broadcasting) {
                require(
                    keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("yes"),
                    "Deploy: refusing to broadcast on a live chain without CONFIRM_MAINNET=yes"
                );
                console2.log("    CONFIRM_MAINNET=yes - LIVE BROADCAST");
            } else {
                console2.log("    dry run (no --broadcast): nothing will be sent");
            }
        }

        address ethFeed = c.ethUsdFeed;
        address usdcFeed = c.usdcUsdFeed;
        vm.startBroadcast();
        if (c.isMainnet) {
            usdc = c.usdc;
            weth = c.weth;
        } else {
            usdc = address(new MockUSDC());
            weth = address(new MockWETH());
            ethFeed = address(new MockAggregator(8, 3000e8));
            usdcFeed = address(new MockAggregator(8, 1e8));
        }
        factory = new LimitDeskFactory(weth, usdc, ethFeed, usdcFeed);
        vm.stopBroadcast();

        console2.log("LimitDeskFactory", address(factory));
        console2.log("USDC", usdc);
        console2.log("WETH", weth);
        console2.log("ETH/USD feed", ethFeed);
        console2.log("USDC/USD feed", usdcFeed);

        if (broadcasting) {
            _writeWebConfig(address(factory), usdc, weth);
        }
    }

    function _checkUsdc(address token) internal view {
        require(token.code.length > 0, "Deploy: USDC has no code on this chain");
        require(keccak256(bytes(IERC20Meta(token).symbol())) == keccak256("USDC"), "Deploy: USDC symbol mismatch");
        require(IERC20Meta(token).decimals() == 6, "Deploy: USDC decimals mismatch");
        console2.log("    USDC verified (symbol USDC, 6 decimals):", token);
    }

    function _checkWeth(address token) internal view {
        require(token.code.length > 0, "Deploy: WETH has no code on this chain");
        require(IERC20Meta(token).decimals() == 18, "Deploy: WETH decimals mismatch");
        console2.log("    WETH verified (18 decimals):", token);
    }

    /// @dev Updates only this chain's entry in web/src/deployments.json. No-op if the file is missing.
    function _writeWebConfig(address factory, address usdc, address weth) internal {
        string memory path = vm.envOr("DEPLOYMENTS_PATH", DEPLOYMENTS_PATH);
        if (!vm.exists(path)) {
            console2.log("    skip writing dapp config: file not found:", path);
            return;
        }
        string memory key = string.concat(".", vm.toString(block.chainid));
        string memory obj = "dep";
        vm.serializeAddress(obj, "factory", factory);
        vm.serializeAddress(obj, "usdc", usdc);
        string memory json = vm.serializeAddress(obj, "weth", weth);
        vm.writeJson(json, path, key);
        console2.log("    wrote factory + USDC + WETH to", path);
    }
}
