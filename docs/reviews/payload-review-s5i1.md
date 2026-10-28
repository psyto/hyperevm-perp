Review the step 5 implementation against docs/step5-close-from-evm-spec.md (s5h APPROVE): the diff
of src/testing/TestnetPricedPerp.sol (rawIocReduceOnly via a shared internal _rawIoc; RawOrder
gains a reduceOnly field), test/TestnetPricedPerp.t.sol (2 new tests), and recorder/orders.py
(px5 rounding to 5 significant figures, both RawOrder topics accepted, unwind now reduce-only and
checks pendingCloid equals the cloid it sent, and the new step 5 section: lots/px8 exact
conversions, live 0x800 stream thread, track5, fill completeness, order5 with the acknowledge
table, cycle5 per kind, step5 plan with seed, g1, lag, book). Nothing has been sent on testnet;
read-only checks only. Check: (1) the contract change keeps the slot, cloid sequence and
acknowledge rules of r3-r6b exactly; (2) order5 and cycle5 implement the spec's acknowledge table,
fail-closed rules and reduce-only-for-every-close rule, with no path that acknowledges or sends
the next order on an unexpected status, position or fill class; (3) measurement correctness:
local-clock brackets, live stream vs fills completeness, pinned reads only when G1 passed, G1's
pass rule, partial classification in lots by exchange oid; (4) RPC rate use (public EVM RPC about
100 requests/min; LIVE_POLL 1.8 s default, batch of three per sample) and what a rate-limited
stream does to the data; (5) thread safety of the live stream; (6) the mainnet book method;
(7) anything that could move funds unexpectedly or leave a position open without stopping.
Read-only. End with VERDICT: APPROVE or VERDICT: CHANGES and a numbered list with severity.
