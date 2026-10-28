// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HedgedPerp, IToken} from "../src/HedgedPerp.sol";
import {TestnetPricedPerp} from "../src/testing/TestnetPricedPerp.sol";
import {MockUSDC, WriterRecorder} from "./HedgedPerp.t.sol";

contract TestnetPricedPerpTest is Test {
    address constant WRITER = 0x3333333333333333333333333333333333333333;
    address constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    MockUSDC usdc;

    function setUp() public {
        usdc = new MockUSDC();
        vm.etch(WRITER, address(new WriterRecorder()).code);
        vm.mockCall(ORACLE_PX, abi.encode(uint32(3)), abi.encode(uint64(800_000))); // 80,000.0
    }

    function test_refusesAnyChainButTestnet() public {
        vm.chainId(999);
        vm.expectRevert(abi.encodeWithSelector(TestnetPricedPerp.NotTestnet.selector, 999));
        new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 80_000e18);
    }

    function test_settleAndLiquidateAtTheSetPrice() public {
        vm.chainId(998);
        vm.warp(1_800_000_000);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 80_000e18);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(perp), type(uint256).max);
        perp.fund(100e6);
        uint256 id = perp.requestOpen(true, 2e6, 20);
        vm.warp(block.timestamp + 2);
        perp.settleOpen(id);
        (,,,,,,, uint256 entry) = perp.positions(id);
        assertEq(entry, 80_000e18);

        vm.expectRevert(HedgedPerp.Healthy.selector);
        perp.liquidate(id);
        perp.setPrice(77_000e18); // -3.75%: equity 0.5 < 1 (liquidatable from -2.5% at 20x)
        perp.liquidate(id);
        assertEq(perp.openCount(), 0);
    }

    /// Position sizes, and so the real hedge, come from the settle price: it must stay near the
    /// real oracle (review r6: a $1 price made a 40 BTC hedge). Liquidation takes any price.
    function test_settlePriceStaysNearTheOracle() public {
        vm.chainId(998);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 1e18);
        vm.expectRevert(abi.encodeWithSelector(TestnetPricedPerp.SettlePriceOff.selector, 1e18, 80_000e18));
        perp.guardedPrice();
        perp.setPrice(80_800e18); // +1%
        assertEq(perp.guardedPrice(), 80_800e18);
        perp.setPrice(1e18);
        assertEq(perp.liquidationPrice(true), 1e18);
    }

    function test_zeroPriceRevertsBothReads() public {
        vm.chainId(998);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 0);
        vm.expectRevert(HedgedPerp.NoPrice.selector);
        perp.guardedPrice();
        vm.expectRevert(HedgedPerp.NoPrice.selector);
        perp.liquidationPrice(true);
    }

    function test_onlyKeeperSetsPriceAndSendsRawOrders() public {
        vm.chainId(998);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 1);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(HedgedPerp.NotKeeper.selector);
        perp.setPrice(2);
        vm.expectRevert(HedgedPerp.NotKeeper.selector);
        perp.rawIoc(true, 1e8, 1000);
        vm.expectRevert(HedgedPerp.NotKeeper.selector);
        perp.rawIocReduceOnly(true, 1e8, 1000);
        vm.stopPrank();
    }

    function test_rawOrderCloidsNeverMeetHedgeCloids() public {
        vm.chainId(998);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 1);
        uint128 c = perp.rawIoc(true, 70_000e8, 1000);
        assertEq(c, (uint128(1) << 127) | 1);
        assertEq(perp.pendingCloid(), c, "takes the one outstanding slot (review r6)");
        vm.expectRevert(HedgedPerp.OrderInFlight.selector);
        perp.rawIoc(true, 70_000e8, 1000);
        perp.acknowledge(c);
        perp.rawIoc(true, 70_000e8, 1000);
        assertEq(WriterRecorder(WRITER).count(), 2);
    }

    struct Order {
        uint32 asset;
        bool isBuy;
        uint64 px;
        uint64 sz;
        bool reduceOnly;
        uint8 tif;
        uint128 cloid;
    }

    function _order(bytes memory a) internal pure returns (Order memory o) {
        assertEq(uint8(a[0]), 1, "version");
        assertEq(uint24(bytes3(abi.encodePacked(a[1], a[2], a[3]))), 1, "limit order action");
        bytes memory args = new bytes(a.length - 4);
        for (uint256 i; i < args.length; i++) args[i] = a[i + 4];
        (o.asset, o.isBuy, o.px, o.sz, o.reduceOnly, o.tif, o.cloid) =
            abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    /// Step 5: the reduce-only twin sets the flag and nothing else differs.
    function test_reduceOnlyFlagIsEncoded() public {
        vm.chainId(998);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 1);
        uint128 c1 = perp.rawIoc(false, 79_000e8, 15_000);
        Order memory o1 = _order(WriterRecorder(WRITER).last());
        assertFalse(o1.reduceOnly, "rawIoc is not reduce-only");
        perp.acknowledge(c1);
        uint128 c2 = perp.rawIocReduceOnly(false, 79_000e8, 15_000);
        Order memory o2 = _order(WriterRecorder(WRITER).last());
        assertTrue(o2.reduceOnly, "rawIocReduceOnly is reduce-only");
        assertEq(o2.asset, 3);
        assertEq(o2.asset, o1.asset);
        assertEq(o2.isBuy, o1.isBuy);
        assertEq(o2.px, o1.px);
        assertEq(o2.sz, o1.sz);
        assertEq(o2.tif, o1.tif);
        assertEq(o1.cloid, c1);
        assertEq(o2.cloid, c2);
    }

    /// Step 5: the twin shares the one slot and the cloid sequence with rawIoc and hedge orders.
    function test_reduceOnlySharesTheSlotAndSequence() public {
        vm.chainId(998);
        TestnetPricedPerp perp = new TestnetPricedPerp(IToken(address(usdc)), 3, 5, 100, 1);
        uint128 c1 = perp.rawIoc(true, 70_000e8, 1000);
        vm.expectRevert(HedgedPerp.OrderInFlight.selector);
        perp.rawIocReduceOnly(false, 70_000e8, 1000);
        perp.acknowledge(c1);
        uint128 c2 = perp.rawIocReduceOnly(false, 70_000e8, 1000);
        assertEq(c2, (uint128(1) << 127) | 2, "one sequence for both");
        assertEq(perp.pendingCloid(), c2);
        vm.expectRevert(HedgedPerp.OrderInFlight.selector);
        perp.rawIoc(true, 70_000e8, 1000);
        vm.expectRevert(HedgedPerp.OrderInFlight.selector);
        perp.rawIocReduceOnly(false, 70_000e8, 1000);
        vm.expectRevert();
        perp.acknowledge(c1); // the old cloid does not clear the new one
        assertEq(perp.pendingCloid(), c2);
        perp.acknowledge(c2);
        assertEq(perp.pendingCloid(), 0);
    }
}
