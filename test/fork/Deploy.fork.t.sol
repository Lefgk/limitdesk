// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LimitDesk} from "../../src/LimitDesk.sol";
import {LimitDeskFactory} from "../../src/LimitDeskFactory.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

/// @dev Runs the production Deploy script against a live-chain fork (no broadcast to a real network).
abstract contract DeployForkBase is Test {
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deployScript_factoryAndCanonicalTokens() public onFork {
        Deploy script = new Deploy();
        (LimitDeskFactory factory, address usdc, address weth) = script.run();

        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        assertTrue(address(factory).code.length > 0, "factory not deployed");
        assertEq(usdc, c.usdc, "must use canonical USDC");
        assertEq(weth, c.weth, "must use canonical WETH");
        assertEq(factory.usdc(), usdc);
        assertEq(factory.weth(), weth);
        assertEq(factory.ethUsdFeed(), c.ethUsdFeed);
        assertEq(factory.usdcUsdFeed(), c.usdcUsdFeed);
        assertEq(IERC20Metadata(usdc).symbol(), "USDC");
        assertEq(IERC20Metadata(usdc).decimals(), 6);
        assertEq(IERC20Metadata(weth).decimals(), 18);

        address user = makeAddr("desk-owner");
        vm.prank(user);
        address desk = factory.createDesk();
        assertTrue(desk.code.length > 0, "desk not created");
        assertEq(LimitDesk(desk).owner(), user);
        address[] memory list = factory.desksOf(user);
        assertEq(list.length, 1);
        assertEq(list[0], desk);
    }

    function test_fork_deployScript_confirmMainnetNotSetIsDryRunSafe() public onFork {
        // In a test, ForgeContext is not ScriptBroadcast, so run() must still succeed
        // without CONFIRM_MAINNET (same path as a CLI dry-run).
        vm.setEnv("CONFIRM_MAINNET", "");
        Deploy script = new Deploy();
        (LimitDeskFactory factory,,) = script.run();
        assertTrue(address(factory).code.length > 0);
    }
}

contract EthereumDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseDeployForkTest is DeployForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
