# Step 5 (spec): seeing and closing a contract's Core position from the EVM

Status: spec, revised after reviews s5, s5b and s5c (CHANGES). Nothing here has been built or sent.

Steps 3 and 4 showed that a CoreWriter order reaches a final `orderStatus` within about 2 s. Step 5
asks the next question: if a contract's Core perp position backs something on the EVM side, how far
apart are the contract's precompile view and Core's own view, and how quickly and reliably can a
contract flatten that position with reduce-only orders sent through CoreWriter.

**Scope (s5 #1).** These are measurements of CoreWriter and precompile primitives, using a
testnet-only reduce-only order. They are not measurements of `HedgedPerp`'s own path: there,
`liquidate()` only removes EVM exposure and a later `hedge()` sends a non-reduce-only IOC sized from
`coreLots()`. That path is unchanged by this step and its results do not describe it.

## Questions
1. **Position visibility.** After a fill, how long until a contract-style `0x800` read shows the
   new size. The method depends on a gate (see Recorder, gate G1): if `eth_call` at an explicit old
   block number is shown to return that block's `0x800` state, the first matching block is found by
   backfill and reported as an interval between block timestamps; if not (the public RPC is already
   known to ignore block numbers for `0x807`, hl-price-guard docs/safe-limits.md), the result is the
   first live observation, bounded by the send/receive times of the last read without the new size
   and the first read with it. Either way it is a bound, not an exact delay.
2. **Divergence from the info API.** While a position is open, paired readings of account value
   (`0x80F` vs `clearinghouseState`) and oracle price (`0x807` vs `metaAndAssetCtxs`). These are not
   a common snapshot; the report gives the difference together with the block read, each request's
   send and receive time and their order. No claim of "precompile staleness" is drawn from them.
   (BBO `0x80E` is dropped from step 5.)
3. **Close latency, as the client observes it.** From the receipt of the transaction that sends a
   reduce-only IOC to (a) the first `orderStatus` response carrying a terminal status, bounded by
   the send and receive times of that poll and of the previous non-terminal poll, and (b) `0x800`
   matching the expected size (same method as question 1). The receipt's own arrival time and the
   whole-second block timestamp are recorded too, so the report states the uncertainty instead of
   an exact block-to-status delay.
4. **Close outcomes**, for long and short positions. Every expected status below is a thing to
   confirm, not an assumption; the recorder records whatever comes back and stops on a surprise.
   - `close-fill`: open, then reduce-only close 1% through the oracle -> expected `filled`, flat.
   - `close-tight`: reduce-only close 15% on the wrong side -> expected `iocCancelRejected`,
     unchanged; then a second close 1% through -> expected `filled`. Time to flat over two attempts.
   - `close-partial`: reduce-only close for the whole position limited at the touch, sent when the
     touch's displayed size (raw snapshot with its request times kept) is smaller than the position;
     then the residual is closed with a second reduce-only order. The attempt is classified from
     fills, not from the book. Let P = |szi| before the close and F = the sum of sizes of all
     `userFills` entries with that exact oid. Completeness: after the terminal status, re-read
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
- Acknowledge rule for every kind: the pending cloid read from the contract equals the cloid this
  client sent, `orderStatus` for that cloid returns a terminal status from the existing list, and the
  outcome and position match the kind. Anything else, or no terminal status within 60 s, stops the
  run and leaves the slot locked for `status` / manual handling.
- **Gate G1 (before any runs):** with the pool holding a position opened at a known block A and
  closed at a later block C, call `0x800` by `eth_call` at block numbers before A, between A and C,
  and after C, and record the results. Historical reads are accepted only if they return the size
  each block should have had. The outcome is written into the step 5 write-up before question 1 or
  3(b) is measured.
- Position visibility, if G1 passes: after each order's block B, read `0x800` pinned to each
  explicit block number from B onward (recording the block hash), backfilling skipped blocks, until
  the expected size is seen or 30 s of blocks pass; record the first matching block, its timestamp
  and the previous block's timestamp.
- Position visibility, if G1 fails: poll `0x800` at `latest` as fast as the RPC limit allows (and
  `eth_blockNumber` before and after each call), recording each request's send and receive time;
  report the first read with the expected size and the last read before it. No block attribution.
- Every `orderStatus` poll records its send and receive times (local monotonic clock) and the
  status returned; every receipt records when it arrived.
- Fill time source: `userFills` (info API) for the pool's Core account, matched by `oid`, using its
  `time` field. If a fill cannot be matched there, the record says so and question 1 excludes it
  (counted, not dropped silently).
- `lag <pool> <n>`: with a position open, n paired readings for question 2, spaced at least 15 s.
- `book <coin...>`: question 5, mainnet info API only, to `recorder/data/book.jsonl`, raw snapshot
  included.
- Kinds and sides are run in a random order (seed recorded).

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
- Question 1 and 3(b): visibility intervals (lower and upper bound) as min / median / max, and p90
  only where n ≥ 30.
- Question 2: differences with timing and ordering, as observed.
- Question 3(a): time to terminal status, min / median / max, p90 where n ≥ 30.
- Question 4: every status returned per kind and side, positions after. Each cell (kind × side)
  shows its own denominator after skips and exclusions, and for zero failures the exact one-sided
  95% upper bound on the failure rate, 1 − 0.05^(1/n): about 9.5% at n = 30, 14% at n = 20, 26% at
  n = 10, 45% at n = 5. Small cells are not read as proof.
- Orders without a terminal status within 60 s, exclusions and skips, each counted.
- Question 5: impact by coin, side and size, median and p90 over the week, with
  insufficient-depth counts.

Reference figures, stated before the runs so the result is not fitted to them: `0x800` matching
within 3 s of the order's block (of the receipt, if G1 fails) at p90, zero orders without a terminal status. They describe what a
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
