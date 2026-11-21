// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LimitDesk} from "../src/LimitDesk.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MockAggregator} from "../src/MockAggregator.sol";

/// @dev Random posts, fills, cancels, withdraws and oracle moves. Ghost vars track escrow.
contract Handler is Test {
    LimitDesk public desk;
    MockUSDC public usdc;
    MockWETH public weth;
    MockAggregator public ethFeed;
    address public owner;
    uint256 public agentKey;
    address public agent;
    address public filler;

    uint256 public ghostDepositedWeth;
    uint256 public ghostDepositedUsdc;
    uint256 public ghostWithdrawnWeth;
    uint256 public ghostWithdrawnUsdc;
    uint256 public ghostSoldWeth;
    uint256 public ghostSoldUsdc;
    uint256 public ghostBoughtWeth;
    uint256 public ghostBoughtUsdc;
    uint256 public ghostFillsBelowLimit;
    uint256 public nonceCursor = 1;
    uint256 public calls;

    constructor(
        LimitDesk desk_,
        MockUSDC usdc_,
        MockWETH weth_,
        MockAggregator ethFeed_,
        address owner_,
        uint256 agentKey_,
        address filler_
    ) {
        desk = desk_;
        usdc = usdc_;
        weth = weth_;
        ethFeed = ethFeed_;
        owner = owner_;
        agentKey = agentKey_;
        agent = vm.addr(agentKey_);
        filler = filler_;
    }

    function _sign(LimitDesk.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentKey, desk.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    function depositWeth(uint256 amt) external {
        amt = bound(amt, 1, 5 ether);
        weth.mint(owner, amt);
        vm.startPrank(owner);
        weth.approve(address(desk), amt);
        desk.deposit(address(weth), amt);
        vm.stopPrank();
        ghostDepositedWeth += amt;
        calls++;
    }

    function depositUsdc(uint256 amt) external {
        amt = bound(amt, 1e6, 20_000e6);
        usdc.mint(owner, amt);
        vm.startPrank(owner);
        usdc.approve(address(desk), amt);
        desk.deposit(address(usdc), amt);
        vm.stopPrank();
        ghostDepositedUsdc += amt;
        calls++;
    }

    function withdraw(uint256 amt, bool useWeth) external {
        address token = useWeth ? address(weth) : address(usdc);
        uint256 avail = desk.available(token);
        if (avail == 0) return;
        amt = bound(amt, 1, avail);
        uint256 before = _bal(token, owner);
        vm.prank(owner);
        try desk.withdraw(token, owner, amt) {
            if (useWeth) ghostWithdrawnWeth += _bal(token, owner) - before;
            else ghostWithdrawnUsdc += _bal(token, owner) - before;
        } catch {}
        calls++;
    }

    function postLimitWeth(uint256 amt, uint256 limit) external {
        uint256 avail = desk.available(address(weth));
        uint256 cap = desk.capOf(agent, address(weth));
        uint256 open = desk.openSellOf(agent, address(weth));
        uint256 room = cap > open ? cap - open : 0;
        if (avail == 0 || room == 0) return;
        uint256 maxAmt = avail < room ? avail : room;
        if (maxAmt < 1e15) return;
        amt = bound(amt, 1e15, maxAmt);
        limit = bound(limit, 1000e6, 5000e6);
        (,, uint32 epoch) = desk.agents(agent);
        LimitDesk.Order memory o = LimitDesk.Order({
            agent: agent,
            tokenSell: address(weth),
            tokenBuy: address(usdc),
            amountSell: amt,
            limitPriceX18: limit,
            stopTriggerX18: 0,
            expiry: uint64(block.timestamp + 2 days),
            nonce: nonceCursor++,
            orderType: LimitDesk.OrderType.Limit,
            epoch: epoch
        });
        try desk.post(o, _sign(o)) {} catch {}
        calls++;
    }

    function fillFirst(uint256) external {
        bytes32[] memory ids = desk.openOrders();
        if (ids.length == 0) return;
        bytes32 id = ids[0];
        LimitDesk.PostedOrder memory po = desk.getOrder(id);
        uint256 oraclePx;
        try desk.oraclePriceX18(po.order.tokenSell, po.order.tokenBuy) returns (uint256 px) {
            oraclePx = px;
        } catch {
            return;
        }
        bool below = po.order.orderType == LimitDesk.OrderType.Limit && oraclePx < po.order.limitPriceX18;
        uint256 sellBefore = _bal(po.order.tokenSell, filler);
        uint256 buyBefore = _bal(po.order.tokenBuy, address(desk));
        // keep filler funded
        if (po.order.tokenBuy == address(usdc)) usdc.mint(filler, 1_000_000e6);
        else weth.mint(filler, 50 ether);
        vm.startPrank(filler);
        usdc.approve(address(desk), type(uint256).max);
        weth.approve(address(desk), type(uint256).max);
        try desk.fill(id) {
            if (below) ghostFillsBelowLimit++;
            uint256 sold = _bal(po.order.tokenSell, filler) - sellBefore;
            uint256 bought = _bal(po.order.tokenBuy, address(desk)) - buyBefore;
            if (po.order.tokenSell == address(weth)) {
                ghostSoldWeth += sold;
                ghostBoughtUsdc += bought;
            } else {
                ghostSoldUsdc += sold;
                ghostBoughtWeth += bought;
            }
        } catch {}
        vm.stopPrank();
        calls++;
    }

    function cancelFirst(uint256) external {
        bytes32[] memory ids = desk.openOrders();
        if (ids.length == 0) return;
        vm.prank(owner);
        try desk.cancel(ids[0]) {} catch {}
        calls++;
    }

    function moveOracle(int256 px) external {
        int256 next = int256(bound(uint256(px < 0 ? -px : px), 1500e8, 4500e8));
        ethFeed.setAnswer(next);
        calls++;
    }

    function revokeAndRegrant(bool regrant) external {
        vm.startPrank(owner);
        desk.revokeAgent(agent);
        if (regrant) {
            desk.grantAgent(agent, uint64(block.timestamp + 365 days));
            desk.setCap(agent, address(weth), 50 ether);
            desk.setCap(agent, address(usdc), 200_000e6);
        }
        vm.stopPrank();
        calls++;
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == address(weth) ? weth.balanceOf(who) : usdc.balanceOf(who);
    }
}

contract LimitDeskInvariantTest is Test {
    LimitDesk desk;
    MockUSDC usdc;
    MockWETH weth;
    MockAggregator ethFeed;
    MockAggregator usdcFeed;
    Handler handler;
    address owner = makeAddr("owner");
    uint256 agentKey = 0xA11CE;
    address filler = makeAddr("filler");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        weth = new MockWETH();
        ethFeed = new MockAggregator(8, 3000e8);
        usdcFeed = new MockAggregator(8, 1e8);
        desk = new LimitDesk(owner, address(weth), address(usdc), address(ethFeed), address(usdcFeed));

        weth.mint(owner, 20 ether);
        usdc.mint(owner, 100_000e6);
        vm.startPrank(owner);
        weth.approve(address(desk), type(uint256).max);
        usdc.approve(address(desk), type(uint256).max);
        desk.deposit(address(weth), 20 ether);
        desk.deposit(address(usdc), 100_000e6);
        desk.grantAgent(vm.addr(agentKey), uint64(block.timestamp + 365 days));
        desk.setCap(vm.addr(agentKey), address(weth), 50 ether);
        desk.setCap(vm.addr(agentKey), address(usdc), 200_000e6);
        vm.stopPrank();

        handler = new Handler(desk, usdc, weth, ethFeed, owner, agentKey, filler);

        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](8);
        sels[0] = Handler.depositWeth.selector;
        sels[1] = Handler.depositUsdc.selector;
        sels[2] = Handler.withdraw.selector;
        sels[3] = Handler.postLimitWeth.selector;
        sels[4] = Handler.fillFirst.selector;
        sels[5] = Handler.cancelFirst.selector;
        sels[6] = Handler.moveOracle.selector;
        sels[7] = Handler.revokeAndRegrant.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    function invariant_escrowEqualsAvailablePlusLocked() public view {
        assertEq(weth.balanceOf(address(desk)), desk.available(address(weth)) + desk.totalLocked(address(weth)));
        assertEq(usdc.balanceOf(address(desk)), desk.available(address(usdc)) + desk.totalLocked(address(usdc)));
    }

    function invariant_lockedEqualsSumOfOpenOrders() public view {
        bytes32[] memory ids = desk.openOrders();
        uint256 w;
        uint256 u;
        for (uint256 i; i < ids.length; i++) {
            LimitDesk.PostedOrder memory po = desk.getOrder(ids[i]);
            assertEq(uint256(po.status), uint256(LimitDesk.Status.Open));
            if (po.order.tokenSell == address(weth)) w += po.order.amountSell;
            else u += po.order.amountSell;
        }
        assertEq(desk.totalLocked(address(weth)), w);
        assertEq(desk.totalLocked(address(usdc)), u);
    }

    function invariant_conservation() public view {
        // desk weth = initial 20 + deposits + bought - withdrawn - sold
        uint256 expectedWeth = 20 ether + handler.ghostDepositedWeth() + handler.ghostBoughtWeth()
            - handler.ghostWithdrawnWeth() - handler.ghostSoldWeth();
        uint256 expectedUsdc = 100_000e6 + handler.ghostDepositedUsdc() + handler.ghostBoughtUsdc()
            - handler.ghostWithdrawnUsdc() - handler.ghostSoldUsdc();
        assertEq(weth.balanceOf(address(desk)), expectedWeth);
        assertEq(usdc.balanceOf(address(desk)), expectedUsdc);
    }

    function invariant_noFillBelowLimit() public view {
        assertEq(handler.ghostFillsBelowLimit(), 0);
    }
}
