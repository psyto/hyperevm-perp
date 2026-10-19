# hyperevm-perp

Learning HyperEVM by building a perp whose pool takes the other side of every trade and hedges
traders' net position with its own position on HyperCore, sent through CoreWriter. The third
build after [hyperevm-amm](https://github.com/psyto/hyperevm-amm) (an exchange that trades on
HyperCore) and [hyperevm-lend](https://github.com/psyto/hyperevm-lend) (a lending market that
reads HyperCore prices).

Status (2026-10-19): a learning project, not audited, not for real funds. It has only been
run on testnet; `HedgedPerp` itself is not restricted to any chain (only the testnet copy is),
so do not deploy it with real money.
- Codex reviewed it adversarially six times (r6 on the testnet-only copy, r6b APPROVE). The
  hedge's "is my order done?" took four rounds and ended as a keeper acknowledgement, below.
- One hedged round trip ran on testnet with real prices: open, hedge on Core, close, unwind the
  hedge, every USDC back (`docs/step3-testnet.md`).
- Liquidation, a margin-rejected hedge and an IOC that found nothing ran on testnet with a
  testnet-only copy whose price the keeper sets (`docs/step4-liquidation-and-rejections.md`).

## How it works
- **One market, BTC on testnet.** Traders post USDC margin (up to 20x) and go long or short.
  The pool is every trader's counterparty.
- **Two-step trades, settled by anyone.** The trader requests; anyone settles at the checked
  oracle 2–15 s later. Within one block the price is one value, so when the trader and the
  keeper are both live, whoever likes that block's price settles it: neither gets a free option.
  After 15 s the trader can cancel.
- **The hedge.** `hedge()` reads the pool's Core position (0x800) and sends one IOC for the gap
  to traders' net position, with a fresh cloid. Nothing else goes out until the keeper
  `acknowledge`s that cloid after reading a final status from the info API (`filled`,
  `iocCancelRejected`, `perpMarginRejected`, …), never on `unknownOid`. The contract keeps no
  record of what the hedge holds; it reads Core each time.
- **Liquidation never refuses a price.** Liquidatable when equity is below 2.5% of notional at
  the price better for the trader: the higher of oracle and mark for a long, the lower for a
  short. One feed moving alone liquidates no one; a real move moves both. The equity left goes
  to the caller; a shortfall is the pool's.
- **Payouts never depend on Core.** Profits are capped at 5× margin, and a position opens only
  while the pool's EVM USDC alone covers every open position's cap. Core money is the hedge's
  and is not counted. Payouts are credits, claimed from the EVM balance.

| Parameter | Value |
|---|---|
| Max leverage | 20x |
| Fee | 10 bp of notional at open and at close |
| Liquidatable below | 2.5% of notional (−2.5% at 20x) |
| Profit cap | 5× margin |
| Settle window | 2–15 s after the request |
| Hedge order | one IOC, limit 30 bp beyond the touch and within 1% of the oracle; at most `maxHedgeLots`; at least $12 |
| Price checks for settles | constructor bounds on mark/oracle, mid/oracle, spread |

## Known limits
- **The keeper is trusted for the hedge.** It is also the only liquidity provider. An early or
  wrong acknowledgement can put two orders on Core; that risks only Core money, never what
  traders are owed.
- **The hedge lags.** Between two hedges the Core position trails traders' exposure by whatever
  settled, with no bound in size or time but the keeper's pace. On top of that, the one
  outstanding order can run after exposure moved and point the wrong way, by at most its size.
  Core liquidations or ADL of the hedge move the Core position on their own; the next hedge
  orders the gap from what Core shows.
- **Capital-hungry.** Because payouts do not count Core money, the EVM must hold 5× every open
  margin.
- **Not handled:** funding (traders pay none; the hedge pays or receives Core's), basis (traders
  settle at the oracle, the hedge fills at the book: 3.6 bp in step 3), gaps under $12, other
  liquidity providers (needs share pricing against open PnL), Core HYPE (gas) cannot be sent
  back to the EVM.

## Why the hedge's acknowledgement is off-chain
A CoreWriter action runs after the EVM block, and the EVM is never told how it ended. Reviews
r3–r5 broke three on-chain answers to "is my order done?":

| Tried | Broke because |
|---|---|
| a timer between orders (r3) | while Core was slow, three calls sent three identical orders |
| "the Core position moved" (r4) | Core liquidations and ADL move it too; an order can net back to its start; a timeout does not cancel a queued action |
| acknowledging "never registered" orders (r5) | `orderStatus` answers `unknownOid` for those and for an order still inside CoreWriter's delay alike |

On testnet every order then showed `unknownOid` for under a second and a final status within
about 2 s.

## Layout
| Path | What |
|---|---|
| `src/HedgedPerp.sol` | the market |
| `src/testing/TestnetPricedPerp.sol` | testnet only (refuses any chain but 998): keeper-set price for liquidation, settles within 1% of the real oracle, a raw IOC for measuring `orderStatus` |
| `test/` | 44 tests; precompiles and CoreWriter mocked at their real addresses |
| `docs/design.md` | the design and what is left |
| `docs/step3-testnet.md` | the hedged round trip on testnet |
| `docs/step4-liquidation-and-rejections.md` | liquidation, `perpMarginRejected`, `iocCancelRejected`; all four order outcomes and their timings |
| `docs/reviews/` | Codex review rounds: payloads, outputs, PoCs, and what was fixed (`r1.md`–`r6.md`) |
| `script/big_blocks.py` | big blocks on/off for the deployer (deployment needs ~2.8M gas, over the 2M small block) |
| `lib/hyperevm-amm`, `lib/hl-price-guard` | pinned git submodules: CoreWriter/precompile helpers, guarded price reads |

## Things this taught (testnet, 2026-10-19)
- A CoreWriter perp order is found in `orderStatus` by its cloid: `unknownOid` for under a
  second, then `filled`, `iocCancelRejected` or `perpMarginRejected`. A margin-rejected order is
  registered, not missing.
- A contract's Core account starts with no perp margin; an order then is rejected
  (`perpMarginRejected`), not dropped silently.
- Deploying a ~14 KB contract needs big blocks (`evmUserModify`); turn them off afterwards, since
  every transaction from the address then waits for a big block.
- Basis shows up even on a quiet book: trader entry at the oracle 82,874.0, hedge fill 82,904.0.
  Core's taker fee was 4.5 bp a side, against the 10 bp charged to traders.
- USDC EVM → Core through `CoreDepositWallet` did not arrive for an EOA either on 2026-10-19
  (it did on 2026-10-17). HYPE's bridge worked, so USDC was made on Core by selling HYPE on spot.

## Reviews
Codex, adversarial, a failing test for every finding (`docs/reviews/`).

| Round | Scope | Findings | Outcome |
|---|---|---|---|
| 1 | whole market | 2 high, 1 medium | capital is EVM USDC only; anyone settles within 2–15 s; no hedge without a Core account |
| 2 | r1 fixes | 1 high | the documented hedge bound was wrong; corrected |
| 3 | r2 fixes | 1 high, 1 medium | a timer let orders pile up; rebuilt as one unconfirmed order |
| 4 | the rebuild | 1 high, 1 medium | a position change is no acknowledgement; keeper acknowledges by cloid; settles never wait |
| 5 | acknowledgement | 1 high (procedure) | never acknowledge on `unknownOid` |
| 6, 6b | the testnet-only copy | 1 medium, 1 low; then APPROVE | the raw IOC takes the one order slot; settle price within 1% of the oracle |

## Next
- A full arithmetic audit round, as hyperevm-lend's r8 did.
- Funding passed through to traders, accrued per second.
- A keeper that polls `orderStatus` and acknowledges by itself (by hand on testnet so far).
- A way to send the pool's Core HYPE back to the EVM.

## Run
```
git clone --recurse-submodules https://github.com/psyto/hyperevm-perp
forge test
```

## License
Apache-2.0
