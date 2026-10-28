Re-review the step 5 implementation after s5i1 (docs/reviews/review-s5i1.out.md, CHANGES: 3
medium, 2 low); the fix diff is HEAD~1..HEAD. Changes: step5 refuses to run until g1.json exists;
g1 now uses the open and close receipt blocks A and C, reads 0x800 pinned at every block from
A - 5 to C + 15, and passes only if every read succeeds and the series is exactly 0, one switch to
the open size within [A, A + 10], one switch back to 0 within [C, C + 10], 0 to the end; px8
refuses precision finer than 1e-8 instead of truncating, order5 takes an exact 1e8 price, and
close-partial sends the quoted touch price as is; LIVE_POLL and pinned pace default to 2.5 s
(72 requests/min for a batch of three), and each position-changing order records a bracket (first
hit, last miss, errors between, degraded if any failed read lies between or no miss precedes the
hit); order5 re-reads pendingCloid immediately before acknowledging; unwind checks the returned
order's cloid, coin, side and size (in lots) and pendingCloid before acknowledging; book records
receive wall time, the asset index from mainnet meta and a session header with the fee basis.
Is anything from s5i1 still open, and anything new. Read-only. End with VERDICT: APPROVE or
VERDICT: CHANGES and a numbered list with severity.
