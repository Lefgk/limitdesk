// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LimitDesk} from "../../src/LimitDesk.sol";
import {LimitDeskFactory} from "../../src/LimitDeskFactory.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockWETH} from "../../src/MockWETH.sol";
import {MockAggregator} from "../../src/MockAggregator.sol";

contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// @dev Regression tests for audit 2026-11-23 (AUDIT-2026-11-23.md).
///      On the pre-fix code, test_H01_dustLimitCannotDrainEscrow's attack loop drained all 10 WETH
///      for < 100 wei USDC with a 1 WETH cap (PoC recorded in the report).
contract AuditRegression is Test {
    LimitDesk desk;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethFeed;
    MockAggregator usdcFeed;
    LimitDeskFactory factory;
    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE;
    address agent;
    address filler = makeAddr("accomplice");

    function setUp() public {
        vm.warp(1_700_000_000);
        agent = vm.addr(agentKey);
        usdc = new MockUSDC();
        weth = new MockWETH();
        ethFeed = new MockAggregator(8, 3000e8);
        usdcFeed = new MockAggregator(8, 1e8);
        factory = new LimitDeskFactory(address(weth), address(usdc), address(ethFeed), address(usdcFeed));
        desk = _newDesk();
    }

    function _newDesk() internal returns (LimitDesk d) {
        vm.prank(owner);
        d = LimitDesk(factory.createDesk());
        weth.mint(owner, 10 ether);
        usdc.mint(filler, 1_000_000e6);
        vm.startPrank(owner);
        weth.approve(address(d), type(uint256).max);
        d.deposit(address(weth), 10 ether);
        d.grantAgent(agent, uint64(block.timestamp + 30 days));
        d.setCap(agent, address(weth), 1 ether);
        vm.stopPrank();
        vm.prank(filler);
        usdc.approve(address(d), type(uint256).max);
    }

    function _order(LimitDesk d, uint256 nonce, uint256 limit) internal view returns (LimitDesk.Order memory o, bytes memory sig) {
        o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: 1 ether,
            limitPriceX18: limit,
            stopTriggerX18: 0,
            expiry: uint64(block.timestamp + 1 days),
            nonce: nonce,
            orderType: LimitDesk.OrderType.Limit,
            epoch: 0
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, d.hashOrder(o));
        sig = abi.encodePacked(r, s, v);
    }

    function _postAndFill(LimitDesk d, uint256 nonce, uint256 limit) internal {
        (LimitDesk.Order memory o, bytes memory sig) = _order(d, nonce, limit);
        bytes32 id = d.post(o, sig);
        vm.prank(filler);
        d.fill(id);
    }

    // ---------------------------------------------------------------- H-01

    function test_H01_dustLimitCannotDrainEscrow() public {
        _postAndFill(desk, 0, 1); // dust limit
        // filler paid oracle - 1% = 2970 USDC, not 1 wei
        assertEq(usdc.balanceOf(address(desk)), 2970e6);
        // cumulative daily cap: the 1 WETH cap now covers filled volume too
        (LimitDesk.Order memory o, bytes memory sig) = _order(desk, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.CapExceeded.selector, 2 ether, 1 ether));
        desk.post(o, sig);
        assertEq(weth.balanceOf(address(desk)), 9 ether);
        assertEq(desk.filledInWindowOf(agent, address(weth)), 1 ether);
    }

    function test_H01_capWindowResetsAfterOneDay() public {
        _postAndFill(desk, 0, 2990e6);
        vm.warp(block.timestamp + 1 days);
        ethFeed.setAnswer(3000e8);
        usdcFeed.setAnswer(1e8);
        assertEq(desk.filledInWindowOf(agent, address(weth)), 0);
        _postAndFill(desk, 1, 2990e6);
        assertEq(weth.balanceOf(address(desk)), 8 ether);
    }

    function test_H01_cancelFreesCapButFillDoesNot() public {
        (LimitDesk.Order memory o, bytes memory sig) = _order(desk, 0, 2990e6);
        bytes32 id = desk.post(o, sig);
        vm.prank(agent);
        desk.cancel(id);
        _postAndFill(desk, 1, 2990e6); // cancel freed the cap
        (o, sig) = _order(desk, 2, 2990e6);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.CapExceeded.selector, 2 ether, 1 ether));
        desk.post(o, sig);
    }

    function test_H01_setFillDiscountBps() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        desk.setFillDiscountBps(50);
        vm.startPrank(owner);
        vm.expectRevert(LimitDesk.InvalidDiscount.selector);
        desk.setFillDiscountBps(1_001);
        desk.setFillDiscountBps(0);
        vm.stopPrank();
        _postAndFill(desk, 0, 1);
        assertEq(usdc.balanceOf(address(desk)), 3000e6); // 0% discount => oracle price
    }

    /// fuzz: whatever limit the agent signs, the desk never receives less than oracle * (1 - discount)
    function testFuzz_H01_fillNeverBelowDiscountedOracle(uint256 limit, uint256 ethPx) public {
        ethPx = bound(ethPx, 100e8, 100_000e8);
        ethFeed.setAnswer(int256(ethPx));
        uint256 oraclePx = desk.oraclePriceX18(address(weth), address(usdc));
        limit = bound(limit, 1, oraclePx);
        _postAndFill(desk, 0, limit);
        uint256 got = usdc.balanceOf(address(desk));
        assertGe(got, oraclePx * 9_900 / 10_000);
        assertGe(got, limit);
    }

    // ---------------------------------------------------------------- M-01 (Base sequencer)

    function _baseDesk(int256 answer, uint256 startedAt) internal returns (LimitDesk d) {
        vm.chainId(8453);
        MockSequencerFeed impl = new MockSequencerFeed();
        address seq = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
        vm.etch(seq, address(impl).code);
        MockSequencerFeed(seq).set(answer, startedAt);
        d = _newDesk();
        assertEq(d.sequencerFeed(), seq);
    }

    function test_M01_noSequencerFeedOffBase() public view {
        assertEq(desk.sequencerFeed(), address(0));
    }

    function test_M01_fillRevertsWhileSequencerDown() public {
        LimitDesk d = _baseDesk(0, block.timestamp - 2 hours);
        (LimitDesk.Order memory o, bytes memory sig) = _order(d, 0, 2990e6);
        bytes32 id = d.post(o, sig);
        MockSequencerFeed(d.sequencerFeed()).set(1, block.timestamp - 10 minutes); // down
        vm.prank(filler);
        vm.expectRevert(LimitDesk.SequencerDown.selector);
        d.fill(id);
    }

    function test_M01_fillRevertsInGracePeriodThenWorks() public {
        LimitDesk d = _baseDesk(0, block.timestamp - 2 hours);
        (LimitDesk.Order memory o, bytes memory sig) = _order(d, 0, 2990e6);
        bytes32 id = d.post(o, sig);
        MockSequencerFeed(d.sequencerFeed()).set(0, block.timestamp - 30 minutes); // just came back
        vm.prank(filler);
        vm.expectRevert(LimitDesk.SequencerGracePeriod.selector);
        d.fill(id);
        vm.warp(block.timestamp + 31 minutes);
        ethFeed.setAnswer(3000e8);
        usdcFeed.setAnswer(1e8);
        vm.prank(filler);
        d.fill(id);
        assertEq(weth.balanceOf(filler), 1 ether);
    }
}
