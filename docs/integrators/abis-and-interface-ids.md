# ABIs and interface IDs

For engineers who call, decode or verify the contracts: where the ABIs come from, the ERC-165
interface IDs, the EIP-712 domains and type strings, and the protocol hashes you recompute
off-chain. Events are in [Events and indexing](events-and-indexing.md), addresses in
[Addresses](addresses.md).

> Pre-audit. See the [project status](../../README.md#status).

## Where ABIs come from

### The exported ABIs

[`abi/`](../../abi/) holds the ABIs of the code on this commit, exported from the build by
[`tools/export_abis.py`](../../tools/export_abis.py) (`--check` fails when they differ). They
are the ABIs of `main`, not of a deployment: for a deployed instance, build its commit.
`abi/manifest.json` lists each file with its kind, source path, interface ID and hash.

```bash
forge build && python tools/export_abis.py          # rewrite abi/
python tools/export_abis.py --check                 # report a difference
jq '.contracts[] | select(.kind=="interface") | {name, interfaceId}' abi/manifest.json
```

Every view is native: there is no lens, extension or fallback on the token contracts.
Runnable examples are in [`examples/`](../../examples/README.md).

## ERC-165 interface IDs

An interface ID is the XOR of the selectors the interface itself declares, not inherited ones.
The IDs below are computed from the frozen interfaces in
[`src/interfaces/core/`](../../src/interfaces/core) with `forge inspect`.

| Interface | ID | Answered by |
| --- | --- | --- |
| [`IStream`](../../src/interfaces/core/IStream.sol) | `0xe38078e5` | Stream, each Independent Stream 1/1 token |
| [`IEditions`](../../src/interfaces/core/IEditions.sol) | `0xa7c1a138` | Editions, each Independent Stream Editions token |
| [`IModuleSlots`](../../src/interfaces/core/IModules.sol) | `0x9ce5ed0a` | Stream, Editions, Directory |
| [`IModules`](../../src/interfaces/core/IModules.sol) | `0x733435b6` | Stream, Editions |
| [`IDirectory`](../../src/interfaces/core/IDirectory.sol) | `0xe8ee5a5e` | Directory |
| [`IWorkFacts`](../../src/interfaces/core/IWorkFacts.sol) | `0xf9ce2773` | WorkFacts |
| [`IWorkRules`](../../src/interfaces/core/IWorkRules.sol) | `0x745fb7f4` | WorkRules (RECORDS) |
| [`ITerms`](../../src/interfaces/core/ITerms.sol) | `0xf22b5cc8` | StreamTerms (TERMS) |
| [`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol) | `0x207cd15b` | PackageRegistry, IndependentStreamRegistry |
| [`IAccounts`](../../src/interfaces/core/IAccounts.sol) | `0xc27b4543` | Accounts |
| [`IIndependentStreamGate`](../../src/interfaces/core/IIndependentStreamGate.sol) | `0x2a7a53b2` | IndependentStreamRegistry |
| [`ILocators`](../../src/interfaces/core/ILocators.sol) | `0x4e8975bf` | WorkDelivery |
| ERC-721, ERC-1155, ERC-2981, ERC-4906 | `0x80ac58cd`, `0xd9b67a26`, `0x2a55205a`, `0x49064906` | the token contracts |

The module interfaces, with the IDs `test/interfaces/InterfacesCompile.t.sol` pins:

| Interface | ID | Answered by |
| --- | --- | --- |
| [`IPackageRegistry`](../../src/interfaces/IPackageRegistry.sol) | `0xfecfa933` | PackageRegistry |
| [`IItemApprovals`](../../src/interfaces/IItemApprovals.sol) | `0x881b19aa` | PackageRegistry |
| [`ICurationVerifier`](../../src/interfaces/ICurationVerifier.sol) | `0x492733ca` | Eip712CurationVerifier |
| [`ICurationSignerVerifier`](../../src/interfaces/ICurationVerifier.sol) | `0x9f12d97a` | Eip712CurationVerifier |
| [`IEnglishAuction`](../../src/interfaces/IEnglishAuction.sol) | `0x54df3713` | EnglishAuction |
| [`IEnglishAuctionClock`](../../src/interfaces/IEnglishAuctionClock.sol) | `0x968c7b07` | EnglishAuction (read by the edition auction) |
| [`IEnglishAuctionRefusal`](../../src/interfaces/IEnglishAuctionRefusal.sol) | `0x625761b5` | EnglishAuction |
| [`IUniformEditionAuction`](../../src/interfaces/IUniformEditionAuction.sol) | `0xa34e53aa` | UniformEditionAuction, IndependentEditionAuction |
| [`ISaleAdapter`](../../src/interfaces/ISaleAdapter.sol) | `0xd15ddb3f` | the sale contracts |
| [`IArtistRegistry`](../../src/interfaces/IArtistRegistry.sol) | `0x1bec3945` | Accounts |
| [`IArtistRoleResolver`](../../src/interfaces/IArtistRoleResolver.sol) | `0x3074ca00` | Accounts |
| [`IConsolidationSource`](../../src/interfaces/IArtistRegistry.sol) | `0x42129132` | ConsolidationAdapter |
| [`IArtistPayoutResolver`](../../src/economics/interfaces/IArtistPayoutResolver.sol) | `0x9b2c1793` | Directory |
| [`IIndependentStreamRegistry`](../../src/interfaces/IIndependentStreamRegistry.sol) | `0x74a7e21a` | IndependentStreamRegistry |
| [`IWorkPowers`](../../src/interfaces/IWorkPowers.sol) | `0xf2f560e3` | WorkRules |
| [`IStatementLog`](../../src/interfaces/IStatementLog.sol) | `0xbb5574c7` | StatementLog |
| [`IEntropyModule`](../../src/interfaces/IEntropyModule.sol) | `0x549d75c9` | VrfEntropyModule |
| [`IRenderer`](../../src/interfaces/IRenderer.sol) | `0xa772216d` | Renderer |
| [`IContentStore`](../../src/interfaces/IContentStore.sol) | `0xe5a30736` | ContentStore |
| [`IDependencyRegistry`](../../src/interfaces/IDependencyRegistry.sol) | `0xe5338d57` | DependencyRegistry |
| [`IEconomicsResolver`](../../src/interfaces/IEconomicsResolver.sol) | `0x9ba8ecb3` | EconomicsResolver |

Every exported interface's ID is also in `abi/manifest.json`.

## EIP-712 domains

Every signing contract uses OpenZeppelin `EIP712` with the four-field domain
`EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` (typehash
`0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f`), so a signature is valid
for one contract on one chain. Each contract reports its domain through EIP-5267
`eip712Domain()`.

| Contract | `name` | `version` | Defined in |
| --- | --- | --- | --- |
| PackageRegistry | `6529 Works Package Registry` | `1` | `Typehashes.PACKAGE_REGISTRY_NAME`, `DOMAIN_VERSION` |
| Eip712CurationVerifier | `6529 Works Curation Verifier` | `1` | `Typehashes.CURATION_VERIFIER_NAME` |
| WorkRules (RECORDS module) | `6529 Works Records` | `1` | `Typehashes.WORK_RECORDS_NAME` |
| Accounts (accounts module) | `6529 Works Artist Registry` | `1` | `Typehashes.ARTIST_REGISTRY_NAME` |
| StatementLog | `6529 Works Statement Log` | `1` | the constructor of [`StatementLog.sol`](../../src/records/StatementLog.sol) |
| SplitLedger (the release verifier) | `6529 Works Release Verifier` | `1` | the constructor of [`SplitLedger.sol`](../../src/economics/SplitLedger.sol) |

The `Typehashes` constants are in
[`src/interfaces/types/Typehashes.sol`](../../src/interfaces/types/Typehashes.sol).

## Typehashes and type strings

### Signed payloads

Type strings exactly as in code; typehashes pinned by `test_signedPayloadTypehashes` in
[`test/interfaces/Typehashes.t.sol`](../../test/interfaces/Typehashes.t.sol) unless noted.

| Constant | Type string | Typehash | Domain and signer |
| --- | --- | --- | --- |
| `Typehashes.MOVE_TO_STREAM` | `MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)` | `0xe193fedc71b458003faf3a90795989683ea6a572f7cae0f6729d1219894814f8` | Package registry; any wallet of the lead artist's account |
| `Typehashes.PACKAGE_ACCEPTANCE` | `PackageAcceptance(bytes32 packageRoot,address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)` | `0x557d83fa1b5c5123a734c14182eab668ea8678f09c42986018a05d2be5aa362f` | Package registry; any wallet of the party's account |
| `Typehashes.PACKAGE_APPROVAL` | `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash,uint256 signerEpoch)` | `0xbf131d47e2ddcf4bd120061a8a3c2841ef379caa26b7eec0881120e1d8a43cdd` | Curation verifier; a curation signer, at its current `signerEpoch` |
| `Typehashes.RELICENSE` | `Relicense(uint256 tokenId,bytes32 licenseKey,bytes32 textFileId,bytes32 stateHash,uint64 deadline)` | `0x8e6e8db23b02e7536fe205ab2dd4340fc5f4b94ad3878dece0549cff5101996f` | Records module; every party of the item, in order |
| `Typehashes.ROYALTY_RATE_CHANGE` | `RoyaltyRateChange(uint256 tokenId,uint32 rate,bytes32 stateHash,uint64 deadline)` | `0x4f00b7a5a626b7fd46a6eb233ba5926281727b94836ffa9091fa1cc73d7fa038` | Records module; every party of the item, in order |
| `Typehashes.RENOUNCE_POWERS` | `RenouncePowers(uint256 tokenId,uint16 powers,bytes32 stateHash,uint64 deadline)` | `0xff8cc1b150cf1b390fd870b4a587d3c2632e80f32efbefe166b9f7b0131d3aff` | Records module; any wallet of the lead artist's account (with the network for `ROYALTY_RATE` or `RELICENSE`) |
| `Typehashes.IDENTITY_CHANGE` | `IdentityChange(uint256 artistId,address root,address payout,bytes32 profileId,bytes32 profileDocHash,uint256 nonce,uint64 deadline)` | `0x861dd247b7856a4fbd738106b59a20eabf86c787bcc7c5c77f8bf506b24e4495` | Accounts module; any wallet of the account (the account's own change) |
| `Typehashes.REPLACEMENT_ACCEPTANCE` | `ReplacementAcceptance(uint256 artistId,address root,address payout,bytes32 profileId,bytes32 profileDocHash,bytes32 evidenceHash,uint64 deadline)` | `0xa0e556173f6123b1243ffd400cc5066b72e9f63a185f7c223a7a9761be52aeff` | Accounts module; the new root of a network replacement (a raw signature, used once) |
| `Typehashes.ACCOUNT_CONSENT` | `Consent(address subject,bytes32 what)` | `0x698c989ad77f65b3786711063b64ef5589a2f9efc6261c97a73e4eee803af539` | Accounts module; any wallet of the account, for the contract `subject` only (`requireConsent`; an Independent Stream collaborator's consent to an item) |
| `Typehashes.ARTIST_REGISTRATION` | `ArtistRegistration(address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)` | `0x251edc52a2bb08ba54c8c256d514ddd287d55597cda1692026fb5fcbf0f8a8d9` | Accounts module; the new account itself (a raw signature, `registerIndependent`) |
| `Typehashes.INDEPENDENT_LISTING` | `IndependentListing(uint256 artistId,address token,uint8 form,address partner,uint32 feeShare,address feeRecipient,uint64 deadline)` | `0xc6c1acdb6e5275d9f6ab97f01f142831a32aa8d4d19a2562f68647103f1436d0` | Accounts module; any wallet of the artist's account (`listIndependentContract`) |
| `StatementLog` `HASHREF_TYPEHASH` | `HashRef(uint16 algorithm,bytes32 digest)` | `0x121a61476ab0828add4a5b9b9f2bb805adcfa15d81ff19494f98b0fd3e0bd6ed` | (a member type) |
| `StatementLog` `STATEMENT_TYPEHASH` | `Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)` | `0xc5917de59a1e9cd194c71a1bfa5d2b7a821403b15a6c26ba9ed4aaa207f324f6` | (a member type, and the statement's identity in the entry hash) |
| `StatementLog` `AUTHORIZATION_TYPEHASH` | `Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)HashRef(uint16 algorithm,bytes32 digest)Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)` | `0x31b41af4c88eb6a6042a07475f214b72f1819151382b4f7c6600f092bf061f89` | Statement log; the relayed signer |
| `SplitLedger.RELEASE_TYPEHASH` | `ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)` | `0xf64c722b2f9f611784cae451d729d2046031dd1ccede35af5642984d5c6f2925` | Split ledger; the payee's payout address |

The three statement-log values are pinned by `test_Golden_TypeHashesAndDomainTags` in
[`StatementLogGolden.t.sol`](../../test/records/StatementLogGolden.t.sol). The release
typehash is checked against its type string by `test_GoldenTypehashDomainAndDigest` in
[`ReleaseVerifier.t.sol`](../../test/economics/ReleaseVerifier.t.sol), which tests the split
ledger's verifier; its hex value was computed for this page.

### How each struct hash is built

Each digest is `keccak256("\x19\x01" ‖ domainSeparator ‖ structHash)`, with every field
ABI-encoded as a 32-byte word:

| Payload | `structHash` | Digest helper |
| --- | --- | --- |
| MoveToStream | `keccak256(abi.encode(MOVE_TO_STREAM, packageRoot, itemHash, nonce, deadline))` | `PackageRegistry.moveDigest` |
| PackageAcceptance | `keccak256(abi.encode(PACKAGE_ACCEPTANCE, packageRoot, account, profileId, profileDocHash, deadline))` | `PackageRegistry.acceptanceDigest` |
| PackageApproval | `keccak256(abi.encode(PACKAGE_APPROVAL, packageRoot, evidenceHash, signerEpoch))` | `Eip712CurationVerifier.approvalDigest` |
| Relicense | `keccak256(abi.encode(RELICENSE, tokenId, licenseKey, textFileId, stateHash, deadline))`, `licenseKey` of the new license | none; use the records module's domain |
| RoyaltyRateChange | `keccak256(abi.encode(ROYALTY_RATE_CHANGE, tokenId, rate, stateHash, deadline))` | none |
| RenouncePowers | `keccak256(abi.encode(RENOUNCE_POWERS, tokenId, powers, stateHash, deadline))`, `powers` a `uint16` mask of `WorkPowers` bits | none; use the records module's domain |
| IdentityChange | `keccak256(abi.encode(IDENTITY_CHANGE, artistId, root, payout, profileId, profileDocHash, nonce, deadline))` | `Accounts.changeDigest` |
| ReplacementAcceptance | `keccak256(abi.encode(REPLACEMENT_ACCEPTANCE, artistId, root, payout, profileId, profileDocHash, evidenceHash, deadline))` | `Accounts.replacementDigest` |
| Consent | `keccak256(abi.encode(ACCOUNT_CONSENT, subject, what))` | `Accounts.consentDigest` |
| Authorization (statement relay) | `keccak256(abi.encode(AUTHORIZATION_TYPEHASH, uint8(role), signer, nonce, deadline, statementHash))`, with `statementHash` [below](#statement-entry-hash-and-chain-head) | `StatementLog.authorizationDigest` |
| ReleaseAuthorization | `keccak256(abi.encode(RELEASE_TYPEHASH, wallet, asset, payee, account, recipient, amount, nonce, deadline))` | `SplitLedger.releaseDigest` |

`stateHash` is the work's current [state hash](#work-state-hash), so a relicense, rate change
or renunciation signature applies only to the state its signers saw. Every party signs the same
Relicense or RoyaltyRateChange digest with any wallet of its account, and the proofs go in
party order ([WS-13, WS-14](../spec/works-and-storage.md#rules-and-invariants)).

**Proof format.** Wherever an account signs (a move, a package acceptance, an own identity
change, a listing consent, a collaborator consent, a work-records consent), the call takes a
proof `abi.encodePacked(wallet, signature)`: `wallet` is the signing wallet, the root or any
wallet consolidated with it, and `signature` its signature over the digest, checked by
`SignatureVerifier` (ECDSA, ERC-1271 or EIP-7702). The accounts module's `requireSigned` checks
both that the wallet acts for the account and the signature. `registerIndependent` and a
replacement's acceptance take the new address's raw signature.

## Protocol hashes recomputed off-chain

None of these binds a chain ID or contract address unless it says so, so a package has the
same item hashes and root on every chain ([CUR-20](../spec/curation.md#rules-and-invariants)).

### Item hash, leaf and package root

From [`WorksHashing.sol`](../../src/interfaces/types/WorksHashing.sol):

```text
PACKAGE_ITEM_DOMAIN = keccak256("6529WORKS_PACKAGE_ITEM_V1")
                    = 0xce048e45e85b58b943276445f3e3305cd4c21570a67fd8a4f189d6c38edcae8d
itemHash = keccak256(abi.encode(PACKAGE_ITEM_DOMAIN, item))
leaf     = keccak256(bytes.concat(itemHash))          // keccak256 of the 32-byte item hash
root     = OpenZeppelin MerkleProof root over the leaves (sorted-pair keccak256)
```

`item` is a `PackageItem` ([`PackageTypes.sol`](../../src/interfaces/types/PackageTypes.sol)).
With an off-chain ABI encoder, encode the two values `["bytes32", <tuple>]` with the tuple

```text
(uint8,uint256,bytes32,bytes32,bytes32,(address,uint8)[],(uint256,address,uint32)[],(string,bytes32),uint8,bytes32,(bytes32,address,bytes),(uint32,address,bytes32,bytes))
```

in field order: `kind`, `collectionId`, `contentHash`, `mediaHash`, `recordFileId`, `parties`
`(account, role)`, `payees` `(artistId, account, share)`, `license` `(spdxId, textFileId)`,
`seedPolicy`, `seed`, `sale` `(saleKind, currency, params)` and `edition`
`(maxCount, currency, saleKind, params)`. The tuple is dynamic, so the
encoding is the domain word, an offset word and then the tuple. This is OpenZeppelin's
`StandardMerkleTree` with leaf encoding `["bytes32", <PackageItem tuple>]` and leaf values
`[PACKAGE_ITEM_DOMAIN, item]`, whose leaf is `keccak256(keccak256(abi.encode(values)))`; the
double hash keeps a 64-byte inner node from passing as a leaf. A one-item package's root is
its leaf, and proofs are at most 32 nodes (`Limits.MAX_PROOF_DEPTH`).

### Media hash, content hash and license key

```text
MEDIA_DOMAIN = keccak256("6529WORKS_MEDIA_V1")
             = 0x722ffd9834d64e2c48b7edc1969f58c7f64a9d03c4a0f7a63da31e7b21c6f062
mediaHash    = keccak256(abi.encode(MEDIA_DOMAIN, media))   // media: (bytes32 fileId, bytes32 sha256Hash, uint8 role)[]
licenseKey   = keccak256(lowercaseAscii(spdxId))            // only A-Z are lowered
CC0_LICENSE_KEY = keccak256("cc0-1.0")
                = 0xc524702ec980d5da7df189fec7f0c9b69529a70700cfd88d07f8cc34d042ad71
```

The media list is in approved order, primary first; `role` is 0 PRIMARY, 1 PREVIEW,
2 AUXILIARY. The **content hash** is not computed on-chain: it is the declared SHA-256 of the
fully decoded primary media, `media[0].sha256Hash`.

### File ID and chunk hash

From [`IContentStore.sol`](../../src/interfaces/IContentStore.sol) (`manifestId`):

```text
chunkHash_i = keccak256(chunk_i)       // every chunk is CHUNK_SIZE = 24,575 bytes, except the last
fileId      = keccak256(abi.encode(chunkHashes, length, uint8(encoding), mimeType, sha256Hash))
              // types: (bytes32[], uint256, uint8, string, bytes32)
```

`length` is the stored length; `encoding` is 0 Identity, 1 Gzip, 2 Base64, 3 GzipBase64;
`mimeType` is the lowercase `type/subtype` of the decoded media; `sha256Hash` is the SHA-256 of
the fully decoded media. A file ID names one encoded stream, not the content: the same media
stored with another encoding or MIME type has another file ID. The Python uploader
([`tools/content/`](../../tools/content/README.md)) computes both values.

### Statement entry hash and chain head

From [`StatementLog.sol`](../../src/records/StatementLog.sol):

```text
subjectKey    = keccak256(abi.encode(token, id))
contentHash   = keccak256(abi.encode(HASHREF_TYPEHASH, content.algorithm, content.digest))
statementHash = keccak256(abi.encode(STATEMENT_TYPEHASH, token, id, kind, schema,
                    contentHash, keccak256(bytes(uri)), fileId, supersedes))
ENTRY_DOMAIN  = keccak256("6529.works.StatementLog.entry.v1")
              = 0x0f3311395c5212a871acb58afd86802fdee2d0bd441c4d282deb4870d87e1f11
entryHash     = keccak256(abi.encode(ENTRY_DOMAIN, block.chainid, address(log), subjectKey,
                    index, uint8(role), signer, resolver, recordedAt, statementHash))
                // types: (bytes32, uint256, address, bytes32, uint64, uint8, address, address, uint64, bytes32)
HEAD_DOMAIN   = keccak256("6529.works.StatementLog.head.v1")
              = 0x20025e2db27e195c57e0612653067df58c83f14892beca1016dfd5dfa49b15e0
head_0        = 0x0000000000000000000000000000000000000000000000000000000000000000
head_(n+1)    = keccak256(abi.encode(HEAD_DOMAIN, head_n, entryHash_n))
```

`statementHash` is EIP-712 `hashStruct(Statement)`. The contract builds the entry hash from two
`abi.encode` calls joined with `bytes.concat`, which equals one `abi.encode` of all ten static
values ([DSP-10](../spec/disputes-and-statements.md#rules-and-invariants)). Every input is in
the `StatementAppended` event; the rebuild procedure is in
[Events and indexing](events-and-indexing.md#rebuilding-state-from-logs).

### Work state hash

From the RECORDS module (`IWorkRules.workStateHash`); the formula below is today's and the module may key it by token as well:

```text
STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1")
             = 0x7d21f448b063eb6f95d0d30296a34671f5000d77778e5c4ec239f7c682f0c766
stateHash = keccak256(abi.encode(STATE_DOMAIN, tokenId, version, recordFileId,
                licenseKey, textFileId, royaltyRate, renderer))
            // types: (bytes32, uint256, uint32, bytes32, bytes32, bytes32, uint32, address)
```

The license is the stored one, or the deployment's CC0 when none is stored. `renderer` is the
pinned renderer once finalized, else the token's current RENDERER module, so a new module
changes every unfinalized work's state hash
([WS-10](../spec/works-and-storage.md#rules-and-invariants)). The renounced-powers mask is not
an input; a renunciation moves the state hash through the version it bumps.

### Other derived values

| Value | Formula | Source |
| --- | --- | --- |
| Artist ID | `artistIdOf(account)` when nonzero, else `uint256(uint160(account))` | [`IArtistRegistry.sol`](../../src/interfaces/IArtistRegistry.sol) |
| Auction sale ID | `uint256(keccak256(abi.encode(token, tokenId)))` | `EnglishAuction.saleIdOf` |
| Split wallet address | `CREATE2(ledger, keccak256(abi.encode(configHash, salt)), walletInitCodeHash)` with `configHash = keccak256(abi.encode(payees))`, `payees` a `(uint256 artistId, address account, uint32 share)[]` in canonical order; `walletInitCodeHash = keccak256(SplitVault.INIT_CODE)`, free of compiler metadata | [`ISplitFactory.sol`](../../src/economics/interfaces/ISplitFactory.sol), [`SplitVault.sol`](../../src/economics/SplitVault.sol); read `walletInitCodeHash()` from the ledger |
| Seller wallet | The salt-zero wallet for the item's payees | `IEconomicsResolver.newWorkTerms` |
| Royalty receiver | The seller when the fee share is zero; otherwise the salt-zero wallet for the two fixed payees `(0, seller, 100,000 - feeShare)` and `(0, feeRecipient, feeShare)`, sorted ascending by address | `Splits.royaltyPayees` in [`Splits.sol`](../../src/economics/Splits.sol) |
| Sale kind | `keccak256("ENGLISH_AUCTION")` `0x42bdbbaa…`, `keccak256("UNIFORM_AUCTION")` `0x81234ccc…`; reserved: `keccak256("FIXED_PRICE")` `0xce977739…`, `keccak256("DUTCH")` `0x57099dca…` | [`SaleTypes.sol`](../../src/interfaces/types/SaleTypes.sol) |
| Product ID | `keccak256("PRODUCT_STREAM")` `0x8d6f9a23…`, `keccak256("PRODUCT_EDITIONS")` `0xdda24e9b…`, `keccak256("PRODUCT_INDEPENDENT")` `0xceae10ee…` | [`EconomicsTypes.sol`](../../src/interfaces/types/EconomicsTypes.sol) |
| Reserved statement kinds | `keccak256("DISPUTE_OUTCOME")` `0xd529e549…`, `keccak256("CURATION_EVIDENCE")` `0x10d8533b…`, `keccak256("GOVERNANCE_MANIFEST")` `0xda3e4cfe…` | [`StatementKinds.sol`](../../src/interfaces/types/StatementKinds.sol) |
| Currency | ETH is `address(0)` (sales are ETH only) | [`EconomicsTypes.sol`](../../src/interfaces/types/EconomicsTypes.sol) |
| Curation signer epoch | `since << 128 \| salt << 64 \| changes`; read `signerEpoch(signer)` | `Eip712CurationVerifier.signerEpoch` |
| AccessManager operation ID | `keccak256(abi.encode(caller, target, data))` | OpenZeppelin `AccessManager.hashOperation` |

## References

- Code: [`src/interfaces/core/`](../../src/interfaces/core),
  [`Typehashes.sol`](../../src/interfaces/types/Typehashes.sol),
  [`WorksHashing.sol`](../../src/interfaces/types/WorksHashing.sol).
- Golden-vector tests pin type strings, domain labels and hashes: `test/interfaces/`,
  `test/records/StatementLogGolden.t.sol`, `test/economics/ReleaseVerifier.t.sol`,
  `test/content/tooling/UploaderGolden.t.sol`.
