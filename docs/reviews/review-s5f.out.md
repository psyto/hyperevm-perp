The s5–s5e findings are otherwise closed, including the final-fill anchor, cross-clock labeling, and local-clock treatment for question 3.

VERDICT: CHANGES

1. **Medium — question 3(b) is not runnable as defined when G1 passes.** It requires the first *live* `0x800` observation with local request/receive brackets, but the G1-pass procedure only performs pinned historical reads and records block data; local timing is recorded only in the G1-fail path. Run an unconditional live-read stream from receipt onward, recording each request/receive time and prior non-match; retain pinned backfill solely for question 1.

2. **Medium — the single pending-cloid slot lacks an acknowledgement state machine for multi-attempt and negative cases.** `close-tight` and observed `close-partial` require a second order, while `close-flat` and `close-wrongside` leave a non-flat state. Each first order must be acknowledged before another order or `unwind` can be sent, yet the rules do not explicitly permit/define acknowledgement after the expected terminal non-flat or partial result. Specify those intermediate acknowledgement checks, then submit the residual/recovery reduce-only order.