# economics

Money routing: the split factory and immutable pull-payment split wallets,
royalty and revenue resolvers with scoped assignments, the settlement recorder
(exact balance deltas, single-use settlement keys, fee-on-transfer rejection),
the escrow fallback with a permissionless flush, and the governed asset
allowlist. Rates use a 100,000 denominator so the 6.529% royalty is exact;
existing works keep the terms locked at mint. Governed by
[ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md) §7, with
the payment-currency rules in §5 and the artist-resolved payout recipient in
§11.
