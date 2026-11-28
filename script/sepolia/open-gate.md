# The open gate: the curated path for any wallet, on a Sepolia test instance

This note is for the engineer who builds a test page against a Sepolia instance of 6529 Works
(r9 is the first one), and for the operator who opens and closes the gate.

On a normal instance two steps of the curated path need someone with a role: a curation signer
approves each package of works, and the platform key creates collections.
[`SepoliaOpenGate`](SepoliaOpenGate.sol) removes both steps **on a test instance only**. It is a
small contract under `script/sepolia/`; nothing under `src/` changes, so the permanent and the
replaceable contracts are the ones `main` builds.

> **A Sepolia test convenience. Never deploy it on mainnet.** With the gate open, nothing is
> curated: every package anyone submits is approved. The contract refuses to deploy or answer on
> any chain but Sepolia (11155111) and a local development chain (31337). The code is pre-audit.

## On r9

| | |
| --- | --- |
| The gate | [`0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac`](https://sepolia.etherscan.io/address/0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac), created on 28 November 2026 in block 12,227,880; its source is verified on [Sourcify](https://repo.sourcify.dev/11155111/0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac) |
| State | **Open**: it holds `CURATION_SIGNER` and `PLATFORM` since blocks 12,227,881 and 12,227,882 |
| r9's addresses | [`core-1795840548.json`](../../deployments/11155111/core-1795840548.json); the round is described in the [Sepolia README](../../deployments/11155111/README.md#sepolia-r9-28-november-2026-current-instance-with-an-open-gate) |
| What ran through it | [flows-r9.md](../../deployments/11155111/flows-r9.md) |

To close the gate on r9, the network Safe revokes the two roles (two Safe transactions, two
owner signatures each, effective at once):

```powershell
./script/sepolia/flows.ps1 -SignerModule <path> -State <state.json> -Record deployments/11155111/core-1795840548.json -Step gateRevoke
```

`-Step gateState` then prints `curationSigner false` and `platform false`. Packages registered
before stay approved; `PackageRegistry.killSignerApprovals(0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac)`,
a network call, stops those too. `-Step gateGrant` opens the gate again.

## What the gate is

| It holds | So that | How |
| --- | --- | --- |
| `CURATION_SIGNER` (role 4) | anyone can register a package | The curation verifier accepts a contract as a signer through ERC-1271. The gate's `isValidSignature` says yes to one kind of digest only: the verifier's approval of a package root, with the gate's own evidence hash for that root, at the gate's current signer epoch |
| `PLATFORM` (role 8) | anyone can create a collection | `createCollection` forwards to `Stream6529.createCollection` |

It has no owner, no setter and no fallback, takes no ETH and forwards no other call. The artist
of a work is the wallet that signs for it: the gate never signs an acceptance or a move, so it
cannot act for an artist ([tests](../../test/sepolia/SepoliaOpenGate.t.sol)).

Two limits to know:

- **Collections have no owner** in 6529 Stream. Any package item may name any collection, so
  on an open instance anyone can add a work to a collection someone else created.
- **`PLATFORM` covers more than collections** (`WorkDelivery.addLocator`,
  `StatementLog.appendPlatform`). The gate has no code that calls them.

## For the operator

All steps go through [`flows.ps1`](flows.ps1); [`OpenGate.s.sol`](OpenGate.s.sol) plans them.
Run them after the deployment, the Safe's `acceptNetwork` and the read-back
([runbook](../README.md#sepolia)).

| Step | What it does | Who signs |
| --- | --- | --- |
| `-Step gateState` | Prints the gate's address, whether it exists and which roles it holds | Nobody |
| `-Step gateDeploy` | Creates the gate through the canonical CREATE2 factory. The address depends only on the gate's code and the instance's `CurationVerifier` and `Stream6529`, so it is known before | The relay key (any account can) |
| `-Step gateGrant` | The network Safe calls `grantRole(4, gate, 0)` and `grantRole(8, gate, 0)` on the manager: two Safe transactions | Two Safe owners |
| `-Step gateRevoke` | The Safe revokes both roles: the gate is closed | Two Safe owners |
| `-Step gateCollection -From <role> -Name <name>` | Creates a collection through the gate | The account |
| `-Step gatePackage` | The `package` step with the gate's approval: no curation signer, no curator statement | The relay key and the artist |

**Roles are granted after deployment, not at genesis.** The gate's constructor takes the
instance's verifier and Stream, and a deployment's genesis file may differ from the committed
policy only in its network and holders, three pausers, two curation signers and one key each
for the rest. The network is the admin of both roles with no delay, so each grant is one Safe
transaction that takes effect at once.

**No step waits.** Granting, revoking and `PackageRegistry.killSignerApprovals(gate)` (which
also stops the packages the gate approved before) are immediate. To close the gate, revoke the
roles: `CurationVerifier.disableSigner(gate)` also closes it at once, but the way back
(`enableSigner`) is a 7-day action.

**The read-back after the grants.** `VerifyCore.s.sol` compares the manager's role logs with
the genesis file, so at the chain's head it reports the gate's two grants as differences. Run
it before `gateGrant` (then complete the record with `make_record.py --confirmed`), and
afterwards with `ALLOW_GOVERNANCE_CHANGES=1`, which prints the two differences and goes on, or
with `--fork-block-number` at a block before the grants.

## For the frontend: the curated flow through the gate

Addresses come from the instance's deployment record, one `<name>: <address>` object: for r9,
[`core-1795840548.json`](../../deployments/11155111/core-1795840548.json). ABIs are in
[`abi/`](../../abi/). The gate's address is printed by `gateState`; on r9 it is
`0x843d8DCdD279215225f39AFCA33a5Fd4E84370Ac`. (On another instance it differs: it depends on
the gate's code and on that instance's `CurationVerifier` and `Stream6529`.)

Everything is an ordinary transaction or an EIP-712 signature (`eth_signTypedData_v4`) by the
connected wallet. `W` is that wallet. Steps 3 and 4 are the only ones that differ from a normal
instance.

### 1. A collection (optional)

Use an existing collection ID (1 to `Stream6529.collectionCount()`), or create one:

```solidity
SepoliaOpenGate.createCollection(string name, bytes32 metadataHash) returns (uint256 collectionId)
```

- `name`: the collection's name. `metadataHash`: any hash of a metadata document (not read on chain).
- Events: `Stream6529.CollectionCreated(collectionId, name, metadataHash)` and the gate's
  `CollectionOpened(collectionId, creator, name, metadataHash)`.

### 2. The files (`ContentStore`, open to anyone on every instance)

A work needs a primary media file and a descriptive record (JSON). For each file:

```solidity
ContentStore.writeChunk(bytes data) returns (bytes32 hash, address pointer)   // each chunk, at most CHUNK_SIZE() bytes
ContentStore.registerManifest(bytes32[] chunkHashes, uint256 length, uint8 encoding,
                              string mimeType, bytes32 sha256Hash) returns (bytes32 fileId)
ContentStore.manifestId(...same arguments...) returns (bytes32 fileId)        // pure: the ID before sending
```

- `chunkHashes`: `keccak256` of each stored chunk, in order. `length`: the stored length in bytes.
- `encoding`: 0 for the bytes as they are (1 gzip, 2 base64, 3 gzip then base64).
- `mimeType`: for example `image/png`, `application/json`. `sha256Hash`: SHA-256 of the decoded bytes.
- Upload the record (write its chunks): the renderer reads it for `tokenURI`. The media may be
  registered only (`registerManifest` without `writeChunk`): the file is then served off chain.
- Event: `ManifestRegistered(fileId, …)`. A file registered already keeps its ID; skip it.
- **Every work needs its own media bytes**: Stream mints a content hash once.

### 3. The item and its package root

Build the `PackageItem` ([`PackageTypes.sol`](../../src/interfaces/types/PackageTypes.sol)). For
a work by one artist:

| Field | Value |
| --- | --- |
| `kind` | 0 for an original, 1 for an edition master |
| `collectionId` | The collection |
| `contentHash` | SHA-256 of the primary media |
| `mediaHash` | `gate.mediaHashOf(media)`, where `media` is `[(fileId, sha256, role)]`, the primary file first with role 0 |
| `recordFileId` | The record's file ID |
| `parties` | `[(W, 0)]`: the wallet, as the lead artist |
| `payees` | `[(uint160(W), address(0), 100000)]`: everything to the artist's account |
| `license` | `("CC0-1.0", StreamWorkFacts6529.cc0TextFileId())` |
| `seedPolicy`, `seed` | 0 and `bytes32(0)` |
| `sale` | `(keccak256("ENGLISH_AUCTION"), address(0), "0x")` |
| `edition` | Original: `(0, address(0), bytes32(0), "0x")`. Master: `(maxCount, address(0), keccak256("UNIFORM_AUCTION"), "0x")`, `maxCount` 0 for no cap |

```solidity
SepoliaOpenGate.oneItemPackage(PackageItem item) returns (bytes32 itemHash, bytes32 packageRoot)   // pure
```

A package of one item has an empty proof. (For several items the root is an OpenZeppelin
sorted-pair Merkle root over `keccak256(itemHash)`; see
[`WorksHashing.sol`](../../src/interfaces/types/WorksHashing.sol).)

### 4. Register the package: the step the gate opens

```solidity
SepoliaOpenGate.attestationOf(bytes32 packageRoot) returns (bytes32 evidenceHash, bytes attestation)   // view
PackageRegistry.registerPackage(bytes32 packageRoot, bytes32 evidenceHash, bytes attestation)
```

- Pass the two values `attestationOf` answers, unchanged. Anyone may send it.
- Event: `PackageRegistered(packageRoot, evidenceHash, verifier, signer)`, with `signer` the gate.
- A root registers once: if `PackageRegistry.packageOf(root)` answers status 1 (approved), skip
  the step. `PackageExists` means the same.

### 5. The artist accepts the package (a signature, then a transaction anyone sends)

Typed data, domain `{ name: "6529 Works Package Registry", version: "1", chainId: 11155111,
verifyingContract: PackageRegistry }`:

```
PackageAcceptance(bytes32 packageRoot,address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)
```

```solidity
PackageRegistry.acceptPackage(bytes32 packageRoot,
    (address account, bytes32 profileId, bytes32 profileDocHash, uint64 deadline) acceptance,
    bytes proof) returns (uint256 artistId)
```

- `account`: `W`. `deadline`: a Unix time after which the signature is void.
- `profileId`, `profileDocHash`: on a wallet's first acceptance, any two values; they become the
  account's profile fields, and every later acceptance must repeat them
  (`Accounts.artist(artistId)` reads them back).
- `proof`: the wallet's 20 bytes followed by the 65-byte signature.
- The first acceptance creates the wallet's account; its artist ID is `uint160(W)`.
- Event: `PackageAccepted(packageRoot, artistId, account)`. Done already when
  `PackageRegistry.acceptedAs(root, W)` is nonzero.
- `PackageRegistry.acceptanceDigest(root, acceptance)` answers the digest, to check an encoding.

### 6. The artist signs the move, and the 1/1 starts

Typed data, same domain:

```
MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)
```

- `nonce`: the artist's next unused move nonce, counted from 0
  (`PackageRegistry.isMoveNonceUsed(artistId, nonce)`).
- The request is `abi.encode` of one `StreamMintRequest` tuple:
  `(packageRoot, item, proof, (nonce, deadline, signature))`, where `proof` is `[]` and
  `signature` is the wallet's 20 bytes followed by the signature.

Then one of:

```solidity
// (a) one transaction: the auction, the payout vaults and the work's record. No bid.
SaleStarter.start(address auction, address stream, bytes request,
                  (bytes32 fileId, bytes32 sha256, uint8 role)[] media) returns (uint256 saleId)

// (b) the start with a first bid by the sender (at least the opening bid, 0.05 ETH)
EnglishAuction.startWithBid(address stream, bytes request, address recipient) payable returns (uint256 saleId)
StreamWorkFacts6529.open(address stream, uint256 tokenId, PackageItem item, MediaFile[] media)   // afterwards, by anyone
```

- `auction`: `EnglishAuction`. `stream`: `Stream6529`. `recipient`: `address(0)` for the sender.
- Anyone may send either; the signed move is what authorizes it, and it is used once.
- Events: `EnglishAuction.SaleStarted(saleId, token, tokenId, saleKind, currency, price, startTime, endTime)`,
  `Stream6529.WorkMinted(tokenId, collectionId, artistId, minter, serial, facts)`,
  `StreamWorkFacts6529.RecordOpened(token, tokenId, item, media)`, and with (b)
  `EnglishAuction.BidPlaced`.
- `saleId` is `EnglishAuction.saleIdOf(stream, tokenId)`. The auction runs 3,600 seconds on r9;
  a bid in the last 15 minutes moves the end to 15 minutes after it.

### 7. The edition sale (edition masters only), right after the start

```solidity
UniformEditionAuction.open(address editions, uint256 masterTokenId, bytes data) returns (uint256 saleId)
```

- `editions`: `StreamEditions6529`. `data`: `abi.encode(item, packageRoot, proof)`. Anyone sends it.
- Events: `UniformEditionAuction.AuctionOpened(saleId, token, id, master, maxCount, terms, closeAt)`
  and `StreamEditions6529.EditionCreated`. The edition's ID is the master's token ID.
- It closes 15 minutes after the 1/1 ends (`endTimes(saleId)`).

### 8. Bids (any wallet)

```solidity
EnglishAuction.minimumBid(uint256 saleId) returns (uint256)
EnglishAuction.bid(uint256 saleId, address recipient) payable                    // BidPlaced; the outbid bidder: Credited
EnglishAuction.claim(address to) returns (uint256 amount)                        // an outbid bidder pulls its ETH; Claimed

UniformEditionAuction.stepPrice(uint256 saleId, uint256 step) returns (uint256)  // steps 0 to 335, 0.0001 ETH at step 0
UniformEditionAuction.bid(uint256 saleId, uint256 step, uint256 quantity) payable returns (uint256 bidId)
```

An edition bid pays exactly `stepPrice * quantity`. Its `BidPlaced` event carries the `bidId`.

### 9. After the end (anyone settles)

```solidity
EnglishAuction.settle(uint256 saleId)                                   // SaleSettled; Stream6529.PrimarySale
UniformEditionAuction.settle(uint256 saleId, uint256[] order) returns (bool settled)
UniformEditionAuction.claimBid(uint256 saleId, uint256 bidId, address to) returns (uint256 unitsWon, uint256 refund)
UniformEditionAuction.claimBidFor(uint256 saleId, uint256 bidId)        // by anyone; the refund is credited
UniformEditionAuction.claim(address currency, address to)               // pulls a credited refund; currency address(0)
SplitFactory.release((uint256 artistId, address account, uint32 share)[] payees, bytes32 salt, address asset, uint256 index)
```

- The edition's `order` is `settlementOrder(saleId)` before the first settle call and
  `settlementOrderFor(saleId, sender)` after it; repeat until `settle` answers true.
  Events: `AuctionCleared`, `AuctionSettled`, `BidClaimed`.
- `release` pays the artist from the work's seller vault: the item's `payees`, salt
  `bytes32(0)`, asset `address(0)` and the payee's index, sent by the artist's wallet.
- [Buying, bidding, settling](../../docs/integrators/buying-bidding-settling.md) and
  [Events and indexing](../../docs/integrators/events-and-indexing.md) have the full detail.

### The Independent path

Unchanged, and not touched by the gate: an artist deploys its own contract from the approved
template, lists it and approves each work itself
([Independent Stream](../../docs/spec/independent-stream.md); the `independent*` steps of
`flows.ps1`).

## What differs from r8

| | r8 | r9 with the gate open |
| --- | --- | --- |
| Addresses | [`core-1795440624.json`](../../deployments/11155111/core-1795440624.json) | [`core-1795840548.json`](../../deployments/11155111/core-1795840548.json) |
| Code | `main` at `961bc956` | `main` at `355a7a71`. Every function above has the same signature; `Accounts`, `EnglishAuction` and `PackageRegistry` gained functions (use the ABIs of this commit) |
| Registering a package (step 4) | The attestation is a curation signer's signature, made by the operator | The attestation comes from `gate.attestationOf(root)`: no signature, nobody to ask |
| The curator's statement | Appended by the curator key after registration (not required by any contract) | Left out |
| A collection (step 1) | Created by the platform key | `gate.createCollection`, by anyone |
| Everything else | | The same calls |

The usual curation signers and the platform key keep their roles on r9, so the operator's own
flows run as on r8.

## Gas

The first column was measured on a local anvil fork of Sepolia before the broadcast
(28 November 2026), where gas is priced as on mainnet today. The second is the receipt on r9
for the steps that ran there ([flows-r9.md](../../deployments/11155111/flows-r9.md)): Sepolia
prices state creation higher, so a step that creates state costs several times the first
figure. Sepolia's gas price is a fraction of a gwei, so even those cost little test ETH.

| Step | Local fork | r9 (Sepolia) |
| --- | ---: | ---: |
| Deploy the gate | 842,550 | 5,780,518 |
| Each role grant (the Safe's `execTransaction`) | 110,887 | 294,257 |
| `gate.createCollection` | 135,234 | 481,954 |
| A record: `writeChunk` and `registerManifest` | 120,842 and 147,970 | 621,958 and 581,870 |
| A media file registered only | 145,412 | 579,336 |
| `registerPackage` with the gate's attestation | 112,693 | 284,033 |
| `acceptPackage` (the first: it creates the account) | 229,880 | 841,740 |
| `SaleStarter.start` | 576,404 | 2,761,886 (the instance's first sale) |
| `startWithBid`, then `StreamWorkFacts6529.open` | 386,373 and 206,212 | |
| `UniformEditionAuction.open` | 400,591 | |
| A 1/1 bid; an edition bid | 74,182; 86,127 | |
| 1/1 `settle`; edition `settle` (two bids) | 137,186; 149,727 | |
| `claimBid`; `claim` of an outbid 1/1 bid | 74,168; 31,996 | |
| `release` to the artist | 101,658 | |
