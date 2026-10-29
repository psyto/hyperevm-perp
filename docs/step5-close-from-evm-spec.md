# Step 5 (spec): seeing and closing a contract's Core position from the EVM

Status: spec s5h APPROVE, built (s5i5 APPROVE); amended after testnet session 1 (review s5r1, below).

Steps 3 and 4 showed that a CoreWriter order reaches a final `orderStatus` within about 2 s. Step 5
asks the next question: if a contract's Core perp position backs something on the EVM side, how far
apart are the contract's precompile view and Core's own view, and how quickly and reliably can a
contract flatten that position with reduce-only orders sent through CoreWriter.

**Scope (s5 #1).** These are measurements of CoreWriter and precompile primitives, using a
testnet-only reduce-only order. They are not measurements of `HedgedPerp`'s own path: there,
`liquidate()` only removes EVM exposure and a later `hedge()` sends a non-reduce-only IOC sized from
`coreLots()`. That path is unchanged by this step and its results do not describe it.

## Questions
1. **Position visibility after the order's last fill.** From the last fill that contributes to an
   order (the latest `time` among the `userFills` entries with its oid; for a single fill, that
   fill) to the first contract-style `0x800` read showing the order's final size. The end depends
   on a gate (see Recorder, gate G1): if `eth_call` at an explicit old block number is shown to
   return that block's `0x800` state, the first matching block is found by backfill; if not (the
   public RPC is already known to ignore block numbers for `0x807`, hl-price-guard
   docs/safe-limits.md), the end is the first live read with the final size.
   **Clocks.** Core's fill `time`, EVM block timestamps (whole seconds) and the local clock are
   different clocks with no shared calibration. Question 1 is therefore reported as a
   **cross-clock delta**, labelled as such and not as a latency bound; the local clock's NTP offset
   (`sntp`) at the start and end of each session is recorded alongside for context only.
2. **Divergence from the info API.** While a position is open, paired readings of account value
   (`0x80F` vs `clearinghouseState`) and oracle price (`0x807` vs `metaAndAssetCtxs`). These are not
   a common snapshot; the report gives the difference together with the block read, each request's
   send and receive time and their order. No claim of "precompile staleness" is drawn from them.
   (BBO `0x80E` is dropped from step 5.)
3. **Close latency, as the client observes it.** From the receipt of the transaction that sends a
   reduce-only IOC to (a) the first `orderStatus` response carrying a terminal status, bounded by
   the send and receive times of that poll and of the previous non-terminal poll (when the first
   poll is already terminal, the lower bound is the receipt's arrival), and (b) the first live
   `0x800` read with the expected size, bounded by the send/receive times of that read and of the
   last read without it. Both (a) and (b) use only the local monotonic clock (receipt arrival and
   request times), so they are defensible client-observed brackets. Block timestamps are recorded
   but not mixed into these figures.
4. **Close outcomes**, for long and short positions. Every expected status below is a thing to
   confirm, not an assumption; the recorder records whatever comes back and stops on a surprise.
   - `close-fill`: open, then reduce-only close 1% through the oracle -> expected `filled`, flat.
   - `close-tight`: reduce-only close 15% on the wrong side -> expected `iocCancelRejected`,
     unchanged; then a second close 1% through -> expected `filled`. Time to flat over two attempts.
   - `close-partial`: reduce-only close for the whole position limited at the touch, sent when the
     touch's displayed size (raw snapshot with its request times kept) is smaller than the position;
     then the residual is closed with a second reduce-only order. The attempt is classified from
     fills, not from the book. All sizes are exact integer lots (BTC: szDecimals 5, so 0.00015 =
     15 lots); `userFills` decimal `sz` strings are converted to lots exactly, without floats. Let
     P = |szi| before the close and F = the sum, in lots, of all `userFills` entries whose numeric
     exchange `oid` equals the `oid` in the terminal `orderStatus` record for this cloid (the cloid
     itself is not used to match fills). Completeness: after the terminal status, re-read
     `userFills` every 2 s until two consecutive reads give the same F and F agrees with the change
     in `0x800` (|szi before| − |szi after|), or 30 s pass. Then `partial` only if 0 < F < P,
     `zero-fill` if F = 0, `full-fill` if F = P; anything else, or no agreement within 30 s, is
     `indeterminate`. Only observed
     partials count toward this kind's results and bounds; the other classes are reported as
     counts. Not attempted (and counted) when the touch is not smaller at send time.
   - `close-flat`: reduce-only close with no position -> to confirm the status name (expected
     `reduceOnlyRejected`) and that nothing opens.
   - `close-over`: reduce-only close for twice the position -> to confirm that only the position is
     closed.
   - `close-wrongside`: reduce-only order in the same direction as the position -> to confirm it is
     rejected and the position is unchanged.

   `close-flat`, `close-over` and `close-wrongside` start in those states. They show what a
   reduce-only order does when the position is already gone, smaller or reversed; they do **not**
   exercise Core changing the position while a CoreWriter close is in flight. That race stays
   untested in step 5 (see Not covered).
5. **Displayed-book close estimate on mainnet (read only).** See the book method below.

## Contract change
`TestnetPricedPerp.rawIoc` sends `reduceOnly = false`. Add one testnet-only function:

    function rawIocReduceOnly(bool isBuy, uint64 limitPx8, uint64 sz8) external onlyKeeper returns (uint128 cloid)

identical to `rawIoc` (same single `pendingCloid` slot, reverts `OrderInFlight` while it is set,
same cloid sequence, cleared only by `acknowledge(cloid)` with the exact pending cloid) except
`reduceOnly = true`. No change to `HedgedPerp`. New testnet deployment with the big-block steps of
step 3. Unit tests: the encoded action has the reduce-only flag set; the slot and acknowledge rules
are identical to `rawIoc` (in-flight revert, wrong-cloid acknowledge reverts, sequence shared).

Opening positions uses the existing `rawIoc`. **Every close and every recovery close uses
`rawIocReduceOnly` (s5 #3).**

## Recorder
Extend `recorder/orders.py`:
- `unwind` switches to `rawIocReduceOnly`. It still requires `pendingCloid == 0` and no open orders,
  and acknowledges only on a terminal status for that exact cloid with the position then flat.
- Acknowledge rule for every order: the pending cloid read from the contract equals the cloid this
  client sent, `orderStatus` for that cloid returns a terminal status from the existing list, and
  the status and the position after (in lots, from the live reads) match that order's row below.
  Only then is it acknowledged and the next order sent. Anything else, or no terminal status within
  60 s, stops the run and leaves the slot locked for `status` / manual handling. P is |szi| before
  the order; s is the open direction.

  | Kind, order | Expected status | Expected position after |
  |---|---|---|
  | any kind, opening `rawIoc` | `filled` | s × 15 |
  | `close-fill`, close | `filled` | 0 |
  | `close-tight`, first close | `iocCancelRejected` | unchanged (s × P) |
  | `close-tight`, second close | `filled` | 0 |
  | `close-partial`, first close | any terminal status; class from fills (partial / zero-fill / full-fill / indeterminate) | s × (P − F), agreeing with F; `indeterminate` stops the run |
  | `close-partial`, residual close (only if position ≠ 0) | `filled` | 0 |
  | `close-flat`, close | recorded (expected `reduceOnlyRejected`) | 0 |
  | `close-over`, close for 2P | recorded (expected `filled`) | 0 |
  | `close-wrongside`, same-direction reduce-only | recorded (expected a rejection) | unchanged (s × P) |
  | `close-wrongside`, then closing reduce-only | `filled` | 0 |

  For the three "recorded" rows the status name is what is being confirmed, so any terminal status
  is acknowledged if the position matches; a position that does not match stops the run.
- **Gate G1 (before any runs):** with the pool holding a position opened at a known block A and
  closed at a later block C, call `0x800` by `eth_call` at block numbers before A, between A and C,
  and after C, and record the results. Historical reads are accepted only if they return the size
  each block should have had. The outcome is written into the step 5 write-up before question 1 or
  3(b) is measured.
- Live reads, always (question 3(b), and question 1's end if G1 fails): from the receipt's
  arrival, poll `0x800` at `latest` as fast as the RPC limit allows (with `eth_blockNumber` before
  and after each call), recording each request's send and receive time and result, for a fixed
  30 s (or longer, until the order's fill total F is stable after its terminal status). The target
  size is chosen afterwards from the order's row in the acknowledge table (for `close-partial`,
  s × (P − F) once F is known), and the first read matching it and the last non-matching read
  before it are selected from the recorded stream.
- Question 3(b) counts only orders that change the position (`close-fill`, the second close of
  `close-tight`, `close-partial` first and residual closes when F > 0, `close-over`, the closing
  order of `close-wrongside`). Orders whose target equals the position before them
  (`close-flat`, the first close of `close-tight`, the same-direction order of `close-wrongside`,
  `close-partial` with F = 0) are reported separately as "target already present at receipt",
  with 3(a) status timing as their measure.
- Pinned reads, only if G1 passes (question 1's end only): after each order's block B, read
  `0x800` pinned to each explicit block number from B onward (recording the block hash),
  backfilling skipped blocks, until the final size is seen or 30 s of blocks pass; record the first
  matching block and its timestamp. Run after the live stream so the two do not share the rate
  budget.
- Every `orderStatus` poll records its send and receive times (local monotonic clock) and the
  status returned; every receipt records when it arrived.
- Fill time source: `userFills` (info API) for the pool's Core account, matched by `oid`, using its
  `time` field. If a fill cannot be matched there, the record says so and question 1 excludes it
  (counted, not dropped silently).
- `lag <pool> <n>`: with a position open, n paired readings for question 2, spaced at least 15 s.
- `book <coin...>`: question 5, mainnet info API only, to `recorder/data/book.jsonl`, raw snapshot
  included.
- Kinds and sides are run in a random order (seed recorded).

## Amendments after session 1 (review s5r1)
Session 1 (2026-10-29): G1 failed (all 55 historical reads 0), so question 1 uses live reads only.
The run stopped at cycle 22 of 120 when an opening `rawIoc` 1% through the oracle found nothing:
the testnet book sat over 1% above the oracle. These apply from session 2:
- **Opens go 2% through the oracle** (`open`, `g1-open`, `lag-open`); every close and recovery
  close stays at 1% (the measured quantity). Every order row records `through_bps`: 200 for opens,
  100 for closes, -1500 for close-tight's first close (15% the wrong way), `"touch"` for
  close-partial's touch-priced close. Session 1 rows have no such field; all of them ran at 100
  (recorder 2e62211), which a `session1_manifest` row in `step5.jsonl` states. Opening data at 1%
  and 2% are reported apart, never pooled. Closes are unaffected; opening fill price and fees are.
- **A stopped open is recovered with `ackopen`**, the only manual acknowledgement. It requires: the
  pending cloid is the last order row's cloid; that row is an opening `rawIoc`, stopped only because
  its status was not `filled`, with a zero-fill, agreed fill count and a flat position before; the
  status is terminal; and two reads `FILLS_EVERY` s apart each show zero `userFills` for its oid, a
  flat position and no open orders. The checks are written to `step5.jsonl` (`manual_ack`) before
  the acknowledgement is sent, and the transaction after (`manual_ack_sent`). Anything else stays for
  a person. Session 1's cycle-22 open was acknowledged by hand after the status, open-order and
  position checks (the zero fill count is in its stopped row), before this command existed; it is
  recorded as `manual_ack_retro` (transaction hash not captured) and excluded from every count.
- **Brackets.** Reads start at the receipt. When the first read already shows the target, the result
  is an upper bound from the receipt to that read, labelled "no observed post-receipt non-match",
  not a failed bracket. Otherwise the bracket is the last non-matching and the first matching read
  (about 2.5 s apart at the current pace). The pace stays at 2.5 s (three calls a read, about 72
  requests a minute against the RPC's 100).
- **Sessions end on record**: `session_end` is written on completion, a stop, or an exception, with
  the reason, and a failure to write it never replaces the stop being reported. A killed process
  (SIGKILL, power loss) leaves none. Session 1 ended before this; its end is recorded as
  `session_end_retro`. The clock check uses `sntp`, or `chronyc tracking` on the AWS host.

## Runs
Testnet BTC perp (index 3), 0.00015 BTC per position (about 12 USD), same key as steps 3-4. Spread
over at least three sessions on different days, including US and Asian hours.

| Kind | n (long + short) |
|---|---|
| `close-fill` | 60 (30 + 30) |
| `close-tight` | 20 (10 + 10) |
| `close-partial` | 10 attempted (5 + 5; skips counted; a side with no observed partial gives no conclusion) |
| `close-flat` | 10 |
| `close-over` | 10 (5 + 5) |
| `close-wrongside` | 10 (5 + 5) |
| `lag` | 300 readings across the sessions |

## Book method (question 5)
- Coins: BTC, ETH, HYPE on mainnet. `l2Book` every 10 min for 7 days; each record keeps the raw
  snapshot, request send and receive times and the coin's asset index, and missed intervals are
  logged.
- Baseline: the mid of the same snapshot. Closing a long walks the bids; closing a short walks the
  asks. For 1k, 10k, 100k and 1M USD notional: walk displayed levels to that notional, take the
  VWAP, report impact = |VWAP − mid| / mid in bp. The taker fee is reported separately as the
  base-tier rate from Hyperliquid's fee schedule on the day of the write-up (dated, with the link);
  actual accounts pay less with volume tiers or discounts.
- If displayed depth runs out before the notional, the result is "insufficient displayed depth"
  with the depth that was there, not an extrapolation.
- Labelled throughout as an instantaneous displayed-book estimate, not an executable close cost.

## What the write-up reports
- Question 1: cross-clock deltas, labelled as such, min / median / max, with the session NTP
  offsets beside them; not presented as latency bounds.
- Question 3(a) and 3(b): client-observed brackets (local clock), min / median / max, p90 only
  where n ≥ 30.
- Question 2: differences with timing and ordering, as observed.
- Question 4: every status returned per kind and side, positions after. Each cell (kind × side)
  shows its own denominator after skips and exclusions, and for zero failures the exact one-sided
  95% upper bound on the failure rate, 1 − 0.05^(1/n): about 9.5% at n = 30, 14% at n = 20, 26% at
  n = 10, 45% at n = 5. Small cells are not read as proof.
- Orders without a terminal status within 60 s, exclusions and skips, each counted.
- Question 5: impact by coin, side and size, median and p90 over the week, with
  insufficient-depth counts.

Reference figures, stated before the runs so the result is not fitted to them: the upper end of
the 3(b) bracket (receipt to `0x800` showing the expected size) within 3 s at p90, zero orders without a terminal status. They describe what a
reader would want to know a contract can meet; they are not pass marks for the code.

## Not covered
- Core liquidation or ADL of the pool's account racing a contract close (needs a real price move
  or a second actor on the same Core account). Untested; `close-flat`, `close-over` and
  `close-wrongside` only show the end states, not the race.
- `HedgedPerp`'s own liquidate-then-hedge path (scope note above).
- Testnet slippage; testnet books are thin and not representative.
- Several orders in flight at once (the single-slot rule from r3-r5 stays).

## Money
Transactions on testnet only. Core fees as observed on testnet in step 3 (4.5 bp per side on
2026-10-19; a pre-run estimate, rechecked from the fills) on about 12 USD per cycle, under 2 USD in
total, plus account activation for the new deployment (about 0.03 HYPE). Every cycle ends flat;
`status` and the reduce-only `unwind` are the manual recovery. Mainnet is read only.
