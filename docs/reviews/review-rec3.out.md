VERDICT: APPROVE

1. **Informational — rec2 high is closed.** `status` exposes the recovery state, and `unwind` is safely gated on no pending cloid/no open orders and only acknowledges a filled order once BTC is flat. That is adequate for this deliberately manual, small testnet measurement.

2. **Informational — rec2 medium is closed.** Receipt polling now survives RPC failures until the deadline; the durable `sent` record plus `status` supports manual reconciliation. Automatic resume is not needed for this scope.

3. **Low — the 60-second receipt deadline is not strict.** One `rpc()` call can consume roughly 50 seconds through its internal retries/timeouts, so a subsequent retry can make wall-clock waiting exceed 60 seconds. This only delays fail-closed recovery; it cannot release the order gate or create another order.