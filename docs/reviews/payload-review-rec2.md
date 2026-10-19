Re-review recorder/orders.py after your rec1 review (docs/reviews/review-rec1.out.md, VERDICT: CHANGES).
Changes: strict terminal-status allowlist; per-kind expected outcome, cloid/coin/side/size/limit check,
and position-delta check, stopping without acknowledge on any mismatch; preflight of pendingCloid,
open orders, and starting position/account before every send; tx hash written before receipt polling,
receipt deadline, block hash and log index recorded; watch mode removed; monotonic clock and timings
documented as client-observed; backoff/retries and slower receipt polling; key-file permission check.
Same scope as before: will it acknowledge a non-final order, leave a position open, or put two orders
on Core; is anything from rec1 still open; anything new. Read-only. End with VERDICT: APPROVE or
VERDICT: CHANGES and a numbered list with severity.
