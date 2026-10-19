## High — `unknownOid` is not safe acknowledgement finality

**PoC:** [R5UnknownCloidPoC.t.sol](test/poc/R5UnknownCloidPoC.t.sol)  
**Result:** fails as intended: `early unknownOid releases a second queued IOC: 2 != 1`. The normal suite remains 38/38 passing.

**Root cause:** `acknowledge()` correctly trusts only the keeper, but the documented runbook permits “never registered by Core.” An `orderStatus` miss returns only `{"status":"unknownOid"}`; it does not distinguish an order that will never exist from a CoreWriter action still in its documented several-second delay / indexing lag. CoreWriter actions are explicitly delayed and appear first as enqueue, then execution. [CoreWriter docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore) [Info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#query-order-status-by-oid-or-cloid)

**Concrete fix:** remove “or never registered by Core” from `design.md`. Never acknowledge or retry on `unknownOid`; leave `pendingCloid` set. Acknowledgement requires an explicit terminal order-status record.

The requested query is the documented format: `type: "orderStatus"`, actual pool address as `user`, and `oid` as a zero-padded 16-byte / 32-hex-digit cloid. Once registered, the documented outcomes are:

- Fill: `order.status: "filled"`.
- IOC with no match: `order.status: "iocCancelRejected"`.
- Insufficient perp margin: `order.status: "perpMarginRejected"`.

Those are terminal; `open` is not. The docs describe cloid lookup and status values, but do not explicitly promise CoreWriter-to-Info indexing latency or state that `unknownOid` is permanent. Measure that on testnet: record EVM submission, CoreWriter enqueue/execution, first `orderStatus` visibility, and terminal status for fill, no-liquidity, and margin-rejection cases. The `orderUpdates` subscription can assist observation, but should not turn an unknown response into finality. [Info status reference](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint#query-order-status-by-oid-or-cloid) [Order-updates subscription](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions)

## On-chain review — no finding

`lastCloid` produces fresh nonzero `uint128` values per pool lifetime; `pendingCloid` gates `hedge()`, and `acknowledge()` requires the exact nonzero pending value and the keeper. The CoreWriter encoding is exactly the documented `(uint32,bool,uint64,uint64,bool,uint8,uint128)` limit-order schema. [CoreWriter encoding](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore)

Cloid reuse across separately deployed pool addresses is not a collision: the status lookup is scoped by required `user`, and each pool is a different Core account. There is no timer/`orderFrom`/settle-wait logic left in production code.

`Settles never wait` is accurate. `What is left` should say the lag has no protocol-enforced time bound—it lasts until the keeper gets an explicit terminal result and hedges again. “At most one wrong-way order” is accurate only under that operating rule.

For the proposed supervised testnet run, I would block only the `unknownOid` acknowledgement path. Manual acknowledgement after an observed terminal status, using disposable funds and the three-case measurement above, is appropriately narrow; trader claims remain EVM-backed.

VERDICT: CHANGES
