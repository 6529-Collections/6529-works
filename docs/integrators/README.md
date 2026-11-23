# Integrator guide

For marketplaces, wallets, indexers and front ends that read 6529 Works or send transactions to
it. Start with the [overview](../overview.md) for the shape of the system.

> Pre-audit. See the [project status](../../README.md#status).

There is no mainnet deployment, and interfaces may change before an audit. The current Sepolia
round, r6, runs this design ([Addresses](addresses.md)).

## The pages

| Page | Read it to |
| --- | --- |
| [Reading a work](reading-a-work.md) | Show a work: `tokenURI` and `uri`, the JSON, media, editions, licenses, disputes, royalties |
| [Events and indexing](events-and-indexing.md) | Index the protocol and rebuild state from logs |
| [Buying, bidding, settling and claiming](buying-bidding-settling.md) | Start and bid on auctions, settle as a keeper, buy editions, claim |
| [ABIs and interface IDs](abis-and-interface-ids.md) | Get the ABIs, detect contracts with ERC-165, recompute digests and hashes |
| [Addresses](addresses.md) | Find the deployed contracts |

Beside the pages: [`abi/`](../../abi/) (exported ABIs), [`examples/`](../../examples/README.md)
(short Foundry examples of the common jobs), [`keeper/`](../../keeper/README.md) (a reference
keeper for the permissionless steps), and [`tools/content/`](../../tools/content/README.md) (the
uploader and byte verifier).

## Five things to know first

1. **One permanent contract per product.** Every Stream work is a token of one ERC-721; every
   edition is a token of one ERC-1155 with its master's token ID. Ownership and transfers never
   depend on any other contract.
2. **Facts are plain views.** `workOf` on the token and `factsOf` on `StreamWorkFacts6529` give
   everything fixed about a work. `royaltyInfo` is two storage reads.
3. **Metadata is on-chain JSON**, built by a renderer. A finalized work's renderer is pinned.
   Call `tokenURI` with a generous gas allowance.
4. **Most actions are permissionless**: start, bid, settle, open a record, upload content, flush
   the escrow, release a fixed payee.
5. **Money moves by pull.** Outbid bidders get a credit; a winner whose wallet refuses the NFT
   gets a pending delivery.

## Conventions

- Rates are out of 100,000; 6.529% is 6,529.
- Sales are in ETH only.
- Gas figures are Prague gas unless they say Sepolia; estimate on the target chain.
- The network's waiting periods are settings you can read (`moduleDelay`, `rescueDelay`,
  `rebindDelay`, `unclaimedPeriod`); do not hard-code them.
