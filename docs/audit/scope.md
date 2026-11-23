# Scope

What an audit of 6529 Works v1 covers: every Solidity file under `src/`, with its size, and what
lies outside.

> Pre-audit. See the [project status](../../README.md#status).

The nSLOC and bytecode figures below are checked against the code in CI by
[`tools/check_docs_facts.py`](../../tools/check_docs_facts.py); after a source change, run it
with `--artifacts out --update` to refresh them. No audit has taken place.

## Summary

| | |
| --- | --- |
| Language and compiler | Solidity 0.8.37, EVM `prague`, optimizer on (200 runs), `via_ir` off ([`foundry.toml`](../../foundry.toml)) |
| Dependencies | OpenZeppelin Contracts 5.7.0 and forge-std 1.17.0, as git submodules in `lib/` |
| Source lines | 13,932 non-blank, non-comment lines in 120 files under `src/` (budget: 17,000) |
| Deployed contracts | Every contract `script/DeployCore.sol` deploys: the permanent core, the money contracts, the modules, the governance pair and the two Independent Stream deployers (the deploy order is in the [runbook](../../script/README.md#how-a-deployment-is-built)) |
| Linked libraries | None: every library function is `internal` |
| Proxies and `delegatecall` | None in `src/`. The one exception is OpenZeppelin `Multicall` inside `AccessManager` ([ADR 0002](../adr/0002-access-manager-hardening.md)) |
| Contract size | Every contract within EIP-170 and EIP-3860; every contract under `src/core/` keeps at least 3,000 bytes of EIP-170 margin and every other contract at least 512 ([`tools/size-margins.json`](../../tools/size-margins.json)) |

## Contracts in scope

nSLOC counts the non-blank lines left after removing comments, as
[`tools/check_budgets.py`](../../tools/check_budgets.py) does for the line budget. Sizes are
from `forge build --sizes` on the `default` profile. The margin is what remains under EIP-170.

### The permanent core

Deployed once and never replaced ([ADR 0010](../adr/0010-plain-permanent-core.md)).

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `Stream6529` (on `StreamBase`) | [`src/core/Stream6529.sol`](../../src/core/Stream6529.sol) | 46 | 14,823 | 16,674 | 9,753 |
| `StreamEditions6529` (on `EditionsBase`) | [`src/core/StreamEditions6529.sol`](../../src/core/StreamEditions6529.sol) | 44 | 13,408 | 15,140 | 11,168 |
| `StreamWorkFacts6529` | [`src/core/StreamWorkFacts6529.sol`](../../src/core/StreamWorkFacts6529.sol) | 166 | 9,533 | 9,738 | 15,043 |
| `StreamDirectory6529` | [`src/core/StreamDirectory6529.sol`](../../src/core/StreamDirectory6529.sol) | 43 | 3,165 | 3,897 | 21,411 |
| `StreamBase` (abstract) | [`src/core/StreamBase.sol`](../../src/core/StreamBase.sol) | 219 |  |  |  |
| `EditionsBase` (abstract) | [`src/core/EditionsBase.sol`](../../src/core/EditionsBase.sol) | 156 |  |  |  |
| `Modules`, `ModuleSlots` (abstract) | [`src/core/Modules.sol`](../../src/core/Modules.sol) | 93 |  |  |  |
| `IndependentStream6529` (each artist deploys a full copy) | [`src/independent/IndependentStream6529.sol`](../../src/independent/IndependentStream6529.sol) | 120 | 14,112 | 15,810 | 10,464 |
| `IndependentStreamEditions6529` (the pair's ERC-1155) | [`src/independent/IndependentStreamEditions6529.sol`](../../src/independent/IndependentStreamEditions6529.sol) | 51 | 11,186 | 12,380 | 13,390 |
| `IndependentStreamMembership` (abstract, both templates) | [`src/independent/IndependentStreamMembership.sol`](../../src/independent/IndependentStreamMembership.sol) | 46 |  |  |  |
| `SplitLedger` (deployed under the name `SplitFactory`) | [`src/economics/SplitLedger.sol`](../../src/economics/SplitLedger.sol) | 363 | 11,686 | 12,691 | 12,890 |
| `SplitVault` (the 66-byte wallet; raw bytecode constants) | [`src/economics/SplitVault.sol`](../../src/economics/SplitVault.sol) | 8 |  |  |  |
| `RevenueEscrow` | [`src/economics/RevenueEscrow.sol`](../../src/economics/RevenueEscrow.sol) | 199 | 7,819 | 8,285 | 16,757 |
| `ContentStore` | [`src/content/ContentStore.sol`](../../src/content/ContentStore.sol) | 455 | 12,017 | 12,045 | 12,559 |

### Sale contracts (minters)

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `EnglishAuction` | [`src/sales/EnglishAuction.sol`](../../src/sales/EnglishAuction.sol) | 604 | 21,287 | 23,553 | 3,289 |
| `UniformEditionAuction` | [`src/sales/UniformEditionAuction.sol`](../../src/sales/UniformEditionAuction.sol) | 922 | 23,535 | 28,010 | 1,041 |
| `UniformEditionAuctionLens` | [`src/sales/UniformEditionAuctionLens.sol`](../../src/sales/UniformEditionAuctionLens.sol) | 962 | 22,795 | 23,267 | 1,781 |
| `IndependentEditionAuction` | [`src/independent/IndependentEditionAuction.sol`](../../src/independent/IndependentEditionAuction.sol) | 77 | 23,982 | 27,941 | 594 |
| `IndependentEditionAuctionLens` | [`src/independent/IndependentEditionAuctionLens.sol`](../../src/independent/IndependentEditionAuctionLens.sol) | 107 | 23,726 | 24,057 | 850 |
| `SaleStarter` (stateless helper for the keeper) | [`src/sales/SaleStarter.sol`](../../src/sales/SaleStarter.sol) | 35 | 5,954 | 5,982 | 18,622 |

### Modules

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `PackageRegistry` (the mint policy) | [`src/curation/PackageRegistry.sol`](../../src/curation/PackageRegistry.sol) | 517 | 19,906 | 21,552 | 4,670 |
| `Eip712CurationVerifier` | [`src/curation/Eip712CurationVerifier.sol`](../../src/curation/Eip712CurationVerifier.sol) | 117 | 5,835 | 6,526 | 18,741 |
| `StreamTerms` (TERMS) | [`src/terms/StreamTerms.sol`](../../src/terms/StreamTerms.sol) | 152 | 7,037 | 7,822 | 17,539 |
| `WorkRules` (RECORDS) | [`src/records/WorkRules.sol`](../../src/records/WorkRules.sol) | 388 | 15,757 | 16,700 | 8,819 |
| `WorkDelivery` | [`src/stream/WorkDelivery.sol`](../../src/stream/WorkDelivery.sol) | 253 | 10,172 | 10,541 | 14,404 |
| `Renderer` (RENDERER) | [`src/content/Renderer.sol`](../../src/content/Renderer.sol) | 724 | 24,057 | 24,372 | 519 |
| `Accounts` (ACCOUNTS) | [`src/identity/Accounts.sol`](../../src/identity/Accounts.sol) | 525 | 15,623 | 17,304 | 8,953 |
| `ConsolidationAdapter` | [`src/identity/ConsolidationAdapter.sol`](../../src/identity/ConsolidationAdapter.sol) | 52 | 1,335 | 1,646 | 23,241 |
| `IndependentStreamRegistry` (INDEPENDENT_STREAM) | [`src/independent/IndependentStreamRegistry.sol`](../../src/independent/IndependentStreamRegistry.sol) | 510 | 24,064 | 24,888 | 512 |
| `IndependentStreamDeployer` (one per template, ownerless) | [`src/independent/IndependentStreamDeployer.sol`](../../src/independent/IndependentStreamDeployer.sol) | 49 | 1,425 | 2,398 | 23,151 |
| `StatementLog` | [`src/records/StatementLog.sol`](../../src/records/StatementLog.sol) | 310 | 11,167 | 12,428 | 13,409 |
| `VrfEntropyModule` (optional) | [`src/entropy/VrfEntropyModule.sol`](../../src/entropy/VrfEntropyModule.sol) | 367 | 12,639 | 14,585 | 11,937 |
| `EconomicsResolver` | [`src/economics/EconomicsResolver.sol`](../../src/economics/EconomicsResolver.sol) | 197 | 8,352 | 11,452 | 16,224 |
| `AssetAllowlist` | [`src/economics/AssetAllowlist.sol`](../../src/economics/AssetAllowlist.sol) | 70 | 2,493 | 3,049 | 22,083 |
| `ClaimRouter` | [`src/economics/ClaimRouter.sol`](../../src/economics/ClaimRouter.sol) | 148 | 4,102 | 4,421 | 20,474 |
| `GovernedVault` (deployed twice: `FeeRecipientVault`, `MuseumVault`) | [`src/economics/GovernedVault.sol`](../../src/economics/GovernedVault.sol) | 114 | 5,237 | 5,785 | 19,339 |
| `DependencyRegistry` | [`src/content/DependencyRegistry.sol`](../../src/content/DependencyRegistry.sol) | 66 | 2,988 | 3,433 | 21,588 |

### Governance

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `WorksAccessManager` | [`src/governance/WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol) | 100 | 12,506 | 14,049 | 12,070 |
| `GovernanceConfigurator` | [`src/governance/GovernanceConfigurator.sol`](../../src/governance/GovernanceConfigurator.sol) | 43 | 9,972 | 24,323 | 14,604 |

`WorksAccessManager` extends OpenZeppelin's `AccessManager`, whose code is part of what it
deploys. `GovernanceConfigurator`'s initcode includes the manager it deploys.

### Internal libraries

Compiled into the contracts that use them; none is deployed or linked.

| Library | Source | nSLOC | Used by |
| --- | --- | ---: | --- |
| `AgedCredits` | [`src/libraries/AgedCredits.sol`](../../src/libraries/AgedCredits.sol) | 32 | `EnglishAuction`, `UniformEditionAuction` (the one credit rule of both auctions) |
| `JsonScan` | [`src/content/JsonScan.sol`](../../src/content/JsonScan.sol) | 444 | `Renderer` |
| `GovernanceConfig` | [`src/governance/GovernanceConfig.sol`](../../src/governance/GovernanceConfig.sol) | 218 | `GovernanceConfigurator` |
| `Utf8` | [`src/libraries/Utf8.sol`](../../src/libraries/Utf8.sol) | 152 | `Renderer`, `JsonScan`, `StatementLog` |
| `UniformClearing` | [`src/sales/UniformClearing.sol`](../../src/sales/UniformClearing.sol) | 149 | The edition auctions and their lenses |
| `TokenTransfer` | [`src/economics/TokenTransfer.sol`](../../src/economics/TokenTransfer.sol) | 100 | `SplitLedger`, `RevenueEscrow`, the sale contracts |
| `JsonEscape` | [`src/libraries/JsonEscape.sol`](../../src/libraries/JsonEscape.sol) | 129 | `Renderer` |
| `BoundedCall` | [`src/libraries/BoundedCall.sol`](../../src/libraries/BoundedCall.sol) | 202 | Modules that call other contracts |
| `HtmlScript` | [`src/content/HtmlScript.sol`](../../src/content/HtmlScript.sol) | 84 | `Renderer` |
| `DataUri` | [`src/content/DataUri.sol`](../../src/content/DataUri.sol) | 82 | `Renderer` |
| `Base64Validator` | [`src/content/Base64Validator.sol`](../../src/content/Base64Validator.sol) | 78 | `ContentStore` |
| `SSTORE2` | [`src/libraries/SSTORE2.sol`](../../src/libraries/SSTORE2.sol) | 88 | `ContentStore`, `Renderer`, `IndependentStreamDeployer` |
| `Roles` | [`src/governance/Roles.sol`](../../src/governance/Roles.sol) | 53 | Governance |
| `SignatureVerifier` | [`src/libraries/SignatureVerifier.sol`](../../src/libraries/SignatureVerifier.sol) | 49 | `PackageRegistry`, `Eip712CurationVerifier`, `Accounts`, `StatementLog`, `SplitLedger` |
| `Splits` | [`src/economics/Splits.sol`](../../src/economics/Splits.sol) | 54 | The money contracts and the terms |
| `RevenuePayment` | [`src/economics/RevenuePayment.sol`](../../src/economics/RevenuePayment.sol) | 23 | The sale contracts |
| `Dependency` | [`src/libraries/Dependency.sol`](../../src/libraries/Dependency.sol) | 32 | Every install and code-hash pin of a module |
| `SpdxId` | [`src/stream/SpdxId.sol`](../../src/stream/SpdxId.sol) | 26 | `PackageRegistry`, `IndependentStreamRegistry`, `StreamWorkFacts6529` |
| `ProtocolContracts` | [`src/libraries/ProtocolContracts.sol`](../../src/libraries/ProtocolContracts.sol) | 26 | `Accounts`, `EconomicsResolver` |
| `BoundedParameter` | [`src/governance/BoundedParameter.sol`](../../src/governance/BoundedParameter.sol) | 22 | `VrfEntropyModule` |
| `DelegatedEOA` | [`src/libraries/DelegatedEOA.sol`](../../src/libraries/DelegatedEOA.sol) | 21 | `Dependency`, `SignatureVerifier` |
| `EditionRules` | [`src/editions/EditionRules.sol`](../../src/editions/EditionRules.sol) | 8 | `PackageRegistry` |

The "Used by" column is a reading aid; the import graph is authoritative.

### Interfaces and shared types

2,415 nSLOC in [`src/interfaces/`](../../src/interfaces/) (with `core/` and `types/`) and
[`src/economics/interfaces/`](../../src/economics/interfaces/), plus the Chainlink interfaces in
[`src/entropy/`](../../src/entropy/). The frozen interfaces of the permanent core are in
`src/interfaces/core/`. They count toward the line budget and are in scope: an error in a
typehash or a bound is an error in every contract that uses it.

## Inherited OpenZeppelin code

These OpenZeppelin 5.7.0 contracts are compiled into in-scope contracts. Their upstream audits
are outside this scope, but their use (overrides, hooks, assumptions) is in scope.

| OpenZeppelin contract | Inherited by |
| --- | --- |
| `AccessManager` (with `Multicall`) | `WorksAccessManager` |
| `AccessManaged` | Every governed contract |
| `ERC721` | `Stream6529`, `IndependentStream6529` (through `StreamBase`) |
| `ERC1155` | `StreamEditions6529`, `IndependentStreamEditions6529` (through `EditionsBase`) |
| `EIP712` | `PackageRegistry`, `Eip712CurationVerifier`, `Accounts`, `StatementLog`, `WorkRules`, `SplitLedger` |
| `ReentrancyGuardTransient` | `EnglishAuction`, `RevenueEscrow`, `UniformEditionAuction` (the split ledger keeps a per-wallet transient lock of its own) |
| `ERC165`, `ERC165Checker`, `MerkleProof`, `ECDSA`, `Math`, `SafeCast`, `Base64`, `Strings`, `Create2` | Utilities across modules |

## Out of scope

- **`lib/`:** OpenZeppelin Contracts and forge-std themselves.
- **`test/`:** tests, mocks and harnesses. They are the evidence for the in-scope code, and
  reviewers should read them, but they are not deployed.
- **`script/`:** the deploy library, deploy and read-back scripts. They are not deployed, but
  [`DeployGuards.sol`](../../script/DeployGuards.sol) enforces deployment preconditions (the
  network a bare canonical Safe, no brake at launch, operational holders only, the committed
  policy) and [`VerifyCore.sol`](../../script/VerifyCore.sol) reads the deployment back, so a
  review of the deployment path should include them. [SECURITY.md](../../SECURITY.md) accepts
  vulnerability reports against them.
- **`tools/`, `keeper/`, `examples/`:** off-chain Python, the reference keeper and integrator
  examples.
- **External contracts:** the 6529 delegation contract, the Chainlink VRF coordinator and
  wrapper, and Safe wallets. The protocol's assumptions about each are in
  [Trust assumptions](trust-assumptions.md).
- **Off-chain systems:** 6529 waves and TDH votes, the curation signer's tooling, the storage
  health monitor, 6529.io and keepers. Their obligations are listed as trust assumptions.

## How the figures are measured

```bash
forge build --sizes                                        # runtime and initcode sizes
python tools/check_budgets.py --profile default            # total lines, libraries, delegatecall, sizes
python tools/check_docs_facts.py --artifacts out --update  # refresh the figures on this page
```

Per-file nSLOC uses `strip_solidity` and `count_code_lines` from `tools/check_budgets.py`;
sizes are the compiled `bytecode` and `deployedBytecode` lengths. CI fails any change that
crosses EIP-170, leaves a contract under `src/core/` under 3,000 bytes of margin or any other
contract declared in `src/` under 512, or takes an exempt contract below the margin
[`tools/size-margins.json`](../../tools/size-margins.json) records for it.

## Related

- [Trust assumptions](trust-assumptions.md).
- [Role and permission matrix](roles.md).
- [Invariants](invariants.md) and [known limitations](known-limitations.md).
- [Quickstart](../quickstart.md) and [Testing](../testing/README.md).
- The [protocol specification](../spec/README.md).
