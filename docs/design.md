# Design

A perp on one HyperCore market (BTC first), settled in USDC on HyperEVM. The pool is every
trader's counterparty, and it **hedges what traders hold, net, with its own position on
HyperCore** through CoreWriter. The third build after
[hyperevm-amm](https://github.com/psyto/hyperevm-amm) (an exchange that trades on HyperCore) and
[hyperevm-lend](https://github.com/psyto/hyperevm-lend) (a lending market that reads HyperCore
prices).

## Why hedge on Core
A pool that is the counterparty to traders holds the opposite of their net position: if traders
are net long BTC, the pool is short. Without a hedge its result is a bet on the price. HyperCore's
own BTC perp is the deepest market for that, and a HyperEVM contract can trade it directly.

## What lives where
| | Where | Why |
|---|---|---|
| Traders' positions, margins, PnL, liquidations | EVM, settled in one transaction | the EVM is never told what happened on Core (hyperevm-amm) |
| The hedge | the pool's Core perp account | the only place that market is |
| Prices | Core precompiles: oracle 0x807, mark 0x806, best bid/ask 0x80e | |

The contract keeps no record of the hedge. `hedge()` reads the Core position (0x800) each time
and orders the gap between it and `targetLots()`, the traders' net position in Core lots. An
order that never fills is ordered again next time; one that fills partly leaves a smaller gap.

## Rules
- **Opens and closes are two-step, and anyone settles.** The trader requests; anyone settles at
  the checked oracle 2–15 s later. Within one block the price is one value, so when the trader
  and the keeper are both live, whichever likes that block's price settles it: neither gets a
  free option (review r1 found one when only the keeper could settle, over 120 s). If one side is
  offline, the other has an option of at most 13 s. After 15 s the trader can cancel (an open is
  refunded; a close goes back to open).
- **Checked price for settles**: oracle, refused when the mark, the mid or the spread is off by
  more than the bounds (hl-price-guard).
- **Liquidation never refuses a price.** A position is liquidatable when its equity is below
  2.5% of notional at the price better for it: the higher of oracle and mark for a long, the
  lower for a short. One feed moving alone liquidates no one; a real move moves both. Whatever
  equity is left goes to the caller; a shortfall is the pool's.
- **Profits are capped** at 5× margin, and a position can only open while the pool's capital
  covers every open position's cap (`capital() >= maxProfits`). So the pool can pay even if the
  hedge did nothing; the hedge is there to make the pool's result not depend on the price.
- **Capital is EVM USDC only**: the pool's EVM balance − traders' margins − credits owed. Core
  money is the hedge's and never backs payouts (review r1: an order that runs after traders'
  exposure changed leaves a wrong-way position on Core; when Core value counted as capital, a
  50% move on that position left a trader's capped profit unpayable). Hedge profit counts once
  the keeper brings it to the EVM.
- **Payouts are credits.** A close or liquidation credits USDC; `claim()` pays it from the EVM
  balance. When the hedge's profit is on Core, the keeper brings it over (`coreToEvm`) first.
- **A late order is the liquidity provider's risk, bounded.** An order sent by `hedge()` can run
  after a settle has changed traders' exposure, leaving the Core position off by at most that
  order (`maxHedgeLots`) until the next `hedge()` after the quiet period. That loss falls on Core
  money only.
- **No Core account, no hedge.** Core drops actions from an account that does not exist yet, so
  `hedge()` reverts until `userExists` (review r1).
- **One IOC per 30 s.** The EVM cannot tell when an order has run; a second order before the
  first runs would double it. Spot IOCs ran 347–477 ms after their block in hyperevm-amm's
  measurements; a BTC perp IOC showed up in the position within 4 s.
- **One liquidity provider** in this version: the keeper funds and defunds; `defund` only takes
  the pool's own EVM USDC and keeps `maxProfits` covered.

## Units
| Value | Unit |
|---|---|
| USDC | 6 decimals on the EVM, 8 on Core spot; perp account value is USD × 1e6 |
| `units` | base asset × 1e18 |
| prices from the precompiles | `6 − szDecimals` decimals, scaled to 1e18 by hl-price-guard |
| order `limitPx`, `sz` | × 1e8; price 5 significant figures (integers always), at most `6 − szDecimals` decimals |
| position `szi` (0x800) | szDecimals units ("lots") |

## Not handled (yet)
- **Funding.** Traders pay none; the hedge pays or receives Core's funding.
- **Basis.** Traders settle at the oracle, the hedge fills at the book and is valued at the mark.
- **Residual.** Under $10 of net exposure cannot be hedged (Core's minimum order).
- **Liquidity providers other than the keeper**, which needs share pricing against open PnL.
