Found 1 issue.

- **High — A late IOC can leave a Core mismatch far larger than `maxHedgeLots`.**  
  **PoC:** [HedgedPerpRound2.t.sol](test/poc/HedgedPerpRound2.t.sol:99), `test_PoC_inFlightOrderDoesNotBoundCoreMismatchAfterExposureReversal` — PASS (reproduces the violation). An existing +1 BTC Core hedge plus a queued +1 BTC IOC is followed by traders reversing to −2 BTC. Once the IOC fills, Core is +2 BTC against −2 BTC traders: a 4× `maxHedgeLots` gap, while correction remains blocked by `HEDGE_QUIET`. With a larger pre-existing hedge, the discrepancy is not bounded by the pending order at all.  
  **Root cause:** `hedge()` only limits the newly submitted IOC; it does not freeze or otherwise constrain exposure-changing `settleOpen`, `settleClose`, or `liquidate` actions while that IOC is unresolved. This contradicts the stated bound in [design.md](docs/design.md:49). It does not recreate the round-1 trader insolvency because Core value is excluded from EVM capital, but it can lose substantially more Core/LP collateral than documented.  
  **Fix:** Block all exposure-changing settlements and liquidations while a Core order is in flight, or explicitly track/reserve the maximum possible mismatch including the existing Core position and all permitted target changes. Given the asynchronous Core interface, the simpler honest alternative is to document this as an unbounded-in-size Core hedge risk rather than `maxHedgeLots`-bounded.

The round-1 fixes otherwise hold under normal USDC semantics: capital/claims remain EVM-backed; `held` and `owed` prevent defund and claim-order drains; donations/Core→EVM arrivals only increase balance. Permissionless settlements retain the documented 13-second timing option, but same-block front-running uses the same oracle price. At `== SETTLE_WINDOW`, settlement is allowed and cancellation is not; one second later the reverse holds. Liquidation winning a close race is expected by the stated liquidation rule.

`forge test -vv`: **35 passed, 0 failed** (34 existing, 1 PoC).

VERDICT: CHANGES
