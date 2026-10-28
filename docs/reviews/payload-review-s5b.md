Re-review docs/step5-close-from-evm-spec.md after s5 (docs/reviews/review-s5.out.md, CHANGES:
3 high, 2 medium). Changes: scope note that these are CoreWriter/precompile primitive measurements,
not HedgedPerp's liquidate-then-hedge path; position visibility reported as an interval from reads
pinned to explicit block numbers with backfill, fill time from userFills `time` matched by oid
(unmatched fills counted and excluded); 0x80F/0x807 vs info API reported as differences with
request timing and order, no staleness claim; BBO dropped; every close and recovery close (unwind
included) uses rawIocReduceOnly, acknowledgement needs the exact pending cloid plus a terminal
status and matching position, timeout or mismatch leaves the slot locked; long and short cases;
new kinds close-partial (skipped and counted when the touch is not smaller than the position) and
close-wrongside, with flat/over/wrongside named as the outcomes of a position Core changed first;
larger n, three sessions on different days, random order with seed, p90 only where n >= 30, rule
of three bounds for zero failures; mainnet book method defined (mid baseline, side, VWAP walk,
fee separate, insufficient displayed depth, raw snapshots, missed intervals, labelled as a
displayed-book estimate). Is anything from s5 still open, and anything new. Read-only. End with
VERDICT: APPROVE or VERDICT: CHANGES and a numbered list with severity.
