You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 4, on a rebuild.

Same repo (src/HedgedPerp.sol, docs/design.md). Round 3 (docs/reviews/r3.md, your output review-r3.out.md) showed a timer between hedge orders let orders accumulate. Commit a372e22 replaces the timer instead of patching it:
- hedge() records orderSentAt and orderFrom (the Core position it started from). orderInFlight() is true until the Core position differs from orderFrom, or ORDER_TIMEOUT (60 s) passes with no change. hedge() reverts OrderInFlight while it is true.
- settleOpen/settleClose revert OrderInFlight while an order is in flight, but only until requestedAt + SETTLE_WINDOW - SETTLE_LAST (13 s); the last 2 s always settle. liquidate() never waits.

Review by breaking (failing tests under test/poc/ only; do not edit src/ or existing tests):
1. Does "seen = position differs from orderFrom" hold? Cases: a partial fill, an IOC that fills zero, Core rejecting the order, Core liquidating or ADL-ing the pool's hedge, an order that runs exactly when the position happens to return to orderFrom, coreLots() returning 0 because 0x810 flips, szi sign conventions.
2. Can anyone (trader, keeper, third party) use the settle wait to grief: delay opens/closes, force cancels at the window edge, or keep the pool in flight forever? Can the keeper's hedge() timing still hold a close back?
3. Is the documented residual (docs/design.md "What is left") accurate and complete?
4. Anything you would block on before a small, supervised testnet run (testnet USDC, BTC perp index 3, 0.001-0.01 BTC hedges).

Output: findings with severity, PoC name and result, root cause, concrete fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
