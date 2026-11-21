// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LimitDesk} from "../src/LimitDesk.sol";
import {LimitDeskFactory} from "../src/LimitDeskFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MockAggregator} from "../src/MockAggregator.sol";

contract LimitDeskTest is Test {
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

    uint256 constant WETH_USDC_3000 = 3000e6;
    uint256 constant USDC_WETH_3000 = uint256(1e30) / 3000;

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

        weth.mint(owner, 100 ether);
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(filler, 1_000_000e6);
        weth.mint(filler, 100 ether);

        vm.startPrank(owner);
        weth.approve(address(desk), type(uint256).max);
        usdc.approve(address(desk), type(uint256).max);
        desk.deposit(address(weth), 10 ether);
        desk.deposit(address(usdc), 50_000e6);
        desk.grantAgent(agent, uint64(block.timestamp + 30 days));
        desk.setCap(agent, address(weth), 5 ether);
        desk.setCap(agent, address(usdc), 20_000e6);
        vm.stopPrank();

        vm.prank(filler);
        usdc.approve(address(desk), type(uint256).max);
        vm.prank(filler);
        weth.approve(address(desk), type(uint256).max);
    }

    function _order(address sell, address buy, uint256 amount, uint256 limit, uint256 stop, LimitDesk.OrderType typ, uint256 nonce)
        internal
        view
        returns (LimitDesk.Order memory o)
    {
        (,, uint32 epoch) = desk.agents(agent);
        o = LimitDesk.Order({
            agent: agent,
            tokenSell: sell,
            tokenBuy: buy,
            amountSell: amount,
            limitPriceX18: limit,
            stopTriggerX18: stop,
            expiry: uint64(block.timestamp + 1 days),
            nonce: nonce,
            orderType: typ,
            epoch: epoch
        });
    }

    function _sign(LimitDesk.Order memory o) internal view returns (bytes memory) {
        bytes32 digest = desk.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _post(LimitDesk.Order memory o) internal returns (bytes32 id) {
        bytes memory sig = _sign(o);
        id = desk.hashOrder(o);
        desk.post(o, sig);
    }

    // ------------------------------------------------------------------ factory / views

    function test_factoryIndexesDesk() public view {
        address[] memory list = factory.desksOf(owner);
        assertEq(list.length, 1);
        assertEq(list[0], address(desk));
        assertEq(desk.owner(), owner);
        assertEq(desk.weth(), address(weth));
        assertEq(desk.usdc(), address(usdc));
    }

    function test_oraclePriceWethUsdc() public view {
        assertEq(desk.oraclePriceX18(address(weth), address(usdc)), WETH_USDC_3000);
        assertEq(desk.oraclePriceX18(address(usdc), address(weth)), USDC_WETH_3000);
    }

    function test_availableAndDeposit() public view {
        assertEq(desk.available(address(weth)), 10 ether);
        assertEq(desk.available(address(usdc)), 50_000e6);
        assertEq(desk.totalLocked(address(weth)), 0);
    }

    // ------------------------------------------------------------------ limit fill

    function test_limitSellWethFillsAtLimitWhenOracleBetter() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 1);
        bytes32 id = _post(o);
        uint256 fillerWeth0 = weth.balanceOf(filler);
        uint256 deskUsdc0 = usdc.balanceOf(address(desk));

        vm.prank(filler);
        desk.fill(id);

        assertEq(weth.balanceOf(filler), fillerWeth0 + 1 ether);
        assertEq(usdc.balanceOf(address(desk)), deskUsdc0 + 2900e6);
        assertEq(desk.available(address(weth)), 9 ether);
        assertEq(desk.totalLocked(address(weth)), 0);
        assertEq(uint256(desk.getOrder(id).status), uint256(LimitDesk.Status.Filled));
    }

    function test_noFillBelowLimit() public {
        // limit 3100 USDC/WETH but oracle is 3000
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 3100e6, 0, LimitDesk.OrderType.Limit, 2);
        bytes32 id = _post(o);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.LimitNotMet.selector, WETH_USDC_3000, uint256(3100e6)));
        desk.fill(id);
        assertEq(uint256(desk.getOrder(id).status), uint256(LimitDesk.Status.Open));
        assertEq(desk.totalLocked(address(weth)), 1 ether);
    }

    function testFuzz_noFillBelowLimit(uint256 limitBps) public {
        // limit from just above oracle (3000e6 + 1) up to 2x
        uint256 limit = bound(limitBps, WETH_USDC_3000 + 1, WETH_USDC_3000 * 2);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 0.1 ether, limit, 0, LimitDesk.OrderType.Limit, limit);
        bytes32 id = _post(o);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.LimitNotMet.selector, WETH_USDC_3000, limit));
        desk.fill(id);
        assertEq(weth.balanceOf(filler), 100 ether); // unchanged
        assertEq(desk.totalLocked(address(weth)), 0.1 ether);
    }

    function test_exactLimitFills() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, WETH_USDC_3000, 0, LimitDesk.OrderType.Limit, 3);
        bytes32 id = _post(o);
        vm.prank(filler);
        desk.fill(id);
        assertEq(usdc.balanceOf(address(desk)), 50_000e6 + 3000e6);
    }

    // ------------------------------------------------------------------ stops

    function test_stopNotTriggered() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 0, 2500e6, LimitDesk.OrderType.Stop, 4);
        bytes32 id = _post(o);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.StopNotTriggered.selector, WETH_USDC_3000, uint256(2500e6)));
        desk.fill(id);
    }

    function test_marketStopFillsAtOracle() public {
        ethFeed.setAnswer(2400e8);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 0, 2500e6, LimitDesk.OrderType.Stop, 5);
        bytes32 id = _post(o);
        vm.prank(filler);
        desk.fill(id);
        assertEq(usdc.balanceOf(address(desk)), 50_000e6 + 2400e6);
    }

    function test_stopLimitFillsAtLimitWhenInBand() public {
        ethFeed.setAnswer(2450e8);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2400e6, 2500e6, LimitDesk.OrderType.Stop, 6);
        bytes32 id = _post(o);
        vm.prank(filler);
        desk.fill(id);
        // fill at the signed limit, not the oracle
        assertEq(usdc.balanceOf(address(desk)), 50_000e6 + 2400e6);
    }

    function test_stopLimitRejectedWhenOracleBelowLimit() public {
        ethFeed.setAnswer(2300e8);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2400e6, 2500e6, LimitDesk.OrderType.Stop, 7);
        bytes32 id = _post(o);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.LimitNotMet.selector, uint256(2300e6), uint256(2400e6)));
        desk.fill(id);
    }

    function test_invalidStopLimitWhenLimitAboveTrigger() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2600e6, 2500e6, LimitDesk.OrderType.Stop, 8);
        bytes memory sig = _sign(o);
        vm.expectRevert(LimitDesk.InvalidOrder.selector);
        desk.post(o, sig);
    }

    // ------------------------------------------------------------------ replay / cancel / revoke

    function test_noReplaySameNonce() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 10);
        _post(o);
        bytes memory sig = _sign(o);
        vm.expectRevert(LimitDesk.NonceUsed.selector);
        desk.post(o, sig);
    }

    function test_noReplayFill() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 11);
        bytes32 id = _post(o);
        vm.prank(filler);
        desk.fill(id);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.OrderNotOpen.selector);
        desk.fill(id);
    }

    function testFuzz_noReplay(uint256 nonce) public {
        nonce = bound(nonce, 1, type(uint256).max);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 0.01 ether, 2900e6, 0, LimitDesk.OrderType.Limit, nonce);
        bytes32 id = _post(o);
        vm.prank(filler);
        desk.fill(id);
        bytes memory sig = _sign(o);
        vm.expectRevert(LimitDesk.NonceUsed.selector);
        desk.post(o, sig);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.OrderNotOpen.selector);
        desk.fill(id);
    }

    function test_cancelByOwnerUnlocks() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 12);
        bytes32 id = _post(o);
        assertEq(desk.available(address(weth)), 9 ether);
        vm.prank(owner);
        desk.cancel(id);
        assertEq(desk.available(address(weth)), 10 ether);
        assertEq(desk.totalLocked(address(weth)), 0);
        assertEq(desk.openOrders().length, 0);
    }

    function test_cancelByAgent() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 13);
        bytes32 id = _post(o);
        vm.prank(agent);
        desk.cancel(id);
        assertEq(uint256(desk.getOrder(id).status), uint256(LimitDesk.Status.Cancelled));
    }

    function test_strangerCannotCancel() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 14);
        bytes32 id = _post(o);
        vm.prank(stranger);
        vm.expectRevert(LimitDesk.NotOwnerOrAgent.selector);
        desk.cancel(id);
    }

    function test_revokeCancelsOpenOrdersAndBlocksFill() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 15);
        bytes32 id = _post(o);
        vm.prank(owner);
        desk.revokeAgent(agent);
        assertEq(uint256(desk.getOrder(id).status), uint256(LimitDesk.Status.Cancelled));
        assertEq(desk.available(address(weth)), 10 ether);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.OrderNotOpen.selector);
        desk.fill(id);
        // old signature cannot be posted under the new epoch
        bytes memory sig = _sign(o);
        vm.expectRevert(LimitDesk.NotAgent.selector);
        desk.post(o, sig);
    }

    function test_regrantDoesNotReviveOldSignature() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 16);
        bytes memory sig = _sign(o);
        vm.prank(owner);
        desk.revokeAgent(agent);
        vm.startPrank(owner);
        desk.grantAgent(agent, uint64(block.timestamp + 30 days));
        desk.setCap(agent, address(weth), 5 ether);
        vm.stopPrank();
        vm.expectRevert(LimitDesk.EpochMismatch.selector);
        desk.post(o, sig);
    }

    // ------------------------------------------------------------------ caps, escrow, pause, expiry

    function test_capExceeded() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 5.1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 17);
        bytes memory sig = _sign(o);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.CapExceeded.selector, 5.1 ether, 5 ether));
        desk.post(o, sig);
    }

    function test_insufficientEscrow() public {
        vm.prank(owner);
        desk.setCap(agent, address(weth), 100 ether);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 11 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 18);
        bytes memory sig = _sign(o);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.InsufficientEscrow.selector, 10 ether, 11 ether));
        desk.post(o, sig);
    }

    function test_withdrawCannotTakeLocked() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 3 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 19);
        _post(o);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LimitDesk.InsufficientEscrow.selector, 7 ether, 8 ether));
        desk.withdraw(address(weth), owner, 8 ether);
        vm.prank(owner);
        desk.withdraw(address(weth), owner, 7 ether);
        assertEq(desk.available(address(weth)), 0);
        assertEq(desk.totalLocked(address(weth)), 3 ether);
    }

    function test_pauseBlocksPostAndFillButNotCancelOrWithdraw() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 20);
        bytes32 id = _post(o);
        vm.prank(owner);
        desk.pause();
        LimitDesk.Order memory o2 =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 21);
        bytes memory sig2 = _sign(o2);
        vm.expectRevert();
        desk.post(o2, sig2);
        vm.prank(filler);
        vm.expectRevert();
        desk.fill(id);
        vm.prank(owner);
        desk.cancel(id);
        vm.prank(owner);
        desk.withdraw(address(usdc), owner, 1000e6);
    }

    function test_expiredOrderCannotPostOrFill() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 22);
        o.expiry = uint64(block.timestamp + 10);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + 11);
        ethFeed.setAnswer(3000e8);
        usdcFeed.setAnswer(1e8);
        vm.expectRevert(LimitDesk.OrderExpired.selector);
        desk.post(o, sig);
    }

    function test_fillRevertsAfterExpiry() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 23);
        o.expiry = uint64(block.timestamp + 60);
        bytes32 id;
        {
            bytes memory sig = _sign(o);
            id = desk.hashOrder(o);
            desk.post(o, sig);
        }
        vm.warp(block.timestamp + 61);
        ethFeed.setAnswer(3000e8);
        usdcFeed.setAnswer(1e8);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.OrderExpired.selector);
        desk.fill(id);
    }

    function test_badSignatureReverts() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 24);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, desk.hashOrder(o));
        vm.expectRevert(LimitDesk.InvalidSignature.selector);
        desk.post(o, abi.encodePacked(r, s, v));
    }

    function test_staleOracleRevertsOnFill() public {
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 25);
        bytes32 id = _post(o);
        ethFeed.setUpdatedAt(block.timestamp - 3 hours);
        vm.prank(filler);
        vm.expectRevert(LimitDesk.StaleOracle.selector);
        desk.fill(id);
    }

    function test_usdcToWethLimitFill() public {
        uint256 px = desk.oraclePriceX18(address(usdc), address(weth));
        LimitDesk.Order memory o =
            _order(address(usdc), address(weth), 3000e6, px, 0, LimitDesk.OrderType.Limit, 26);
        bytes32 id = _post(o);
        uint256 weth0 = weth.balanceOf(address(desk));
        uint256 paid = 3000e6 * px / 1e18;
        vm.prank(filler);
        desk.fill(id);
        assertEq(weth.balanceOf(address(desk)), weth0 + paid);
        assertEq(usdc.balanceOf(filler), 1_000_000e6 + 3000e6);
        assertGt(paid, 0.99 ether);
        assertLe(paid, 1 ether);
    }

    function testFuzz_escrowConservedOnLimitFill(uint256 amtWei) public {
        amtWei = bound(amtWei, 1e15, 5 ether); // 0.001 to 5 WETH
        // use a marketable limit (2900 <= 3000)
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), amtWei, 2900e6, 0, LimitDesk.OrderType.Limit, amtWei);
        uint256 weth0 = weth.balanceOf(address(desk));
        uint256 usdc0 = usdc.balanceOf(address(desk));
        uint256 locked0 = desk.totalLocked(address(weth));
        bytes32 id = _post(o);
        assertEq(desk.totalLocked(address(weth)), locked0 + amtWei);
        assertEq(weth.balanceOf(address(desk)), desk.available(address(weth)) + desk.totalLocked(address(weth)));
        vm.prank(filler);
        desk.fill(id);
        uint256 paid = amtWei * 2900e6 / 1e18;
        assertEq(weth.balanceOf(address(desk)), weth0 - amtWei);
        assertEq(usdc.balanceOf(address(desk)), usdc0 + paid);
        assertEq(weth.balanceOf(address(desk)), desk.available(address(weth)) + desk.totalLocked(address(weth)));
        assertEq(usdc.balanceOf(address(desk)), desk.available(address(usdc)) + desk.totalLocked(address(usdc)));
    }

    function test_invalidateNonceBlocksPost() public {
        vm.prank(owner);
        desk.invalidateNonce(agent, 99);
        LimitDesk.Order memory o =
            _order(address(weth), address(usdc), 1 ether, 2900e6, 0, LimitDesk.OrderType.Limit, 99);
        bytes memory sig = _sign(o);
        vm.expectRevert(LimitDesk.NonceUsed.selector);
        desk.post(o, sig);
    }
}
