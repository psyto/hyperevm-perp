You are Codex, reviewing code Claude (another model) wrote. Do not defer to it. Round 2.

Same repo as round 1 (a perp on HyperEVM whose pool is every trader's counterparty and hedges traders' net position on HyperCore through CoreWriter; src/HedgedPerp.sol, docs/design.md). Round 1 (docs/reviews/r1.md, your output in review-r1.out.md) found three issues; commit 9b7a276 fixes them:
1. capital() now counts EVM USDC only (balance - held - owed); Core value is informational and never backs payouts.
2. settleOpen/settleClose are permissionless, window SETTLE_DELAY 2 s to SETTLE_WINDOW 15 s.
3. hedge() reverts NoCoreAccount unless 0x810 says the pool's Core account exists.

Review by breaking: for every finding, write a failing Foundry test under test/poc/ that demonstrates it, run `forge test`, report the numbers. Only add files under test/poc/; do not edit src/ or existing tests.

Attack:
1. Do the fixes close the round-1 findings? Is any residual worse than docs/design.md states (a party offline gives the other at most a 13 s option; a late hedge order leaves the Core position off by at most maxHedgeLots until the next hedge, on Core money only)?
2. New surface from permissionless settles: griefing (settling someone else's request at a bad moment, front-running a settle, settling an open that then fails Undercapitalised, ordering of settles in one block), interaction with cancel() at the window edge (== SETTLE_WINDOW), and with liquidate().
3. With Core money excluded from capital: can EVM capital still be overstated or drained (claim ordering when the EVM balance is short, defund racing settles, donations, coreToEvm arrivals)? Can traders be owed more than the EVM can ever pay?
4. Anything round 1 missed.

Output: findings with severity (critical/high/medium/low), PoC name and result, root cause, concrete fix. End with exactly one line: `VERDICT: APPROVE` or `VERDICT: CHANGES`.
