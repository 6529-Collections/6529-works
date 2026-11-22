# Scope

What an audit of 6529 Works v1 covers: every Solidity file under `src/`, with its size, and what
lies outside.

> Pre-audit. See the [project status](../../README.md#status).

The nSLOC and bytecode figures below are checked against the code in CI by
[`tools/check_docs_facts.py`](../../tools/check_docs_facts.py); after a source change, run it
with `--artifacts out --update` to refresh them. No audit has taken place.

**Two trees until integration.** The plain permanent core ([ADR 0010](../adr/0010-plain-permanent-core.md))
is in `src/core/`. The contracts it replaces (`src/stream/Stream.sol`, `StreamViews.sol`,
`StreamLayout.sol`, `WorkRecords.sol`, `src/editions/Editions.sol`,
`src/identity/ArtistRegistry.sol`, `src/sales/EnglishAuctionLens.sol`; the full list is
[`tools/retiring.json`](../../tools/retiring.json)) still appear below and are deleted at
integration, when this page is regenerated.

## Summary

| | |
| --- | --- |
| Language and compiler | Solidity 0.8.37, EVM `prague`, optimizer on (200 runs), `via_ir` off ([`foundry.toml`](../../foundry.toml)) |
| Dependencies | OpenZeppelin Contracts 5.7.0 and forge-std 1.17.0, as git submodules in `lib/` |
| Source lines | 17,185 non-blank, non-comment lines in 133 files under `src/` (budget: 17,000; both trees are counted until integration deletes the retiring files) |
| Deployed contracts | Regenerated at integration from `script/DeployCore.sol`: the permanent core (`Stream`, `Editions`, `WorkFacts`, `Directory`, `SplitLedger`, `RevenueEscrow`, `ContentStore`), the modules, the governed vaults and the AccessManager. Split vaults are deployed on demand by the split ledger |
| Linked libraries | None: every library function is `internal` |
| Proxies and `delegatecall` | None in `src/`. The one exception is OpenZeppelin `Multicall` inside `AccessManager` ([ADR 0002](../adr/0002-access-manager-hardening.md)) |
| Contract size | Every contract within EIP-170 and EIP-3860; every contract under `src/core/` keeps at least 3,000 bytes of EIP-170 margin and every other contract at least 512 ([`tools/size-margins.json`](../../tools/size-margins.json)), checked by `tools/check_budgets.py` in CI |

## Contracts in scope

nSLOC counts the non-blank lines left after removing comments, as
[`tools/check_budgets.py`](../../tools/check_budgets.py) does for the line budget. Sizes are
from `forge build --sizes` on the `default` profile. The margin is what remains under EIP-170.

### The permanent core

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `Stream` (on `StreamBase`) | [`src/core/Stream.sol`](../../src/core/Stream.sol) | 46 | 13,821 | 15,351 | 10,755 |
| `Editions` (on `EditionsBase`) | [`src/core/Editions.sol`](../../src/core/Editions.sol) | 41 | 12,538 | 13,953 | 12,038 |
| `WorkFacts` | [`src/core/WorkFacts.sol`](../../src/core/WorkFacts.sol) | 161 | 9,076 | 9,281 | 15,500 |
| `Directory` | [`src/core/Directory.sol`](../../src/core/Directory.sol) | 40 | 2,911 | 3,479 | 21,665 |

`StreamBase`, `EditionsBase` and `Modules` are abstract and counted with the contracts above
only through their bytecode; the frozen interfaces are in `src/interfaces/core/`.

### Products and sales

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `Stream` | [`src/stream/Stream.sol`](../../src/stream/Stream.sol) | 799 | 13,821 | 15,351 | **10,755** |
| `StreamViews` (created by `Stream`'s constructor) | [`src/stream/StreamViews.sol`](../../src/stream/StreamViews.sol) | 79 | 4,110 | 4,138 | 20,466 |
| `WorkRecords` | [`src/stream/WorkRecords.sol`](../../src/stream/WorkRecords.sol) | 737 | 22,934 | 36,031 | 1,642 |
| `WorkDelivery` (created by `WorkRecords`' constructor; replaceable) | [`src/stream/WorkDelivery.sol`](../../src/stream/WorkDelivery.sol) | 203 | 9,283 | 9,708 | 15,293 |
| `Editions` | [`src/editions/Editions.sol`](../../src/editions/Editions.sol) | 502 | 12,538 | 13,953 | 12,038 |
| `EnglishAuction` | [`src/sales/EnglishAuction.sol`](../../src/sales/EnglishAuction.sol) | 880 | 23,799 | 27,002 | 777 |
| `EnglishAuctionLens` | [`src/sales/EnglishAuctionLens.sol`](../../src/sales/EnglishAuctionLens.sol) | 345 | 7,787 | 8,094 | 16,789 |
| `UniformEditionAuction` | [`src/sales/UniformEditionAuction.sol`](../../src/sales/UniformEditionAuction.sol) | 914 | 21,764 | 26,070 | 2,812 |
| `UniformEditionAuctionLens` | [`src/sales/UniformEditionAuctionLens.sol`](../../src/sales/UniformEditionAuctionLens.sol) | 901 | 23,003 | 23,369 | 1,573 |
| `SaleStarter` (stateless helper for the network's keeper) | [`src/sales/SaleStarter.sol`](../../src/sales/SaleStarter.sol) | 57 | 5,956 | 5,984 | 18,620 |

### Federation

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `FederatedStream` (a template: each artist deploys a full copy) | [`src/federated/FederatedStream.sol`](../../src/federated/FederatedStream.sol) | 579 | 23,965 | 26,110 | 611 |
| `FederatedEditions` (a template: the pair's ERC-1155) | [`src/federated/FederatedEditions.sol`](../../src/federated/FederatedEditions.sol) | 230 | 15,965 | 17,570 | 8,611 |
| `FederatedDeployer` (one per template version, ownerless; genesis deploys two, which hold the creation code in `SSTORE2` data contracts and record every copy they create) | [`src/federated/FederatedDeployer.sol`](../../src/federated/FederatedDeployer.sol) | 49 | 1,425 | 2,398 | 23,151 |
| `FederationRegistry` (replaceable) | [`src/federated/FederationRegistry.sol`](../../src/federated/FederationRegistry.sol) | 255 | 10,536 | 11,556 | 14,040 |
| `FederatedEditionAuction` (replaceable) | [`src/federated/FederatedEditionAuction.sol`](../../src/federated/FederatedEditionAuction.sol) | 94 | 22,294 | 26,098 | 2,282 |
| `FederatedEditionAuctionLens` | [`src/federated/FederatedEditionAuctionLens.sol`](../../src/federated/FederatedEditionAuctionLens.sol) | 119 | 23,700 | 24,015 | 876 |

`FederatedMembership` (abstract, both templates' shared source) and the interfaces
`IFederatedToken`, `IFederatedStream`, `IFederatedEditions` and `IFederationRegistry` count
toward the line budget with the other interfaces.

### Curation, identity and records

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `PackageRegistry` | [`src/curation/PackageRegistry.sol`](../../src/curation/PackageRegistry.sol) | 435 | 16,891 | 18,286 | 7,685 |
| `Eip712CurationVerifier` | [`src/curation/Eip712CurationVerifier.sol`](../../src/curation/Eip712CurationVerifier.sol) | 117 | 5,835 | 6,526 | 18,741 |
| `ArtistRegistry` | [`src/identity/ArtistRegistry.sol`](../../src/identity/ArtistRegistry.sol) | 611 | 19,053 | 20,293 | 5,523 |
| `ConsolidationAdapter` | [`src/identity/ConsolidationAdapter.sol`](../../src/identity/ConsolidationAdapter.sol) | 52 | 1,335 | 1,646 | 23,241 |
| `StatementLog` | [`src/records/StatementLog.sol`](../../src/records/StatementLog.sol) | 309 | 11,125 | 12,386 | 13,451 |
| `VrfEntropyModule` (optional) | [`src/entropy/VrfEntropyModule.sol`](../../src/entropy/VrfEntropyModule.sol) | 351 | 11,998 | 13,915 | 12,578 |

### Economics

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `EconomicsResolver` | [`src/economics/EconomicsResolver.sol`](../../src/economics/EconomicsResolver.sol) | 212 | 8,917 | 12,028 | 15,659 |
| `AssetAllowlist` | [`src/economics/AssetAllowlist.sol`](../../src/economics/AssetAllowlist.sol) | 151 | 5,137 | 6,153 | 19,439 |
| `SplitLedger` (deployed under the name `SplitFactory`; also the release verifier) | [`src/economics/SplitLedger.sol`](../../src/economics/SplitLedger.sol) | 371 | 11,069 | 12,067 | 13,507 |
| `SplitVault` (the 66-byte wallet, one per payee configuration; raw bytecode constants, not a compiled contract) | [`src/economics/SplitVault.sol`](../../src/economics/SplitVault.sol) | 8 | 85 | 135 | 24,491 |
| `RevenueEscrow` | [`src/economics/RevenueEscrow.sol`](../../src/economics/RevenueEscrow.sol) | 143 | 7,083 | 7,535 | 17,493 |
| `ClaimRouter` | [`src/economics/ClaimRouter.sol`](../../src/economics/ClaimRouter.sol) | 148 | 4,102 | 4,421 | 20,474 |
| `GovernedVault` (deployed twice: `FeeRecipientVault`, `MuseumVault`) | [`src/economics/GovernedVault.sol`](../../src/economics/GovernedVault.sol) | 114 | 5,437 | 5,985 | 19,139 |

### Content and rendering

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `ContentStore` | [`src/content/ContentStore.sol`](../../src/content/ContentStore.sol) | 436 | 11,436 | 11,464 | 13,140 |
| `DependencyRegistry` | [`src/content/DependencyRegistry.sol`](../../src/content/DependencyRegistry.sol) | 66 | 2,988 | 3,433 | 21,588 |
| `Renderer` | [`src/content/Renderer.sol`](../../src/content/Renderer.sol) | 761 | 24,064 | 24,379 | **512** |

### Governance

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `WorksAccessManager` | [`src/governance/WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol) | 100 | 12,506 | 14,049 | 12,070 |
| `GovernanceConfigurator` | [`src/governance/GovernanceConfigurator.sol`](../../src/governance/GovernanceConfigurator.sol) | 43 | 10,161 | 24,512 | 14,415 |

`WorksAccessManager` is 71 lines over OpenZeppelin's `AccessManager`, whose code is part of
what it deploys. `GovernanceConfigurator`'s initcode includes the manager it deploys.

### Internal libraries

Compiled into the contracts that use them; none is deployed or linked.

| Library | Source | nSLOC | Used by |
| --- | --- | ---: | --- |
| `JsonScan` | [`src/content/JsonScan.sol`](../../src/content/JsonScan.sol) | 444 | Renderer |
| `GovernanceConfig` | [`src/governance/GovernanceConfig.sol`](../../src/governance/GovernanceConfig.sol) | 230 | GovernanceConfigurator |
| `Utf8` | [`src/libraries/Utf8.sol`](../../src/libraries/Utf8.sol) | 152 | `Renderer`, `Stream`, `StatementLog` |
| `UniformClearing` | [`src/sales/UniformClearing.sol`](../../src/sales/UniformClearing.sol) | 149 | `UniformEditionAuction` (sweep, claims), `UniformEditionAuctionLens` (every clearing view) |
| `TokenTransfer` | [`src/economics/TokenTransfer.sol`](../../src/economics/TokenTransfer.sol) | 149 | Sale adapters, `SplitLedger`, `RevenueEscrow`, `AssetAllowlist`, `RevenuePayment` |
| `JsonEscape` | [`src/libraries/JsonEscape.sol`](../../src/libraries/JsonEscape.sol) | 129 | Renderer |
| `BoundedCall` | [`src/libraries/BoundedCall.sol`](../../src/libraries/BoundedCall.sol) | 202 | `Renderer`, `ConsolidationAdapter`, `ArtistRegistry`, `StatementLog`, `EnglishAuction`, `ClaimRouter`, `SignatureVerifier`, `TokenTransfer`, `RevenuePayment` |
| `HtmlScript` | [`src/content/HtmlScript.sol`](../../src/content/HtmlScript.sol) | 84 | Renderer |
| `DataUri` | [`src/content/DataUri.sol`](../../src/content/DataUri.sol) | 82 | Renderer |
| `Base64Validator` | [`src/content/Base64Validator.sol`](../../src/content/Base64Validator.sol) | 78 | ContentStore |
| `SSTORE2` | [`src/libraries/SSTORE2.sol`](../../src/libraries/SSTORE2.sol) | 88 | `ContentStore`, `Renderer` |
| `Roles` | [`src/governance/Roles.sol`](../../src/governance/Roles.sol) | 53 | Governance, `Eip712CurationVerifier`, `AssetAllowlist`, `EnglishAuction` |
| `SignatureVerifier` | [`src/libraries/SignatureVerifier.sol`](../../src/libraries/SignatureVerifier.sol) | 49 | `PackageRegistry`, `Eip712CurationVerifier`, `ArtistRegistry`, `WorkRecords`, `StatementLog`, `SplitLedger` |
| `Splits` | [`src/economics/Splits.sol`](../../src/economics/Splits.sol) | 42 | Economics, `Stream`, `Editions`, `PackageRegistry`, `EnglishAuction` |
| `RevenuePayment` | [`src/economics/RevenuePayment.sol`](../../src/economics/RevenuePayment.sol) | 43 | `EnglishAuction` |
| `WorksHashing` | [`src/interfaces/types/WorksHashing.sol`](../../src/interfaces/types/WorksHashing.sol) | 37 | `PackageRegistry`, `WorkRecords`, `Editions`, `EconomicsResolver`, `VrfEntropyModule` |
| `Dependency` | [`src/libraries/Dependency.sol`](../../src/libraries/Dependency.sol) | 32 | Every install, bind and listing check, and every use-time code-hash pin |
| `SpdxId` | [`src/stream/SpdxId.sol`](../../src/stream/SpdxId.sol) | 29 | Stream, WorkRecords |
| `ProtocolContracts` | [`src/libraries/ProtocolContracts.sol`](../../src/libraries/ProtocolContracts.sol) | 24 | ArtistRegistry, EconomicsResolver |
| `BoundedParameter` | [`src/governance/BoundedParameter.sol`](../../src/governance/BoundedParameter.sol) | 22 | VrfEntropyModule |
| `DelegatedEOA` | [`src/libraries/DelegatedEOA.sol`](../../src/libraries/DelegatedEOA.sol) | 21 | `Dependency` and `SignatureVerifier` |
| `EditionRules` | [`src/editions/EditionRules.sol`](../../src/editions/EditionRules.sol) | 8 | Editions, PackageRegistry |

The "Used by" column is a reading aid; the import graph is authoritative.

### Interfaces and shared types

3,005 nSLOC in [`src/interfaces/`](../../src/interfaces/) (with `types/` and `external/`) and
[`src/economics/interfaces/`](../../src/economics/interfaces/), plus the 14-line Chainlink
coordinator interface [`src/entropy/IVRFCoordinatorV2Plus.sol`](../../src/entropy/IVRFCoordinatorV2Plus.sol).
`WorksHashing` is counted here and listed with the libraries above. They carry the external
surfaces, events, errors and NatSpec every module builds against, the shared structs, the
per-call bounds (`Limits`), every EIP-712 typehash (`Typehashes`) and the protocol hashes
(`WorksHashing`). They count toward the line budget and are in scope:
an error in a typehash or a bound is an error in every contract that uses it.

## Inherited OpenZeppelin code

These OpenZeppelin 5.7.0 contracts are compiled into in-scope contracts. Their upstream audits
are outside this scope, but their use (overrides, hooks, assumptions) is in scope.

| OpenZeppelin contract | Inherited by |
| --- | --- |
| `AccessManager` (with `Multicall`) | `WorksAccessManager`, which overrides `_canCancel` (three cancellation rules), `hasRole`, `_grantRole` and `_revokeRole` (suspension), and adds `suspend` and `isSuspended` |
| `AccessManaged` | Every governed contract |
| `ERC721` | `Stream` |
| `ERC1155` | `Editions` |
| `EIP712` | `PackageRegistry`, `Eip712CurationVerifier`, `ArtistRegistry`, `StatementLog`, `WorkRecords`, `SplitLedger` |
| `ReentrancyGuardTransient` | `EnglishAuction`, `RevenueEscrow`, `UniformEditionAuction` (the split ledger keeps a per-wallet transient lock of its own) |
| `ERC165`, `ERC165Checker`, `MerkleProof`, `ECDSA`, `Math`, `SafeCast`, `Base64`, `Strings`, `Create2` | Utilities across modules |

## Out of scope

- **`lib/`:** OpenZeppelin Contracts and forge-std themselves.
- **`test/`:** tests, mocks and harnesses. They are the evidence for the in-scope code, and
  reviewers should read them, but they are not deployed.
- **`script/`:** the deploy library, deploy and verify scripts. They are not deployed, but
  [`DeployGuards.sol`](../../script/DeployGuards.sol) enforces deployment preconditions
  (the network a bare canonical Safe, no brake at launch, operational holders
  only, at least two curation signers, committed policy, canonical dependencies on mainnet) that the trust model relies on, and
  [`Verify.s.sol`](../../script/Verify.s.sol) repeats them at readback, so a review of
  the deployment path should include them. [SECURITY.md](../../SECURITY.md) accepts
  vulnerability reports against them.
- **`tools/`:** off-chain Python: CI gates and the uploader.
- **6529 Stream Federated:** in scope ([ADR 0008](../adr/0008-federation.md),
  [Federation](../spec/federation.md)): the two templates (each artist deploys a full copy; a
  template version's code hash is what governance approves), the federation registry and the
  federated edition auction, installed at genesis; the permanent artist registry's federation
  directory (ID-33, ID-34) lists every federated contract.
- **External contracts:** the 6529 delegation contract, the Chainlink VRF coordinator,
  and Safe wallets. The protocol's assumptions about each are
  in [Trust assumptions](trust-assumptions.md).
- **Off-chain systems:** 6529 waves and TDH votes, the curation signer's tooling, the storage
  health monitor, 6529.io and keepers. Their obligations are listed as trust assumptions.

## How the figures are measured

```bash
forge build --sizes                                        # runtime and initcode sizes
python tools/check_budgets.py --profile default            # total lines, libraries, delegatecall, sizes
python tools/check_docs_facts.py --artifacts out --update  # refresh the figures on this page
```

Per-file nSLOC uses `strip_solidity` and `count_code_lines` from `tools/check_budgets.py`;
sizes are the compiled `bytecode` and `deployedBytecode` lengths. `EnglishAuction`,
`UniformEditionAuction` and `Renderer` have the smallest EIP-170 margins (see the tables); CI fails
any change that crosses the limit, that leaves a contract declared in `src/` under 512 bytes of
margin, or that takes an exempt contract below the margin
[`tools/size-margins.json`](../../tools/size-margins.json) records for it (none today).

## Related

- [Trust assumptions](trust-assumptions.md).
- [Role and permission matrix](roles.md).
- [Invariants](invariants.md) and [known limitations](known-limitations.md).
- [Quickstart](../quickstart.md) and [Testing](../testing/README.md).
- The [protocol specification](../spec/README.md).
