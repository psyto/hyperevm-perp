Re-review docs/step5-close-from-evm-spec.md after s5d (docs/reviews/review-s5d.out.md, CHANGES:
2 medium, 1 low). Changes: close-partial works in exact integer lots (userFills sz strings
converted without floats; BTC szDecimals 5) and matches fills by the numeric exchange oid taken from
the terminal orderStatus record, not by cloid; question 1 now starts from the matched userFills
time (Core clock) and ends at the G1-dependent 0x800 visibility bound, with the clocks used named
per figure, and receipt-to-visibility kept as question 3(b); when the first orderStatus poll is
already terminal, the lower bound is the receipt's arrival. Is anything from s5-s5d still open,
and anything new. Read-only. End with VERDICT: APPROVE or VERDICT: CHANGES and a numbered list
with severity.
