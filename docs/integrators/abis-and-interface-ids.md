# ABIs and interface IDs

For integration engineers who call, decode or verify the 6529 Works contracts: where the ABIs
come from and which build matches which deployment, the ERC-165 interface IDs and who answers
them, every EIP-712 domain and type string, and the formulas of the protocol hashes you
recompute off-chain. The current Sepolia instance, r3, runs `v1.0.0-rc.1` (`e5fe78c`), and
every r3 contract is verified on Sourcify; `main` has changed since, see
[Changes since the Sepolia r3 build](#changes-since-the-sepolia-r3-build). The superseded r2
runs an earlier build, see
[Changes since the Sepolia r2 build](#changes-since-the-sepolia-r2-build). Addresses are in
[Addresses](addresses.md), events in [Events and indexing](events-and-indexing.md).

> Pre-audit. See the [project status](../../README.md#status).

## Where ABIs come from

ABIs are build outputs, not committed (`out/` is in [`.gitignore`](../../.gitignore)). Build
them from the commit the target deployment was built from:

```bash
git clone --recurse-submodules https://github.com/6529-Collections/6529-works.git
cd 6529-works
git checkout e5fe78c                 # Sepolia r3 (400f96d for r2); main for the current code
git submodule update --init --recursive
forge build
```

`forge build` writes one artifact per contract at `out/<File>.sol/<Contract>.json`, whose
`abi` field is the ABI. `forge inspect` prints one field (building first if needed):

```bash
forge inspect src/stream/Stream.sol:Stream abi                 # the ABI
forge inspect src/stream/Stream.sol:Stream methodIdentifiers   # function selectors
forge inspect src/stream/Stream.sol:Stream events              # event signatures and topic0
forge inspect src/stream/Stream.sol:Stream errors              # custom error selectors
```

Decode a deployed address with the **contract** artifact, not the interface's: some contracts
declare events and errors their interfaces do not (the entropy module's `ConfigSet`, and the
errors of the libraries they use, such as `Dependency` and `SignatureVerifier`). A revert can
come from a contract further down the call, so decode it against every contract on the path.

**The English auction is the exception: call it with `IEnglishAuction`.** Its views live on its
lens, `EnglishAuctionLens`, which its constructor creates (`lens()`): the auction forwards every
call it does not declare to the lens with a read-only `staticcall` and returns the lens's answer
byte for byte. The views keep their signatures, selectors and ERC-165 IDs, so a caller using the
auction's address and `IEnglishAuction` (or `ISaleAdapter`) sees no change. The
`EnglishAuction` artifact's `abi` lists only the functions the contract declares (the writes,
`saleKind`, `auctionClock`, `onERC721Received`, `lens`, `storageWords`, `settlePayout` and
AccessManaged's); for the whole surface, merge it with the `EnglishAuctionLens` artifact's `abi`
(the views, and the getters `MAX_PAUSE`, `OPENING_BID_FLOORS`, `PAYOUT_GAS`, `allowlist`,
`economicsResolver`, `permit2` and `federationRegistryCodeHash`), or use the `IEnglishAuction`
artifact. The lens's own `adapter()` is answered through the auction too.

A view through the lens costs a contract that calls it on chain about 7,000 more gas than
before (one more cold account and the lens's reads). **A contract that reads an auction on
its own hot path should call `auctionClock(saleId)`**
([`IEnglishAuctionClock`](../../src/interfaces/IEnglishAuctionClock.sol)): the auction answers
it itself, with exactly `auction(saleId).state` and `.endTime`, from one cold slot for a sale
never paused (24,207 Prague gas cold as a transaction, against 39,342 for `auction`). It is an
integration view, outside `IEnglishAuction`: `supportsInterface` reports no ID for it, and
`IEnglishAuction`'s ID does not change. The edition auction reads its 1/1 this way.

### Contract names

Deployment records name contracts by their contract name, except `CurationVerifier` and
`EntropyModule`.

| Deployment record name | Source and contract |
| --- | --- |
| `WorksAccessManager` | [`src/governance/WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol) |
| `GovernanceConfigurator` | [`src/governance/GovernanceConfigurator.sol`](../../src/governance/GovernanceConfigurator.sol) |
| `ContentStore` | [`src/content/ContentStore.sol`](../../src/content/ContentStore.sol) |
| `DependencyRegistry` | [`src/content/DependencyRegistry.sol`](../../src/content/DependencyRegistry.sol) |
| `Renderer` | [`src/content/Renderer.sol`](../../src/content/Renderer.sol) |
| `ConsolidationAdapter` | [`src/identity/ConsolidationAdapter.sol`](../../src/identity/ConsolidationAdapter.sol) |
| `ArtistRegistry` | [`src/identity/ArtistRegistry.sol`](../../src/identity/ArtistRegistry.sol) |
| `ReleaseVerifier` | [`src/economics/ReleaseVerifier.sol`](../../src/economics/ReleaseVerifier.sol) |
| `SplitFactory` | [`src/economics/SplitFactory.sol`](../../src/economics/SplitFactory.sol) |
| (each split wallet, deployed by the factory) | [`src/economics/SplitWallet.sol`](../../src/economics/SplitWallet.sol) |
| `ClaimRouter` | [`src/economics/ClaimRouter.sol`](../../src/economics/ClaimRouter.sol) |
| `AssetAllowlist` | [`src/economics/AssetAllowlist.sol`](../../src/economics/AssetAllowlist.sol) |
| `EconomicsResolver` | [`src/economics/EconomicsResolver.sol`](../../src/economics/EconomicsResolver.sol) |
| `RevenueEscrow` | [`src/economics/RevenueEscrow.sol`](../../src/economics/RevenueEscrow.sol) |
| `CurationVerifier` | [`src/curation/Eip712CurationVerifier.sol`](../../src/curation/Eip712CurationVerifier.sol), contract `Eip712CurationVerifier` |
| `PackageRegistry` | [`src/curation/PackageRegistry.sol`](../../src/curation/PackageRegistry.sol) |
| `StatementLog` | [`src/records/StatementLog.sol`](../../src/records/StatementLog.sol) |
| `EntropyModule` | [`src/entropy/VrfEntropyModule.sol`](../../src/entropy/VrfEntropyModule.sol), contract `VrfEntropyModule` |
| `Stream` | [`src/stream/Stream.sol`](../../src/stream/Stream.sol) |
| `WorkRecords` | [`src/stream/WorkRecords.sol`](../../src/stream/WorkRecords.sol) |
| `Editions` | [`src/editions/Editions.sol`](../../src/editions/Editions.sol) |
| `EnglishAuction` | [`src/sales/EnglishAuction.sol`](../../src/sales/EnglishAuction.sol) |
| `EnglishAuctionLens` (created by the auction: its first `CREATE`) | [`src/sales/EnglishAuctionLens.sol`](../../src/sales/EnglishAuctionLens.sol) |
| `FixedPriceSale`, `DutchSale` | Sepolia r1 to r3 only: removed by [ADR 0005](../adr/0005-stream-editions-auction.md); the source is at the `v1.0.0-rc.1` tag |

### Compiler settings

From [`foundry.toml`](../../foundry.toml), unchanged since the r2 build; a block explorer or
Sourcify needs them to verify the bytecode.

| Setting | Value |
| --- | --- |
| Compiler | solc 0.8.37 (`solc_version`, with `auto_detect_solc = false`) |
| EVM version | `prague` |
| Optimizer | enabled, 200 runs |
| IR pipeline | off (`via_ir = false`) |
| Metadata | CBOR metadata appended (`cbor_metadata = true`) with an IPFS metadata hash (`bytecode_hash = "ipfs"`) |
| Remappings | `@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/` and `forge-std/=lib/forge-std/src/`, with `auto_detect_remappings = false` |
| Libraries | OpenZeppelin Contracts 5.7.0 (the `lib/openzeppelin-contracts` submodule). Every protocol library is internal, so nothing is linked. |

The metadata hash covers every source file byte for byte, NatSpec included, so only a build
from the deployment's commit matches the deployed bytecode exactly. The deployment records
hold each contract's code hash, which [`Verify.s.sol`](../../script/Verify.s.sol) compares.

## Changes since the Sepolia r3 build

r3 runs `v1.0.0-rc.1`. [ADR 0005](../adr/0005-stream-editions-auction.md) changes the edition
surface on `main`; more lands with the edition auction and the museum.

| File | Change on `main` |
| --- | --- |
| [`types/PackageTypes.sol`](../../src/interfaces/types/PackageTypes.sol) | `EditionTerms` is `(uint32 maxCount, address currency, bytes32 saleKind, bytes params)`, was `(uint8 format, uint64 size, uint64 window, uint256 price, address currency, bytes32 saleKind, bytes params)`; `EditionFormat` is removed. Every function and event that carries a `PackageItem` or `EditionTerms` changed its selector or topic0 (below). |
| [`IEditions.sol`](../../src/interfaces/IEditions.sol) | New `name()`, `symbol()`, event `EditionMinterBound(uint256,address)` and error `MinterMismatch(uint256,address)`; `Edition.windowStart` became `address minter`; `formatOf`, `EditionWindowOpened` and `PricedDefaultCurrency` are removed. |
| `IFixedPriceSale.sol`, `IDutchSale.sol`, `IMintSale.sol` | Removed, with the fixed-price and Dutch adapters. |
| [`types/SaleTypes.sol`](../../src/interfaces/types/SaleTypes.sol) | New `SaleKind.UNIFORM_AUCTION`; `FIXED_PRICE` and `DUTCH` stay as reserved labels; `DutchParams` is removed. |
| [`types/Typehashes.sol`](../../src/interfaces/types/Typehashes.sol) | `FIXED_PRICE_SALE_NAME`, `PHASE`, `PHASE_CONFIGURATION`, `PURCHASE_WITNESS`, `DUTCH_PURCHASE_WITNESS` and their type strings are removed. |
| [`types/Limits.sol`](../../src/interfaces/types/Limits.sol) | `MAX_PHASES` is removed. |
| [`IStream.sol`](../../src/interfaces/IStream.sol) | New `setDependency(bytes32,address,address)` (`0x480b197d`), `entropyModuleOf(uint256)` (`0x24ca0202`), event `DependencySet(bytes32,address,address)` and error `UnknownDependency(bytes32)` (owner decision 16): `packageRegistry()`, `artistRegistry()`, `economics()` and `entropyModule()` are governed, no longer immutable, and `entropyModuleOf` answers the module each work minted under. |
| [`IUniformEditionAuction.sol`](../../src/interfaces/IUniformEditionAuction.sol), [`types/StepLadder.sol`](../../src/interfaces/types/StepLadder.sol), [`IEconomicsResolver.sol`](../../src/interfaces/IEconomicsResolver.sol) | ADR 0005's frozen interfaces for the edition auction and the 6529 Network Museum, implemented by `UniformEditionAuction` and `EconomicsResolver`. |
| [`IUniformEditionAuctionStorage.sol`](../../src/interfaces/IUniformEditionAuctionStorage.sol), [`IUniformEditionAuctionLens.sol`](../../src/interfaces/IUniformEditionAuctionLens.sol) | New: the adapter's raw storage words and `SettlementScanned`, and the stateless lens that answers its views. Neither is advertised through ERC-165. |
| [`IEditions.sol`](../../src/interfaces/IEditions.sol) | `bindMinter(editionId, item)` (ADR 0005 §6): an adapter binds an edition when its sale opens. |
| [`IArtistRegistry.sol`](../../src/interfaces/IArtistRegistry.sol) | New `setPackageRegistry(address,address)` (`0x00752cf1`) and event `PackageRegistrySet(address,address)`: the only `register` caller is replaceable by governance with Stream's package registry (owner decision 16). |

| Function or event | r3 | `main` |
| --- | --- | --- |
| `PackageRegistry.consume` | `0xbe93e628` | `0xbf69b193` |
| `Editions.createEdition` | `0xb44dd3d8` | `0x26c8844c` |
| `Editions.bindMinter` (ADR 0005 §6) | none | `0x459e34d7` |
| `WorkRecords.openRecord` | `0x22029b68` | `0x0068e575` |
| `WorkRecords.relicense` | `0x291e2c27` | `0xd60ad0db` |
| `WorkRecords.setRoyaltyRate` | `0xe27fed56` | `0xc13560ef` |
| `VrfEntropyModule.requestSeed` | `0x5c9c3014` | `0x68d50901` |
| `EditionCreated` topic0 | `0xda49138a…` | `0x3a4f273b…` |

The interface IDs of `IWorkRecords`, `IEditions`, `IPackageRegistry` and `IEntropyModule`
changed with them, `IStream`'s with `setDependency` and `entropyModuleOf`, `IArtistRegistry`'s with
`setPackageRegistry`, and `IEconomicsResolver`'s with the museum ([below](#erc-165-interface-ids));
the role matrix maps the new selectors.

## Changes since the Sepolia r2 build

r2 runs `400f96d` ([Sepolia README](../../deployments/11155111/README.md)).
`git diff --stat 400f96d main -- src/interfaces src/economics/interfaces` lists the changed
files. The functions and events changed in these; the custom errors changed more widely, as
the [next section](#error-changes-in-the-source-quality-pass) lists:

| File | Change on `main` |
| --- | --- |
| [`IStream.sol`](../../src/interfaces/IStream.sol) | `releaseContent(uint256,bytes32)` became `releaseContent(uint256 tokenId, bytes32 contentHash, uint256 beneficiary)`. |
| [`IPackageRegistry.sol`](../../src/interfaces/IPackageRegistry.sol) | `releaseContent` gains `uint256 beneficiary`; `ContentReleased` gains `uint256 indexed beneficiary`, so its topic0 changed (r2: `ContentReleased(bytes32,bytes32)`, `0xef2bb807d85d6da30ac2c351cb6ce8a4b9514207726b5fa1dfc6d63445f66c7c`); new `releasedTo(bytes32)` and error `ContentReserved`. |
| [`IEntropyModule.sol`](../../src/interfaces/IEntropyModule.sol) | New event `SeedLinked`. `SeedDelivered` keeps its types and topic0, but its indexed first parameter is now the **content hash**; on r2 it is the item hash, because r2 draws one seed per item. |
| [`IWorkRecords.sol`](../../src/interfaces/IWorkRecords.sol) | New event `OnChainSyncProgress`: `syncOnChain` became resumable. |
| [`IArtistRegistry.sol`](../../src/interfaces/IArtistRegistry.sol) | New `activeAuthorityOf(uint256)`, `reservedFor(address)`, `consolidationSourceCodeHash()`; new event `StandingRefreshSkipped`; new error `DelegationReadFailed` on `IConsolidationSource`. |
| [`ICurationVerifier.sol`](../../src/interfaces/ICurationVerifier.sol) | `ICurationSignerVerifier` gains `signerEpoch(address)`. |
| [`types/Typehashes.sol`](../../src/interfaces/types/Typehashes.sol) | `PACKAGE_APPROVAL` now binds the signer's epoch: `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash,uint256 signerEpoch)`. On r2 it is `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash)`, typehash `0x042a3f421b5117b21363cb14bb213061c468e91b1af5d8d925a04a5d0a6648c9`. |
| [`IStatementLog.sol`](../../src/interfaces/IStatementLog.sol) | New `disputeOutcomeOf(address,uint256)`; new error `UnknownDisputeSubject`. |
| [`IEnglishAuction.sol`](../../src/interfaces/IEnglishAuction.sol) | New `claimFor(address,address)`. |
| `IFixedPriceSale.sol`, `IDutchSale.sol` | On r3: new `scheduleDelay(uint256)`, and `IFixedPriceSale` lost error `PriceBelowPackage`. Both are removed on `main` ([since r3](#changes-since-the-sepolia-r3-build)). |
| [`IEditions.sol`](../../src/interfaces/IEditions.sol) | On r3: new `formatOf(uint256)`, removed again on `main` ([since r3](#changes-since-the-sepolia-r3-build)). |
| [`ISaleAdapter.sol`](../../src/interfaces/ISaleAdapter.sol) | New shared errors `ClaimFailed`, `InvalidRecipient`, `NotPaused`, `PaymentExpired`, `UnpauseTooEarly`. |
| [`IEconomicsResolver.sol`](../../src/interfaces/IEconomicsResolver.sol) | New error `InvalidFeeRecipient`. For rc.2 (D140): new `museum()`, `museumRevision()`, `setMuseum(uint64,address)`, event `MuseumSet` and error `InvalidMuseum`. |
| [`IAssetAllowlist.sol`](../../src/economics/interfaces/IAssetAllowlist.sol) | New `statusClock(address)`; new error `ReadmissionTooEarly`. |
| [`IClaimRouter.sol`](../../src/economics/interfaces/IClaimRouter.sol) | New `SHORTFALL_REVERT_CEILING()`. |
| [`IRevenueEscrow.sol`](../../src/economics/interfaces/IRevenueEscrow.sol) | New `consentToRecovery(address)`, `recoveryConsent(address)`, event `RecoveryConsentSet` and error `RecoveryNotConsented`. |
| [`ISplitFactory.sol`](../../src/economics/interfaces/ISplitFactory.sol) | New `pendingPayees()`, `walletInitCodeHash()` and error `WalletAddressMismatch`. |
| [`types/Limits.sol`](../../src/interfaces/types/Limits.sol) | New `MAX_PREVIEW_BYTES`. |

The other changed files (`IArtistPayoutResolver`, `IArtistRoleResolver`, `IReleaseVerifier`,
`ISplitWallet`, `IRenderer`, and the `ContentTypes`, `IdentityTypes`, `PackageTypes` and
`SaleTypes` types) changed only in NatSpec and errors from r2 to r3.

### Error changes in the source-quality pass

PR #66 changed custom errors only: no function, event or interface ID. Two internal libraries
now hold the errors every contract shares, and appear in each contract's ABI:

| Error | Selector | Raised when |
| --- | --- | --- |
| `Dependency.InvalidDependency(address)` | `0xf7293a48` | An installed, bound, listed or pinned contract has no code, is an EIP-7702 delegated account, lacks the ERC-165 interface of its role, or lacks the pinned code hash |
| `Dependency.DependencyCodeChanged(address)` | `0x258d23f5` | A pinned contract's code no longer has its pinned hash, at use (renderers, the verifier, resolvers, the consolidation source, the VRF coordinator) |
| `SignatureVerifier.InvalidSignature(address)` | `0xd855c4f4` | A signature does not verify for the named signer |
| `SignatureVerifier.SignatureExpired(uint256)` | `0xcd21db4f` | A signed payload's deadline has passed |

They replace these r2 errors:

| r2 error | Selector | Now |
| --- | --- | --- |
| `InvalidSignature()` (package and artist registries) | `0x8baa579f` | `SignatureExpired` or `InvalidSignature(address)` |
| `DeadlineExpired(uint64)` (statement log), `AuthorizationExpired(uint256)` (release verifier) | `0x44d7a6f0`, `0x3d91b05f` | `SignatureExpired` |
| `InvalidArtistConsent()` (fixed-price sale) | `0x4a4af2fd` | On r3, `SignatureExpired`, `IFixedPriceSale.ConsentNonceUsed(address,uint256)` (`0xd2603ab8`) or `InvalidSignature(address)`; removed on `main` with the adapter |
| `InvalidBinding(address)` for an install check, `InvalidSource(address)`, `InvalidResolver(address)`, `InvalidRenderer(address)`, `InvalidCoordinator(address)`, `InvalidRegistry(address)`, `InvalidFactory(address)`, `DependencyStoreInvalid(address)`, `NoDelegationCode(address)`, the auction's `InvalidTarget(address)` from `setTarget`, both `CodeHashMismatch` and `ResolverCodeHashMismatch` | various | `InvalidDependency` at install, `DependencyCodeChanged` at use |
| `ResolverCodeChanged()` (split wallet) | `0xc61de18d` | `DependencyCodeChanged` |
| `ResolverMismatch(address)` (statement log) | `0xbd85d10c` | `IStatementLog.ExpectedValueMismatch()` (`0x281aa7f8`) |
| The auction's `InvalidTerms(address,uint256)` | `0xdb4f7be7` | `ISaleAdapter.InvalidSaleTerms(address,uint256)` (`0x2bf76211`) |

On `IStream`, `InvalidMintRequest()` (`0xa6df31da`) moved to `IMintTarget` and now means a
malformed call. Each Stream rule has its own error: `InvalidItemSale()`, `InvalidLeadArtist()`,
`UnknownCollection(uint256)`, `InvalidSeedPolicy()`, `InvalidLicenseId()`, `InvalidWorkTerms()`
and `TermsCapacityExceeded()`. `NotMintingAdapter(address)` (`0x271ce5c9`) replaces
`NotAdmittedMinter` and `UnboundCaller` from `burn` and `markPrimarySettled`. The errors that
only the implementations declared (Editions, the adapters, the entropy module, the renderer)
are now declared in their interfaces, with unchanged selectors. The errors only the fixed-price
and Dutch adapters raise (`InvalidAddress`, `SaleAlreadyOpen`, `NotSaleManager`, and the
currency, quantity, close and approval errors) are on `IMintSale`, which `IFixedPriceSale` and
`IDutchSale` extend, so the auction's ABI does not list them; `main` removes all three.

`WorksAccessManager`, which has no interface file, gained the guardians' suspension of
operational keys (review finding GOV-2), plus the events `RoleSuspended` and
`RoleSuspensionLifted` ([Events and indexing](events-and-indexing.md#governanceconfigurator-and-worksaccessmanager)):

| Kind | Signature | Selector |
| --- | --- | --- |
| Function (GUARDIAN only) | `suspend(uint64 roleId, address account)` | `0x64bf6e5d` |
| View | `isSuspended(uint64 roleId, address account) returns (bool)` | `0xbd2e6ac3` |
| Error | `RoleNotSuspendable(uint64 roleId)` | `0x3bf24b39` |
| Error | `NotSuspendable(uint64 roleId, address account)` | `0x48431385` |

`hasRole` keeps its signature but answers false for a suspended holder
([GV-28](../spec/governance.md#rules-and-invariants)). The function selectors are from the
`manager` section of [`config/genesis.example.json`](../../config/genesis.example.json); the
error selectors were computed with [`tools/content/keccak.py`](../../tools/content/keccak.py).

These tables cover only the declared surface. Behavior changed too (the October 2026 internal
review fixes, PRs #51 to #57), so read the `400f96d` source for r2's semantics, comparing
declarations rather than `git diff --stat`, which also counts comment changes.

## ERC-165 interface IDs

An interface ID is the XOR of the selectors of the functions the interface itself declares,
not inherited ones, so `IStream`'s ID does not cover ERC-721 or ERC-2981. `test_interfaceIds`
in [`test/interfaces/InterfacesCompile.t.sol`](../../test/interfaces/InterfacesCompile.t.sol)
pins the IDs of every interface in `src/interfaces/`; the r2 column is the same test at
`400f96d`. The economics interfaces in `src/economics/interfaces/` (except
`IArtistPayoutResolver`) are pinned by no test: their IDs were computed from the compiled
selectors.

| Interface | Source | ID on `main` | ID on r2 | Deployed contract that answers `supportsInterface` |
| --- | --- | --- | --- | --- |
| `IMintTarget` | [`IMintTarget.sol`](../../src/interfaces/IMintTarget.sol) | `0x4f4f5133` | `0x4f4f5133` | Stream, Editions |
| `IStream` | [`IStream.sol`](../../src/interfaces/IStream.sol) | `0x01cc497c` | `0x4b62279d` | Stream |
| `IWorkRecords` | [`IWorkRecords.sol`](../../src/interfaces/IWorkRecords.sol) | `0xc109676d` | `0x3f3d6835` | WorkRecords |
| `IEditions` | [`IEditions.sol`](../../src/interfaces/IEditions.sol) | `0xe183b26f` | `0xa5bd946e` | Editions |
| `ISaleAdapter` | [`ISaleAdapter.sol`](../../src/interfaces/ISaleAdapter.sol) | `0x312dc1e1` | `0x312dc1e1` | EnglishAuction (and FixedPriceSale, DutchSale on r1 to r3) |
| `IEnglishAuction` | [`IEnglishAuction.sol`](../../src/interfaces/IEnglishAuction.sol) | `0x75122f3e` | `0xc1a8b12f` | EnglishAuction |
| `IEnglishAuctionClock` | [`IEnglishAuctionClock.sol`](../../src/interfaces/IEnglishAuctionClock.sol) | `0x968c7b07` | none | None: an integration view of EnglishAuction (`auctionClock`), never reported through ERC-165 |
| `IUniformEditionAuction` | [`IUniformEditionAuction.sol`](../../src/interfaces/IUniformEditionAuction.sol) | `0x69e7405b` | none | UniformEditionAuction, the edition auction of [ADR 0005](../adr/0005-stream-editions-auction.md) (its views are answered by its lens, through a read-only fallback) |
| `IFixedPriceSale`, `IDutchSale`, `IMintSale` | Removed by ADR 0005 | none | `0xfedd2754`, `0xb1c10995`, none | FixedPriceSale and DutchSale on r1 to r3 (r3: `0x773a4920`, `0x382667e1`) |
| `ICurationVerifier` | [`ICurationVerifier.sol`](../../src/interfaces/ICurationVerifier.sol) | `0x492733ca` | `0x492733ca` | Eip712CurationVerifier |
| `ICurationSignerVerifier` | [`ICurationVerifier.sol`](../../src/interfaces/ICurationVerifier.sol) | `0x9f12d97a` | `0xb7ab1d96` | Eip712CurationVerifier |
| `IPackageRegistry` | [`IPackageRegistry.sol`](../../src/interfaces/IPackageRegistry.sol) | `0xe7669f7c` | `0xc0f6f835` | PackageRegistry |
| `IContentStore` | [`IContentStore.sol`](../../src/interfaces/IContentStore.sol) | `0x3f437f81` | `0x3f437f81` | None: ContentStore does not implement ERC-165 |
| `IDependencyRegistry` | [`IDependencyRegistry.sol`](../../src/interfaces/IDependencyRegistry.sol) | `0xe5338d57` | `0xe5338d57` | None: DependencyRegistry does not implement ERC-165 |
| `IRenderer` | [`IRenderer.sol`](../../src/interfaces/IRenderer.sol) | `0xa772216d` | `0xa772216d` | Renderer |
| `IEconomicsResolver` | [`IEconomicsResolver.sol`](../../src/interfaces/IEconomicsResolver.sol) | `0x9ba8ecb3` | `0x310247d8` | EconomicsResolver |
| `IStatementLog` | [`IStatementLog.sol`](../../src/interfaces/IStatementLog.sol) | `0xbb5574c7` | `0x276fbc56` | None: StatementLog does not implement ERC-165 |
| `IArtistRoleResolver` | [`IArtistRoleResolver.sol`](../../src/interfaces/IArtistRoleResolver.sol) | `0x3074ca00` | `0x3074ca00` | ArtistRegistry |
| `IArtistPayoutResolver` | [`IArtistPayoutResolver.sol`](../../src/economics/interfaces/IArtistPayoutResolver.sol) | `0x9b2c1793` | `0x9b2c1793` | ArtistRegistry |
| `IArtistRegistry` | [`IArtistRegistry.sol`](../../src/interfaces/IArtistRegistry.sol) | `0xee1e8c55` | `0x3e70f8a1` | ArtistRegistry |
| `IConsolidationSource` | [`IArtistRegistry.sol`](../../src/interfaces/IArtistRegistry.sol) | `0x88836e34` | `0x88836e34` | ConsolidationAdapter |
| `IEntropyModule` | [`IEntropyModule.sol`](../../src/interfaces/IEntropyModule.sol) | `0x0e083814` | `0x3a410101` | VrfEntropyModule |
| `IFederationRegistry` | [`IFederationRegistry.sol`](../../src/interfaces/IFederationRegistry.sol) | `0xeefee933` | `0xeefee933` | None: no implementation in v1 |
| `IClaimRouter` | [`IClaimRouter.sol`](../../src/economics/interfaces/IClaimRouter.sol) | `0x31a9798a` (computed) | not answered on r2 | ClaimRouter (on `main` only) |
| `IRevenueEscrow` | [`IRevenueEscrow.sol`](../../src/economics/interfaces/IRevenueEscrow.sol) | `0x50267de3` (computed) | not answered on r2 | RevenueEscrow (on `main` only) |
| `IAssetAllowlist` | [`IAssetAllowlist.sol`](../../src/economics/interfaces/IAssetAllowlist.sol) | `0xa8952cd8` (computed) | | None: AssetAllowlist does not implement ERC-165 |
| `IReleaseVerifier` | [`IReleaseVerifier.sol`](../../src/economics/interfaces/IReleaseVerifier.sol) | `0x50c67982` (computed) | | None: ReleaseVerifier does not implement ERC-165 |
| `ISplitFactory` | [`ISplitFactory.sol`](../../src/economics/interfaces/ISplitFactory.sol) | `0xfd1edda8` (computed) | | None: SplitFactory does not implement ERC-165 |
| `ISplitWallet` | [`ISplitWallet.sol`](../../src/economics/interfaces/ISplitWallet.sol) | `0x535afbe4` (computed) | | None: split wallets do not implement ERC-165 |

Every contract that implements `supportsInterface` also answers `0x01ffc9a7` (`IERC165`), and
the tokens and the auction answer these standard interfaces:

| Interface | ID | Answered by |
| --- | --- | --- |
| `IERC721` | `0x80ac58cd` | Stream (OpenZeppelin `ERC721`) |
| `IERC721Metadata` | `0x5b5e139f` | Stream |
| `IERC1155` | `0xd9b67a26` | Editions (OpenZeppelin `ERC1155`) |
| `IERC1155MetadataURI` | `0x0e89341c` | Editions |
| `IERC2981` | `0x2a55205a` | Stream, Editions |
| ERC-4906 | `0x49064906` | Stream, Editions: the EIP's constant, hard-coded because OpenZeppelin's `IERC4906` declares no functions, so `type(IERC4906).interfaceId` would be zero |
| `IERC721Receiver` | `0x150b7a02` | EnglishAuction (it accepts only the token it mints during a start) |

**Contracts without ERC-165.** The content store, dependency registry, statement log, asset
allowlist, release verifier, split factory, split wallets, configurator and AccessManager have
no `supportsInterface`. The IDs of `IContentStore`, `IDependencyRegistry` and `IStatementLog`
are pinned to catch a surface change, not because anything answers them. Installs check code
and no EIP-7702 delegation instead ([GV-22](../spec/governance.md#rules-and-invariants)), and
`bindStatementLog` checks that the log's
`artistResolver()` is the registry ([`ArtistRegistry.sol`](../../src/identity/ArtistRegistry.sol)).
Code alone is checked for the work records' dependency registry, the dependency registry's
content store, the consolidation adapter's delegation contract and the configurator's targets;
the renderer checks nothing.

**EIP-7702 delegated accounts.** `DelegatedEOA.isDelegated`
([`DelegatedEOA.sol`](../../src/libraries/DelegatedEOA.sol)) recognizes the `0xef0100`
designator. Besides the installs above, the asset allowlist refuses a delegated token
([ECO-32](../spec/economics-and-payouts.md#rules-and-invariants)), and the deploy refuses a
delegated sender and, off anvil, a delegated Safe owner
([GV-29, GV-34](../spec/governance.md#rules-and-invariants)). A delegated **signer** is
accepted: `SignatureVerifier` ([`SignatureVerifier.sol`](../../src/libraries/SignatureVerifier.sol))
checks ECDSA against the account's own address, then ERC-1271 through its delegate. Nothing
else checks delegation on-chain, so payees, payout addresses, recipients and bidders may be
delegated.

`ProtocolContracts.isProtocolContract`
([`ProtocolContracts.sol`](../../src/libraries/ProtocolContracts.sol)) refuses a payout or fee
recipient that answers `IRevenueEscrow`, `IClaimRouter`, `ISaleAdapter`, `IMintTarget`,
`IArtistRegistry`, `IPackageRegistry` or `IWorkRecords`
([ECO-3](../spec/economics-and-payouts.md#rules-and-invariants),
[ECO-19](../spec/economics-and-payouts.md#rules-and-invariants)).

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
| WorkRecords | `6529 Works Records` | `1` | `Typehashes.WORK_RECORDS_NAME` |
| ArtistRegistry | `6529 Works Artist Registry` | `1` | `Typehashes.ARTIST_REGISTRY_NAME` |
| StatementLog | `6529 Works Statement Log` | `1` | the constructor of [`StatementLog.sol`](../../src/records/StatementLog.sol) |
| ReleaseVerifier | `6529 Works Release Verifier` | `1` | the constructor of [`ReleaseVerifier.sol`](../../src/economics/ReleaseVerifier.sol) |

The `Typehashes` constants are in
[`src/interfaces/types/Typehashes.sol`](../../src/interfaces/types/Typehashes.sol).
Permit2 payments are signed in Permit2's own domain (Uniswap's canonical deployment at
`0x000000000022D473030F116dDEE9F6B43aC78BA3`,
[`ISignatureTransfer.sol`](../../src/interfaces/external/ISignatureTransfer.sol)), with the
sale adapter as spender and a 6529 Works witness.

## Typehashes and type strings

### Signed payloads

Type strings exactly as in code; typehashes pinned by `test_signedPayloadTypehashes` in
[`test/interfaces/Typehashes.t.sol`](../../test/interfaces/Typehashes.t.sol) unless noted.

| Constant | Type string | Typehash | Domain and signer |
| --- | --- | --- | --- |
| `Typehashes.MOVE_TO_STREAM` | `MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)` | `0xe193fedc71b458003faf3a90795989683ea6a572f7cae0f6729d1219894814f8` | Package registry; the lead artist's active authority |
| `Typehashes.PACKAGE_ACCEPTANCE` | `PackageAcceptance(bytes32 packageRoot,address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)` | `0x557d83fa1b5c5123a734c14182eab668ea8678f09c42986018a05d2be5aa362f` | Package registry; the party (or its artist ID's active authority) |
| `Typehashes.PACKAGE_APPROVAL` | `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash,uint256 signerEpoch)` | `0xbf131d47e2ddcf4bd120061a8a3c2841ef379caa26b7eec0881120e1d8a43cdd` | Curation verifier; a curation signer, at its current `signerEpoch` |
| `Typehashes.RELICENSE` | `Relicense(uint256 tokenId,bytes32 licenseKey,bytes32 textFileId,bytes32 stateHash,uint64 deadline)` | `0x8e6e8db23b02e7536fe205ab2dd4340fc5f4b94ad3878dece0549cff5101996f` | Work records; every party of the item, in order |
| `Typehashes.ROYALTY_RATE_CHANGE` | `RoyaltyRateChange(uint256 tokenId,uint32 rate,bytes32 stateHash,uint64 deadline)` | `0x4f00b7a5a626b7fd46a6eb233ba5926281727b94836ffa9091fa1cc73d7fa038` | Work records; every party of the item, in order |
| `Typehashes.RENDERER_REPIN` | `RendererRepin(uint256 tokenId,address renderer,bytes32 rendererCodeHash,bytes32 stateHash,uint64 deadline)` | `0xe02c73b10a1645fcc06fd6d114765861f5bcd1cd03d788c53c6bdf196c748bd4` | Work records; the lead artist's active authority |
| `Typehashes.IDENTITY_CHANGE` | `IdentityChange(uint256 artistId,address authority,address payout,bytes32 profileId,bytes32 profileDocHash,uint256 nonce,uint64 deadline)` | `0xa474bd174aa5ecb19efe75995251c1fb8289b62bca04bc6c19e869f254e190f0` | Artist registry; the authority or an established consolidated wallet, and a new authority over the same digest |
| `Typehashes.OVERRIDE_ACCEPTANCE` | `OverrideAcceptance(uint256 artistId,uint8 kind,address authority,address payout,bytes32 profileId,bytes32 profileDocHash,bytes32 evidenceHash,uint64 deadline)` | `0xe94c9e2e1a4e3c2652a414f70c177a61fc880d94ede3aaaf03a976666431f9a3` | Artist registry; the override's new authority |
| `StatementLog` `HASHREF_TYPEHASH` | `HashRef(uint16 algorithm,bytes32 digest)` | `0x121a61476ab0828add4a5b9b9f2bb805adcfa15d81ff19494f98b0fd3e0bd6ed` | (a member type) |
| `StatementLog` `STATEMENT_TYPEHASH` | `Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)HashRef(uint16 algorithm,bytes32 digest)` | `0xc5917de59a1e9cd194c71a1bfa5d2b7a821403b15a6c26ba9ed4aaa207f324f6` | (a member type, and the statement's identity in the entry hash) |
| `StatementLog` `AUTHORIZATION_TYPEHASH` | `Authorization(uint8 role,address signer,uint256 nonce,uint64 deadline,Statement statement)HashRef(uint16 algorithm,bytes32 digest)Statement(address token,uint256 id,bytes32 kind,bytes32 schema,HashRef content,string uri,bytes32 fileId,bytes32 supersedes)` | `0x31b41af4c88eb6a6042a07475f214b72f1819151382b4f7c6600f092bf061f89` | Statement log; the relayed signer |
| `ReleaseVerifier.RELEASE_TYPEHASH` | `ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)` | `0xf64c722b2f9f611784cae451d729d2046031dd1ccede35af5642984d5c6f2925` | Release verifier; the payee's payout address |

The three statement-log values are pinned by `test_Golden_TypeHashesAndDomainTags` in
[`StatementLogGolden.t.sol`](../../test/records/StatementLogGolden.t.sol). The release
typehash is checked against its type string by `test_GoldenTypehashDomainAndDigest` in
[`ReleaseVerifier.t.sol`](../../test/economics/ReleaseVerifier.t.sol); its hex value was
computed for this page.

### How each struct hash is built

Each digest is `keccak256("\x19\x01" ‖ domainSeparator ‖ structHash)`, with every field
ABI-encoded as a 32-byte word:

| Payload | `structHash` | Digest helper |
| --- | --- | --- |
| MoveToStream | `keccak256(abi.encode(MOVE_TO_STREAM, packageRoot, itemHash, nonce, deadline))` | `PackageRegistry.moveDigest` |
| PackageAcceptance | `keccak256(abi.encode(PACKAGE_ACCEPTANCE, packageRoot, account, profileId, profileDocHash, deadline))` | `PackageRegistry.acceptanceDigest` |
| PackageApproval | `keccak256(abi.encode(PACKAGE_APPROVAL, packageRoot, evidenceHash, signerEpoch))` | `Eip712CurationVerifier.approvalDigest` |
| Relicense | `keccak256(abi.encode(RELICENSE, tokenId, licenseKey, textFileId, stateHash, deadline))`, `licenseKey` of the new license | none; use the WorkRecords domain |
| RoyaltyRateChange | `keccak256(abi.encode(ROYALTY_RATE_CHANGE, tokenId, rate, stateHash, deadline))` | none |
| RendererRepin | `keccak256(abi.encode(RENDERER_REPIN, tokenId, renderer, rendererCodeHash, stateHash, deadline))` | none |
| IdentityChange | `keccak256(abi.encode(IDENTITY_CHANGE, artistId, authority, payout, profileId, profileDocHash, nonce, deadline))` | `ArtistRegistry.changeDigest` |
| OverrideAcceptance | `keccak256(abi.encode(OVERRIDE_ACCEPTANCE, artistId, uint8(kind), authority, payout, profileId, profileDocHash, evidenceHash, deadline))` | `ArtistRegistry.overrideDigest` |
| Authorization (statement relay) | `keccak256(abi.encode(AUTHORIZATION_TYPEHASH, uint8(role), signer, nonce, deadline, statementHash))`, with `statementHash` [below](#statement-entry-hash-and-chain-head) | `StatementLog.authorizationDigest` |
| ReleaseAuthorization | `keccak256(abi.encode(RELEASE_TYPEHASH, wallet, asset, payee, account, recipient, amount, nonce, deadline))` | `ReleaseVerifier.releaseDigest` |

`stateHash` is the work's current [state hash](#work-state-hash), so a relicense, rate change
or repin signature applies only to the state its signers saw. Every party signs the same
Relicense or RoyaltyRateChange digest with its artist ID's active authority, and the signatures
go in party order ([WS-13, WS-14](../spec/works-and-storage.md#rules-and-invariants)).

### Permit2 witnesses

PERMIT2 payments call `permitWitnessTransferFrom`. Permit2 completes its stub
`PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,`
with the witness type string below.

| Constant | Witness type | Witness typehash | Full Permit2 typehash |
| --- | --- | --- | --- |
| `BID_WITNESS` | `Bid(uint256 saleId,address recipient,uint256 amount,uint256 deadline)` | `0x36fe48f963a8333b63c773927bbdc20f266277d65935733a27e6264edda25ea8` | `0x0bfd3d1d308e98f9f0a38b17a9eaaad1118b7813eead91902f6714537c0eb034` |
| `START_BID_WITNESS` | `StartBid(address token,bytes32 mintDataHash,address recipient,uint256 amount,uint256 deadline)` | `0xb8513f1f66acd0543fe8542e5c408fd4a7b59dfcf47fc1e4c2c164c66cd5bd0e` | `0xb44f39960bfdaf0c5fedccb2b3159844117a56c2d506bcf2c35776fe2c346acf` |

Each `witnessTypeString` (`BID_WITNESS_TYPE` and so on) is the witness name, `" witness)"`, the
witness type and `TokenPermissions(address token,uint256 amount)`, for example
`Bid witness)Bid(uint256 saleId,address recipient,uint256 amount,uint256 deadline)TokenPermissions(address token,uint256 amount)`.
`test_witnessTypehashes` and `test_witnessTypeStrings` in `Typehashes.t.sol` pin both columns.

| Adapter | `witness` | `recipient` in the witness |
| --- | --- | --- |
| EnglishAuction `bid` | `keccak256(abi.encode(BID_WITNESS, saleId, recipient, amount, deadline))` | resolved: the payer when the argument is zero |
| EnglishAuction `startWithBid` | `keccak256(abi.encode(START_BID_WITNESS, token, keccak256(mintData), recipient, amount, deadline))` | resolved: the payer when the argument is zero |

`amount` is the payment amount and `deadline` the payment's deadline. The Permit2
`TokenPermissions` carry the currency and `payment.amount`, which the auction pulls exactly
([AUC-19](../spec/stream-and-auctions.md#rules-and-invariants)).

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
[Events and indexing](events-and-indexing.md#statements).

### Work state hash

From [`WorkRecords.sol`](../../src/stream/WorkRecords.sol) (`workStateHash`):

```text
STATE_DOMAIN = keccak256("6529WORKS_WORK_STATE_V1")
             = 0x7d21f448b063eb6f95d0d30296a34671f5000d77778e5c4ec239f7c682f0c766
stateHash = keccak256(abi.encode(STATE_DOMAIN, tokenId, version, recordFileId,
                licenseKey, textFileId, royaltyRate, renderer))
            // types: (bytes32, uint256, uint32, bytes32, bytes32, bytes32, uint32, address)
```

The license is the stored one, or the deployment's CC0 when none is stored. `renderer` is the
pinned renderer once finalized, else Stream's current `defaultRenderer()`, so a new default
renderer changes every unfinalized work's state hash
([WS-10](../spec/works-and-storage.md#rules-and-invariants)).

### Other derived values

| Value | Formula | Source |
| --- | --- | --- |
| Artist ID | `artistIdOf(account)` when nonzero, else `uint256(uint160(account))` | [`IArtistRegistry.sol`](../../src/interfaces/IArtistRegistry.sol) |
| Auction sale ID | `uint256(keccak256(abi.encode(token, tokenId)))` | `EnglishAuction.saleIdOf` |
| Split wallet address | `CREATE2(factory, keccak256(abi.encode(configHash, salt)), walletInitCodeHash)` with `configHash = keccak256(abi.encode(payees))`, `payees` a `(uint256 artistId, address account, uint32 share)[]` in canonical order | [`ISplitFactory.sol`](../../src/economics/interfaces/ISplitFactory.sol); read `walletInitCodeHash()` from the factory |
| Seller wallet | The salt-zero wallet for the item's payees | `IEconomicsResolver.newWorkTerms` |
| Royalty receiver | The seller when the fee share is zero; otherwise the salt-zero wallet for the two fixed payees `(0, seller, 100,000 - feeShare)` and `(0, feeRecipient, feeShare)`, sorted ascending by address | `Splits.royaltyPayees` in [`Splits.sol`](../../src/economics/Splits.sol) |
| Sale kind | `keccak256("ENGLISH_AUCTION")` `0x42bdbbaa…`, `keccak256("UNIFORM_AUCTION")` `0x81234ccc…`; reserved: `keccak256("FIXED_PRICE")` `0xce977739…`, `keccak256("DUTCH")` `0x57099dca…` | [`SaleTypes.sol`](../../src/interfaces/types/SaleTypes.sol) |
| Product ID | `keccak256("PRODUCT_STREAM")` `0x8d6f9a23…`, `keccak256("PRODUCT_EDITIONS")` `0xdda24e9b…`, `keccak256("PRODUCT_FEDERATED")` `0x12f6fbd5…` | [`EconomicsTypes.sol`](../../src/interfaces/types/EconomicsTypes.sol) |
| Reserved statement kinds | `keccak256("DISPUTE_OUTCOME")` `0xd529e549…`, `keccak256("CURATION_EVIDENCE")` `0x10d8533b…`, `keccak256("GOVERNANCE_MANIFEST")` `0xda3e4cfe…` | [`StatementKinds.sol`](../../src/interfaces/types/StatementKinds.sol) |
| Currencies | ETH is `address(0)`; `CURRENCY_DEFAULT` is `0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF` | [`EconomicsTypes.sol`](../../src/interfaces/types/EconomicsTypes.sol) |
| Curation signer epoch | `since << 128 \| salt << 64 \| changes`; read `signerEpoch(signer)` | `Eip712CurationVerifier.signerEpoch` |
| AccessManager operation ID | `keccak256(abi.encode(caller, target, data))` | OpenZeppelin `AccessManager.hashOperation` |

## Golden-vector tests

These tests pin the values on this page against fixed hex produced outside the contracts
(`cast keccak`, `cast abi-encode` or a pure-Python implementation), so a change to a type
string, domain label or encoding fails them.

| Test | Pins |
| --- | --- |
| [`test/interfaces/InterfacesCompile.t.sol`](../../test/interfaces/InterfacesCompile.t.sol) `test_interfaceIds` | Every interface ID in `src/interfaces/` |
| [`test/interfaces/Typehashes.t.sol`](../../test/interfaces/Typehashes.t.sol) `test_domainConstants`, `test_signedPayloadTypehashes`, `test_witnessTypehashes`, `test_witnessTypeStrings` | Domain names and version; every `Typehashes` constant; the full Permit2 typehashes |
| [`test/interfaces/WorksHashing.t.sol`](../../test/interfaces/WorksHashing.t.sol) `test_domainLabels`, `test_constants`, `test_mediaHash_golden`, `test_itemHash_golden`, `test_licenseKey_isCaseInsensitive` | Domain labels, sale kinds and product IDs, a media hash, an item hash and its leaf, the CC0 key |
| [`test/records/StatementLogGolden.t.sol`](../../test/records/StatementLogGolden.t.sol) `test_Golden_TypeHashesAndDomainTags`, `test_Golden_DomainSeparatorMatchesEip5267Fields`, `test_Golden_AuthorizationDigest`, `test_Golden_DigestMatchesForgeTypedDataEncoder`, `test_Golden_EntryHashAndHead` | The statement-log type hashes and tags, domain separator, relay digest, an entry hash, a head and a subject key |
| [`test/curation/PackageRegistry.t.sol`](../../test/curation/PackageRegistry.t.sol) `test_golden_typehashes`, `test_golden_digests` | Move and acceptance typehashes and digests |
| [`test/curation/Eip712CurationVerifier.t.sol`](../../test/curation/Eip712CurationVerifier.t.sol) `test_golden_typehash`, `test_golden_digest` | The approval typehash, domain separator and digest |
| [`test/identity/ArtistRegistry.t.sol`](../../test/identity/ArtistRegistry.t.sol) `test_Golden_TypehashesAndSelectors`, `test_Golden_DigestsAreStandardEip712` | Identity typehashes, the domain, and standard EIP-712 digests |
| [`test/economics/ReleaseVerifier.t.sol`](../../test/economics/ReleaseVerifier.t.sol) `test_GoldenTypehashDomainAndDigest` | The release typehash, domain and digest |
| [`test/stream/WorkRecords.t.sol`](../../test/stream/WorkRecords.t.sol) `test_stateHash_golden` | The state-hash preimage |
| [`test/sales/auction/EnglishAuction.t.sol`](../../test/sales/auction/EnglishAuction.t.sol) `test_Permit2Witness_Golden` | The auction's full Permit2 typehashes |
| [`test/content/tooling/UploaderGolden.t.sol`](../../test/content/tooling/UploaderGolden.t.sol) | Chunk hashes and file IDs from the Python uploader against the content store |

The testing guide is
[docs/testing/README.md](../testing/README.md).

## References

- Code: [`src/interfaces/`](../../src/interfaces/README.md),
  [`src/economics/interfaces/`](../../src/economics/README.md),
  [`Typehashes.sol`](../../src/interfaces/types/Typehashes.sol),
  [`WorksHashing.sol`](../../src/interfaces/types/WorksHashing.sol),
  [`foundry.toml`](../../foundry.toml).
- Deployments: [Sepolia README](../../deployments/11155111/README.md),
  [`1792095396.json`](../../deployments/11155111/1792095396.json) (r3),
  [`1791750816.json`](../../deployments/11155111/1791750816.json) (r2).
- ADRs: [ADR 0001](../adr/0001-v1-scope.md): verification through CBOR metadata with an IPFS
  hash (under "Intended behavior"), and golden typehash tests (the §17 reuse plan).
- Related pages: [Events and indexing](events-and-indexing.md), [Addresses](addresses.md),
  [Buying, bidding and settling](buying-bidding-settling.md),
  [Reading a work](reading-a-work.md), [Glossary](../glossary.md).
