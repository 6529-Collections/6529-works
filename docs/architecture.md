# 6529 Works architecture

The contracts and how they call each other. Read the [three-page overview](overview.md) first;
the rules are in the [specification](spec/README.md), by rule ID.

> Pre-audit. See the [project status](../README.md#status).

## At a glance

```
                         network (one address, through the AccessManager)
                                  |  proposes / removes modules and minters, settings
        +-------------------------+---------------------------+
        |                         |                           |
   PERMANENT                 PERMANENT                    PERMANENT
   Stream (ERC-721)  <---   Editions (ERC-1155)         Directory
     slots: TERMS,            slots: TERMS                slots: ACCOUNTS, FEDERATION,
     RENDERER, RECORDS        minters: edition auctions   FEDERATED_TERMS, FEDERATED_RECORDS
     minters: EnglishAuction                              setting: unclaimedPeriod
        |                                                     |
   PERMANENT WorkFacts (records of Stream and every       PERMANENT SplitLedger + vaults
   federated token)                                         (asks Directory for payout addresses)
   PERMANENT ContentStore          PERMANENT RevenueEscrow  (reads unclaimedPeriod from Directory)

   MODULES (replaceable): EnglishAuction, PackageRegistry, UniformEditionAuction (+ lens),
   StreamTerms, WorkRules, WorkDelivery, Renderer, Accounts, FederationRegistry,
   EconomicsResolver, StatementLog, DependencyRegistry, entropy module, governed vaults
```

## Modules

A permanent contract finds each module in a named slot (`moduleOf(slot)`) and each sale
contract in its minter list (`isMinter`). Both change only as
[`Modules`](../src/core/Modules.sol) allows: the network announces, anyone installs after
`moduleDelay`, the network removes at once.

| Slot or list | In | Module | What the permanent contract accepts from it |
| --- | --- | --- | --- |
| minters | `Stream` | `EnglishAuction` | `mint`, then once `recordPrimarySale` or `burn` while it holds the token unsold |
| minters | `Editions` | `UniformEditionAuction` | `create` (once per edition), `mint` up to the maximum, `seal` |
| `TERMS` | `Stream`, `Editions` | `StreamTerms` | `setRoyalty`, `lockRoyaltyRate` |
| `RENDERER` | `Stream` | `Renderer` | Read by `tokenURI` for a work that is not finalized |
| `RECORDS` | `Stream` | `WorkRules` | Calls `WorkFacts.setRecord`, `setLicense`, `finalize`, `repin`, `lock` for that token |
| `ACCOUNTS` | `Directory` | `Accounts` | Answers `payoutAddress` for the split ledger |
| `FEDERATION` | `Directory` | `FederationRegistry` | Answers which sale contracts may mint for a federated token |
| `FEDERATED_TERMS`, `FEDERATED_RECORDS` | `Directory` | `StreamTerms`, `WorkRules` (token-keyed) | As TERMS and RECORDS, for every federated token |

Modules that no permanent contract calls (the mint policy, the economics resolver, the
statement log, the entropy module) are wired to the sale contracts and to each other through
the AccessManager's governed setters.

## Deployment order

Every address is predicted before deployment, so the permanent contracts take their genesis
modules and minters as constructor arguments; every later addition waits `moduleDelay`.
[`script/DeployCore.sol`](../script/DeployCore.sol) deploys, in order: the AccessManager →
`ContentStore` → `WorkFacts` → `Directory` → `SplitLedger` (with `Directory` as its payout
resolver) → vaults and `RevenueEscrow` → `Stream` → `Editions` → the modules. `VerifyCore`
reads every slot, minter and setting back. The genesis policy is
[`config/genesis.core.example.json`](../config/genesis.core.example.json).

## Identifiers and hashes

Package hashes are keccak256 over `abi.encode` with a domain label per type and no chain ID, so
they are the same on every chain. EIP-712 signatures are bound to their contract's domain.

| Identifier | Definition |
| --- | --- |
| item hash | `keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item))`; stored in `Work.itemHash` |
| package root | OpenZeppelin `MerkleProof` root over leaves `keccak256(bytes.concat(itemHash))` |
| content hash | The SHA-256 of the primary media; one live token per content hash |
| file ID | `IContentStore.manifestId(chunkHashes, length, encoding, mimeType, sha256Hash)` |
| artist ID | The address the artist first registered with, as a number; never changes |
| token ID | One sequence on `Stream`, from 1, never reused |
| edition ID | Equal to its master's Stream token ID |
| sale ID | `uint256(keccak256(abi.encode(token, tokenId)))` in both auctions |
| split vault | The ledger's CREATE2 address over a canonical payee list and a salt |

Shares and rates are out of 100,000 (6.529% is 6,529). Payments are in ETH only.

## Call flows

**Curated sale.** `EnglishAuction.start` → `PackageRegistry.authorize` (checks and consumes the
item, answers `MintFacts` and `MintTerms`) → `Stream.mint(auction, facts)` → bids → `settle` →
`Stream.recordPrimarySale` → token transfer to the buyer → payment to the seller's split vault
and the fee recipient (a refused payment goes to `RevenueEscrow`). Unsold: the auction transfers
the token to the museum.

**Edition.** `UniformEditionAuction.open` checks the master on `Stream`, deploys the vaults and
calls `Editions.create`; after clearing it calls `seal` and mints to each winner who claims.

**Records.** `WorkFacts.open` (anyone, checked against the token's item) fixes the media.
`WorkRules` edits the record and finalizes; `WorkFacts.finalize` pins the token's RENDERER
module and its code hash. `ContentStore.attestComplete` then `WorkFacts.markOnChainComplete`
records that every file is on-chain.

**Payout.** Anyone calls `SplitLedger.release` for a vault; for an artist payee the ledger asks
`Directory.payoutAddress`, which asks the ACCOUNTS module. If that call fails, the money stays.

### Dispute pause

A pauser key pauses an auction once, for at most 3 days, citing a dispute. If the dispute is
upheld (a dispute outcome statement in `StatementLog` recorded after the pause), the network
cancels the sale: the bid is credited back and the auction burns the token. Otherwise the sale
resumes. Rules: [stream and auctions](spec/stream-and-auctions.md).

## Trust boundaries

- A collector's token depends on no other contract: transfers, approvals and `ownerOf` call
  nothing outside the token, and `royaltyInfo` reads two storage values.
- `tokenURI` depends on the renderer: the pinned one for a finalized work, the RENDERER module
  otherwise. It reverts rather than fall back.
- An artist's payout depends on the ACCOUNTS module; a missing or failing module leaves the money
  in the vault.
- Modules are the network's choice. What the network can do, to whom and how fast:
  [trust assumptions](audit/trust-assumptions.md) and the [role matrix](audit/roles.md).
