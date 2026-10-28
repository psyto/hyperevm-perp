Four s5i1 findings are fixed: stronger G1 shape validation, exact px8/touch handling, rate headroom plus degraded brackets, and stricter unwind acknowledgement. Syntax compilation and `git diff --check` pass.

VERDICT: CHANGES

1. **Medium — G1 is not scoped to the pool and is bypassed by `lag`.** A passed shared `g1.json` from any pool enables pinned reads for any later `step5 <pool>` invocation; it records neither pool nor chain context. Also [`lag()`](recorder/orders.py:691) performs Step 5 orders without requiring G1, despite the spec saying G1 occurs before any runs. Bind G1 output to the pool/chain and enforce it for all Step 5 commands, or explicitly exempt lag in the spec.

2. **Medium — the new px8 rejection can leave `close-partial` exposure open.** [`px8(touch["px"])`](recorder/orders.py:597) now raises on an over-precise quote after the opening order has already been acknowledged. The exception exits without the reduce-only cleanup, leaving the position open. Catch and record the rejected touch, then run the existing reduce-only cleanup.

3. **Low — the book fee record remains incomplete.** The new session header has a timestamp and fee-schedule link, but only states that the write-up will add the base-tier taker rate; it does not capture the actual rate. That leaves the prior fee/date/link evidence requirement only partially addressed.