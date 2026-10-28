Review docs/step5-close-from-evm-spec.md (a measurement spec, nothing built or sent yet) against
the repo as it stands: src/HedgedPerp.sol, src/testing/TestnetPricedPerp.sol, recorder/orders.py,
docs/step3-testnet.md, docs/step4-liquidation-and-rejections.md, docs/reviews/ (r1-r6b, rec1-rec3).
The question step 5 answers: if a contract's Core perp position backs something on the EVM side,
how stale is the contract's precompile view, and how quickly and reliably can the contract flatten
it through CoreWriter. Check: (1) whether each measurement actually measures what it claims (e.g.
can 0x800 per-block reads and Core's fill timestamp be compared as described; is the 0x80F vs
clearinghouseState pairing meaningful given eth_call at "latest" and API timing), (2) whether the
four close kinds cover the outcomes a liquidation path must handle and whether expected statuses
(reduceOnlyRejected, reduce-only cap on an oversized close) are stated as things to confirm rather
than assumed, (3) whether rawIocReduceOnly keeps the single-slot and acknowledge rules from r3-r5
and rec1-rec3 intact, (4) fail-closed gaps in the recorder extension, (5) sample sizes and the
mainnet read-only book sampling, (6) anything missing that would make the results misleading.
Read-only. End with VERDICT: APPROVE or VERDICT: CHANGES and a numbered list with severity.
