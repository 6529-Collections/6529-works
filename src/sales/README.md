# sales

Shared sale adapters written against a minimal mint interface rather than
against Stream: the English auction (Stream's only primary sale; anti-snipe
clock, pull refunds, escrow fallback, pending claim when NFT delivery fails,
dispute pause), fixed price with allowlist phases and ERC-20 permits, and Dutch
pricing. Each sale locks its currency (ETH or an allowlisted standard ERC-20)
when it starts, and new sale types arrive as new adapters through a timelocked
minter-role grant. Governed by
[ADR 0001](../../docs/adr/0055-v1-network-curated-stream-rescope.md) §5, with
§6 (edition sales), §12 (dispute pause) and §16 (federated use).
