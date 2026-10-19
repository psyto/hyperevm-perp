// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {HedgedPerp, IToken} from "../HedgedPerp.sol";
import {Core} from "hyperevm-amm/Core.sol";

/// @notice TESTNET ONLY. HedgedPerp with the settle and liquidation price set by the keeper
/// instead of read from HyperCore, so liquidation can be exercised on testnet, where BTC does not
/// move 3.75% on request. The hedge still trades the real Core book at real prices. Also sends one
/// raw IOC on request, to measure what orderStatus returns for a CoreWriter order that does not
/// fill. Never deploy this anywhere real: the keeper can set any price and liquidate anyone.
contract TestnetPricedPerp is HedgedPerp {
    uint256 internal constant HYPEREVM_TESTNET = 998;
    /// Raw orders' cloids have the top bit set, so they never collide with hedge() cloids.
    uint128 internal constant RAW_CLOID_BIT = uint128(1) << 127;

    uint256 public price; // 1e18 USD per unit
    uint128 public rawCount;

    error NotTestnet(uint256 chainId);

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
        return price;
    }

    function liquidationPrice(bool) public view override returns (uint256) {
        if (price == 0) revert NoPrice();
        return price;
    }

    /// One IOC exactly as given (8-decimal price and size), outside the hedge bookkeeping.
    function rawIoc(bool isBuy, uint64 limitPx8, uint64 sz8) external onlyKeeper returns (uint128 cloid) {
        cloid = RAW_CLOID_BIT | ++rawCount;
        Core.limitOrder(perpIndex, isBuy, limitPx8, sz8, false, Core.TIF_IOC, cloid);
        emit RawOrder(cloid, isBuy, limitPx8, sz8);
    }
}
