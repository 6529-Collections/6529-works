# Integrator guide

For marketplaces, wallets, indexers, analytics and front ends that read 6529 Works or send
transactions to it.

> Pre-audit. See the [project status](../../README.md#status).

The current Sepolia rehearsal, r3, runs `main` at `e5fe78c`, verified on Sourcify; the
superseded r2 runs the earlier `400f96d`, so build r2's ABIs from that commit. There is no
mainnet deployment, and interfaces may still change before the audit.

## The pages

| Page | Read it to |
| --- | --- |
| [Reading a work](reading-a-work.md) | Show a work: `tokenURI` and `uri`, the JSON fields, inline and locator media, editions, licenses, dispute statements, royalties |
| [Events and indexing](events-and-indexing.md) | Index the protocol: every event of every contract, and how to rebuild each entity's state from logs |
| [Addresses](addresses.md) | Find the deployed contracts: Sepolia r3 now, mainnet later |
| [ABIs and interface IDs](abis-and-interface-ids.md) | Get the ABIs, detect contracts with ERC-165, and recompute the EIP-712 digests and protocol hashes |
| [Buying, bidding, settling and claiming](buying-bidding-settling.md) | Send transactions: start and bid on auctions, settle as a keeper, buy editions, claim credits and payouts, with the errors to handle and gas notes |
| [Storage](storage.md) | Fetch and verify a work's bytes: the content store, Arweave and IPFS locators, and the uploader |

## Five things to know first

1. **One contract per product.** Every Stream work is a token of one ERC-721; every edition is
   a token of one ERC-1155, and its ID equals its master's Stream token ID.
2. **Metadata is on-chain JSON.** `tokenURI` returns `data:application/json;utf8,…`, built by
   a renderer from the work's record. A finalized work's renderer is pinned, so its output
   format never changes. Call it with a generous gas allowance: its bounded reads need about
   1.07M gas available even when the call uses far less, and the worst case uses about 7.8M
   ([reading a work](reading-a-work.md)).
3. **Events tell you when to refresh.** ERC-4906 `MetadataUpdate` and `BatchMetadataUpdate`
   mark every metadata change, on works and on their editions.
4. **Most actions are permissionless.** Anyone may start an auction, bid, settle, create an
   edition once its master has settled, open a record, upload content, flush the escrow and
   release a fixed payee's share.
5. **Money moves by pull.** Outbid bidders, buyers who overpay, and winners whose wallets
   refuse the NFT get a credit or a pending delivery to collect, never a push that can fail.

## Conventions

- Rates use a denominator of 100,000; 6.529% is 6,529.
- `address(0)` as a currency is ETH.
- Gas figures are Prague gas unless they say Sepolia; Sepolia runs Glamsterdam, which prices
  new state far higher ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md)). Estimate on
  the target chain.

## Related

- The [specification](../spec/README.md) has the rules behind every call.
- The [glossary](../glossary.md) defines the terms.
- The [role and permission matrix](../audit/roles.md) lists every governed setting and its
  delay, which tells you how much notice a change gives.
