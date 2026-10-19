# hyperevm-perp

A perp on HyperEVM whose pool takes the other side of every trade and hedges traders' net
position on HyperCore through CoreWriter. Learning project; testnet only. Not audited.

Status: six Codex review rounds ([docs/reviews/](docs/reviews/)), 44 tests, and one hedged
round trip on testnet ([docs/step3-testnet.md](docs/step3-testnet.md)): open, hedge on Core,
close, unwind, every USDC back. Liquidation, a margin-rejected hedge and an IOC that found nothing, on testnet with a
testnet-only, keeper-priced copy ([docs/step4-liquidation-and-rejections.md](docs/step4-liquidation-and-rejections.md)).

- Design: [docs/design.md](docs/design.md)
- Contract: [src/HedgedPerp.sol](src/HedgedPerp.sol)
- Earlier builds: [hyperevm-amm](https://github.com/psyto/hyperevm-amm), [hyperevm-lend](https://github.com/psyto/hyperevm-lend)

```
forge test
```

## License
Apache-2.0
