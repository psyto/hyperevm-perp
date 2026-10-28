Re-review docs/step5-close-from-evm-spec.md after s5g (docs/reviews/review-s5g.out.md, CHANGES:
2 medium). Changes: the live 0x800 stream now records for a fixed 30 s (longer until F is stable
after the terminal status), and the target size is chosen afterwards from the acknowledge table
(close-partial: s x (P - F) once F is known), then the first matching read and the last
non-matching read before it are selected from the recording; question 3(b) counts only
position-changing orders (close-fill, close-tight second close, close-partial closes with F > 0,
close-over, close-wrongside's closing order), and no-change orders (close-flat, close-tight first
close, close-wrongside same-direction order, close-partial with F = 0) are reported separately as
"target already present at receipt" with 3(a) status timing as their measure. Is anything from
s5-s5g still open, and anything new. Read-only. End with VERDICT: APPROVE or VERDICT: CHANGES and
a numbered list with severity.
