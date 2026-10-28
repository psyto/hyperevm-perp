The major s5/s5b/s5c findings are otherwise closed, including scope, G1, reduce-only recovery, race scoping, side denominators, and fee provenance.

VERDICT: CHANGES

1. **Medium — `close-partial` still compares incompatible quantities.** `0x800.szi` is in integer lots, while `userFills.sz` is base-asset decimal size. For BTC, a 0.00015 fill is compared with `szi = 15`, so `F = P` and the `0x800` delta agreement cannot work. Normalize both to exact integer lots (no floats) before classification. Also explicitly obtain the numeric exchange `oid` from the terminal `orderStatus` record and match fills by it; the submitted cloid is a different identifier. [Info API documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint)

2. **Medium — question 1 still does not specify a fill-to-visibility measurement.** It calls the result “after a fill,” but G1 backfill starts from the EVM order block and reports only block timestamps. Recording `userFills.time` without defining its use leaves this as order-block-to-`0x800` latency, including CoreWriter delay. Report the visibility interval relative to the matched fill timestamp (with the API/block-clock caveat); retain receipt/block-to-visibility as the separate question 3(b) metric.

3. **Low — terminal-status bounds lack the first-poll case.** A first `orderStatus` poll can already be terminal, leaving no previous non-terminal poll. Define its lower bound as receipt arrival (or explicitly mark it unavailable), rather than requiring a nonexistent previous poll.