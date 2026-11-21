// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LimitDesk} from "./LimitDesk.sol";

/// @title LimitDeskFactory
/// @notice Deploys one LimitDesk per call, owned by the caller, and indexes desks by owner.
///         WETH, USDC and their Chainlink USD feeds are fixed at factory deploy.
contract LimitDeskFactory {
    address public immutable weth;
    address public immutable usdc;
    address public immutable ethUsdFeed;
    address public immutable usdcUsdFeed;

    mapping(address owner => address[]) internal _desksOf;

    event DeskCreated(address indexed owner, address indexed desk);

    error ZeroAddress();
    error InvalidPair();

    constructor(address weth_, address usdc_, address ethUsdFeed_, address usdcUsdFeed_) {
        if (weth_ == address(0) || usdc_ == address(0) || ethUsdFeed_ == address(0) || usdcUsdFeed_ == address(0)) {
            revert ZeroAddress();
        }
        if (weth_ == usdc_) revert InvalidPair();
        weth = weth_;
        usdc = usdc_;
        ethUsdFeed = ethUsdFeed_;
        usdcUsdFeed = usdcUsdFeed_;
    }

    function createDesk() external returns (address desk) {
        desk = address(new LimitDesk(msg.sender, weth, usdc, ethUsdFeed, usdcUsdFeed));
        _desksOf[msg.sender].push(desk);
        emit DeskCreated(msg.sender, desk);
    }

    function desksOf(address owner) external view returns (address[] memory) {
        return _desksOf[owner];
    }
}
