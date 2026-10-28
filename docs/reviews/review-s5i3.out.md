All s5i1/s5i2 findings are fixed, including the actual fee values (`feeSchedule.cross`/`add`) required by Hyperliquid’s `userFees` schema. [Official API docs](https://hyperliquid.gitbook.io/Hyperliquid-docs/for-developers/api/info-endpoint)

Note: a blocked compile probe left an untracked `recorder/__pycache__/orders.cpython-311.pyc`; AST syntax parsing and `git diff --check` passed.

VERDICT: CHANGES

1. **Low — Step 5’s plan and records remain cross-pool.** [`step5_plan.json`](recorder/orders.py:639) has no pool binding, so after pool A advances it, pool B can pass its own G1 then resume A’s `done` index. The session and order rows also omit the pool. This makes per-pool planned denominators and provenance ambiguous. Bind the plan to its pool (or use per-pool files) and record pool/chain/G1 provenance in each session.