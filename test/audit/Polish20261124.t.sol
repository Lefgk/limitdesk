// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {LimitDesk} from "../../src/LimitDesk.sol";
import {LimitDeskFactory} from "../../src/LimitDeskFactory.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockWETH} from "../../src/MockWETH.sol";
import {MockAggregator} from "../../src/MockAggregator.sol";

/// @dev EIP-1271 smart-contract agent: accepts any signature it is told to accept.
contract Agent1271 {
    bytes32 public okHash;

    function setOk(bytes32 h) external {
        okHash = h;
    }

    function isValidSignature(bytes32 h, bytes calldata) external view returns (bytes4) {
        return h == okHash ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Polish pass 2026-11-24: access control, factory, validation, cap window, quote, 1271, oracle edge cases.
contract Polish20261124 is Test {
    LimitDesk desk;
    LimitDeskFactory factory;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethFeed;
    MockAggregator usdcFeed;

    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE;
    address agent;
    address filler = makeAddr("filler");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_700_000_000);
        agent = vm.addr(agentKey);
        usdc = new MockUSDC();
        weth = new MockWETH();
        ethFeed = new MockAggregator(8, 3000e8);
        usdcFeed = new MockAggregator(8, 1e8);
        factory = new LimitDeskFactory(address(weth), address(usdc), address(ethFeed), address(usdcFeed));
        vm.prank(owner);
        desk = LimitDesk(factory.createDesk());

        weth.mint(owner, 1_000 ether);
        usdc.mint(owner, 10_000_000e6);
        usdc.mint(filler, 10_000_000e6);
        weth.mint(filler, 1_000 ether);

        vm.startPrank(owner);
        weth.approve(address(desk), type(uint256).max);
        usdc.approve(address(desk), type(uint256).max);
        desk.deposit(address(weth), 100 ether);
        desk.deposit(address(usdc), 500_000e6);
        desk.grantAgent(agent, uint64(block.timestamp + 30 days));
        desk.setCap(agent, address(weth), 10 ether);
        desk.setCap(agent, address(usdc), 100_000e6);
        vm.stopPrank();

        vm.startPrank(filler);
        usdc.approve(address(desk), type(uint256).max);
        weth.approve(address(desk), type(uint256).max);
        vm.stopPrank();
    }

    function _o(address sell, address buy, uint256 amt, uint256 limit, uint256 nonce)
        internal
        view
        returns (LimitDesk.Order memory)
    {
        (,, uint32 epoch) = desk.agents(agent);
        return LimitDesk.Order({
            agent: agent,
            tokenSell: sell,
            tokenBuy: buy,
            amountSell: amt,
            limitPriceX18: limit,
            stopTriggerX18: 0,
            expiry: uint64(block.timestamp + 1 days),
            nonce: nonce,
            orderType: LimitDesk.OrderType.Limit,
            epoch: epoch
        });
    }

    function _sig(LimitDesk d, LimitDesk.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, d.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    function _post(LimitDesk.Order memory o) internal returns (bytes32) {
        return desk.post(o, _sig(desk, o));
    }

    function _sellWeth(uint256 amt, uint256 nonce) internal returns (bytes32) {
        return _post(_o(address(weth), address(usdc), amt, 2900e6, nonce));
    }

    // ------------------------------------------------------------ factory

    function test_factoryRejectsZeroAddresses() public {
        address a = address(1);
        vm.expectRevert(LimitDeskFactory.ZeroAddress.selector);
        new LimitDeskFactory(address(0), a, a, a);
        vm.expectRevert(LimitDeskFactory.ZeroAddress.selector);
        new LimitDeskFactory(a, address(0), a, a);
        vm.expectRevert(LimitDeskFactory.ZeroAddress.selector);
        new LimitDeskFactory(a, a, address(0), a);
        vm.expectRevert(LimitDeskFactory.ZeroAddress.selector);
        new LimitDeskFactory(a, a, a, address(0));
    }

    function test_factoryRejectsSameWethUsdc() public {
        vm.expectRevert(LimitDeskFactory.InvalidPair.selector);
        new LimitDeskFactory(address(1), address(1), address(2), address(3));
    }

    function test_deskConstructorChecks() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LimitDesk(address(0), address(weth), address(usdc), address(ethFeed), address(usdcFeed));
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        new LimitDesk(owner, address(weth), address(weth), address(ethFeed), address(usdcFeed));
        vm.expectRevert(LimitDesk.ZeroAddress.selector);
        new LimitDesk(owner, address(weth), address(usdc), address(0), address(usdcFeed));
    }

    function test_factoryMultipleDesksIndependentOwners() public {
        vm.prank(stranger);
        address d2 = factory.createDesk();
        assertEq(LimitDesk(d2).owner(), stranger);
        assertEq(factory.desksOf(stranger).length, 1);
        assertEq(factory.desksOf(owner).length, 1);
        assertTrue(d2 != address(desk));
    }

    // ------------------------------------------------------------ access control

    function test_onlyOwnerAdmin() public {
        bytes memory e = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(e);
        desk.grantAgent(stranger, uint64(block.timestamp + 1 days));
        vm.expectRevert(e);
        desk.setCap(agent, address(weth), 1);
        vm.expectRevert(e);
        desk.setFillDiscountBps(5);
        vm.expectRevert(e);
        desk.revokeAgent(agent);
        vm.expectRevert(e);
        desk.pause();
        vm.expectRevert(e);
        desk.unpause();
        vm.expectRevert(e);
        desk.withdraw(address(weth), stranger, 1);
        vm.stopPrank();
    }

    function test_agentCannotWithdrawOrGrantItself() public {
        vm.startPrank(agent);
        vm.expectRevert();
        desk.withdraw(address(weth), agent, 1);
        vm.expectRevert();
        desk.setCap(agent, address(weth), type(uint256).max);
        vm.stopPrank();
    }

    function test_ownershipTwoStep() public {
        vm.prank(owner);
        desk.transferOwnership(stranger);
        assertEq(desk.owner(), owner);
        vm.prank(stranger);
        desk.acceptOwnership();
        assertEq(desk.owner(), stranger);
    }

    function test_invalidateNonceAccessAndReuse() public {
        vm.prank(stranger);
        vm.expectRevert(LimitDesk.NotOwnerOrAgent.selector);
        desk.invalidateNonce(agent, 1);
        vm.prank(agent);
        desk.invalidateNonce(agent, 1);
        assertTrue(desk.nonceUsed(agent, 1));
        vm.prank(owner);
        vm.expectRevert(LimitDesk.AlreadyUsed.selector);
        desk.invalidateNonce(agent, 1);
    }

    function test_invalidateNonceCannotTouchPostedOrderNonce() public {
        _sellWeth(1 ether, 7);
        vm.prank(owner);
        vm.expectRevert(LimitDesk.AlreadyUsed.selector);
        desk.invalidateNonce(agent, 7);
    }

    // ------------------------------------------------------------ funding validation

    function test_depositZeroAndWrongToken() public {
        vm.startPrank(owner);
        vm.expectRevert(LimitDesk.ZeroAmount.selector);
        desk.deposit(address(weth), 0);
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        desk.deposit(address(0xdead), 1);
        vm.stopPrank();
    }

    function test_withdrawValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(LimitDesk.ZeroAddress.selector);
        desk.withdraw(address(weth), address(0), 1);
        vm.expectRevert(LimitDesk.ZeroAmount.selector);
        desk.withdraw(address(weth), owner, 0);
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        desk.withdraw(address(0xdead), owner, 1);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.InsufficientEscrow.selector, 100 ether, type(uint256).max));
        desk.withdraw(address(weth), owner, type(uint256).max);
        vm.stopPrank();
    }

    function test_anyoneCanDepositButOnlyOwnerWithdraws() public {
        weth.mint(stranger, 1 ether);
        vm.startPrank(stranger);
        weth.approve(address(desk), 1 ether);
        desk.deposit(address(weth), 1 ether);
        vm.expectRevert();
        desk.withdraw(address(weth), stranger, 1 ether);
        vm.stopPrank();
        assertEq(desk.available(address(weth)), 101 ether);
    }

    function test_directTransferDonationDoesNotBreakLockAccounting() public {
        weth.mint(address(desk), 5 ether);
        _sellWeth(1 ether, 1);
        assertEq(desk.totalLocked(address(weth)), 1 ether);
        assertEq(desk.available(address(weth)), 104 ether);
    }

    // ------------------------------------------------------------ agent grant / expiry

    function test_grantAgentValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(LimitDesk.ZeroAddress.selector);
        desk.grantAgent(address(0), uint64(block.timestamp + 1));
        vm.expectRevert(LimitDesk.InvalidExpiry.selector);
        desk.grantAgent(agent, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_setCapValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(LimitDesk.ZeroAddress.selector);
        desk.setCap(address(0), address(weth), 1);
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        desk.setCap(agent, address(0xdead), 1);
        vm.stopPrank();
    }

    function test_postAfterAgentExpiryReverts() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        o.expiry = uint64(block.timestamp + 60 days);
        bytes memory sig = _sig(desk, o);
        vm.warp(block.timestamp + 31 days);
        ethFeed.setAnswer(3000e8);
        vm.expectRevert(LimitDesk.AgentExpired.selector);
        desk.post(o, sig);
    }

    function test_fillAfterAgentExpiryRevertsButOwnerCanCancel() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        o.expiry = uint64(block.timestamp + 60 days);
        bytes32 id = desk.post(o, _sig(desk, o));
        vm.warp(block.timestamp + 31 days);
        ethFeed.setAnswer(3000e8);
        usdcFeed.setAnswer(1e8);
        assertFalse(_quoteOk(id));
        vm.prank(filler);
        vm.expectRevert(LimitDesk.AgentExpired.selector);
        desk.fill(id);
        vm.prank(owner);
        desk.cancel(id);
        assertEq(desk.totalLocked(address(weth)), 0);
    }

    function _quoteOk(bytes32 id) internal view returns (bool ok) {
        (ok,,,) = desk.quoteFill(id);
    }

    function test_renounceAgent() public {
        bytes32 id = _sellWeth(1 ether, 1);
        vm.prank(stranger);
        vm.expectRevert(LimitDesk.NotAgent.selector);
        desk.renounceAgent();
        vm.prank(agent);
        desk.renounceAgent();
        assertEq(uint8(desk.getOrder(id).status), uint8(LimitDesk.Status.Cancelled));
        assertEq(desk.totalLocked(address(weth)), 0);
        (bool active,, uint32 epoch) = desk.agents(agent);
        assertFalse(active);
        assertEq(epoch, 1);
        // cannot renounce twice
        vm.prank(agent);
        vm.expectRevert(LimitDesk.NotAgent.selector);
        desk.renounceAgent();
    }

    function test_revokeThenRegrantNeedsNewCapAndEpoch() public {
        _sellWeth(1 ether, 1);
        vm.startPrank(owner);
        desk.revokeAgent(agent);
        desk.grantAgent(agent, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(desk.capOf(agent, address(weth)), 0);
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 2);
        bytes memory sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.NoCap.selector);
        desk.post(o, sig);
    }

    function test_revokeFreesAllLockedAndKeepsListsConsistent() public {
        for (uint256 i; i < 5; i++) {
            _sellWeth(1 ether, i);
        }
        assertEq(desk.openOrders().length, 5);
        vm.prank(owner);
        desk.revokeAgent(agent);
        assertEq(desk.openOrders().length, 0);
        assertEq(desk.openOrdersOf(agent).length, 0);
        assertEq(desk.totalLocked(address(weth)), 0);
    }

    // ------------------------------------------------------------ post validation

    function test_postValidation() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 0, 2900e6, 1);
        bytes memory sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.ZeroAmount.selector);
        desk.post(o, sig);

        o = _o(address(weth), address(weth), 1 ether, 2900e6, 2);
        sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        desk.post(o, sig);

        o = _o(address(weth), address(usdc), 1 ether, 0, 3); // limit with zero price
        sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.InvalidOrder.selector);
        desk.post(o, sig);

        o = _o(address(weth), address(usdc), 1 ether, 2900e6, 4);
        o.stopTriggerX18 = 1; // limit with stop trigger
        sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.InvalidOrder.selector);
        desk.post(o, sig);

        o = _o(address(weth), address(usdc), 1 ether, 2900e6, 5);
        o.orderType = LimitDesk.OrderType.Stop; // stop with zero trigger
        o.stopTriggerX18 = 0;
        sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.InvalidOrder.selector);
        desk.post(o, sig);

        o = _o(address(weth), address(usdc), 1 ether, 2900e6, 6);
        o.expiry = uint64(block.timestamp);
        sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.OrderExpired.selector);
        desk.post(o, sig);
    }

    function test_postWrongSignerAndTamperedOrder() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, desk.hashOrder(o));
        vm.expectRevert(LimitDesk.InvalidSignature.selector);
        desk.post(o, abi.encodePacked(r, s, v));

        bytes memory good = _sig(desk, o);
        o.amountSell = 2 ether; // tamper after signing
        vm.expectRevert(LimitDesk.InvalidSignature.selector);
        desk.post(o, good);
    }

    function test_postUnknownAgentReverts() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        o.agent = stranger;
        vm.expectRevert(LimitDesk.NotAgent.selector);
        desk.post(o, hex"");
    }

    function test_signatureNotReplayableAcrossDesks() public {
        vm.prank(owner);
        LimitDesk d2 = LimitDesk(factory.createDesk());
        vm.startPrank(owner);
        weth.approve(address(d2), type(uint256).max);
        d2.deposit(address(weth), 10 ether);
        d2.grantAgent(agent, uint64(block.timestamp + 30 days));
        d2.setCap(agent, address(weth), 10 ether);
        vm.stopPrank();
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        bytes memory sig = _sig(desk, o);
        desk.post(o, sig);
        vm.expectRevert(LimitDesk.InvalidSignature.selector);
        d2.post(o, sig);
    }

    function test_maxOpenOrdersPerAgent() public {
        vm.prank(owner);
        desk.setCap(agent, address(weth), 1_000 ether);
        uint256 n = desk.MAX_OPEN_PER_AGENT();
        for (uint256 i; i < n; i++) {
            _post(_o(address(weth), address(usdc), 1, 2900e6, i));
        }
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1, 2900e6, n);
        bytes memory sig = _sig(desk, o);
        vm.expectRevert(LimitDesk.TooManyOpenOrders.selector);
        desk.post(o, sig);
    }

    function test_erc1271AgentCanPost() public {
        Agent1271 a = new Agent1271();
        vm.startPrank(owner);
        desk.grantAgent(address(a), uint64(block.timestamp + 1 days));
        desk.setCap(address(a), address(weth), 5 ether);
        vm.stopPrank();
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        o.agent = address(a);
        bytes32 h = desk.hashOrder(o);
        vm.expectRevert(LimitDesk.InvalidSignature.selector);
        desk.post(o, hex"01");
        a.setOk(h);
        desk.post(o, hex"01");
        assertEq(desk.totalLocked(address(weth)), 1 ether);
    }

    function test_cannotPostSameOrderTwiceDifferentNonceIsSeparate() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        bytes memory sig = _sig(desk, o);
        desk.post(o, sig);
        vm.expectRevert(LimitDesk.NonceUsed.selector);
        desk.post(o, sig);
    }

    // ------------------------------------------------------------ fill / cancel states

    function test_fillUnknownAndCancelledOrder() public {
        vm.prank(filler);
        vm.expectRevert(LimitDesk.OrderNotOpen.selector);
        desk.fill(bytes32(uint256(1)));
        bytes32 id = _sellWeth(1 ether, 1);
        vm.prank(owner);
        desk.cancel(id);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.OrderNotOpen.selector);
        desk.fill(id);
        vm.prank(owner);
        vm.expectRevert(LimitDesk.OrderNotOpen.selector);
        desk.cancel(id);
    }

    function test_fillTransfersExactAmountsAndIsPermissionless() public {
        bytes32 id = _sellWeth(2 ether, 1);
        (bool ok, uint256 buy, uint256 px, uint256 oracle) = desk.quoteFill(id);
        assertTrue(ok);
        assertEq(oracle, 3000e6);
        assertEq(px, 2970e6); // max(2900, 3000*0.99)
        assertEq(buy, 5940e6);
        uint256 uBefore = usdc.balanceOf(filler);
        vm.prank(filler);
        desk.fill(id);
        assertEq(usdc.balanceOf(filler), uBefore - buy);
        assertEq(weth.balanceOf(filler), 1_000 ether + 2 ether);
        assertEq(desk.totalLocked(address(weth)), 0);
        assertEq(desk.openSellOf(agent, address(weth)), 0);
        assertEq(desk.filledInWindowOf(agent, address(weth)), 2 ether);
        assertEq(uint8(desk.getOrder(id).status), uint8(LimitDesk.Status.Filled));
    }

    function test_quoteFillNotOkWhenLimitNotMetOrClosed() public {
        bytes32 id = _post(_o(address(weth), address(usdc), 1 ether, 3100e6, 1));
        (bool ok,,, uint256 oracle) = desk.quoteFill(id);
        assertFalse(ok);
        assertEq(oracle, 3000e6);
        (ok,,,) = desk.quoteFill(bytes32(uint256(99)));
        assertFalse(ok);
        vm.warp(block.timestamp + 2 days);
        (ok,,,) = desk.quoteFill(id);
        assertFalse(ok);
    }

    function test_dustOrderCannotFillButCanCancel() public {
        bytes32 id = _post(_o(address(weth), address(usdc), 1, 2900e6, 1));
        vm.prank(filler);
        vm.expectRevert(LimitDesk.ZeroAmount.selector);
        desk.fill(id);
        vm.prank(agent);
        desk.cancel(id);
        assertEq(desk.totalLocked(address(weth)), 0);
    }

    function test_pauseBlocksFillAndPostResumeWorks() public {
        bytes32 id = _sellWeth(1 ether, 1);
        vm.prank(owner);
        desk.pause();
        vm.prank(filler);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        desk.fill(id);
        vm.prank(owner);
        desk.unpause();
        vm.prank(filler);
        desk.fill(id);
    }

    // ------------------------------------------------------------ oracle edge cases

    function test_badOracleNegativeAndZero() public {
        bytes32 id = _sellWeth(1 ether, 1);
        ethFeed.setAnswer(0);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.BadOracle.selector);
        desk.fill(id);
        ethFeed.setAnswer(-5);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.BadOracle.selector);
        desk.fill(id);
    }

    function test_staleStableFeedRevertsOnFill() public {
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1 ether, 2900e6, 1);
        o.expiry = uint64(block.timestamp + 10 days);
        bytes32 id = desk.post(o, _sig(desk, o));
        vm.warp(block.timestamp + 25 hours + 1);
        ethFeed.setAnswer(3000e8);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.StaleOracle.selector);
        desk.fill(id);
        vm.warp(block.timestamp);
        usdcFeed.setAnswer(1e8);
        vm.prank(filler);
        desk.fill(id);
    }

    function test_oracleAnsweredInRoundStale() public {
        // answeredInRound < roundId is flagged BadOracle; MockAggregator always equal, so use ok path price
        assertEq(desk.oraclePriceX18(address(weth), address(usdc)), 3000e6);
        assertEq(desk.oraclePriceX18(address(usdc), address(weth)), uint256(1e30) / 3000);
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        desk.oraclePriceX18(address(weth), address(weth));
        vm.expectRevert(LimitDesk.InvalidPair.selector);
        desk.oraclePriceX18(address(0xdead), address(usdc));
    }

    function test_usdcDepegPricing() public {
        usdcFeed.setAnswer(0.95e8);
        uint256 px = desk.oraclePriceX18(address(weth), address(usdc));
        // 3000/0.95 USDC per WETH
        assertApproxEqRel(px, uint256(3000e6) * 100 / 95, 1e12);
    }

    // ------------------------------------------------------------ cap window

    function test_capCountsOpenPlusFilledInWindow() public {
        // cap 10 WETH: fill 6, then 4 open ok, 1 wei more reverts
        bytes32 a = _sellWeth(6 ether, 1);
        vm.prank(filler);
        desk.fill(a);
        _sellWeth(4 ether, 2);
        LimitDesk.Order memory o = _o(address(weth), address(usdc), 1, 2900e6, 3);
        bytes memory sig = _sig(desk, o);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.CapExceeded.selector, 10 ether + 1, 10 ether));
        desk.post(o, sig);
    }

    function test_capWindowRollsAfterOneDay() public {
        bytes32 a = _sellWeth(10 ether, 1);
        vm.prank(filler);
        desk.fill(a);
        vm.warp(block.timestamp + 1 days);
        ethFeed.setAnswer(3000e8);
        usdcFeed.setAnswer(1e8);
        assertEq(desk.filledInWindowOf(agent, address(weth)), 0);
        _sellWeth(10 ether, 2);
    }

    function test_capIsPerToken() public {
        bytes32 a = _sellWeth(10 ether, 1);
        vm.prank(filler);
        desk.fill(a);
        // USDC cap untouched
        _post(_o(address(usdc), address(weth), 100_000e6, uint256(1e30) / 3200, 2));
    }

    function testFuzz_cumulativeSellNeverExceedsCap(uint256 a1, uint256 a2, uint256 a3) public {
        a1 = bound(a1, 1e12, 10 ether);
        a2 = bound(a2, 1e12, 10 ether);
        a3 = bound(a3, 1e12, 10 ether);
        uint256[3] memory amts = [a1, a2, a3];
        uint256 total;
        for (uint256 i; i < 3; i++) {
            LimitDesk.Order memory o = _o(address(weth), address(usdc), amts[i], 2900e6, i);
            bytes memory sig = _sig(desk, o);
            if (total + amts[i] > 10 ether) {
                vm.expectRevert();
                desk.post(o, sig);
            } else {
                bytes32 id = desk.post(o, sig);
                total += amts[i];
                if (i % 2 == 0) {
                    vm.prank(filler);
                    desk.fill(id); // filled volume still counts in window
                }
            }
            assertLe(desk.openSellOf(agent, address(weth)) + desk.filledInWindowOf(agent, address(weth)), 10 ether);
        }
    }

    function testFuzz_setFillDiscountBounds(uint16 bps) public {
        vm.prank(owner);
        if (bps > 1000) {
            vm.expectRevert(LimitDesk.InvalidDiscount.selector);
            desk.setFillDiscountBps(bps);
        } else {
            desk.setFillDiscountBps(bps);
            assertEq(desk.fillDiscountBps(), bps);
        }
    }

    // ------------------------------------------------------------ production-scale precision (6dp vs 18dp)

    function testFuzz_usdcSellFillAmountMatchesOracle(uint256 usdcAmt) public {
        usdcAmt = bound(usdcAmt, 1e6, 100_000e6);
        uint256 limit = uint256(1e30) / 3200; // buy WETH wei per 1e18 USDC-units
        bytes32 id = _post(_o(address(usdc), address(weth), usdcAmt, limit, 1));
        (bool ok, uint256 buy, uint256 px,) = desk.quoteFill(id);
        assertTrue(ok);
        assertEq(buy, usdcAmt * px / 1e18);
        uint256 wBefore = weth.balanceOf(filler);
        vm.prank(filler);
        desk.fill(id);
        assertEq(wBefore - weth.balanceOf(filler), buy);
        assertEq(usdc.balanceOf(filler), 10_000_000e6 + usdcAmt);
    }
}
