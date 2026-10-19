You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 6, narrow.

Same repo (src/HedgedPerp.sol, docs/design.md; rounds 1-5 in docs/reviews/). Commit HEAD adds a testnet-only contract for the next testnet run, src/testing/TestnetPricedPerp.sol, and makes HedgedPerp.guardedPrice() and liquidationPrice(bool) virtual. TestnetPricedPerp: the keeper sets the settle/liquidation price (so liquidation can be exercised; BTC will not move 3.75% on request); the hedge still uses the real Core quote (_hedgeLimit, not overridden); rawIoc() sends one IOC exactly as given with a cloid that has the top bit set, outside pendingCloid, to measure what orderStatus returns for a CoreWriter IOC that does not fill; the constructor reverts unless chainid == 998 (HyperEVM testnet). Tests: test/TestnetPricedPerp.t.sol.

Planned run with it (testnet USDC, a few USDC): fund; 2 USDC 20x long settled at a set price; hedge on the real book; setPrice -3.75% and liquidate; hedge back; rawIoc a buy far below the book (expect iocCancelRejected); empty the pool's Core perp account and hedge() a new position (expect perpMarginRejected); acknowledge each by its final orderStatus; unwind.

Review by breaking (failing tests under test/poc/ only; do not edit src/ or existing tests):
1. Does making the two price functions virtual change HedgedPerp's own behaviour anywhere (every internal path that reads a price)?
2. Is TestnetPricedPerp safe to the extent it claims (testnet only, enforced), and does the mix of a set price for settles and the real quote for the hedge break any accounting the run relies on (capital, held, owed, targetLots)?
3. Can rawIoc() interfere with hedge() bookkeeping or acknowledge() (cloid collisions, pendingCloid)?
4. Will the planned steps produce the expected Core statuses, as far as docs say? Anything in the plan that could lose more than the few USDC, or leave funds stuck (note: the pool cannot return Core HYPE to the EVM; that is known)?

Output: findings with severity, PoC name and result, root cause, concrete fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
