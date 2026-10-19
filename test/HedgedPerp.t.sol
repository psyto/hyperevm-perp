// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HedgedPerp, IToken} from "../src/HedgedPerp.sol";
import {Core} from "hyperevm-amm/Core.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Stands in for CoreWriter (0x3333…) and keeps the last action.
contract WriterRecorder {
    bytes public last;
    uint256 public count;

    function sendRawAction(bytes calldata data) external {
        last = data;
        count++;
    }
}

contract HedgedPerpTest is Test {
    address constant POSITION = 0x0000000000000000000000000000000000000800;
    address constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address constant BBO = 0x000000000000000000000000000000000000080e;
    address constant MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address constant USER_EXISTS = 0x0000000000000000000000000000000000000810;
    address constant WRITER = 0x3333333333333333333333333333333333333333;
    uint32 constant BTC = 3; // testnet; perp prices have 6 - szDecimals(5) = 1 decimal

    HedgedPerp perp;
    MockUSDC usdc;
    address keeper = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address liquidator = address(0x11);

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        perp = new HedgedPerp(IToken(address(usdc)), BTC, 5, 100_000, 100, 100, 100); // max 1 BTC per hedge
        vm.etch(WRITER, address(new WriterRecorder()).code);
        _setPrice(800_000); // 80,000.0
        _setCore(true, 0, 0, 0);

        usdc.mint(keeper, 1_000_000e6);
        usdc.approve(address(perp), type(uint256).max);
        perp.fund(10_000e6);

        for (uint256 i; i < 2; i++) {
            address t = i == 0 ? alice : bob;
            usdc.mint(t, 1_000_000e6);
            vm.prank(t);
            usdc.approve(address(perp), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    /// Oracle, mark and a 1 bp book around `px1` (1 decimal).
    function _setPrice(uint64 px1) internal {
        _setQuote(px1, px1, px1 - px1 / 20_000, px1 + px1 / 20_000);
    }

    function _setQuote(uint64 oracle1, uint64 mark1, uint64 bid1, uint64 ask1) internal {
        vm.mockCall(ORACLE_PX, abi.encode(BTC), abi.encode(oracle1));
        vm.mockCall(MARK_PX, abi.encode(BTC), abi.encode(mark1));
        vm.mockCall(BBO, abi.encode(BTC), abi.encode(bid1, ask1));
    }

    function _setCore(bool exists, int64 szi, int64 accountValue, uint64 spotUsdcWei) internal {
        vm.mockCall(USER_EXISTS, abi.encode(address(perp)), abi.encode(exists));
        vm.mockCall(POSITION, abi.encode(address(perp), uint16(BTC)), abi.encode(Core.Position(szi, 0, 0, 20, false)));
        vm.mockCall(
            MARGIN_SUMMARY, abi.encode(uint32(0), address(perp)), abi.encode(Core.MarginSummary(accountValue, 0, 0, 0))
        );
        vm.mockCall(SPOT_BALANCE, abi.encode(address(perp), uint64(0)), abi.encode(Core.SpotBalance(spotUsdcWei, 0, 0)));
    }

    function _open(address t, bool long, uint256 margin, uint256 lev) internal returns (uint256 id) {
        vm.prank(t);
        id = perp.requestOpen(long, margin, lev);
        vm.warp(block.timestamp + 2);
        perp.settleOpen(id);
    }

    function _close(address t, uint256 id) internal {
        vm.prank(t);
        perp.requestClose(id);
        vm.warp(block.timestamp + 2);
        perp.settleClose(id);
    }

    function _lastOrder()
        internal
        view
        returns (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool reduceOnly, uint8 tif)
    {
        bytes memory raw = WriterRecorder(WRITER).last();
        assertEq(uint8(raw[0]), 1, "version");
        assertEq(uint24(bytes3(abi.encodePacked(raw[1], raw[2], raw[3]))), Core.LIMIT_ORDER, "action");
        bytes memory args = new bytes(raw.length - 4);
        for (uint256 i; i < args.length; i++) {
            args[i] = raw[i + 4];
        }
        (asset, isBuy, px, sz, reduceOnly, tif,) =
            abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    // ---------------------------------------------------------------- open, close, cancel

    function test_openSettlesAtOracleAndTakesFee() public {
        uint256 before = usdc.balanceOf(alice);
        uint256 id = _open(alice, true, 100e6, 10); // $1,000 notional
        assertEq(before - usdc.balanceOf(alice), 100e6 + 1e6, "margin + 10 bp fee");
        (,, HedgedPerp.State s,,, uint256 notional, uint256 units, uint256 entry) = perp.positions(id);
        assertEq(uint8(s), uint8(HedgedPerp.State.Open));
        assertEq(notional, 1_000e6);
        assertEq(entry, 80_000e18);
        assertEq(units, 0.0125e18, "1,000 / 80,000 BTC");
        assertEq(perp.held(), 100e6, "the fee left held");
        assertEq(perp.longUnits(), 0.0125e18);
        assertEq(perp.maxProfits(), 500e6);
    }

    function test_settleWindow() public {
        vm.prank(alice);
        uint256 id = perp.requestOpen(true, 100e6, 10);
        vm.expectRevert(HedgedPerp.TooEarly.selector);
        perp.settleOpen(id);
        vm.warp(block.timestamp + 16);
        vm.expectRevert(HedgedPerp.TooLate.selector);
        perp.settleOpen(id);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        perp.cancel(id);
        assertEq(usdc.balanceOf(alice) - before, 101e6, "full refund");
        assertEq(perp.held(), 0);
    }

    /// Anyone settles, so the keeper cannot wait for a price it likes (review r1).
    function test_anyoneSettles() public {
        vm.prank(alice);
        uint256 id = perp.requestOpen(true, 100e6, 10);
        vm.warp(block.timestamp + 2);
        vm.prank(bob);
        perp.settleOpen(id);
        vm.prank(alice);
        perp.requestClose(id);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        perp.settleClose(id);
        assertEq(perp.openCount(), 0);
    }

    function test_closeWithProfitCreditsThenClaims() public {
        uint256 id = _open(alice, true, 100e6, 10);
        _setPrice(840_000); // +5%
        _close(alice, id);
        // value 1,050, pnl +50, close fee 1 -> payout 149
        assertEq(perp.credit(alice), 149e6);
        assertEq(perp.owed(), 149e6);
        assertEq(perp.held(), 0);
        assertEq(perp.openCount(), 0);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        perp.claim();
        assertEq(usdc.balanceOf(alice) - before, 149e6);
    }

    function test_closeWithLoss() public {
        uint256 id = _open(alice, false, 100e6, 10); // short
        _setPrice(820_000); // +2.5%: short loses 25
        _close(alice, id);
        assertEq(perp.credit(alice), 100e6 - 25e6 - 1e6);
    }

    function test_profitCapped() public {
        uint256 id = _open(alice, true, 100e6, 20); // $2,000
        _setPrice(1_200_000); // +50%: pnl +1,000, cap 500
        _close(alice, id);
        assertEq(perp.credit(alice), 600e6);
    }

    function test_cancelCloseGoesBackToOpen() public {
        uint256 id = _open(alice, true, 100e6, 10);
        vm.prank(alice);
        perp.requestClose(id);
        vm.warp(block.timestamp + 16);
        vm.prank(alice);
        perp.cancel(id);
        (,, HedgedPerp.State s,,,,,) = perp.positions(id);
        assertEq(uint8(s), uint8(HedgedPerp.State.Open));
    }

    function test_badRequests() public {
        vm.startPrank(alice);
        vm.expectRevert(HedgedPerp.BadRequest.selector);
        perp.requestOpen(true, 0.5e6, 10);
        vm.expectRevert(HedgedPerp.BadRequest.selector);
        perp.requestOpen(true, 100e6, 21);
        vm.expectRevert(HedgedPerp.BadRequest.selector);
        perp.requestOpen(true, 100e6, 0);
        vm.stopPrank();
    }

    function test_onlyOwnerCloses() public {
        uint256 id = _open(alice, true, 100e6, 10);
        vm.prank(bob);
        vm.expectRevert(HedgedPerp.NotOwner.selector);
        perp.requestClose(id);
    }

    // ---------------------------------------------------------------- capital

    function test_openNeedsCapitalForMaxProfit() public {
        perp.defund(9_000e6); // 1,000 + fees left
        vm.prank(alice);
        uint256 id = perp.requestOpen(true, 300e6, 10); // cap 1,500
        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(HedgedPerp.Undercapitalised.selector, 1_003e6, 1_500e6));
        perp.settleOpen(id);
    }

    /// Core money is the hedge's: it never backs what traders can be owed (review r1).
    function test_coreValueIsNotCapital() public {
        perp.defund(10_000e6);
        _setCore(true, 0, 1_000e6, 600e8); // perp 1,000 + spot 600
        assertEq(perp.coreValue(), 1_600e6);
        assertEq(perp.capital(), 0);
        vm.prank(alice);
        uint256 id = perp.requestOpen(true, 300e6, 10);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(HedgedPerp.Undercapitalised.selector, 3e6, 1_500e6));
        perp.settleOpen(id);
    }

    function test_defundKeepsMaxProfits() public {
        _open(alice, true, 1_000e6, 10); // cap 5,000; fee 10
        vm.expectRevert(abi.encodeWithSelector(HedgedPerp.Undercapitalised.selector, 4_010e6, 5_000e6));
        perp.defund(6_000e6);
        perp.defund(5_010e6);
        assertEq(perp.capital(), 5_000e6);
    }

    function test_defundNeverTakesTradersMoney() public {
        perp.defund(10_000e6);
        vm.prank(alice);
        perp.requestOpen(true, 100e6, 10);
        assertEq(perp.capital(), 0);
        vm.expectRevert(HedgedPerp.BadRequest.selector);
        perp.defund(1);
    }

    function test_owedCountsAgainstCapital() public {
        uint256 id = _open(alice, true, 100e6, 10);
        _setPrice(840_000);
        _close(alice, id); // owes 149: margin 100 + pnl 50 - close fee 1
        assertEq(perp.capital(), 10_000e6 + 1e6 - 49e6, "open fee in, net profit out");
    }

    // ---------------------------------------------------------------- liquidation

    function test_liquidateLong() public {
        uint256 id = _open(alice, true, 100e6, 20); // $2,000, liquidatable below equity 50
        _setPrice(762_000); // -4.75%: equity 100 - 95 = 5
        vm.prank(liquidator);
        uint256 reward = perp.liquidate(id);
        assertEq(reward, 5e6);
        assertEq(perp.credit(liquidator), 5e6);
        assertEq(perp.openCount(), 0);
        assertEq(perp.longUnits(), 0);
        assertEq(perp.held(), 0);
    }

    function test_liquidateShortfallIsThePools() public {
        uint256 id = _open(alice, true, 100e6, 20);
        uint256 capBefore = perp.capital();
        _setPrice(720_000); // -10%: equity -100
        vm.prank(liquidator);
        assertEq(perp.liquidate(id), 0);
        assertEq(perp.capital(), capBefore + 100e6, "the pool keeps the margin, nothing more");
    }

    function test_liquidationLongNeedsBothPrices() public {
        uint256 id = _open(alice, true, 100e6, 20);
        _setQuote(762_000, 800_000, 761_000, 763_000); // oracle down alone
        vm.expectRevert(HedgedPerp.Healthy.selector);
        perp.liquidate(id);
        _setQuote(800_000, 762_000, 761_000, 763_000); // mark down alone
        vm.expectRevert(HedgedPerp.Healthy.selector);
        perp.liquidate(id);
        _setQuote(762_000, 765_000, 761_000, 763_000); // both down: judged at the higher
        perp.liquidate(id);
    }

    function test_liquidationShortUsesTheLower() public {
        uint256 id = _open(alice, false, 100e6, 20);
        _setQuote(840_000, 800_000, 839_000, 841_000); // oracle up alone
        vm.expectRevert(HedgedPerp.Healthy.selector);
        perp.liquidate(id);
        _setQuote(840_000, 838_000, 839_000, 841_000);
        perp.liquidate(id);
    }

    /// The price check that guards settles must not block liquidations in a crash.
    function test_liquidationIgnoresThePriceCheck() public {
        uint256 id = _open(alice, true, 100e6, 20);
        _setQuote(700_000, 720_000, 600_000, 760_000); // book 23% wide, mark 2.9% off
        vm.expectRevert();
        perp.guardedPrice();
        perp.liquidate(id);
    }

    function test_liquidateWhileClosing() public {
        uint256 id = _open(alice, true, 100e6, 20);
        vm.prank(alice);
        perp.requestClose(id);
        _setPrice(762_000);
        perp.liquidate(id);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(HedgedPerp.BadState.selector);
        perp.settleClose(id);
    }

    function test_healthyNotLiquidatable() public {
        uint256 id = _open(alice, true, 100e6, 20);
        _setPrice(770_000); // -3.75%: equity 25 < 50
        perp.liquidate(id);
        uint256 id2 = _open(bob, true, 100e6, 20); // entry 77,000
        _setPrice(765_000); // -0.65%: equity 87
        vm.expectRevert(HedgedPerp.Healthy.selector);
        perp.liquidate(id2);
    }

    // ---------------------------------------------------------------- hedge

    function test_hedgeBuysTradersNetLong() public {
        _open(alice, true, 1_000e6, 10); // 0.125 BTC long
        _open(bob, false, 100e6, 10); // 0.0125 BTC short
        assertEq(perp.targetLots(), 11_250, "0.1125 BTC in 5-decimal lots");
        perp.hedge();
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif) = _lastOrder();
        assertEq(asset, BTC);
        assertTrue(isBuy);
        assertEq(sz, 0.1125e8);
        assertFalse(ro);
        assertEq(tif, Core.TIF_IOC);
        // ask 80,004.0 + 30 bp = 80,244.012, buy limit rounded down to an integer (5 sig figs)
        assertEq(px, 80_244e8);
    }

    function test_hedgeSellsWhenNetShort() public {
        _open(alice, false, 1_000e6, 10);
        perp.hedge();
        (, bool isBuy, uint64 px, uint64 sz,,) = _lastOrder();
        assertFalse(isBuy);
        assertEq(sz, 0.125e8);
        // bid 79,996.0 - 30 bp = 79,756.012, sell limit rounded up
        assertEq(px, 79_757e8);
    }

    function test_hedgeOrdersOnlyTheGap() public {
        _open(alice, true, 1_000e6, 10); // 12,500 lots
        _setCore(true, 10_000, 500e6, 0); // 0.1 BTC already on Core
        perp.hedge();
        (,,, uint64 sz,,) = _lastOrder();
        assertEq(sz, 0.025e8);
    }

    /// At most one unconfirmed order: repeated calls send nothing until Core shows a change
    /// (review r3: three calls 10 s apart used to send three orders).
    function test_oneUnconfirmedOrder() public {
        _open(alice, true, 1_000e6, 10);
        perp.hedge();
        for (uint256 i; i < 3; i++) {
            vm.warp(block.timestamp + 15);
            vm.expectRevert(HedgedPerp.OrderInFlight.selector);
            perp.hedge();
        }
        assertEq(WriterRecorder(WRITER).count(), 1);
        _setCore(true, 12_500, 500e6, 0); // filled
        assertFalse(perp.orderInFlight());
        vm.expectRevert(HedgedPerp.NothingToHedge.selector);
        perp.hedge();
    }

    function test_partialFillConfirmsAndTheRestIsOrdered() public {
        _open(alice, true, 1_000e6, 10);
        perp.hedge();
        _setCore(true, 5_000, 500e6, 0); // part filled: confirmed
        perp.hedge();
        (,,, uint64 sz,,) = _lastOrder();
        assertEq(sz, 0.075e8);
    }

    function test_unfilledOrderGivenUpAfterTimeout() public {
        _open(alice, true, 1_000e6, 10);
        perp.hedge();
        vm.warp(block.timestamp + 59);
        vm.expectRevert(HedgedPerp.OrderInFlight.selector);
        perp.hedge();
        vm.warp(block.timestamp + 1);
        perp.hedge();
        assertEq(WriterRecorder(WRITER).count(), 2);
    }

    /// Settles wait for an unconfirmed order, but never past the window's last 2 s.
    function test_settleWaitsForOrderButNotForever() public {
        _open(alice, true, 1_000e6, 10);
        vm.prank(bob);
        uint256 id = perp.requestOpen(false, 100e6, 10);
        perp.hedge();
        vm.warp(block.timestamp + 2);
        vm.expectRevert(HedgedPerp.OrderInFlight.selector);
        perp.settleOpen(id);
        vm.warp(block.timestamp + 11); // requestedAt + 13: the last 2 s
        perp.settleOpen(id);
    }

    function test_settleProceedsOnceOrderSeen() public {
        _open(alice, true, 1_000e6, 10);
        vm.prank(bob);
        uint256 id = perp.requestOpen(false, 100e6, 10);
        perp.hedge();
        vm.warp(block.timestamp + 2);
        _setCore(true, 12_500, 500e6, 0);
        perp.settleOpen(id);
    }

    function test_liquidationDoesNotWaitForOrder() public {
        uint256 id = _open(alice, true, 100e6, 20);
        _open(bob, true, 1_000e6, 10);
        perp.hedge();
        assertTrue(perp.orderInFlight());
        _setPrice(762_000);
        perp.liquidate(id);
    }

    function test_hedgeUnwindsAfterClose() public {
        uint256 id = _open(alice, true, 1_000e6, 10);
        _setCore(true, 12_500, 500e6, 0);
        _close(alice, id);
        perp.hedge();
        (, bool isBuy,, uint64 sz,,) = _lastOrder();
        assertFalse(isBuy);
        assertEq(sz, 0.125e8);
    }

    function test_hedgeCappedPerCall() public {
        perp.fund(30_000e6);
        _open(alice, true, 6_000e6, 20); // $120,000 = 1.5 BTC, cap per call 1 BTC
        perp.hedge();
        (,,, uint64 sz,,) = _lastOrder();
        assertEq(sz, 1e8);
    }

    function test_hedgeTooSmall() public {
        _open(alice, true, 1e6, 10); // $10 = 12.5 lots, rounded to 13 ($10.40)
        vm.expectRevert(abi.encodeWithSelector(HedgedPerp.HedgeTooSmall.selector, 10.4e6));
        perp.hedge();
    }

    function test_hedgeRefusesABadBook() public {
        _open(alice, true, 1_000e6, 10);
        _setQuote(800_000, 800_000, 790_000, 810_000); // 2.5% wide, over the 1% bound
        vm.expectRevert(
            abi.encodeWithSelector(HLPriceGuard.PriceRejected.selector, HLPriceGuard.Breach.Spread, 254, 100)
        );
        perp.hedge();
    }

    function test_hedgeLimitStaysNearOracle() public {
        HedgedPerp loose = new HedgedPerp(IToken(address(usdc)), BTC, 5, 100_000, 0, 0, 0);
        usdc.approve(address(loose), type(uint256).max);
        loose.fund(10_000e6);
        vm.mockCall(USER_EXISTS, abi.encode(address(loose)), abi.encode(true));
        vm.mockCall(POSITION, abi.encode(address(loose), uint16(BTC)), abi.encode(Core.Position(0, 0, 0, 20, false)));
        vm.prank(alice);
        usdc.approve(address(loose), type(uint256).max);
        vm.prank(alice);
        uint256 id = loose.requestOpen(true, 1_000e6, 10);
        vm.warp(block.timestamp + 2);
        loose.settleOpen(id);
        _setQuote(800_000, 800_000, 799_000, 810_000); // ask 1.25% above the oracle
        vm.expectRevert(abi.encodeWithSelector(HedgedPerp.BadQuote.selector, 81_243e18, 80_000e18));
        loose.hedge();
    }

    function test_hedgeNeedsACoreAccount() public {
        _open(alice, true, 1_000e6, 10);
        _setCore(false, 0, 0, 0);
        vm.expectRevert(HedgedPerp.NoCoreAccount.selector);
        perp.hedge();
        assertEq(WriterRecorder(WRITER).count(), 0);
    }

    function test_onlyKeeperHedges() public {
        _open(alice, true, 1_000e6, 10);
        vm.prank(alice);
        vm.expectRevert(HedgedPerp.NotKeeper.selector);
        perp.hedge();
    }

    function test_coreMoneyActions() public {
        perp.coreUsdClass(5e6, true);
        bytes memory raw = WriterRecorder(WRITER).last();
        assertEq(uint24(bytes3(abi.encodePacked(raw[1], raw[2], raw[3]))), Core.USD_CLASS_TRANSFER);
        perp.coreToEvm(5e8);
        raw = WriterRecorder(WRITER).last();
        assertEq(uint24(bytes3(abi.encodePacked(raw[1], raw[2], raw[3]))), Core.SEND_ASSET);
        vm.expectRevert(HedgedPerp.BadRequest.selector);
        perp.coreToEvm(5e8 + 1);
    }

    function test_badConfig() public {
        vm.expectRevert(HedgedPerp.BadConfig.selector);
        new HedgedPerp(IToken(address(usdc)), BTC, 7, 1, 0, 0, 0);
        vm.expectRevert(HedgedPerp.BadConfig.selector);
        new HedgedPerp(IToken(address(usdc)), BTC, 5, 0, 0, 0, 0);
    }
}
