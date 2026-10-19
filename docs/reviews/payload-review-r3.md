You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 3, narrow.

Same repo (src/HedgedPerp.sol, docs/design.md). Round 2 (docs/reviews/r2.md, your output review-r2.out.md) found that design.md overstated the hedge bound. Commit c96daaf answers it by documentation, not by freezing settles: the Core gap is the usual lag (no size bound, time-bounded by the next hedge()) plus at most one in-flight order the wrong way; HEDGE_QUIET is now 10 s (was 30 s); freezing settles during an order was rejected because the keeper could then hold closes back by hedging.

Review by breaking (failing tests under test/poc/ only; do not edit src/ or existing tests), then answer:
1. Is the new wording in docs/design.md ("The hedge lags…" and "One IOC per 10 s") accurate for the code? Any case where the gap exceeds "lag + one order", e.g. two orders both running because the first ran later than 10 s (stated), or something not stated?
2. Is the reason for not freezing settles sound, or is there a freeze that the keeper could not abuse (e.g. bounded so a request's 15 s window always has a settleable second)?
3. Does the 10 s quiet create any new problem in the code (tests, hedge() reverts, interplay with SETTLE_WINDOW)?
4. Anything else in the current code you would block on before a testnet run with small amounts (testnet USDC, BTC perp, 0.001-0.01 BTC hedges).

Output: findings with severity, PoC name and result, root cause, concrete fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
