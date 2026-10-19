## High — multiple late IOCs can accumulate; “lag + one order” remains false

PoC: [R3AccumulatedLateIocs.t.sol](test/poc/R3AccumulatedLateIocs.t.sol)

Result: intentionally fails:

```text
documented lag plus one-order bound: 50000 > 25000
```

`hedge()` only waits for `HEDGE_QUIET`; it has no acknowledgement that the previous IOC executed. If Core is delayed for 20+ seconds, calls at 0, 10, and 20 seconds all see the same Core position and send three identical orders. After trader exposure reverses, all can execute wrong-way. This is unbounded in the number of missed quiet periods, not merely “doubled once.” The code and design wording at [HedgedPerp.sol:244](src/HedgedPerp.sol:244) and [design.md:50](docs/design.md:50) are therefore inaccurate.

Fix: if the intended invariant is a one-order bound, record one unconfirmed order and do not send another until Core state shows a position change attributable to it. A zero-fill/rejected IOC then sacrifices automatic retry/liveness—the unavoidable cost without a Core execution acknowledgement. Otherwise, explicitly document that delayed actions can accumulate without a size bound and enforce a keeper operational rule not to retry before observing terminal Core state.

The existing suite remains green: `34 passed`. The dedicated PoC fails as above.

## Medium — the rationale against freezing settles is too broad

An indefinite/global freeze keyed to every hedge would let the keeper continually delay closes. But a per-request, non-extendable cap avoids that: e.g., block a settle for `min(hedgeQuietUntil, requestedAt + 13)` only, leaving the final two seconds of the 2–15 second window available regardless of later hedge calls.

That improves close availability but does not solve late IOC execution after the cap. It should be paired with the unconfirmed-order fix above if hedge-position bounds matter.

## 10-second quiet / settle-window interaction

No new direct settle revert exists: `hedge()` does not gate `settleOpen` or `settleClose`, and 10 seconds fits inside the 15-second window. The new problem is the increased chance of repeated unacknowledged orders; 10 seconds makes the PoC feasible after only three calls. The documentation mentions one delayed order being doubled, but not repeated accumulation.

No additional code blocker surfaced for a tightly supervised, very-small testnet experiment, provided the keeper never retries an IOC until observing its Core result. That procedure is not currently enforced by the contract.

VERDICT: CHANGES
