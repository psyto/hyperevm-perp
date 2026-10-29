# Review s5r1: step 5 testnet session 1 — results and handling, before session 2

Adversarial review. Spec: docs/step5-close-from-evm-spec.md (s5h APPROVE). Recorder:
recorder/orders.py at 2e62211 (s5i6 APPROVE). Session 1 data (read only) in <scratchpad>/s1/:
g1.json, step5.jsonl, step5_plan.json, step5-s1.log, orders.jsonl.

What happened (testnet, 2026-10-29, pool 0x7cD037094A60666280E6CB389e696DED19Da5D6f):
1. G1: open at A=68156552, close at C=68156586, then 0x800 by eth_call pinned at A-5..C+15:
   all 55 reads returned 0, so G1 failed and question 1 uses live reads only.
2. step5 seed 1029, 40 cycles requested; stopped at cycle 22 (22 of 120 done): the opening rawIoc
   of close-wrongside (long) came back iocCancelRejected. Oracle 80,055.7, limit oracle+1% = 80,856,
   testnet asks around 80,948. The run stopped with pendingCloid set, as designed.
3. Manual recovery: orderStatus for that cloid = iocCancelRejected, openOrders = [], position 0
   (clearinghouseState), then acknowledge(cloid) by hand. Plan stays at done=22.
4. Close brackets: 11 closes already flat at the first live read after the receipt (bracket
   degraded), 9 flat at the next read ~2.5 s later (LIVE_POLL 2.5 s).

Questions:
(a) Is the G1 conclusion sound from g1.json (could the reads be wrong for another reason, e.g. the
    call encoding, the block range, or the RPC answering "latest" — and does that matter)?
(b) Was the manual acknowledge correct under the spec's acknowledge rule, and did resuming leave the
    plan consistent (the failed cycle's item is still next; nothing double-counted in step5.jsonl)?
(c) The open limit is oracle ±1% (the spec's "1% through" is for closes; opens reuse through()).
    The testnet book drifts >1% from the oracle at times. Options: rerun unchanged and accept stops,
    or widen only the open limit to 2%. Which, and does widening open limits affect any measured
    quantity?
(d) Does the 2.5 s live-read pace make question 1 / 3(b) unanswerable at the resolution the spec
    claims (most closes are flat at the first read)? If so, what is the smallest change that fixes
    it within the RPC limit (100 requests/min), and does the spec need to say so before session 2?
(e) Anything in step5.jsonl that contradicts the acknowledge table or the plan.

Findings with severity and evidence (row/cycle). End with VERDICT: APPROVE (session 2 may run
unchanged) or VERDICT: CHANGES.
