You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 5, narrow.

Same repo (src/HedgedPerp.sol, docs/design.md). Round 4 (docs/reviews/r4.md, your output review-r4.out.md) showed no on-chain signal acknowledges a CoreWriter order. Commit 83125cf follows your suggested fix: each hedge IOC gets a fresh nonzero cloid (++lastCloid); hedge() reverts OrderInFlight while pendingCloid != 0; the keeper calls acknowledge(cloid) after reading the order's status by cloid from the Hyperliquid info API; no automatic retry; settles never wait for the hedge. The keeper is the only liquidity provider and payouts are EVM-backed only, so a wrong acknowledgement risks only Core money.

Review by breaking (failing tests under test/poc/ only; do not edit src/ or existing tests), then answer:
1. Is the on-chain part now correct and minimal: cloid uniqueness (per pool, across redeploys at different addresses, uint128 encoding in the CoreWriter limit-order action), acknowledge() guards, anything left from the removed timer/position logic?
2. The off-chain procedure: can the keeper reliably decide "final" from the info API for an order sent through CoreWriter? Concretely: does `{"type":"orderStatus","user":<pool>,"oid":"0x<32 hex cloid>"}` find CoreWriter orders by cloid; what does it return for an IOC that filled, for one that found no liquidity, and for an action Core rejected before it reached the book (e.g. insufficient perp margin) — is "never registered" distinguishable from "not yet processed"? What should the keeper wait for before acknowledging an unknown order? Cite Hyperliquid docs; say where they are silent so this can be measured on testnet.
3. Is docs/design.md ("One outstanding order…", "Settles never wait…", "What is left") accurate now?
4. Anything you would still block on before a small, supervised testnet run (testnet USDC, BTC perp index 3, 0.001-0.01 BTC hedges, keeper acknowledging by hand).

Output: findings with severity, PoC name and result, root cause, concrete fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
