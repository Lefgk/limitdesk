// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {DeployConfig} from "../script/DeployConfig.sol";
import {LimitDeskFactory} from "../src/LimitDeskFactory.sol";
import {LimitDesk} from "../src/LimitDesk.sol";

contract DeployConfigTest is Test {
    function test_ethereumAndBaseAddressesAndFlags() public pure {
        DeployConfig.Chain memory e = DeployConfig.get(1);
        assertEq(e.usdc, 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(e.weth, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(e.ethUsdFeed, 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        assertEq(e.usdcUsdFeed, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
        assertTrue(e.isMainnet);
        DeployConfig.Chain memory b = DeployConfig.get(8453);
        assertEq(b.usdc, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(b.weth, 0x4200000000000000000000000000000000000006);
        assertEq(b.ethUsdFeed, 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
        assertEq(b.usdcUsdFeed, 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B);
        assertTrue(b.isMainnet);
    }

    function test_anvilConfigIsNotMainnet() public pure {
        DeployConfig.Chain memory c = DeployConfig.get(31337);
        assertEq(c.usdc, address(0));
        assertEq(c.weth, address(0));
        assertFalse(c.isMainnet);
    }

    function test_unsupportedChainReverts() public {
        vm.chainId(11155111); // Sepolia is not a supported target
        Deploy script = new Deploy();
        vm.expectRevert(bytes("DeployConfig: unsupported chain (only 1, 8453, 31337)"));
        script.run();
    }

    function test_deployScriptOnAnvilDeploysFactoryAndMocks() public {
        if (block.chainid != 31337) {
            vm.skip(true);
            return;
        }
        Deploy script = new Deploy();
        (LimitDeskFactory factory, address usdc, address weth) = script.run();
        assertTrue(address(factory).code.length > 0);
        assertTrue(usdc.code.length > 0);
        assertTrue(weth.code.length > 0);
        assertEq(factory.usdc(), usdc);
        assertEq(factory.weth(), weth);
        assertEq(factory.desksOf(address(this)).length, 0);
        address desk = factory.createDesk();
        assertTrue(desk.code.length > 0);
        assertEq(LimitDesk(desk).owner(), address(this));
        assertEq(factory.desksOf(address(this)).length, 1);
    }
}
