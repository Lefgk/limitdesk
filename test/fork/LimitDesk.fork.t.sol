// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LimitDesk} from "../../src/LimitDesk.sol";
import {LimitDeskFactory} from "../../src/LimitDeskFactory.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function mint(address to, uint256 amount) external returns (bool);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev Runs against a fork of a live chain using real USDC, WETH and Chainlink feeds.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url` on port 8625). Otherwise skipped.
abstract contract ForkBase is Test {
    LimitDeskFactory factory;
    LimitDesk desk;
    IERC20Metadata usdc;
    IWETH weth;
    address owner = makeAddr("fork-owner");
    uint256 agentKey = uint256(keccak256("limitdesk-fork-agent"));
    address agent;
    address filler = makeAddr("fork-filler");
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return;
            vm.createSelectFork(rpc);
        } else {
            return;
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");

        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        usdc = IERC20Metadata(c.usdc);
        weth = IWETH(c.weth);
        factory = new LimitDeskFactory(c.weth, c.usdc, c.ethUsdFeed, c.usdcUsdFeed);
        agent = vm.addr(agentKey);
        // Some mainnet addresses already have EIP-7702/code; signatures must be plain EOA.
        if (agent.code.length > 0) vm.etch(agent, "");
        if (owner.code.length > 0) vm.etch(owner, "");
        if (filler.code.length > 0) vm.etch(filler, "");
        vm.prank(owner);
        desk = LimitDesk(factory.createDesk());

        _fundUsdc(c.usdc, owner, 100_000e6);
        _fundUsdc(c.usdc, filler, 100_000e6);
        _fundWeth(c.weth, owner, 20 ether);
        _fundWeth(c.weth, filler, 20 ether);

        vm.startPrank(owner);
        IERC20(c.usdc).approve(address(desk), type(uint256).max);
        IERC20(c.weth).approve(address(desk), type(uint256).max);
        desk.deposit(c.weth, 5 ether);
        desk.deposit(c.usdc, 20_000e6);
        desk.grantAgent(agent, uint64(block.timestamp + 30 days));
        desk.setCap(agent, c.weth, 5 ether);
        desk.setCap(agent, c.usdc, 20_000e6);
        vm.stopPrank();

        vm.startPrank(filler);
        IERC20(c.usdc).approve(address(desk), type(uint256).max);
        IERC20(c.weth).approve(address(desk), type(uint256).max);
        vm.stopPrank();
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _fundUsdc(address token, address to, uint256 amount) internal {
        deal(token, to, amount, true);
        if (IERC20(token).balanceOf(to) >= amount) return;
        address master = IFiatToken(token).masterMinter();
        vm.prank(master);
        IFiatToken(token).configureMinter(address(this), type(uint256).max);
        uint256 have = IERC20(token).balanceOf(to);
        if (have < amount) {
            IFiatToken(token).mint(to, amount - have);
        }
        assertGe(IERC20(token).balanceOf(to), amount, "USDC funding failed");
    }

    function _fundWeth(address token, address to, uint256 amount) internal {
        vm.deal(to, amount + 1 ether);
        vm.prank(to);
        IWETH(token).deposit{value: amount}();
        assertGe(IWETH(token).balanceOf(to), amount, "WETH funding failed");
    }

    function _sign(LimitDesk.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, desk.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    function test_fork_realMetadataAndFeeds() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(IERC20Metadata(address(weth)).decimals(), 18);
        DeployConfig.Chain memory c = DeployConfig.get(block.chainid);
        assertGt(c.ethUsdFeed.code.length, 0);
        assertGt(c.usdcUsdFeed.code.length, 0);
        (, int256 ethPx,, uint256 ethUpdated,) = AggregatorV3Interface(c.ethUsdFeed).latestRoundData();
        (, int256 usdcPx,, uint256 usdcUpdated,) = AggregatorV3Interface(c.usdcUsdFeed).latestRoundData();
        assertGt(ethPx, 0);
        assertGt(usdcPx, 0);
        assertGt(ethUpdated, 0);
        assertGt(usdcUpdated, 0);
        uint256 px = desk.oraclePriceX18(address(weth), address(usdc));
        assertGt(px, 0);
        assertEq(usdc.balanceOf(address(desk)), 20_000e6);
        assertEq(IERC20(address(weth)).balanceOf(address(desk)), 5 ether);
    }

    function test_fork_limitFillWhenOracleAtOrAboveLimit() public onFork {
        uint256 oraclePx = desk.oraclePriceX18(address(weth), address(usdc));
        uint256 limit = oraclePx * 99 / 100; // slightly below market, so fillable
        (,, uint32 epoch) = desk.agents(agent);
        LimitDesk.Order memory o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: 1 ether,
            limitPriceX18: limit,
            stopTriggerX18: 0,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 1,
            orderType: LimitDesk.OrderType.Limit,
            epoch: epoch
        });
        bytes32 id = desk.hashOrder(o);
        desk.post(o, _sign(o));
        uint256 fillerWeth0 = IERC20(address(weth)).balanceOf(filler);
        uint256 deskUsdc0 = usdc.balanceOf(address(desk));
        vm.prank(filler);
        desk.fill(id);
        assertEq(IERC20(address(weth)).balanceOf(filler), fillerWeth0 + 1 ether);
        assertEq(usdc.balanceOf(address(desk)), deskUsdc0 + limit);
        assertEq(uint256(desk.getOrder(id).status), uint256(LimitDesk.Status.Filled));
    }

    function test_fork_noFillBelowLimit() public onFork {
        uint256 oraclePx = desk.oraclePriceX18(address(weth), address(usdc));
        uint256 limit = oraclePx + oraclePx / 100 + 1; // above market
        (,, uint32 epoch) = desk.agents(agent);
        LimitDesk.Order memory o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: 1 ether,
            limitPriceX18: limit,
            stopTriggerX18: 0,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 2,
            orderType: LimitDesk.OrderType.Limit,
            epoch: epoch
        });
        bytes32 id = desk.hashOrder(o);
        desk.post(o, _sign(o));
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.LimitNotMet.selector, oraclePx, limit));
        desk.fill(id);
        assertEq(desk.totalLocked(address(weth)), 1 ether);
    }

    function test_fork_stopNotTriggeredAboveMarket() public onFork {
        uint256 oraclePx = desk.oraclePriceX18(address(weth), address(usdc));
        uint256 trigger = oraclePx * 80 / 100; // well below market: not triggered
        (,, uint32 epoch) = desk.agents(agent);
        LimitDesk.Order memory o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: 1 ether,
            limitPriceX18: 0,
            stopTriggerX18: trigger,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 3,
            orderType: LimitDesk.OrderType.Stop,
            epoch: epoch
        });
        bytes32 id = desk.hashOrder(o);
        desk.post(o, _sign(o));
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.StopNotTriggered.selector, oraclePx, trigger));
        desk.fill(id);
    }

    function test_fork_marketStopFillsAtOracleWhenTriggered() public onFork {
        uint256 oraclePx = desk.oraclePriceX18(address(weth), address(usdc));
        uint256 trigger = oraclePx; // already at or below trigger
        (,, uint32 epoch) = desk.agents(agent);
        LimitDesk.Order memory o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: 1 ether,
            limitPriceX18: 0,
            stopTriggerX18: trigger,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 4,
            orderType: LimitDesk.OrderType.Stop,
            epoch: epoch
        });
        bytes32 id = desk.hashOrder(o);
        desk.post(o, _sign(o));
        uint256 deskUsdc0 = usdc.balanceOf(address(desk));
        vm.prank(filler);
        desk.fill(id);
        assertEq(usdc.balanceOf(address(desk)), deskUsdc0 + oraclePx);
    }

    function test_fork_revokeAndOwnerWithdraw() public onFork {
        uint256 oraclePx = desk.oraclePriceX18(address(weth), address(usdc));
        (,, uint32 epoch) = desk.agents(agent);
        LimitDesk.Order memory o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: 1 ether,
            limitPriceX18: oraclePx,
            stopTriggerX18: 0,
            expiry: uint64(block.timestamp + 1 days),
            nonce: 5,
            orderType: LimitDesk.OrderType.Limit,
            epoch: epoch
        });
        bytes32 id = desk.hashOrder(o);
        desk.post(o, _sign(o));
        vm.prank(owner);
        desk.revokeAgent(agent);
        assertEq(uint256(desk.getOrder(id).status), uint256(LimitDesk.Status.Cancelled));
        assertEq(desk.totalLocked(address(weth)), 0);
        uint256 before = IERC20(address(weth)).balanceOf(owner);
        vm.prank(owner);
        desk.withdraw(address(weth), owner, 5 ether);
        assertEq(IERC20(address(weth)).balanceOf(owner), before + 5 ether);
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
