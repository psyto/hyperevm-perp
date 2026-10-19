Confirmed: both Round 6 findings are closed.

- `rawIoc` now shares `pendingCloid`; it cannot overlap `hedge`, and `acknowledge(rawCloid)` clears it correctly.
- Settlement prices beyond 1% of 0x807 now fail before units/`targetLots` can be created; liquidation still accepts the artificial price.
- No new accounting or cloid regression found. Base `HedgedPerp` behavior is unchanged.
- The run is safe with small testnet funds, provided every Core action is acknowledged only after a final status, and the price is reset near the current oracle before settling the later “new position.” The liquidation-only price intentionally blocks subsequent opens/closes otherwise.
- `forge test`: 44 passed.

VERDICT: APPROVE
