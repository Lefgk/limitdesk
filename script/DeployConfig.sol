// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Per-chain deploy settings. Only these chains are supported.
library DeployConfig {
    struct Chain {
        string name;
        bool isMainnet; // live chain with real funds -> needs CONFIRM_MAINNET=yes to broadcast
        address usdc;
        address weth;
        address ethUsdFeed;
        address usdcUsdFeed;
    }

    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ANVIL = 31337;

    address internal constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH_ETHEREUM = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_USD_ETHEREUM = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_ETHEREUM = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address internal constant ETH_USD_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_BASE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    function get(uint256 chainId) internal pure returns (Chain memory) {
        if (chainId == ETHEREUM) {
            return Chain("Ethereum mainnet", true, USDC_ETHEREUM, WETH_ETHEREUM, ETH_USD_ETHEREUM, USDC_USD_ETHEREUM);
        }
        if (chainId == BASE) {
            return Chain("Base", true, USDC_BASE, WETH_BASE, ETH_USD_BASE, USDC_USD_BASE);
        }
        if (chainId == ANVIL) {
            return Chain("Local anvil", false, address(0), address(0), address(0), address(0));
        }
        revert("DeployConfig: unsupported chain (only 1, 8453, 31337)");
    }
}
