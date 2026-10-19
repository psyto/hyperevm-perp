## High — position delta is not an IOC acknowledgement

PoCs: [R4OrderConfirmationPoC.t.sol](test/poc/R4OrderConfirmationPoC.t.sol)

- `test_poc_adlPositionMoveIsNotAnIocAcknowledgement`: fails, `2 != 1`.
- `test_poc_timeoutDoesNotCancelACoreWriterAction`: fails, `3 != 1`.

`orderInFlight()` treats any `szi != orderFrom` as completion. Core liquidations and ADL can change a pool position independently of its queued IOC, releasing another IOC while the original remains pending. An IOC that happens to net back to `orderFrom` instead looks perpetually pending. A zero-fill/rejected IOC also blocks for 60 seconds despite already being terminal.

The 60-second fallback recreates R3’s accumulation problem at a slower cadence: expiry does not cancel a CoreWriter action, so repeated expiries can queue arbitrarily many IOCs. CoreWriter is asynchronous, while HyperCore liquidations/ADL can close positions independently. [CoreWriter docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore), [liquidations](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/liquidations), [ADL](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/auto-deleveraging).

Fix: do not release or retry based on position movement or elapsed time. Use a unique nonzero cloid and wait for verified terminal Core order status off-chain; absent an on-chain status proof, this must be a trusted operational acknowledgement or automatic retries must be removed. Document that this invariant cannot be enforced solely from `0x800`.

## Medium — keeper can still delay every close

PoC: `test_poc_keeperCanHoldCloseUntilTheLastTwoSeconds` fails with `OrderInFlight()` when a third party settles at the ordinary two-second delay.

Root cause: `_waitForOrder()` blocks all settles until request + 13 seconds. Only the keeper can start the hedge, and a zero-fill/rejected/delayed order gives it an 11-second settlement hold. It cannot force cancellation—seconds 13–15 remain open—but “cannot hold a close back” is inaccurate and the original “anyone settles” anti-option property is weakened.

Fix: either remove the close wait and explicitly accept the one-IOC residual, or retain it but document the keeper’s bounded 11-second option and require verified order finality before using it.

## Documentation / edge-case audit

- “What is left” is incomplete: Core liquidation/ADL deltas, exact return to `orderFrom`, and every repeated 60-second retry can invalidate the claimed one-order residual.
- The residual says under `$10` is unhedgeable, but code rejects amounts below `$12`.
- `szi` convention is correct: positive is long and negative is short. [Hyperliquid notation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/notation)
- A `0x810` false result makes `coreLots()` return zero; it does not create an order because `hedge()` separately rejects `NoCoreAccount`, but it can falsely clear or preserve in-flight state and affect settle availability.

The original 39-test suite passes. I would not run automatic hedging, even at 0.001–0.01 BTC, until the acknowledgement/retry invariant is redesigned; a manual Core-status-verified plumbing smoke test with disposable testnet funds is a narrower exception.

VERDICT: CHANGES
