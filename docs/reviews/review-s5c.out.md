The three s5 high findings are closed in the spec. G1 remains an explicit pre-run empirical gate, which is appropriate. The deliberately untested in-flight external-position race is now honestly scoped out.

VERDICT: CHANGES

1. **Medium — `close-partial` remains under-specified for short positions and multi-fill orders.** Define `P = abs(pre-close szi)`, aggregate all fills for the exact `oid`, and specify a timed/retried completeness rule before classifying zero/full/partial. As written, “filled size < position before” is invalid for a signed short and an incomplete `userFills` response can misclassify a full fill.

2. **Medium — close-latency timing is not sufficiently recorded or bounded.** The spec reports time from inclusion block to the first terminal status, but only requires request/response timing for the live `0x800` fallback and paired reads. Record send/receive times for every `orderStatus` poll and report this as client-observed latency with inclusion/receipt uncertainty, rather than an exact block-to-status delay.

3. **Medium — the planned partial runs do not ensure long and short coverage.** `close-partial` has ten undivided attempts, unlike the explicitly split kinds. Assign attempts by side (and report observed-partial denominators per side), or state that a zero-observation side produces no conclusion.

4. **Low — the cost estimate still states an undated “4.5 bp per side.”** The book methodology fixes the reporting basis, but the Money section should also identify this as the dated base-tier schedule rate or as a pre-run estimate to be rechecked.