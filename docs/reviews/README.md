# Reviews

Each round: the prompt sent to Codex (`payload-review-rN.md`), its full output
(`review-rN.out.md`), its proof-of-concept tests (`rN-poc.t.sol.txt`, kept as text so they do
not run with the suite; each says which commit it ran against), and what was fixed (`rN.md`).
Test counts quoted in Codex's outputs include its own PoCs.

| Round | Notes |
|---|---|
| [r1](r1.md) | whole market |
| [r2](r2.md) | round-1 fixes |
| [r3](r3.md) | round-2 fixes; the hedge's in-flight order rebuilt |
| [r4](r4.md) | the rebuild; keeper acknowledgement by cloid |
| [r5](r5.md) | acknowledgement procedure (with web search) |
| [r6](r6.md) | the testnet-only copy; r6b APPROVE |
| rec1–rec3 | `recorder/orders.py`; rec3 APPROVE (payloads and outputs only) |
| s5–s5h | `docs/step5-close-from-evm-spec.md` (the spec); s5h APPROVE. Payloads and outputs only: each round's fixes are in the spec itself, whose status line names the rounds. Local paths in the outputs were removed |
| s5i1–s5i5 | step 5 implementation (`rawIocReduceOnly`, recorder `g1`/`step5`/`lag`/`book`); s5i5 APPROVE. Payloads and outputs only; the fixes are the commits between them |
