All s5–s5f findings are closed. Two new measurement gaps remain.

1. **Medium — `close-partial` cannot drive the live-read stop condition as specified.** Its expected final size depends on `F`, which is only established after terminal status and the subsequent fill-completeness polling. The live stream begins at receipt, so it cannot know which size to stop on or preserve as its first matching observation. Record the complete live stream for 30 seconds (or until post-terminal `F` is stable), then select the first read matching `s × (P − F)` and its preceding non-match.

2. **Medium — question 3(b) is invalid for no-change orders unless excluded or redefined.** For `close-flat`, the first `0x800` read can show zero because it was already zero; similarly, `close-tight`’s first attempt and `close-wrongside` target the unchanged pre-order position. That is not evidence of the order’s outcome or a close-latency bound. Restrict 3(b) to state-changing closes, or report these cases separately as “target already present at receipt,” with status timing as the applicable measure.

VERDICT: CHANGES