The prior s5–s5d findings are closed. Two new measurement-definition gaps remain.

1. **Medium — fill-to-visibility is undefined for multi-fill orders.** Question 1 anchors to “the matched `userFills` entry,” but `close-partial` correctly aggregates multiple entries for one `oid`. The first `0x800` state with the final expected size cannot be attributed to an unspecified individual fill. Define the metric as final-state visibility anchored to the last contributing fill, or define per-fill cumulative-state matching.

2. **Medium — naming distinct clocks does not make the reported values physical latency bounds.** Question 1 subtracts a Core `userFills.time` timestamp from EVM block timestamps or local request times; question 3(b) similarly mixes receipt-local and block clocks. Without a stated synchronization/error bound, these are cross-clock timestamp deltas, not lower/upper bounds on propagation latency. Calibrate/bound clock offsets, or label them accordingly and retain local-clock observation brackets as the defensible client-observed bounds.

VERDICT: CHANGES