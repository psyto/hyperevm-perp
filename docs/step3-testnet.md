# Step 3: one hedged round trip on testnet

HyperEVM testnet, 2026-10-19, at 5a539b3. Pool `0xEA62C070D8Fead38132c1F3B10308e892CEf2dE0`
on the BTC perp (index 3, szDecimals 5), real precompiles, testnet USDC
`0x2B3370eE501B4a559b57D449569354196457D8Ab`. Keeper, liquidity provider and trader were the same
testnet key, `0xBA378703f3a71e99F51393Cc3589EBcbBa26B40E`.

## Setup
| # | Step | Result |
|---|---|---|
| 1 | `forge create` | refused, "exceeds block gas limit": deployment needs ~2.8M gas, over the 2M small block. Big blocks on (`script/big_blocks.py on`), deploy, off again |
| 2 | `fundCoreGas()` with 0.05 HYPE | the pool's Core account exists (`userExists` true); activation took 0.0274 HYPE, 0.0226 HYPE left for Core gas |
| 3 | 4.9 USDC on Core from the key to the pool, then `coreUsdClass(4.9e6, true)` | perp account value 4.9 |
| 4 | `fund(10.5e6)` | `capital()` 10.5 |
| 5 | first reads | `guardedPrice()` 82,904.1; `liquidationPrice(true)` 82,927.0 (mark above oracle) |

## Round trip
| # | Step | Result |
|---|---|---|
| 1 | `requestOpen(long, 2 USDC, 10x)`, `settleOpen` 3 s later | entry 82,874.0, 0.000241330 BTC, `targetLots` 24, `maxProfits` 10 |
| 2 | `hedge()` (cloid 1) | IOC buy 0.00024, limit 83,152 (ask + 30 bp, an integer). Filled at **82,904.0**; fee 0.008953 |
| 3 | `acknowledge(1)` | after `orderStatus` said `filled`; `coreLots` 24 = `targetLots` |
| 4 | `requestClose`, `settleClose` 3 s later | credit 1.979613 (margin 2, PnL −0.000387, close fee 0.02); `targetLots` 0 |
| 5 | `hedge()` (cloid 2) | IOC sell 0.00024, filled at **82,895.0**, fee 0.008952; `coreLots` 0 |
| 6 | `acknowledge(2)`, `claim()` | `held` 0, `owed` 0, EVM balance = `capital()` = 10.540387 |
| 7 | `coreUsdClass(…, false)`, `coreToEvm(487993500)` | 4.879935 USDC arrived on the EVM by the next read; 0.00002 HYPE of Core gas |
| 8 | `defund(15.420322)` | pool empty on the EVM and on Core (except 0.0226 HYPE) |

Pool result: +0.040387 on the EVM (the trader's fees and loss), −0.020065 on Core (hedge spread
0.00216, fees 0.017905) = **+0.020322**. The hedge cost about what the trader's 10 bp fees
brought in.

## When an order shows up in orderStatus
Order 1, polled every 0.5 s from the EVM block's timestamp:

| Since the block | `orderStatus` by cloid |
|---|---|
| 0.43 s | `unknownOid` |
| 1.05 s | `filled` (Core's order timestamp: 0.45 s after the block) |

Order 2 read `filled` on the first poll, about 3 s after sending. So an order still inside
CoreWriter's delay does answer `unknownOid` first, as review r5 said; acknowledging on it would
have been wrong here.

## Things this showed
- **Basis is real even on a quiet market.** The trader entered at the oracle (82,874.0); the
  hedge bought at the book (82,904.0), 3.6 bp higher, and the mark was above the oracle too.
- **Core fees are about half the pool's fee.** 4.5 bp a side on Core against 10 bp a side
  charged to traders.
- **The pool cannot take its Core HYPE back.** There is no function to send Core HYPE to the
  EVM; 0.0226 HYPE stays on the pool's Core account.
- **Not exercised here:** liquidation, an IOC that finds nothing (`iocCancelRejected`) and a
  margin rejection (`perpMarginRejected`).
