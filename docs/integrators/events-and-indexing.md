# Events and indexing

What each contract logs and how to rebuild state from logs alone. Every permanent contract
emits an event for every state change, enough to rebuild its state from its own logs
([ADR 0010](../adr/0010-plain-permanent-core.md)). Modules log their own changes.

> Pre-audit. See the [project status](../../README.md#status).

## How to read this page

- **Key every log by emitter address and topic0.** Stream and Editions share `RoyaltySet`,
  the module and minter events, `OwnershipTransferred`, `ContractURIUpdated` and the ERC-4906
  events; `Directory` shares the module events. `Transfer(address,address,uint256)` is also
  ERC-20's (the ERC-721 log has four topics).
- **Topics.** `indexed` parameters are topics 1 to 3. Structs, strings, bytes and arrays are in
  the data. Struct names below (`MintFacts`, `Outcome`, `License`, `PackageItem`, `MediaFile`)
  are encoded as tuples or `uint8` in the canonical signature; topic0 is computed from that.
- **Module slots** (`bytes32 slot`) are ASCII names left-aligned: `"TERMS"`, `"RENDERER"`,
  `"RECORDS"`, `"ACCOUNTS"`, `"FEDERATION"`, `"FEDERATED_TERMS"`, `"FEDERATED_RECORDS"`.
- **Where to start.** Scan from the deployment record's `startBlock` in
  [`deployments/11155111/`](../../deployments/11155111). The Sepolia round for this code is r6;
  earlier rounds ran an earlier design.
- **Module events** (auctions, accounts, federation, ledger, escrow, statement log) are listed by
  name below. Their exact signatures and topics are in the exported ABIs ([`abi/`](../../abi)),
  regenerated from the built code.

## The permanent core

Topics are the full 32 bytes, from the compiled interfaces.

### Stream

`IStream` and `IModules`; each federated 1/1 token emits the same.

| Event | topic0 | When |
| --- | --- | --- |
| `Transfer(address indexed from, address indexed to, uint256 indexed tokenId)` | `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` | ERC-721; a mint from zero, a burn to zero |
| `WorkMinted(uint256 indexed tokenId, uint256 indexed collectionId, uint256 indexed artistId, address minter, uint32 serial, MintFacts facts)` | `0xcd68913783d22c6ac5aa99ac78ee918f220587f0e31f1a6c34e2779b4cd16766` | `mint`; carries every fact, stored or not (content hash, package root, media hash, record file, seller) |
| `PrimarySale(uint256 indexed tokenId, Outcome outcome, address indexed buyer, uint256 price)` | `0xdab3433b107eccad74f51c88fb8f34052a6e9ddea138cea44f51f483cdd84791` | `recordPrimarySale`; the price is only here |
| `WorkRescued(uint256 indexed tokenId, address indexed from, address to)` | `0x77ac3c6455fa9305b1c12dc5c6cefeb7417b9d5ed5009a19a6bb464e41428ea8` | `rescue`; outcome becomes `RESCUED` |
| `RoyaltySet(uint256 indexed tokenId, address receiver, uint24 rate)` | `0x95019fbde998daec25616fe98bcbb03ae176b511150b8c5930d4c0b1c287f5df` | `mint` and the TERMS module's `setRoyalty` |
| `RoyaltyRateLocked(uint256 indexed tokenId)` | `0x10f30d67237f019693a7756fd9e01091b8acf081f3cca0eea2aa23ef568ad775` | the TERMS module's `lockRoyaltyRate` |
| `CollectionCreated(uint256 indexed collectionId, string name, bytes32 metadataHash)` | `0x8966ba956c90c682e7629fa1eff72812e2a5d54259d1e684285c761439588057` | `createCollection` |
| `RescueDelaySet(uint48 previous, uint48 next)` | `0x329b9d8b22e5399b02553a22d24cbdd5f73e805fd198b83e827953a7fa564bbd` | `setRescueDelay` |
| `MinterAdded(address indexed minter, uint48 activeFrom)` | `0x496a0c955fc4acb0b3d3d396b62936b1d5b09ee24a0c387ac3117741a399a128` | constructor (genesis minters) and `addMinter` |
| `MinterRemoved(address indexed minter)` | `0xe94479a9f7e1952cc78f2d6baab678adc1b772d936c6583def489e524cb66692` | `removeMinter` |
| `ModuleProposed(bytes32 indexed slot, address module, uint48 readyAt)` | `0x230c42ee34613ec831fa45f3254d06dd923ae04ee5ddbeb6dc9c371f516aaf8c` | `proposeModule` |
| `ModuleSet(bytes32 indexed slot, address previous, address module)` | `0x805f6cfd1882ecfb5ba14cc1b701b7242cf95893badde12b29ffd0236bef0422` | constructor (genesis modules), `activateModule`, `removeModule` (module zero) |
| `ModuleDelaySet(uint48 previous, uint48 next)` | `0x4269f60ea01fb342018e13abcba2ff1e41cf055d5d3fca5a8c044196a0b48662` | `setModuleDelay` |
| `OwnershipTransferred(address indexed previousOwner, address indexed newOwner)` | `0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` | constructor, `setOwner` (marketplace owner only; not authority) |
| `ContractURIUpdated()` | `0xa5d4097edda6d87cb9329af83fb3712ef77eeb13738ffe43cc35a4ce305ad962` | `setContractURI` (ERC-7572) |
| `MetadataUpdate(uint256)` | `0xf8e1a15aba9398e019f0b49df1a4fde98ee17ae345cb5f6b5e2c27f5033e8ce7` | ERC-4906, from `emitMetadataUpdate` (WorkFacts, RECORDS, TERMS) |
| `BatchMetadataUpdate(uint256,uint256)` | `0x6bd5c950a8d8df17f772f5af37cb3655737899cbf903264b9795592da439661c` | ERC-4906 |

A federated token has no minter list: its minters are the federation module's answer, so
`MinterAdded` and `MinterRemoved` come from that module, not the token.

### Editions

`IEditions`; each federated editions token emits the same.

| Event | topic0 | When |
| --- | --- | --- |
| `TransferSingle`, `TransferBatch`, `ApprovalForAll`, `URI` | ERC-1155 | |
| `EditionCreated(uint256 indexed editionId, address indexed minter, uint40 maxSupply, address royaltyReceiver, uint24 royaltyRate)` | `0xaf291dbb8a8a6559eeef23b8207c336a6a43ed327b858d04a4bd0968a811a571` | `create` by the sale contract |
| `EditionMinted(uint256 indexed editionId, address indexed to, uint256 amount, uint256 unitPrice)` | `0x2525f1c59f45d123089be811400f55744de110480bc112beb610091b3e19b98b` | `mint`; precedes its `TransferSingle` |
| `EditionSupplySealed(uint256 indexed editionId, uint256 supply)` | `0xbf26eb1fb29573bf3ae0bba9e4607e51bbe158ec8720aaee88bc9f1d83abf356` | `seal` |
| `EditionRebound(uint256 indexed editionId, address indexed previous, address indexed minter)` | `0xfae5f534a1d8ad1378852156c102769f74d5ce61652202e83af9c953e71d93cd` | `rebind` |
| `RebindDelaySet(uint48 previous, uint48 next)` | `0xf0258e3cf75e4109d4976fba77ef26ac166571b541f608b43cf1d5ce4a3fc655` | `setRebindDelay` |
| `RoyaltySet`, module and minter events, `OwnershipTransferred`, `ContractURIUpdated`, ERC-4906 | as for Stream | |

### Directory

| Event | topic0 | When |
| --- | --- | --- |
| `UnclaimedPeriodSet(uint48 previous, uint48 next)` | `0x675bb988a9e92cf64b105c329cfef3c29dcb2475b43701d44ba80b5d5277657c` | `setUnclaimedPeriod` |
| `ModuleProposed`, `ModuleSet`, `ModuleDelaySet` | as for Stream | slots `ACCOUNTS`, `FEDERATION`, `FEDERATED_TERMS`, `FEDERATED_RECORDS` |

### WorkFacts

Every event is keyed by `(token, tokenId)`.

| Event | topic0 | When |
| --- | --- | --- |
| `RecordOpened(address indexed token, uint256 indexed tokenId, PackageItem item, MediaFile[] media)` | `0x2e1741d38953f812a26b7c727db87f67db827c4eaae1fa6ac4dfd2a3bf0405d7` | `open` (anyone) |
| `RecordSet(address indexed token, uint256 indexed tokenId, bytes32 recordFileId)` | `0xe2ab84ae980dead14dd785fc1a3aa7e3a4db245c79f4e29aa25b6fe11b38271e` | `setRecord` (RECORDS module) |
| `LicenseSet(address indexed token, uint256 indexed tokenId, License license)` | `0xdbeaa1306eb467d078313c1869eb964231f71ed9791f543bd2f423fe9854fa74` | `setLicense` |
| `Finalized(address indexed token, uint256 indexed tokenId, address renderer, bytes32 codeHash)` | `0x8538d96f513764912daed2eb6771c4a3df868fb8da04037f4a54bbee3cb9a318` | `finalize` |
| `RendererRepinned(address indexed token, uint256 indexed tokenId, address renderer, bytes32 codeHash)` | `0xe1aba5ab1fdafb57d79519ce3d65820f89a34f37b223b28536d2c2653bff5c83` | `repin` |
| `Locked(address indexed token, uint256 indexed tokenId, bool license, bool repin)` | `0x9a26d7aa8d0b0885c3a5cce1b95072a26bc415306c652f20e7b507c07a3914d5` | `lock` |
| `OnChainComplete(address indexed token, uint256 indexed tokenId)` | `0x3ffaeac88d7480b689b75b72fe9d967909eec8dba4ba385433cae1abb9a9893a` | `markOnChainComplete` (anyone) |

### Module interfaces frozen with the core

| Contract | Event | topic0 |
| --- | --- | --- |
| RECORDS (`IWorkRules`) | `FinalizeNoticeRecorded(address indexed token, uint256 indexed tokenId, uint256 dueAt)` | `0xc2333be19fc2214b40c22ecb199512c11bde20cec926c9cc45d84b1f2edb925c` |
| RECORDS | `PowersRenounced(address indexed token, uint256 indexed tokenId, uint16 powers)` | `0x134c17fd149ea45174ca8d4d33d06a7a06e7380cb026e6168b42f249522d696d` |
| RECORDS | `DeliverySet(address previous, address next)` | `0x113e2022127f41af1670206bb33d2c69486d7f4f382e9284c2c974fea2fbd666` |
| TERMS (`ITerms`) | `FeeShareLowered(address,uint256,uint32,uint32,address)` | `0x49e5ebea2aa2c1872dee48dfdae2fd7748c45f330b1b62140e5f1ac969b50c39` |
| Mint policy (`IMintPolicy`) | `ContentReleased(address,uint256,bytes32,uint256)` | `0x3148787f9c7b59535c75e7f202ad401ad0a5747807bcbba3a776fd1eb84f8776` |

## Modules

Names only; signatures and topics are in [`abi/`](../../abi), regenerated from the built code.

### EnglishAuction

`SaleStarted`, `BidPlaced`, `Credited`, `Claimed`, `AuctionPaused`, `AuctionResumed`,
`AuctionCancelled`, `DeliveryPending`, `DeliveryClaimed`, `RescuedSaleClosed`,
`SettlementRefused`, `SaleSettled`, `ConfigSet`, `Paused`, `Unpaused`. Sale IDs are
`uint256(keccak256(abi.encode(token, tokenId)))`.

### UniformEditionAuction

`AuctionOpened`, `BidPlaced`, `BidRaised`, `AuctionCleared`, `SaleSettled`, `DeparturesSwept`,
`AuctionSettled`, `AuctionVoided`, `BidClaimed`, `Credited`, `Claimed`, `ConfigSet`, `LimitsSet`.
Key a bid by `(saleId, bidId)`.

### PackageRegistry

Package registration, acceptance, revocation, move-nonce revocation, `ContentReleased`.

### Eip712CurationVerifier

Signer disabled and enabled.

### ArtistRegistry

The accounts module (today's artist registry, replaceable behind `Directory.ACCOUNTS`):
registration, staged, executed and cancelled changes, contests, freezes, payout changes.

### FederationRegistry

Listings, status, delisting, fee share, sale contracts, template approval.

### SplitLedger and RevenueEscrow

`WalletCreated` (the whole payee list), releases, marks, forfeits; escrow credits, flushes,
recoveries, expiries.

### StatementLog

`StatementAppended`, `StatementRelayed`, `NonceRevoked`, `ArtistResolverSet`.

### VrfEntropyModule

Seed requests, item links, deliveries, configuration and coordinator changes.

### ContentStore

`ChunkWritten`, `ChunkLinked`, `ManifestRegistered`, attestations.

### GovernanceConfigurator and WorksAccessManager

OpenZeppelin AccessManager events (roles, delays, target functions, scheduled operations), the
genesis `GovernanceConfigured`, and the network handover.

## Rebuilding state from logs

- **A Stream work.** `WorkMinted` gives the token, collection, artist, serial and every fact;
  `RoyaltySet` and `RoyaltyRateLocked` the royalty; `PrimarySale` or `WorkRescued` the outcome;
  `Transfer` the owner. A burn (`Transfer` to zero) frees the content hash `WorkMinted` carried,
  so `tokenOfContent` is rebuilt from the two.
- **Modules and minters.** `ModuleSet` (genesis and activation, zero on removal),
  `ModuleProposed` (pending), `MinterAdded`, `MinterRemoved`, and the `*DelaySet` events give the
  current settings.
- **A record.** The `WorkFacts` events for `(token, tokenId)` in order.
- **An edition.** `EditionCreated`, `EditionMinted`, `EditionSupplySealed`, `EditionRebound`,
  `RoyaltySet`.

### Statements

Index `StatementAppended` by `subjectKey`; each chain's indexes are contiguous and its head
matches `chainOf`.

## Caveats

- **Order by log index**, not by contract: a start touches the policy, Stream and the auction.
- **Reorgs.** Keep the block hash with every log; each collection's serials run 1, 2, 3.
- **Burned tokens leave ID gaps.** `totalMinted()` is the highest ID; `totalSupply()` counts
  live tokens.
- **Edition ID equals master token ID.**
- **Lazy events.** An expired auction pause is written down by a later transaction.
- **Not emitted:** content-store completeness before attestation (read `isComplete`), which
  wallets act for an account (read `isWallet`), money arriving in a split vault (read balances).
- **Governed vault forwards.** A `GovernedVault` forward log can be emitted for a token the
  vault never held: key it on the token address and match the token's own `Transfer`.

## ERC-4906 refresh triggers

| Change | Event |
| --- | --- |
| A record opened, set, finalized, relicensed, repinned, marked on-chain complete; a royalty change | `MetadataUpdate(tokenId)` on the token |
| A delivery preference change for many works | `BatchMetadataUpdate` |
| `setContractURI` | `ContractURIUpdated` |

Metadata also changes with no ERC-4906 event when a dispute outcome is recorded, when a record
or preview file completes in the store, and when a base64 file is attested. A burned token's
`tokenURI` reverts; its `Transfer` to zero is the signal.
