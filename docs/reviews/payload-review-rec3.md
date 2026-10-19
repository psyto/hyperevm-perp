Re-review recorder/orders.py after rec2 (docs/reviews/review-rec2.out.md, CHANGES: 1 high, 1 medium).
Changes: `status <pool>` prints pendingCloid, its orderStatus, open orders and position for manual
recovery; `unwind <pool>` closes a leftover position with one IOC (only when pendingCloid is 0 and no
open orders; acknowledges only if filled and flat); receipt polling now keeps waiting to its 60 s
deadline through RPC errors. Recovery from a stop is by hand with these two commands (testnet,
~12 USD positions); an automatic resume is deliberately not built. Is that adequate for this testnet
measurement, is anything from rec1/rec2 still open, anything new. Read-only. End with VERDICT: APPROVE
or VERDICT: CHANGES and a numbered list with severity.
