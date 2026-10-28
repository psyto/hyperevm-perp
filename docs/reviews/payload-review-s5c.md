Re-review docs/step5-close-from-evm-spec.md after s5b (docs/reviews/review-s5b.out.md, CHANGES:
1 high, 3 medium, 1 low). Changes: gate G1 before any runs tests whether eth_call at explicit old
block numbers returns historical 0x800 state (position opened at A, closed at C, reads before,
between, after); backfill is used only if G1 passes, otherwise first live observation at latest
with request send/receive times and eth_blockNumber around each call, no block attribution; the
flat/over/wrongside kinds are now described as end states only and the in-flight race is listed
as untested; close-partial is classified from userFills for its oid (partial only if 0 < filled <
pre-close position; else zero-fill/full-fill/indeterminate), with results and bounds from observed
partials only; every kind x side cell reports its own denominator and the exact bound
1 - 0.05^(1/n); the taker fee is the dated base-tier rate from the fee schedule, reported
separately. Is anything from s5 or s5b still open, and anything new. Read-only. End with
VERDICT: APPROVE or VERDICT: CHANGES and a numbered list with severity.
