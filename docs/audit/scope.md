# Scope

What an audit of 6529 Works v1 covers: every Solidity file under `src/`, with its size, and what
lies outside.

> Pre-audit. See the [project status](../../README.md#status).

The nSLOC and bytecode figures below are checked against the code in CI by
[`tools/check_docs_facts.py`](../../tools/check_docs_facts.py); after a source change, run it
with `--artifacts out --update` to refresh them. The internal review that preceded this pack is
[docs/security/internal-review-2026-10.md](../security/internal-review-2026-10.md); it is not
an audit.

## Summary

| | |
| --- | --- |
| Language and compiler | Solidity 0.8.37, EVM `prague`, optimizer on (200 runs), `via_ir` off ([`foundry.toml`](../../foundry.toml)) |
| Dependencies | OpenZeppelin Contracts 5.7.0 and forge-std 1.17.0, as git submodules in `lib/` |
| Source lines | 16,253 non-blank, non-comment lines in 111 files under `src/` (budget: 16,000; ADR 0001, amended 1 November 2026, ADR 0007 and ADR 0008) |
| Deployed contracts | 29 per deployment without the optional VRF entropy module and 30 with it: the 26 (or 27) that `DeployV1.order` lists, the three auctions' lenses among them (each deployed in its own transaction and pinned by its auction) and the two governed vaults (`FeeRecipientVault`, `MuseumVault`, after the split ledger), plus the AccessManager the governance configurator creates, `StreamViews`, the read-only extension `Stream`'s constructor creates, and `WorkDelivery`, the first delivery contract `WorkRecords`' constructor creates (replaceable by `setDelivery`); one 66-byte `SplitVault` per payee configuration, deployed on demand by the split ledger; and, outside genesis, each federated artist's own template copies ([ADR 0008](../adr/0008-federation.md)) |
| Linked libraries | None: every library function is `internal` |
| Proxies and `delegatecall` | None in `src/`. The one exception is OpenZeppelin `Multicall` inside `AccessManager` ([ADR 0002](../adr/0002-access-manager-hardening.md)) |
| Contract size | Every contract within EIP-170 (24,576 bytes of runtime) and EIP-3860 (49,152 bytes of initcode), and every contract declared in `src/` with at least 512 bytes of EIP-170 margin; [`tools/size-margins.json`](../../tools/size-margins.json) records no exemption since the permanence integration ([ADR 0007](../adr/0007-permanence.md)): the English auction regained its floor when its opening bids moved to the asset allowlist, the renderer when its reads stopped carrying gas caps, and the edition auction when its lane replaced the interim wiring. Checked by `tools/check_budgets.py` in CI ([Build, test and budgets](build-and-test.md)) |

## Contracts in scope

nSLOC counts the non-blank lines left after removing comments, as
[`tools/check_budgets.py`](../../tools/check_budgets.py) does for the line budget. Sizes are
from `forge build --sizes` on the `default` profile. The margin is what remains under EIP-170.

### Products and sales

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `Stream` | [`src/stream/Stream.sol`](../../src/stream/Stream.sol) | 793 | 22,863 | 29,055 | **1,713** |
| `StreamViews` (created by `Stream`'s constructor) | [`src/stream/StreamViews.sol`](../../src/stream/StreamViews.sol) | 79 | 4,110 | 4,138 | 20,466 |
| `WorkRecords` | [`src/stream/WorkRecords.sol`](../../src/stream/WorkRecords.sol) | 732 | 23,180 | 35,125 | 1,396 |
| `WorkDelivery` (created by `WorkRecords`' constructor; replaceable) | [`src/stream/WorkDelivery.sol`](../../src/stream/WorkDelivery.sol) | 183 | 8,673 | 9,084 | 15,903 |
| `Editions` | [`src/editions/Editions.sol`](../../src/editions/Editions.sol) | 484 | 19,025 | 20,854 | 5,551 |
| `EnglishAuction` | [`src/sales/EnglishAuction.sol`](../../src/sales/EnglishAuction.sol) | 898 | 24,062 | 27,384 | 514 |
| `EnglishAuctionLens` | [`src/sales/EnglishAuctionLens.sol`](../../src/sales/EnglishAuctionLens.sol) | 314 | 7,022 | 7,315 | 17,554 |
| `UniformEditionAuction` | [`src/sales/UniformEditionAuction.sol`](../../src/sales/UniformEditionAuction.sol) | 971 | 24,061 | 29,175 | 515 |
| `UniformEditionAuctionLens` | [`src/sales/UniformEditionAuctionLens.sol`](../../src/sales/UniformEditionAuctionLens.sol) | 932 | 23,168 | 23,541 | 1,408 |

### Federation

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `FederatedStream` (a template: each artist deploys a full copy) | [`src/federated/FederatedStream.sol`](../../src/federated/FederatedStream.sol) | 528 | 23,044 | 25,170 | 1,532 |
| `FederatedEditions` (a template: the pair's ERC-1155) | [`src/federated/FederatedEditions.sol`](../../src/federated/FederatedEditions.sol) | 238 | 16,429 | 18,034 | 8,147 |
| `FederationRegistry` (replaceable) | [`src/federated/FederationRegistry.sol`](../../src/federated/FederationRegistry.sol) | 261 | 10,706 | 11,733 | 13,870 |
| `FederatedEditionAuction` (replaceable) | [`src/federated/FederatedEditionAuction.sol`](../../src/federated/FederatedEditionAuction.sol) | 71 | 23,389 | 27,973 | 1,187 |
| `FederatedEditionAuctionLens` | [`src/federated/FederatedEditionAuctionLens.sol`](../../src/federated/FederatedEditionAuctionLens.sol) | 108 | 23,837 | 24,138 | 739 |

`FederatedMembership` (abstract, both templates' shared source) and the interfaces
`IFederatedToken`, `IFederatedStream`, `IFederatedEditions` and `IFederationRegistry` count
toward the line budget with the other interfaces.

### Curation, identity and records

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `PackageRegistry` | [`src/curation/PackageRegistry.sol`](../../src/curation/PackageRegistry.sol) | 402 | 15,725 | 17,113 | 8,851 |
| `Eip712CurationVerifier` | [`src/curation/Eip712CurationVerifier.sol`](../../src/curation/Eip712CurationVerifier.sol) | 103 | 5,383 | 6,074 | 19,193 |
| `ArtistRegistry` | [`src/identity/ArtistRegistry.sol`](../../src/identity/ArtistRegistry.sol) | 746 | 23,485 | 25,033 | 1,091 |
| `ConsolidationAdapter` | [`src/identity/ConsolidationAdapter.sol`](../../src/identity/ConsolidationAdapter.sol) | 133 | 3,059 | 3,371 | 21,517 |
| `StatementLog` | [`src/records/StatementLog.sol`](../../src/records/StatementLog.sol) | 309 | 11,125 | 12,386 | 13,451 |
| `VrfEntropyModule` (optional) | [`src/entropy/VrfEntropyModule.sol`](../../src/entropy/VrfEntropyModule.sol) | 252 | 8,791 | 10,701 | 15,785 |

### Economics

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `EconomicsResolver` | [`src/economics/EconomicsResolver.sol`](../../src/economics/EconomicsResolver.sol) | 212 | 8,917 | 12,028 | 15,659 |
| `AssetAllowlist` | [`src/economics/AssetAllowlist.sol`](../../src/economics/AssetAllowlist.sol) | 154 | 5,275 | 6,291 | 19,301 |
| `SplitLedger` (deployed under the name `SplitFactory`; also the release verifier) | [`src/economics/SplitLedger.sol`](../../src/economics/SplitLedger.sol) | 264 | 8,851 | 9,776 | 15,725 |
| `SplitVault` (the 66-byte wallet, one per payee configuration; raw bytecode constants, not a compiled contract) | [`src/economics/SplitVault.sol`](../../src/economics/SplitVault.sol) | 8 | 85 | 135 | 24,491 |
| `RevenueEscrow` | [`src/economics/RevenueEscrow.sol`](../../src/economics/RevenueEscrow.sol) | 122 | 6,430 | 6,875 | 18,146 |
| `ClaimRouter` | [`src/economics/ClaimRouter.sol`](../../src/economics/ClaimRouter.sol) | 146 | 4,034 | 4,353 | 20,542 |
| `GovernedVault` (deployed twice: `FeeRecipientVault`, `MuseumVault`) | [`src/economics/GovernedVault.sol`](../../src/economics/GovernedVault.sol) | 108 | 5,277 | 6,039 | 19,299 |

### Content and rendering

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `ContentStore` | [`src/content/ContentStore.sol`](../../src/content/ContentStore.sol) | 436 | 11,436 | 11,464 | 13,140 |
| `DependencyRegistry` | [`src/content/DependencyRegistry.sol`](../../src/content/DependencyRegistry.sol) | 66 | 2,988 | 3,433 | 21,588 |
| `Renderer` | [`src/content/Renderer.sol`](../../src/content/Renderer.sol) | 761 | 24,064 | 24,379 | **512** |

### Governance

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `WorksAccessManager` | [`src/governance/WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol) | 451 | 22,738 | 25,314 | 1,838 |
| `GovernanceConfigurator` | [`src/governance/GovernanceConfigurator.sol`](../../src/governance/GovernanceConfigurator.sol) | 51 | 11,813 | 37,443 | 12,763 |

`WorksAccessManager` is 71 lines over OpenZeppelin's `AccessManager`, whose code is part of
what it deploys. `GovernanceConfigurator`'s initcode includes the manager it deploys.

### Internal libraries

Compiled into the contracts that use them; none is deployed or linked.

| Library | Source | nSLOC | Used by |
| --- | --- | ---: | --- |
| `JsonScan` | [`src/content/JsonScan.sol`](../../src/content/JsonScan.sol) | 444 | Renderer |
| `GovernanceConfig` | [`src/governance/GovernanceConfig.sol`](../../src/governance/GovernanceConfig.sol) | 269 | GovernanceConfigurator |
| `Utf8` | [`src/libraries/Utf8.sol`](../../src/libraries/Utf8.sol) | 152 | `Renderer`, `Stream`, `StatementLog` |
| `UniformClearing` | [`src/sales/UniformClearing.sol`](../../src/sales/UniformClearing.sol) | 149 | `UniformEditionAuction` (sweep, claims), `UniformEditionAuctionLens` (every clearing view) |
| `TokenTransfer` | [`src/economics/TokenTransfer.sol`](../../src/economics/TokenTransfer.sol) | 149 | Sale adapters, `SplitLedger`, `RevenueEscrow`, `AssetAllowlist`, `RevenuePayment` |
| `JsonEscape` | [`src/libraries/JsonEscape.sol`](../../src/libraries/JsonEscape.sol) | 129 | Renderer |
| `BoundedCall` | [`src/libraries/BoundedCall.sol`](../../src/libraries/BoundedCall.sol) | 202 | `Renderer`, `ConsolidationAdapter`, `ArtistRegistry`, `StatementLog`, `EnglishAuction`, `ClaimRouter`, `SignatureVerifier`, `TokenTransfer`, `RevenuePayment` |
| `HtmlScript` | [`src/content/HtmlScript.sol`](../../src/content/HtmlScript.sol) | 84 | Renderer |
| `DataUri` | [`src/content/DataUri.sol`](../../src/content/DataUri.sol) | 82 | Renderer |
| `Base64Validator` | [`src/content/Base64Validator.sol`](../../src/content/Base64Validator.sol) | 78 | ContentStore |
| `SSTORE2` | [`src/libraries/SSTORE2.sol`](../../src/libraries/SSTORE2.sol) | 88 | `ContentStore`, `Renderer` |
| `Roles` | [`src/governance/Roles.sol`](../../src/governance/Roles.sol) | 60 | Governance, `Eip712CurationVerifier`, `AssetAllowlist`, `EnglishAuction` |
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

2,548 nSLOC in [`src/interfaces/`](../../src/interfaces/) (with `types/` and `external/`) and
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
  (bare, independent admin and guardian Safes, guardian count, committed policy, canonical
  dependencies on mainnet) that the trust model relies on, and
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
  Permit2, Safe wallets and admitted ERC-20 tokens. The protocol's assumptions about each are
  in [Trust assumptions](trust-assumptions.md).
- **Off-chain systems:** 6529 waves and TDH votes, the curation signer's tooling, the storage
  health monitor, 6529.io and keepers. Their obligations are listed as trust assumptions.
- **The RC1 reference implementation** in the private 6529Stream repository.

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

- [Trust assumptions](trust-assumptions.md) and the [threat model](threat-model.md).
- [Role and permission matrix](roles.md).
- [Invariants](invariants.md) and [known limitations](known-limitations.md).
- [Build, test and budgets](build-and-test.md).
- The [protocol specification](../spec/README.md).
