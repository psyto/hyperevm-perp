Found 3 issues. Added reproducible PoCs in [HedgedPerpRound1.t.sol](test/poc/HedgedPerpRound1.t.sol:8). `forge test -vv`: **70 passed, 0 failed** (including 4 PoC cases).

- **High — Delayed hedge can become the wrong-way naked position and bankrupt claims.**  
  **PoCs:** `test_PoC_delayedHedgeBecomesNakedAfterClose`, `test_PoC_staleHedgeCanConsumeTheReserveNeededForAnotherTrader` — pass.  
  **Root cause:** `hedge()` submits an asynchronous IOC, then only sets a 30-second lock. Trader exposure may close or reverse before the Core action executes; a fill then creates a Core position opposite to the current book. The pool cannot correct it during `HEDGE_QUIET`. The insolvency PoC flips exposure, wipes the Core reserve with the stale hedge, then proves Bob’s valid 5×-capped credit cannot be claimed. CoreWriter order actions are explicitly delayed for seconds, so EVM reads cannot observe the submitted action synchronously. [Hyperliquid CoreWriter docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)  
  **Fix:** Treat orders as in-flight risk. Serialize book-changing settlements while a hedge is unresolved, track a bounded pending intent and reconcile it only after Core finality, and reserve capital for the maximum adverse stale-order exposure. CLOIDs/cancellation can help operationally, but do not replace confirmation.

- **High — The keeper has a free 118-second settlement option against every trader.**  
  **PoC:** `test_PoC_keeperHasA120SecondFreeOptionOnEveryClose` — pass.  
  **Root cause:** only the keeper may settle; it can wait within the 2–120-second window and select the most favorable checked oracle price. The PoC requests a long close when it would pay 149 USDC, then the keeper waits and settles it for 49 USDC. If price validation fails, the keeper can simply allow expiry, returning a closing position to `Open`, and repeat the option.  
  **Fix:** Remove unilateral timing discretion: settle at a deterministic, independently recorded price/time, or introduce an enforceable permissionless settlement mechanism with a committed snapshot. A permissionless 120-second window alone merely transfers the option to the caller.

- **Medium — `hedge()` reports success although Core will certainly reject an unactivated pool account.**  
  **PoC:** `test_PoC_hedgeClaimsSuccessForAnUnactivatedCoreAccount` — pass.  
  **Root cause:** `coreLots()` returns zero for a nonexistent Core account, after which `hedge()` queues an order, emits `Hedged`, and starts the quiet period. Hyperliquid states that unactivated accounts cannot send CoreWriter actions and that even an EVM→Core transfer in the same block is too late to initialize the account. [Activation requirement](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/activation-gas-fee), [execution timing](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings)  
  **Fix:** Require an explicit Core-ready initialization step that verifies `userExists` before accepting hedges or opening hedge-dependent risk; revert `hedge()` when not ready. Also operationally verify collateral and market leverage, since Core applies margin checks when orders open/match. [Hyperliquid margining](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/margining)

I found no separate arithmetic defect in the 1e30 PnL conversion, fee rounding, `held`/`owed` transitions, ID lifecycle, or liquidation’s better-price rule under the exact-USDC assumptions. The `maxProfits` rule is only sound while the capital it counts cannot be lost to an untracked/wrong-way Core hedge; the first finding violates that prerequisite.

VERDICT: CHANGES
