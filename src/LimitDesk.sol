// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title LimitDesk
/// @notice Per-owner self-custodial book: the owner escrows WETH/USDC, an authorized agent
///         signs EIP-712 limit or stop orders within caps, and anyone may fill if the
///         Chainlink price condition and expiry still hold. One full-fill path only.
/// @dev    PROTOTYPE - NOT AUDITED. WETH and USDC only. No native ETH. No partial fills.
contract LimitDesk is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    enum OrderType {
        Limit,
        Stop
    }

    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Order {
        address agent;
        address tokenSell;
        address tokenBuy;
        uint256 amountSell;
        uint256 limitPriceX18; // tokenBuy native units per 1e18 tokenSell
        uint256 stopTriggerX18; // 0 for a pure limit
        uint64 expiry;
        uint256 nonce;
        OrderType orderType;
        uint32 epoch; // must match the agent's current epoch
    }

    struct PostedOrder {
        Order order;
        Status status;
    }

    struct Agent {
        bool active;
        uint64 expiry;
        uint32 epoch;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address agent,address tokenSell,address tokenBuy,uint256 amountSell,uint256 limitPriceX18,uint256 stopTriggerX18,uint64 expiry,uint256 nonce,uint8 orderType,uint32 epoch)"
    );

    uint256 public constant MAX_OPEN_PER_AGENT = 32;
    uint256 public constant ETH_HEARTBEAT = 2 hours;
    uint256 public constant STABLE_HEARTBEAT = 25 hours;
    /// @notice Rolling window for the per-agent cap: open + filled sell volume per token per day.
    uint256 public constant CAP_WINDOW = 1 days;
    /// @notice Owner can allow fillers at most this discount to the oracle (10%).
    uint16 public constant MAX_FILL_DISCOUNT_BPS = 1_000;
    uint16 public constant BPS = 10_000;
    /// @notice Chainlink L2 sequencer uptime feed on Base; set only when deployed on chain 8453.
    address public constant BASE_SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 public constant SEQUENCER_GRACE = 1 hours;

    address public immutable weth;
    address public immutable usdc;
    address public immutable ethUsdFeed;
    address public immutable usdcUsdFeed;
    /// @notice address(0) on chains without a sequencer (Ethereum, anvil).
    address public immutable sequencerFeed;

    /// @notice Fills never price below oracle * (1 - fillDiscountBps). Default 1%.
    uint16 public fillDiscountBps = 100;

    mapping(address agent => Agent) public agents;
    /// @dev sell-token cap for the current epoch; agent cannot have more than this locked
    mapping(bytes32 key => uint256) internal _caps;
    /// @dev currently locked sell amount for (agent, epoch, token)
    mapping(bytes32 key => uint256) internal _openSell;
    mapping(bytes32 nonceKey => bool) internal _nonceUsed; // keyed with agent+nonce

    mapping(bytes32 orderId => PostedOrder) internal _orders;
    bytes32[] internal _openIds;
    mapping(bytes32 orderId => uint256) internal _openPos; // 1-based index into _openIds
    mapping(address agent => bytes32[]) internal _openByAgent;
    mapping(bytes32 orderId => uint256) internal _openByAgentPos; // 1-based
    mapping(address token => uint256) public totalLocked;
    /// @dev sell volume filled in the current cap window for (agent, epoch, token)
    mapping(bytes32 key => uint256) internal _filledInWindow;
    mapping(bytes32 key => uint64) internal _windowStart;

    event Deposited(address indexed from, address indexed token, uint256 amount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event AgentGranted(address indexed agent, uint64 expiry, uint32 epoch);
    event AgentRevoked(address indexed agent, address indexed by, uint32 newEpoch);
    event CapSet(address indexed agent, address indexed token, uint256 maxOpenSell);
    event FillDiscountSet(uint16 bps);
    event NonceInvalidated(address indexed agent, uint256 nonce);
    event OrderPosted(bytes32 indexed orderId, address indexed agent, address tokenSell, address tokenBuy, uint256 amountSell);
    event OrderCancelled(bytes32 indexed orderId, address indexed by);
    event OrderFilled(bytes32 indexed orderId, address indexed filler, uint256 amountSell, uint256 amountBuy, uint256 fillPriceX18);

    error NotAgent();
    error AgentExpired();
    error InvalidExpiry();
    error InvalidOrder();
    error InvalidPair();
    error InvalidSignature();
    error NonceUsed();
    error OrderNotOpen();
    error OrderExpired();
    error EpochMismatch();
    error CapExceeded(uint256 wouldLock, uint256 cap);
    error NoCap();
    error InsufficientEscrow(uint256 available_, uint256 needed);
    error TooManyOpenOrders();
    error LimitNotMet(uint256 oraclePriceX18, uint256 limitPriceX18);
    error StopNotTriggered(uint256 oraclePriceX18, uint256 stopTriggerX18);
    error StaleOracle();
    error BadOracle();
    error ZeroAddress();
    error ZeroAmount();
    error NotOwnerOrAgent();
    error AlreadyUsed();
    error InvalidDiscount();
    error SequencerDown();
    error SequencerGracePeriod();

    constructor(address initialOwner, address weth_, address usdc_, address ethUsdFeed_, address usdcUsdFeed_)
        Ownable(initialOwner)
        EIP712("LimitDesk", "1")
    {
        if (initialOwner == address(0) || weth_ == address(0) || usdc_ == address(0) || ethUsdFeed_ == address(0)
            || usdcUsdFeed_ == address(0)) revert ZeroAddress();
        if (weth_ == usdc_) revert InvalidPair();
        weth = weth_;
        usdc = usdc_;
        ethUsdFeed = ethUsdFeed_;
        usdcUsdFeed = usdcUsdFeed_;
        sequencerFeed = block.chainid == 8453 ? BASE_SEQUENCER_FEED : address(0);
    }

    // ------------------------------------------------------------------ funding

    function deposit(address token, uint256 amount) external nonReentrant {
        _onlyPair(token);
        if (amount == 0) revert ZeroAmount();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, token, IERC20(token).balanceOf(address(this)) - before);
    }

    /// @notice Owner withdraws unlocked escrow (and any fill proceeds). Works while paused.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _onlyPair(token);
        uint256 avail = available(token);
        if (amount == 0) revert ZeroAmount();
        if (amount > avail) revert InsufficientEscrow(avail, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(to, token, amount);
    }

    // ------------------------------------------------------------------ admin

    function grantAgent(address agent, uint64 expiry) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        Agent storage a = agents[agent];
        a.active = true;
        a.expiry = expiry;
        emit AgentGranted(agent, expiry, a.epoch);
    }

    /// @notice Max discount to the Chainlink price a filler may receive (bounds filler surplus).
    function setFillDiscountBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FILL_DISCOUNT_BPS) revert InvalidDiscount();
        fillDiscountBps = bps;
        emit FillDiscountSet(bps);
    }

    function setCap(address agent, address token, uint256 maxOpenSell) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        _onlyPair(token);
        _caps[_key(agent, agents[agent].epoch, token)] = maxOpenSell;
        emit CapSet(agent, token, maxOpenSell);
    }

    /// @notice Kill switch: cancels every open order for the agent and bumps its epoch so
    ///         outstanding signatures cannot be posted.
    function revokeAgent(address agent) external onlyOwner {
        _revoke(agent);
    }

    function renounceAgent() external {
        if (!agents[msg.sender].active) revert NotAgent();
        _revoke(msg.sender);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function invalidateNonce(address agent, uint256 nonce) external {
        if (msg.sender != owner() && msg.sender != agent) revert NotOwnerOrAgent();
        bytes32 nkey = _nonceKey(agent, nonce);
        if (_nonceUsed[nkey]) revert AlreadyUsed();
        _nonceUsed[nkey] = true;
        emit NonceInvalidated(agent, nonce);
    }

    // ------------------------------------------------------------------ book

    /// @notice Register a signed order and lock `amountSell` from the owner's escrow.
    ///         Anyone with a valid agent signature may post.
    function post(Order calldata order, bytes calldata signature) external whenNotPaused nonReentrant returns (bytes32 orderId) {
        Agent memory a = agents[order.agent];
        if (!a.active) revert NotAgent();
        if (block.timestamp >= a.expiry) revert AgentExpired();
        if (order.epoch != a.epoch) revert EpochMismatch();
        if (order.expiry <= block.timestamp) revert OrderExpired();
        if (order.amountSell == 0) revert ZeroAmount();
        _validPair(order.tokenSell, order.tokenBuy);
        _validatePrices(order);

        bytes32 nkey = _nonceKey(order.agent, order.nonce);
        if (_nonceUsed[nkey]) revert NonceUsed();

        orderId = _hashOrder(order);
        if (!SignatureChecker.isValidSignatureNow(order.agent, orderId, signature)) revert InvalidSignature();
        if (_orders[orderId].status != Status.None) revert AlreadyUsed();

        bytes32 ck = _key(order.agent, a.epoch, order.tokenSell);
        uint256 cap = _caps[ck];
        if (cap == 0) revert NoCap();
        uint256 would = _openSell[ck] + order.amountSell;
        uint256 used = would + _rollWindow(ck);
        if (used > cap) revert CapExceeded(used, cap);

        uint256 avail = available(order.tokenSell);
        if (order.amountSell > avail) revert InsufficientEscrow(avail, order.amountSell);
        if (_openByAgent[order.agent].length >= MAX_OPEN_PER_AGENT) revert TooManyOpenOrders();

        _nonceUsed[nkey] = true;
        _openSell[ck] = would;
        totalLocked[order.tokenSell] += order.amountSell;

        _orders[orderId] = PostedOrder({order: order, status: Status.Open});
        _pushOpen(_openIds, _openPos, orderId);
        _pushOpen(_openByAgent[order.agent], _openByAgentPos, orderId);

        emit OrderPosted(orderId, order.agent, order.tokenSell, order.tokenBuy, order.amountSell);
    }

    /// @notice Single fill path: full fill only. Filler pays tokenBuy and receives tokenSell.
    ///         Limit orders fill if the oracle price is at or better than the signed limit, at
    ///         max(limit, oracle * (1 - fillDiscountBps)). Stop orders fill once the oracle is at
    ///         or below the trigger; with a limit the oracle must stay at or above it and the
    ///         same bounded price applies, otherwise the fill is at the oracle price.
    ///         Filled volume counts against the agent's cap for CAP_WINDOW.
    function fill(bytes32 orderId) external whenNotPaused nonReentrant {
        PostedOrder storage po = _orders[orderId];
        if (po.status != Status.Open) revert OrderNotOpen();
        Order memory o = po.order;
        if (block.timestamp >= o.expiry) revert OrderExpired();

        Agent memory a = agents[o.agent];
        if (!a.active || a.epoch != o.epoch) revert NotAgent();
        if (block.timestamp >= a.expiry) revert AgentExpired();

        uint256 oraclePx = oraclePriceX18(o.tokenSell, o.tokenBuy);
        uint256 fillPx = _fillPrice(o, oraclePx);

        uint256 amountBuy = Math.mulDiv(o.amountSell, fillPx, 1e18);
        if (amountBuy == 0) revert ZeroAmount();

        po.status = Status.Filled;
        _unlock(o);
        bytes32 fk = _key(o.agent, o.epoch, o.tokenSell);
        _filledInWindow[fk] = _rollWindow(fk) + o.amountSell;
        _popOpen(_openIds, _openPos, orderId);
        _popOpen(_openByAgent[o.agent], _openByAgentPos, orderId);

        emit OrderFilled(orderId, msg.sender, o.amountSell, amountBuy, fillPx);

        IERC20(o.tokenBuy).safeTransferFrom(msg.sender, address(this), amountBuy);
        IERC20(o.tokenSell).safeTransfer(msg.sender, o.amountSell);
    }

    function cancel(bytes32 orderId) external nonReentrant {
        PostedOrder storage po = _orders[orderId];
        if (po.status != Status.Open) revert OrderNotOpen();
        if (msg.sender != owner() && msg.sender != po.order.agent) revert NotOwnerOrAgent();
        po.status = Status.Cancelled;
        _unlock(po.order);
        _popOpen(_openIds, _openPos, orderId);
        _popOpen(_openByAgent[po.order.agent], _openByAgentPos, orderId);
        emit OrderCancelled(orderId, msg.sender);
    }

    // ------------------------------------------------------------------ views

    function available(address token) public view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 locked_ = totalLocked[token];
        return bal > locked_ ? bal - locked_ : 0;
    }

    /// @notice Sell volume already filled in the current cap window (counts against the cap).
    function filledInWindowOf(address agent, address token) external view returns (uint256) {
        bytes32 k = _key(agent, agents[agent].epoch, token);
        if (block.timestamp >= uint256(_windowStart[k]) + CAP_WINDOW) return 0;
        return _filledInWindow[k];
    }

    function capOf(address agent, address token) external view returns (uint256) {
        return _caps[_key(agent, agents[agent].epoch, token)];
    }

    function openSellOf(address agent, address token) external view returns (uint256) {
        return _openSell[_key(agent, agents[agent].epoch, token)];
    }

    function nonceUsed(address agent, uint256 nonce) external view returns (bool) {
        return _nonceUsed[_nonceKey(agent, nonce)];
    }

    function getOrder(bytes32 orderId) external view returns (PostedOrder memory) {
        return _orders[orderId];
    }

    function openOrders() external view returns (bytes32[] memory) {
        return _openIds;
    }

    function openOrdersOf(address agent) external view returns (bytes32[] memory) {
        return _openByAgent[agent];
    }

    function hashOrder(Order calldata order) external view returns (bytes32) {
        return _hashOrder(order);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice tokenBuy native units per 1e18 tokenSell, from the Chainlink USD feeds.
    function oraclePriceX18(address tokenSell, address tokenBuy) public view returns (uint256) {
        _validPair(tokenSell, tokenBuy);
        _checkSequencer();
        (uint256 sellUsd, uint8 sellTokDec, uint8 sellFeedDec) = _usd(tokenSell);
        (uint256 buyUsd, uint8 buyTokDec, uint8 buyFeedDec) = _usd(tokenBuy);
        // Multiply first so early division cannot drop precision (USDC 6dp vs WETH 18dp).
        uint256 numScale = 10 ** (uint256(buyTokDec) + uint256(buyFeedDec));
        uint256 denScale = 10 ** (uint256(sellTokDec) + uint256(sellFeedDec));
        return Math.mulDiv(Math.mulDiv(sellUsd, 1e18, 1), numScale, Math.mulDiv(buyUsd, denScale, 1));
    }

    /// @notice Preview a fill. `ok` is false if the order cannot be filled right now.
    function quoteFill(bytes32 orderId)
        external
        view
        returns (bool ok, uint256 amountBuy, uint256 fillPrice, uint256 oraclePx)
    {
        PostedOrder storage po = _orders[orderId];
        if (po.status != Status.Open) return (false, 0, 0, 0);
        Order memory o = po.order;
        if (block.timestamp >= o.expiry) return (false, 0, 0, 0);
        Agent memory a = agents[o.agent];
        if (!a.active || a.epoch != o.epoch || block.timestamp >= a.expiry) return (false, 0, 0, 0);
        oraclePx = oraclePriceX18(o.tokenSell, o.tokenBuy);
        if (!_conditionMet(o, oraclePx)) return (false, 0, 0, oraclePx);
        fillPrice = _boundedPrice(o, oraclePx);
        amountBuy = Math.mulDiv(o.amountSell, fillPrice, 1e18);
        ok = amountBuy > 0;
    }

    // ------------------------------------------------------------------ internal

    function _fillPrice(Order memory o, uint256 oraclePx) internal view returns (uint256 fillPx) {
        if (!_conditionMet(o, oraclePx)) {
            if (o.orderType == OrderType.Limit || o.limitPriceX18 > 0) {
                revert LimitNotMet(oraclePx, o.limitPriceX18);
            }
            revert StopNotTriggered(oraclePx, o.stopTriggerX18);
        }
        return _boundedPrice(o, oraclePx);
    }

    /// @dev Limit / stop-limit fill at max(limit, oracle * (1 - fillDiscountBps)); market stops at the oracle.
    ///      Audit 2026-11-23 H-01: an unbounded signed limit let a filler take the whole surplus.
    function _boundedPrice(Order memory o, uint256 oraclePx) internal view returns (uint256) {
        if (o.orderType == OrderType.Limit || o.limitPriceX18 > 0) {
            uint256 floor_ = Math.mulDiv(oraclePx, BPS - fillDiscountBps, BPS);
            return o.limitPriceX18 > floor_ ? o.limitPriceX18 : floor_;
        }
        return oraclePx;
    }

    /// @dev Returns filled volume in the current window, resetting it once the window has elapsed.
    function _rollWindow(bytes32 k) internal returns (uint256) {
        if (block.timestamp >= uint256(_windowStart[k]) + CAP_WINDOW) {
            _windowStart[k] = uint64(block.timestamp);
            _filledInWindow[k] = 0;
            return 0;
        }
        return _filledInWindow[k];
    }

    /// @dev Audit 2026-11-23 M-01: refuse prices while the L2 sequencer is down or just restarted.
    function _checkSequencer() internal view {
        address f = sequencerFeed;
        if (f == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(f).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || block.timestamp - startedAt <= SEQUENCER_GRACE) revert SequencerGracePeriod();
    }

    function _conditionMet(Order memory o, uint256 oraclePx) internal pure returns (bool) {
        if (o.orderType == OrderType.Limit) {
            return oraclePx >= o.limitPriceX18;
        }
        if (oraclePx > o.stopTriggerX18) return false;
        if (o.limitPriceX18 > 0 && oraclePx < o.limitPriceX18) return false;
        return true;
    }

    function _validatePrices(Order calldata o) internal pure {
        if (o.orderType == OrderType.Limit) {
            if (o.limitPriceX18 == 0 || o.stopTriggerX18 != 0) revert InvalidOrder();
        } else if (o.orderType == OrderType.Stop) {
            if (o.stopTriggerX18 == 0) revert InvalidOrder();
            if (o.limitPriceX18 > o.stopTriggerX18) revert InvalidOrder();
        } else {
            revert InvalidOrder();
        }
    }

    function _usd(address token) internal view returns (uint256 usd, uint8 tokDec, uint8 feedDec) {
        address feed = token == weth ? ethUsdFeed : usdcUsdFeed;
        uint256 heartbeat = token == weth ? ETH_HEARTBEAT : STABLE_HEARTBEAT;
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0 || answeredInRound < roundId || updatedAt == 0) revert BadOracle();
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > heartbeat) revert StaleOracle();
        usd = uint256(answer);
        tokDec = IERC20Metadata(token).decimals();
        feedDec = AggregatorV3Interface(feed).decimals();
    }

    function _hashOrder(Order memory o) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    o.agent,
                    o.tokenSell,
                    o.tokenBuy,
                    o.amountSell,
                    o.limitPriceX18,
                    o.stopTriggerX18,
                    o.expiry,
                    o.nonce,
                    o.orderType,
                    o.epoch
                )
            )
        );
    }

    function _unlock(Order memory o) internal {
        bytes32 k = _key(o.agent, o.epoch, o.tokenSell);
        _openSell[k] -= o.amountSell;
        totalLocked[o.tokenSell] -= o.amountSell;
    }

    function _revoke(address agent) internal {
        Agent storage a = agents[agent];
        bytes32[] memory ids = _openByAgent[agent];
        uint256 n = ids.length;
        for (uint256 i; i < n; i++) {
            bytes32 id = ids[i];
            PostedOrder storage po = _orders[id];
            if (po.status == Status.Open) {
                po.status = Status.Cancelled;
                _unlock(po.order);
                _popOpen(_openIds, _openPos, id);
                emit OrderCancelled(id, msg.sender);
            }
            delete _openByAgentPos[id];
        }
        delete _openByAgent[agent];
        a.active = false;
        a.expiry = 0;
        unchecked {
            a.epoch += 1;
        }
        emit AgentRevoked(agent, msg.sender, a.epoch);
    }

    function _pushOpen(bytes32[] storage arr, mapping(bytes32 => uint256) storage pos, bytes32 id) internal {
        arr.push(id);
        pos[id] = arr.length;
    }

    function _popOpen(bytes32[] storage arr, mapping(bytes32 => uint256) storage pos, bytes32 id) internal {
        uint256 i = pos[id];
        if (i == 0) return;
        uint256 idx = i - 1;
        bytes32 last = arr[arr.length - 1];
        arr[idx] = last;
        pos[last] = i;
        arr.pop();
        delete pos[id];
    }

    function _onlyPair(address token) internal view {
        if (token != weth && token != usdc) revert InvalidPair();
    }

    function _validPair(address tokenSell, address tokenBuy) internal view {
        if (!((tokenSell == weth && tokenBuy == usdc) || (tokenSell == usdc && tokenBuy == weth))) {
            revert InvalidPair();
        }
    }

    function _key(address agent, uint32 epoch, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, epoch, token));
    }

    function _nonceKey(address agent, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, nonce));
    }
}
