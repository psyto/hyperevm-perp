# Step 4: liquidation and a margin rejection on testnet

HyperEVM testnet, 2026-10-19, `TestnetPricedPerp` at d7f80eb (review r6/r6b: APPROVE), pool
`0xBD0E898Ca9B3A41E853aF36B5c6C911e0b549D81`, BTC perp (index 3). The keeper sets the settle and
liquidation price; settles need it within 1% of the real oracle. Same testnet key as step 3.

## A hedge from an empty perp account
| # | Step | Result |
|---|---|---|
| 1 | `fundCoreGas` 0.035 HYPE, `fund(10.5)`, a 2 USDC 20x long settled at the real oracle | entry 82,789.1, `targetLots` 48. No USDC on Core at all |
| 2 | `hedge()` (cloid 1) | `orderStatus` on the first read, 2.08 s after the block: **`perpMarginRejected`**, `origSz` 0.00048, limit 83,095. `coreLots` stays 0 |
| 3 | `acknowledge(1)` | the slot is free again |

So a margin-rejected CoreWriter order is registered (it has an `oid`, a status, and Core's
timestamp) rather than missing: the keeper sees a final status, not `unknownOid`.

## Liquidation
| # | Step | Result |
|---|---|---|
| 1 | price 79,600 (−3.85%) | `liquidate(1)`: the caller is credited **0.459169**, the position's equity (2 − 40 × 3.85%); `openCount` 0, `targetLots` 0, `held` 0; capital 12.080831 = 10.5 + 0.04 open fee + 1.540831 kept from the margin |
| 2 | a new 2 USDC 20x long at the oracle (82,809.8), price −2% | `liquidate` reverts `0xda1dae0c` = `Healthy()` |
| 3 | price back, close it | settled normally |

At 20x the line is −2.5% (equity below 2.5% of notional = half the margin). A first attempt to
show "healthy" at −3.37% was itself liquidatable (a call returned 0.652431): the threshold was
misremembered as 3.75%, not a contract issue.

## An IOC that finds nothing
Later the same day, with USDC made on Core by selling 0.30 HYPE on spot `@1035` (IOC at 35.0,
filled at 36.491: 10.94 USDC):

| # | Step | Result |
|---|---|---|
| 1 | 6 USDC on Core to the pool, `coreUsdClass(6e6, true)` | pool perp account 6.0 |
| 2 | `rawIoc(buy, 70,000.0, 0.00015)`, about 15% under the book (cloid `0x8000…0001`) | 0.45 s after the block `unknownOid`; 1.08 s **`iocCancelRejected`**; `coreLots` 0 |
| 3 | `acknowledge(cloid)`, `coreUsdClass(6e6, false)`, `coreToEvm(6e8)`, `defund(6)` | pool empty except 0.0076 HYPE on Core |

## All four outcomes seen
| Order | First read | Final status | Seen after |
|---|---|---|---|
| step 3 hedge buy | 0.43 s `unknownOid` | `filled` | 1.05 s |
| step 3 hedge sell | | `filled` | ≤ 3 s |
| hedge from an empty perp account | | `perpMarginRejected` | ≤ 2.08 s |
| raw IOC under the book | 0.45 s `unknownOid` | `iocCancelRejected` | 1.08 s |

Every CoreWriter order showed up in `orderStatus` by its cloid, with a final status, within about
2 s; each was `unknownOid` until then. None stayed unknown, so the "never acknowledge on
unknownOid" rule cost nothing here.

## Money
Everything came back: EVM USDC on the key 19.879934 before and after (trader, liquidator and
liquidity provider were the same key). HYPE: 0.035 into the pool's Core account, of which 0.0274
was account activation; 0.0076 is left there (no function sends Core HYPE back).

## Notes
- **USDC EVM → Core stopped working for an EOA.** `CoreDepositWallet.deposit(5e6, spot)` from the
  key emitted `Transfer(key → 0x2000…0000, 5e6)` and nothing reached Core (still 0.1 after several
  minutes; no ledger entry). On 2026-10-17 the same call from an EOA arrived within 1 s
  (hyperevm-amm docs/step1-bridging.md); only a contract's deposit failed then. USDC for the last test was made on Core instead,
  from HYPE bridged over (HYPE's bridge works) and sold on spot.
