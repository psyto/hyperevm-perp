// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Core} from "hyperevm-amm/Core.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {HLPrecompiles} from "hl-price-guard/HLPrecompiles.sol";

interface IToken {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice A perp on one HyperCore market, settled in USDC on HyperEVM, where the pool is every
/// trader's counterparty and hedges what traders hold, net, with a position of its own on
/// HyperCore (docs/design.md).
///
/// - Traders' books live here and settle synchronously. The hedge is the only thing on Core, and
///   the contract never assumes an order filled: hedge() reads the Core position (0x800) each
///   time and orders the gap.
/// - Opens and closes are requested by the trader and settled by anyone at the checked oracle
///   SETTLE_DELAY to SETTLE_WINDOW seconds later. Within one block the price is one value, so
///   when both sides are live the first block settles it; neither side gets a free option
///   (review r1). After the window the trader can cancel.
/// - Liquidation never refuses a price: it uses whichever of the oracle and the mark is better
///   for the trader, and no other check (hyperevm-lend review r1).
/// - One liquidity provider in this version, the keeper. The pool's EVM USDC alone must cover
///   every open position's largest possible profit (`capital() >= maxProfits`). Core money is
///   the hedge's and is not counted: an order that runs late can leave a wrong-way position on
///   Core, and that must never reach what traders are owed (review r1).
contract HedgedPerp {
    uint256 internal constant BPS = 10_000;

    uint256 public constant FEE_BPS = 10; // on notional, at open and at close
    uint256 public constant MAX_LEVERAGE = 20;
    uint256 public constant MAINT_BPS = 250; // liquidatable when equity < 2.5% of notional
    uint256 public constant MAX_PROFIT_X = 5; // a position's profit is capped at 5x its margin
    uint256 public constant MIN_MARGIN = 1e6; // 1 USDC
    uint64 public constant SETTLE_DELAY = 2; // seconds; the keeper settles at a price after the request
    uint64 public constant SETTLE_WINDOW = 15; // seconds; after this the trader can cancel
    uint256 public constant HEDGE_SLIP_BPS = 30; // IOC limit beyond the best bid/ask
    uint256 public constant HEDGE_MAX_ORACLE_BPS = 100; // and never further than this from the oracle
    uint64 public constant ORDER_TIMEOUT = 60; // seconds an unconfirmed order blocks the next one
    uint64 public constant SETTLE_LAST = 2; // the last seconds of a settle window never wait for an order
    uint256 public constant MIN_HEDGE_USD = 12e6; // HyperCore rejects orders under $10

    IToken public immutable usdc; // 6 decimals
    address public immutable keeper; // also the only liquidity provider
    uint32 public immutable perpIndex; // a validator-operated perp (dex 0)
    uint8 public immutable szDecimals;
    uint256 public immutable maxHedgeLots; // per hedge() call, in szDecimals units
    uint16 public immutable maxMarkOracleBps;
    uint16 public immutable maxMidOracleBps;
    uint16 public immutable maxSpreadBps;

    enum State {
        None,
        Opening,
        Open,
        Closing
    }

    struct Position {
        address owner;
        bool long;
        State state;
        uint64 requestedAt;
        uint256 margin; // USDC
        uint256 notional; // USDC, margin * leverage
        uint256 units; // base asset, 1e18, set at open
        uint256 entry; // 1e18 USD per unit
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;
    uint256 public openCount;

    uint256 public held; // EVM USDC that belongs to traders: margins (pending and open) and pending fees
    uint256 public owed; // credited to traders, not yet claimed
    mapping(address => uint256) public credit;
    uint256 public longUnits;
    uint256 public shortUnits;
    uint256 public maxProfits; // sum of open positions' profit caps
    // The one order that may be unconfirmed: sent at `orderSentAt` from Core position `orderFrom`.
    // It is confirmed once the Core position differs from `orderFrom` (only this pool's orders
    // move it), and given up on after ORDER_TIMEOUT with no change (review r3).
    uint64 public orderSentAt;
    int256 public orderFrom;

    event Requested(uint256 indexed id, address indexed owner, bool open);
    event Opened(uint256 indexed id, uint256 price, uint256 units);
    event Closed(uint256 indexed id, uint256 price, int256 pnl, uint256 payout);
    event Liquidated(uint256 indexed id, address indexed by, uint256 price, int256 equity, uint256 reward);
    event Cancelled(uint256 indexed id);
    event Claimed(address indexed to, uint256 amount);
    event Hedged(bool isBuy, uint256 lots, uint64 limitPx8, int256 targetLots, int256 coreLots);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);

    error BadConfig();
    error NotKeeper();
    error NotOwner();
    error BadRequest();
    error BadState();
    error TooEarly();
    error TooLate();
    error Healthy();
    error NoPrice();
    error Undercapitalised(uint256 capital, uint256 required);
    error NothingToHedge();
    error NoCoreAccount();
    error HedgeTooSmall(uint256 usd);
    error OrderInFlight();
    error BadQuote(uint256 limit, uint256 oracle);
    error TransferFailed();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        IToken usdc_,
        uint32 perpIndex_,
        uint8 szDecimals_,
        uint256 maxHedgeLots_,
        uint16 maxMarkOracleBps_,
        uint16 maxMidOracleBps_,
        uint16 maxSpreadBps_
    ) {
        if (szDecimals_ > 6 || maxHedgeLots_ == 0) revert BadConfig();
        usdc = usdc_;
        keeper = msg.sender;
        perpIndex = perpIndex_;
        szDecimals = szDecimals_;
        maxHedgeLots = maxHedgeLots_;
        maxMarkOracleBps = maxMarkOracleBps_;
        maxMidOracleBps = maxMidOracleBps_;
        maxSpreadBps = maxSpreadBps_;
    }

    // ---------------------------------------------------------------- traders

    function requestOpen(bool long, uint256 margin, uint256 leverage) external returns (uint256 id) {
        if (margin < MIN_MARGIN || leverage == 0 || leverage > MAX_LEVERAGE) revert BadRequest();
        uint256 notional = margin * leverage;
        uint256 fee = _fee(notional);
        _pull(margin + fee);
        held += margin + fee;
        id = nextId++;
        positions[id] = Position(msg.sender, long, State.Opening, uint64(block.timestamp), margin, notional, 0, 0);
        emit Requested(id, msg.sender, true);
    }

    function requestClose(uint256 id) external {
        Position storage p = positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (p.state != State.Open) revert BadState();
        p.state = State.Closing;
        p.requestedAt = uint64(block.timestamp);
        emit Requested(id, msg.sender, false);
    }

    /// After SETTLE_WINDOW without a settle: a pending open is refunded, a pending close goes
    /// back to open (the trader can ask again).
    function cancel(uint256 id) external {
        Position storage p = positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (block.timestamp <= p.requestedAt + SETTLE_WINDOW) revert TooEarly();
        if (p.state == State.Opening) {
            uint256 refund = p.margin + _fee(p.notional);
            held -= refund;
            delete positions[id];
            _send(msg.sender, refund);
        } else if (p.state == State.Closing) {
            p.state = State.Open;
        } else {
            revert BadState();
        }
        emit Cancelled(id);
    }

    function claim() external returns (uint256 amount) {
        amount = credit[msg.sender];
        if (amount == 0) revert BadRequest();
        credit[msg.sender] = 0;
        owed -= amount;
        _send(msg.sender, amount); // reverts until the keeper has brought enough USDC to the EVM
        emit Claimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- anyone: settle

    function settleOpen(uint256 id) external {
        Position storage p = positions[id];
        if (p.state != State.Opening) revert BadState();
        _checkWindow(p.requestedAt);
        _waitForOrder(p.requestedAt);
        uint256 price = guardedPrice();
        uint256 units = p.notional * 1e30 / price; // 1e6 USDC * 1e30 / 1e18 price = 1e18 units
        if (units == 0) revert BadRequest();
        p.units = units;
        p.entry = price;
        p.state = State.Open;
        held -= _fee(p.notional); // the open fee is now the pool's
        if (p.long) longUnits += units;
        else shortUnits += units;
        maxProfits += p.margin * MAX_PROFIT_X;
        openCount++;
        uint256 c = capital();
        if (c < maxProfits) revert Undercapitalised(c, maxProfits);
        emit Opened(id, price, units);
    }

    function settleClose(uint256 id) external {
        Position storage p = positions[id];
        if (p.state != State.Closing) revert BadState();
        _checkWindow(p.requestedAt);
        _waitForOrder(p.requestedAt);
        uint256 price = guardedPrice();
        int256 pnl = _pnl(p, price) - int256(_fee(p.notional));
        int256 cap = int256(p.margin * MAX_PROFIT_X);
        if (pnl > cap) pnl = cap;
        uint256 payout = pnl + int256(p.margin) > 0 ? uint256(pnl + int256(p.margin)) : 0;
        address owner = p.owner;
        _remove(id);
        _credit(owner, payout);
        emit Closed(id, price, pnl, payout);
    }

    // ---------------------------------------------------------------- anyone: liquidate

    /// Equity below MAINT_BPS of notional at the price better for the trader. Whatever equity is
    /// left goes to the caller; a shortfall is the pool's.
    function liquidate(uint256 id) external returns (uint256 reward) {
        Position storage p = positions[id];
        if (p.state != State.Open && p.state != State.Closing) revert BadState();
        uint256 price = liquidationPrice(p.long);
        int256 equity = int256(p.margin) + _pnl(p, price);
        if (equity >= int256(p.notional * MAINT_BPS / BPS)) revert Healthy();
        reward = equity > 0 ? uint256(equity) : 0;
        _remove(id);
        _credit(msg.sender, reward);
        emit Liquidated(id, msg.sender, price, equity, reward);
    }

    // ---------------------------------------------------------------- keeper: hedge

    /// Order the gap between what traders hold, net, and the pool's Core position. One IOC, at
    /// most maxHedgeLots, limit HEDGE_SLIP_BPS beyond the touch and within HEDGE_MAX_ORACLE_BPS
    /// of the oracle. Never while the previous order is unconfirmed (orderInFlight), so at most
    /// one order is ever outstanding unless Core holds an action for over ORDER_TIMEOUT.
    function hedge() external onlyKeeper returns (int256 sent) {
        // Core drops actions from an account that does not exist yet (review r1)
        if (!Core.userExists(address(this))) revert NoCoreAccount();
        if (orderInFlight()) revert OrderInFlight();
        int256 target = targetLots();
        int256 cur = coreLots();
        int256 gap = target - cur;
        if (gap == 0) revert NothingToHedge();
        bool isBuy = gap > 0;
        uint256 lots = uint256(isBuy ? gap : -gap);
        if (lots > maxHedgeLots) lots = maxHedgeLots;

        (uint64 px8, uint256 oracle) = _hedgeLimit(isBuy);
        uint256 usd = lots * 10 ** (18 - szDecimals) * oracle / 1e30;
        if (usd < MIN_HEDGE_USD) revert HedgeTooSmall(usd);
        uint64 sz8 = uint64(lots * 10 ** (8 - szDecimals));
        Core.limitOrder(perpIndex, isBuy, px8, sz8, false, Core.TIF_IOC, 0);
        orderSentAt = uint64(block.timestamp);
        orderFrom = cur;
        sent = isBuy ? int256(lots) : -int256(lots);
        emit Hedged(isBuy, lots, px8, target, cur);
    }

    // ---------------------------------------------------------------- keeper: money

    function fund(uint256 amount) external onlyKeeper {
        _pull(amount);
        emit Funded(amount);
    }

    /// Only from the pool's own EVM USDC, and only while the rest still covers maxProfits.
    function defund(uint256 amount) external onlyKeeper {
        uint256 c = capital();
        if (amount == 0 || amount > c) revert BadRequest();
        c -= amount;
        if (c < maxProfits) revert Undercapitalised(c, maxProfits);
        _send(keeper, amount);
        emit Defunded(amount);
    }

    /// HYPE to the pool's Core account, for the gas Core charges on non-HYPE sends.
    function fundCoreGas() external payable onlyKeeper {
        (bool ok,) = Core.HYPE_SYSTEM.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }

    /// Core USDC between spot and perp, 6 decimals.
    function coreUsdClass(uint64 ntl, bool toPerp) external onlyKeeper {
        Core.usdClassTransfer(ntl, toPerp);
    }

    /// Core spot USDC to the pool's EVM balance, 8 decimals (a multiple of 100).
    function coreToEvm(uint64 usdcWei) external onlyKeeper {
        if (usdcWei == 0 || usdcWei % 100 != 0) revert BadRequest();
        Core.sendAsset(address(Core.BASE_SYSTEM), Core.SPOT_DEX, Core.SPOT_DEX, Core.USDC, usdcWei);
    }

    // ---------------------------------------------------------------- views

    /// The oracle, checked against the mark, the mid and the spread. 1e18 USD per unit.
    function guardedPrice() public view returns (uint256) {
        return HLPriceGuard.read(_asset(), _bounds(), _noRef());
    }

    /// The better of the oracle and the mark for the trader: the higher for a long, the lower
    /// for a short. One feed moving alone liquidates no one; a real move moves both.
    function liquidationPrice(bool long) public view returns (uint256) {
        uint256 o = HLPrecompiles.oracle(perpIndex, szDecimals);
        uint256 m = HLPrecompiles.mark(perpIndex, szDecimals);
        if (o == 0 || m == 0) revert NoPrice();
        return long ? (o > m ? o : m) : (o < m ? o : m);
    }

    /// The last order is neither seen on Core (the position still equals orderFrom) nor timed out.
    function orderInFlight() public view returns (bool) {
        return orderSentAt != 0 && block.timestamp < orderSentAt + ORDER_TIMEOUT && coreLots() == orderFrom;
    }

    /// Traders' net position in Core lots (szDecimals units), rounded to the nearest lot. The
    /// pool takes the other side of traders, so it hedges by holding the same position.
    function targetLots() public view returns (int256) {
        uint256 unit = 10 ** (18 - szDecimals);
        if (longUnits >= shortUnits) return int256((longUnits - shortUnits + unit / 2) / unit);
        return -int256((shortUnits - longUnits + unit / 2) / unit);
    }

    /// The pool's Core position in lots; 0 before the Core account exists.
    function coreLots() public view returns (int256) {
        if (!Core.userExists(address(this))) return 0;
        return Core.position(address(this), uint16(perpIndex)).szi;
    }

    /// What the pool's Core account is worth in USDC: perp account value (at the mark, with the
    /// hedge's unrealised PnL) plus spot USDC. Informational: not part of capital().
    function coreValue() public view returns (uint256) {
        if (!Core.userExists(address(this))) return 0;
        int64 perp = Core.marginSummary(0, address(this)).accountValue;
        uint256 spot = uint256(Core.spotBalance(address(this), Core.USDC).total) / 100;
        return (perp > 0 ? uint256(int256(perp)) : 0) + spot;
    }

    /// The pool's own EVM USDC: neither traders' margin nor owed to them. Hedge profit counts
    /// once the keeper has brought it over (coreToEvm).
    function capital() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal > held + owed ? bal - held - owed : 0;
    }

    // ---------------------------------------------------------------- internals

    function _pnl(Position storage p, uint256 price) internal view returns (int256) {
        uint256 value = p.units * price / 1e30;
        int256 move = int256(value) - int256(p.notional);
        return p.long ? move : -move;
    }

    function _remove(uint256 id) internal {
        Position storage p = positions[id];
        if (p.long) longUnits -= p.units;
        else shortUnits -= p.units;
        maxProfits -= p.margin * MAX_PROFIT_X;
        held -= p.margin;
        openCount--;
        delete positions[id];
    }

    function _credit(address to, uint256 amount) internal {
        if (amount == 0) return;
        credit[to] += amount;
        owed += amount;
    }

    /// While a hedge order is unconfirmed, settles wait, so it does not run against exposure
    /// that has already moved. Per request and capped: the window's last SETTLE_LAST seconds
    /// are always open, so hedging cannot hold a close back (review r3).
    function _waitForOrder(uint64 requestedAt) internal view {
        if (block.timestamp < requestedAt + SETTLE_WINDOW - SETTLE_LAST && orderInFlight()) revert OrderInFlight();
    }

    function _checkWindow(uint64 requestedAt) internal view {
        if (block.timestamp < requestedAt + SETTLE_DELAY) revert TooEarly();
        if (block.timestamp > requestedAt + SETTLE_WINDOW) revert TooLate();
    }

    function _fee(uint256 notional) internal pure returns (uint256) {
        return (notional * FEE_BPS + BPS - 1) / BPS;
    }

    function _asset() internal view returns (HLPriceGuard.Asset memory) {
        return HLPriceGuard.Asset(0, perpIndex, szDecimals);
    }

    function _bounds() internal view returns (HLPriceGuard.Bounds memory) {
        return HLPriceGuard.Bounds(maxMarkOracleBps, maxMidOracleBps, maxSpreadBps, 0);
    }

    function _noRef() internal pure returns (HLPriceGuard.Ref memory) {
        return HLPriceGuard.Ref(0, 0, 0);
    }

    /// The IOC limit (8 decimals, on the tick) and the checked oracle.
    function _hedgeLimit(bool isBuy) internal view returns (uint64 px8, uint256 oracle) {
        HLPriceGuard.Quote memory q = HLPriceGuard.quote(_asset());
        (HLPriceGuard.Breach reason, uint256 observed, uint256 limit) = HLPriceGuard.check(q, _bounds(), _noRef());
        if (reason != HLPriceGuard.Breach.None) revert HLPriceGuard.PriceRejected(reason, observed, limit);
        uint256 limit18 = isBuy ? q.ask * (BPS + HEDGE_SLIP_BPS) / BPS : q.bid * (BPS - HEDGE_SLIP_BPS) / BPS;
        if (HLPriceGuard.diffBps(limit18, q.oracle) > HEDGE_MAX_ORACLE_BPS) revert BadQuote(limit18, q.oracle);
        return (_toTick(limit18 / 1e10, !isBuy), q.oracle);
    }

    /// Round to a valid perp price: 5 significant figures (integers always allowed) and at most
    /// `6 - szDecimals` decimals. `px8` has 8 decimals; up for a sell limit, down for a buy.
    function _toTick(uint256 px8, bool up) internal view returns (uint64) {
        uint256 step = 10 ** (2 + szDecimals);
        uint256 digits;
        for (uint256 x = px8; x > 0; x /= 10) {
            digits++;
        }
        if (digits > 5) {
            uint256 sig = 10 ** (digits - 5);
            if (sig > 1e8) sig = 1e8;
            if (sig > step) step = sig;
        }
        uint256 down = px8 / step * step;
        return uint64(up && down < px8 ? down + step : down);
    }

    function _pull(uint256 amount) internal {
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }
}
