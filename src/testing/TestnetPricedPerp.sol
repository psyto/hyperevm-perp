// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HedgedPerp, IToken} from "../HedgedPerp.sol";
import {Core} from "hyperevm-amm/Core.sol";
import {HLPrecompiles} from "hl-price-guard/HLPrecompiles.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";

/// @notice TESTNET ONLY. HedgedPerp with the price set by the keeper instead of read from
/// HyperCore, so liquidation can be exercised on testnet, where BTC does not move 2.5% on
/// request. Settles still need the set price within 1% of the real oracle, because position
/// sizes (and so the real hedge) come from it (review r6); liquidation takes the set price as is.
/// The hedge trades the real Core book at real prices. Also sends one raw IOC on request, to
/// measure what orderStatus returns for a CoreWriter order that does not fill; it takes the same
/// one-outstanding-order slot as hedge() (review r6). Never deploy this anywhere real: the keeper
/// can set any liquidation price and liquidate anyone.
contract TestnetPricedPerp is HedgedPerp {
    uint256 internal constant HYPEREVM_TESTNET = 998;
    /// Raw orders' cloids have the top bit set, so they never collide with hedge() cloids.
    uint128 internal constant RAW_CLOID_BIT = uint128(1) << 127;
    uint256 public constant MAX_SETTLE_DEV_BPS = 100;

    uint256 public price; // 1e18 USD per unit
    uint128 public rawCount;

    error NotTestnet(uint256 chainId);
    error SettlePriceOff(uint256 price, uint256 oracle);

    event RawOrder(uint128 indexed cloid, bool isBuy, uint64 limitPx8, uint64 sz8);

    constructor(IToken usdc_, uint32 perpIndex_, uint8 szDecimals_, uint256 maxHedgeLots_, uint256 price_)
        HedgedPerp(usdc_, perpIndex_, szDecimals_, maxHedgeLots_, 100, 100, 100)
    {
        // enforced, not only named (hyperevm-lend review r9): HyperEVM testnet is 998, mainnet 999
        if (block.chainid != HYPEREVM_TESTNET) revert NotTestnet(block.chainid);
        price = price_;
    }

    function setPrice(uint256 price_) external onlyKeeper {
        price = price_;
    }

    function guardedPrice() public view override returns (uint256) {
        if (price == 0) revert NoPrice();
        uint256 o = HLPrecompiles.oracle(perpIndex, szDecimals);
        if (HLPriceGuard.diffBps(price, o) > MAX_SETTLE_DEV_BPS) revert SettlePriceOff(price, o);
        return price;
    }

    function liquidationPrice(bool) public view override returns (uint256) {
        if (price == 0) revert NoPrice();
        return price;
    }

    /// One IOC exactly as given (8-decimal price and size). It holds pendingCloid like a hedge
    /// order, so it is acknowledged the same way and never runs alongside one.
    function rawIoc(bool isBuy, uint64 limitPx8, uint64 sz8) external onlyKeeper returns (uint128 cloid) {
        if (pendingCloid != 0) revert OrderInFlight();
        cloid = RAW_CLOID_BIT | ++rawCount;
        pendingCloid = cloid;
        Core.limitOrder(perpIndex, isBuy, limitPx8, sz8, false, Core.TIF_IOC, cloid);
        emit RawOrder(cloid, isBuy, limitPx8, sz8);
    }
}
