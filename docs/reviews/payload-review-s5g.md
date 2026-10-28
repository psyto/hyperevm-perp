Re-review docs/step5-close-from-evm-spec.md after s5f (docs/reviews/review-s5f.out.md, CHANGES:
2 medium). Changes: the live 0x800 read stream from receipt arrival now runs for every order
regardless of G1 (it serves question 3(b) and question 1's end if G1 fails); pinned historical
reads run only if G1 passes, only for question 1's end, after the live stream; the acknowledge
rule now has a per-order table (opening rawIoc, each close of each kind, the second/residual
closes of close-tight and close-partial, the negative cases) giving the expected terminal status
and the expected position in lots, so each first order is acknowledged before the next order; for
close-flat, close-over and close-wrongside's first order the status name is recorded and any
terminal status is acknowledged only if the position matches; close-partial indeterminate stops
the run. Is anything from s5-s5f still open, and anything new. Read-only. End with VERDICT:
APPROVE or VERDICT: CHANGES and a numbered list with severity.
