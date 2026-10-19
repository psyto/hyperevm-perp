- **Medium — `rawIoc()` bypasses the one-outstanding-order invariant.**  
  **PoC:** [`test_poc_rawIocBypassesTheOneOutstandingOrderGate`](test/poc/r6-poc.t.sol:54) fails: CoreWriter receives 2 actions while `pendingCloid == 1`.  
  **Root cause:** [`rawIoc`](src/testing/TestnetPricedPerp.sol:47) uses a separate cloid but no `pendingCloid` gate, so it can race a hedge IOC from the same Core account. Cloids do not collide, and `acknowledge(rawCloid)` cannot clear the hedge lock, but the raw order can still fill later and invalidate the hedge’s Core-position snapshot.  
  **Fix:** Make raw orders participate in the same pending slot: reject if `pendingCloid != 0`, set `pendingCloid = rawCloid` after submission, and acknowledge its final API status through `acknowledge`. This preserves the high-bit namespace while serializing all CoreWriter orders.

- **Low — an arbitrary simulated entry price can produce an arbitrarily oversized real-book hedge.**  
  **PoC:** [`test_poc_simulatedEntryPriceCanMakeTheRealHedgeMillions`](test/poc/r6-poc.t.sol:66) fails: a $40 virtual position opened at simulated `$1/BTC` creates a 40-BTC target and submits a roughly $3.2m real-book IOC, despite only $10 of EVM capital required.  
  **Root cause:** [`guardedPrice`](src/testing/TestnetPricedPerp.sol:36) controls units and therefore `targetLots`, while [`hedge`](src/HedgedPerp.sol:263) deliberately prices that quantity from the real quote. `capital`, `held`, and `owed` remain EVM-correct, but they do not constrain this Core-only exposure.  
  **Fix:** Split simulated settlement and liquidation pricing. Require the test settlement price to remain within a tight bound of the real oracle/quote; retain an unrestricted test-only liquidation price so the −3.75% liquidation exercise still works. `maxHedgeLots` is only a per-call cap and is not sufficient.

`virtual` itself does not change `HedgedPerp` behavior: `settleOpen`/`settleClose` are its only `guardedPrice()` paths, liquidation is its only `liquidationPrice()` path, and `_hedgeLimit()` still reads the real quote directly. The constructor blocks canonical mainnet deployment: HyperEVM documents testnet as chain 998 and mainnet as 999. [HyperEVM docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm)

For the stated run, use a real-current price at open; changing it by −3.75% only after the position is hedged does not change its stored units or `targetLots`. The expected statuses are plausible, provided the raw IOC has a valid tick, is at least $10 notional, and stays below the book until execution; Core documents `iocCancelRejected` and `perpMarginRejected` as terminal outcomes. [Info API](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint)

Before the margin-rejection step, wait until the perp-to-spot transfer has executed and verify zero perp margin; CoreWriter actions are delayed. Likewise, serialize the unwind’s class transfer and Core-to-EVM send, or USDC can remain on Core pending a retry. [CoreWriter timing](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)

Tests: 43 existing tests pass; the two added PoCs intentionally fail.

VERDICT: CHANGES
