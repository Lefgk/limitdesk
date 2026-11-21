// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test/local-only WETH with deposit/withdraw and open mint. Never deploy to mainnet.
contract MockWETH is ERC20 {
    constructor() ERC20("Mock Wrapped Ether", "mWETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
