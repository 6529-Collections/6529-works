# Scope

What an audit of 6529 Works v1 covers: every Solidity file under `src/`, with its size, and what
lies outside.

> **Status.** Pre-audit. The figures on this page were measured on `main` at `c4b3355`
> (15 October 2026). Other work in progress changes gas and storage layouts, so re-measure
> at the audit commit with the commands under [How the figures are measured](#how-the-figures-are-measured).
> An internal adversarial review ran on 14 October 2026; its fixes merged in PRs #51 and #53 to
> #57, and open PR #52 (GOV-1 to GOV-4, DEPS-3, DEPS-4) is not on `main`. It is not an audit.

## Summary

| | |
| --- | --- |
| Language and compiler | Solidity 0.8.37, EVM `prague`, optimizer on (200 runs), `via_ir` off ([`foundry.toml`](../../foundry.toml)) |
| Dependencies | OpenZeppelin Contracts 5.7.0 and forge-std 1.17.0, as git submodules in `lib/` |
| Source lines | 10,274 non-blank, non-comment lines in 83 files under `src/` (budget: 12,000) |
| Deployed contracts | 23 per deployment, plus one `SplitWallet` per payee configuration, deployed on demand |
| Linked libraries | None: every library function is `internal` |
| Proxies and `delegatecall` | None in `src/`. The one exception is OpenZeppelin `Multicall` inside `AccessManager` ([ADR 0002](../adr/0002-access-manager-hardening.md)) |
| Contract size | Every contract within EIP-170 (24,576 bytes of runtime) and EIP-3860 (49,152 bytes of initcode), checked by `tools/check_budgets.py` in CI |

## Contracts in scope

nSLOC counts the non-blank lines left after removing comments, as
[`tools/check_budgets.py`](../../tools/check_budgets.py) does for the line budget. Sizes are
from `forge build --sizes` on the `default` profile. The margin is what remains under EIP-170.

### Products and sales

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `Stream` | [`src/stream/Stream.sol`](../../src/stream/Stream.sol) | 502 | 19,608 | 21,421 | 4,968 |
| `WorkRecords` | [`src/stream/WorkRecords.sol`](../../src/stream/WorkRecords.sol) | 633 | 22,900 | 25,824 | 1,676 |
| `Editions` | [`src/editions/Editions.sol`](../../src/editions/Editions.sol) | 308 | 18,552 | 20,274 | 6,024 |
| `EnglishAuction` | [`src/sales/EnglishAuction.sol`](../../src/sales/EnglishAuction.sol) | 789 | 24,449 | 26,746 | **127** |
| `FixedPriceSale` | [`src/sales/FixedPriceSale.sol`](../../src/sales/FixedPriceSale.sol) | 278 | 21,999 | 23,571 | 2,577 |
| `DutchSale` | [`src/sales/DutchSale.sol`](../../src/sales/DutchSale.sol) | 145 | 16,550 | 17,638 | 8,026 |
| `MintSaleBase` (abstract; in both adapters above) | [`src/sales/MintSaleBase.sol`](../../src/sales/MintSaleBase.sol) | 364 | | | |

### Curation, identity and records

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `PackageRegistry` | [`src/curation/PackageRegistry.sol`](../../src/curation/PackageRegistry.sol) | 384 | 14,779 | 16,179 | 9,797 |
| `Eip712CurationVerifier` | [`src/curation/Eip712CurationVerifier.sol`](../../src/curation/Eip712CurationVerifier.sol) | 103 | 5,694 | 6,385 | 18,882 |
| `ArtistRegistry` | [`src/identity/ArtistRegistry.sol`](../../src/identity/ArtistRegistry.sol) | 569 | 20,525 | 21,729 | 4,051 |
| `ConsolidationAdapter` | [`src/identity/ConsolidationAdapter.sol`](../../src/identity/ConsolidationAdapter.sol) | 133 | 3,059 | 3,255 | 21,517 |
| `StatementLog` | [`src/records/StatementLog.sol`](../../src/records/StatementLog.sol) | 322 | 11,732 | 13,021 | 12,844 |
| `VrfEntropyModule` (optional) | [`src/entropy/VrfEntropyModule.sol`](../../src/entropy/VrfEntropyModule.sol) | 242 | 8,266 | 10,222 | 16,310 |

### Economics

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `EconomicsResolver` | [`src/economics/EconomicsResolver.sol`](../../src/economics/EconomicsResolver.sol) | 196 | 9,083 | 12,533 | 15,493 |
| `AssetAllowlist` | [`src/economics/AssetAllowlist.sol`](../../src/economics/AssetAllowlist.sol) | 124 | 4,528 | 5,544 | 20,048 |
| `SplitFactory` | [`src/economics/SplitFactory.sol`](../../src/economics/SplitFactory.sol) | 106 | 10,077 | 17,455 | 14,499 |
| `SplitWallet` (one per payee configuration) | [`src/economics/SplitWallet.sol`](../../src/economics/SplitWallet.sol) | 142 | 5,350 | 6,861 | 19,226 |
| `ReleaseVerifier` | [`src/economics/ReleaseVerifier.sol`](../../src/economics/ReleaseVerifier.sol) | 47 | 3,672 | 4,193 | 20,904 |
| `RevenueEscrow` | [`src/economics/RevenueEscrow.sol`](../../src/economics/RevenueEscrow.sol) | 91 | 5,224 | 5,641 | 19,352 |
| `ClaimRouter` | [`src/economics/ClaimRouter.sol`](../../src/economics/ClaimRouter.sol) | 99 | 3,026 | 3,054 | 21,550 |

### Content and rendering

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `ContentStore` | [`src/content/ContentStore.sol`](../../src/content/ContentStore.sol) | 240 | 7,257 | 7,285 | 17,319 |
| `DependencyRegistry` | [`src/content/DependencyRegistry.sol`](../../src/content/DependencyRegistry.sol) | 65 | 3,007 | 3,339 | 21,569 |
| `Renderer` | [`src/content/Renderer.sol`](../../src/content/Renderer.sol) | 774 | 24,397 | 24,712 | **179** |

### Governance

| Contract | Source | nSLOC | Runtime (bytes) | Initcode (bytes) | EIP-170 margin |
| --- | --- | ---: | ---: | ---: | ---: |
| `WorksAccessManager` | [`src/governance/WorksAccessManager.sol`](../../src/governance/WorksAccessManager.sol) | 26 | 10,737 | 11,964 | 13,839 |
| `GovernanceConfigurator` | [`src/governance/GovernanceConfigurator.sol`](../../src/governance/GovernanceConfigurator.sol) | 43 | 10,634 | 22,900 | 13,942 |

`WorksAccessManager` is 26 lines over OpenZeppelin's `AccessManager`, whose code is part of
what it deploys. `GovernanceConfigurator`'s initcode includes the manager it deploys.

### Internal libraries

Compiled into the contracts that use them; none is deployed or linked.

| Library | Source | nSLOC | Used by |
| --- | --- | ---: | --- |
| `JsonScan` | [`src/content/JsonScan.sol`](../../src/content/JsonScan.sol) | 444 | Renderer |
| `JsonEscape` | [`src/libraries/JsonEscape.sol`](../../src/libraries/JsonEscape.sol) | 197 | Renderer |
| `Utf8` | [`src/libraries/Utf8.sol`](../../src/libraries/Utf8.sol) | 152 | `Renderer`, `Stream`, `StatementLog` |
| `GovernanceConfig` | [`src/governance/GovernanceConfig.sol`](../../src/governance/GovernanceConfig.sol) | 246 | GovernanceConfigurator |
| `TokenTransfer` | [`src/economics/TokenTransfer.sol`](../../src/economics/TokenTransfer.sol) | 134 | Sale adapters, `SplitWallet`, `RevenueEscrow`, `AssetAllowlist`, `RevenuePayment` |
| `BoundedCall` | [`src/libraries/BoundedCall.sol`](../../src/libraries/BoundedCall.sol) | 104 | `Renderer`, `ConsolidationAdapter`, `ArtistRegistry`, `StatementLog`, `EnglishAuction`, `ClaimRouter`, `SignatureVerifier`, `TokenTransfer`, `RevenuePayment` |
| `HtmlScript` | [`src/content/HtmlScript.sol`](../../src/content/HtmlScript.sol) | 84 | Renderer |
| `DataUri` | [`src/content/DataUri.sol`](../../src/content/DataUri.sol) | 82 | Renderer |
| `Base64Validator` | [`src/content/Base64Validator.sol`](../../src/content/Base64Validator.sol) | 78 | ContentStore |
| `SSTORE2` | [`src/libraries/SSTORE2.sol`](../../src/libraries/SSTORE2.sol) | 76 | `ContentStore`, `Renderer` |
| `Roles` | [`src/governance/Roles.sol`](../../src/governance/Roles.sol) | 57 | Governance, `Eip712CurationVerifier`, `AssetAllowlist`, the sale adapters |
| `SignatureVerifier` | [`src/libraries/SignatureVerifier.sol`](../../src/libraries/SignatureVerifier.sol) | 47 | `PackageRegistry`, `Eip712CurationVerifier`, `ArtistRegistry`, `WorkRecords`, `StatementLog`, `FixedPriceSale`, `ReleaseVerifier` |
| `Splits` | [`src/economics/Splits.sol`](../../src/economics/Splits.sol) | 44 | Economics, `Stream`, `Editions`, `PackageRegistry`, the sale adapters |
| `RevenuePayment` | [`src/economics/RevenuePayment.sol`](../../src/economics/RevenuePayment.sol) | 43 | `EnglishAuction`, `MintSaleBase` |
| `WorksHashing` | [`src/interfaces/types/WorksHashing.sol`](../../src/interfaces/types/WorksHashing.sol) | 37 | `PackageRegistry`, `WorkRecords`, `Editions`, `EconomicsResolver`, `VrfEntropyModule` |
| `SpdxId` | [`src/stream/SpdxId.sol`](../../src/stream/SpdxId.sol) | 29 | Stream, WorkRecords |
| `ProtocolContracts` | [`src/libraries/ProtocolContracts.sol`](../../src/libraries/ProtocolContracts.sol) | 27 | ArtistRegistry, EconomicsResolver |
| `DutchPricing` | [`src/sales/DutchPricing.sol`](../../src/sales/DutchPricing.sol) | 27 | `DutchSale`, `EditionRules` |
| `BoundedParameter` | [`src/governance/BoundedParameter.sol`](../../src/governance/BoundedParameter.sol) | 22 | VrfEntropyModule |
| `DelegatedEOA` | [`src/libraries/DelegatedEOA.sol`](../../src/libraries/DelegatedEOA.sol) | 21 | Every install and bind check, and `SignatureVerifier` |
| `EditionRules` | [`src/editions/EditionRules.sol`](../../src/editions/EditionRules.sol) | 21 | Editions, PackageRegistry |

The "Used by" column is a reading aid; the import graph is authoritative.

### Interfaces and shared types

1,600 nSLOC in [`src/interfaces/`](../../src/interfaces/) (with `types/` and `external/`) and
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
| `AccessManager` (with `Multicall`) | `WorksAccessManager`, which overrides `_canCancel` only |
| `AccessManaged` | Every governed contract |
| `ERC721` | `Stream` |
| `ERC1155` | `Editions` |
| `EIP712` | `PackageRegistry`, `Eip712CurationVerifier`, `ArtistRegistry`, `StatementLog`, `WorkRecords`, `FixedPriceSale`, `ReleaseVerifier` |
| `ReentrancyGuardTransient` | `EnglishAuction`, `MintSaleBase`, `SplitWallet`, `RevenueEscrow` |
| `ERC165`, `ERC165Checker`, `MerkleProof`, `ECDSA`, `Math`, `SafeCast`, `Base64`, `Strings`, `Create2` | Utilities across modules |

## Out of scope

- **`lib/`:** OpenZeppelin Contracts and forge-std themselves.
- **`test/`:** tests, mocks and harnesses. They are the evidence for the in-scope code, and
  reviewers should read them, but they are not deployed.
- **`script/`:** the deploy library, deploy and verify scripts. They are not deployed, but
  [`DeployGuards.sol`](../../script/DeployGuards.sol) enforces deployment preconditions
  (Safes, guardian count, committed policy) that the trust model relies on, so a review of
  the deployment path should include them. [SECURITY.md](../../SECURITY.md) accepts
  vulnerability reports against them.
- **`tools/`:** off-chain Python: CI gates and the uploader.
- **6529 Stream Federated:** v1.1, only if needed. v1 contains only the interfaces it needs
  (`IFederationRegistry`) and the sale adapters' registry hooks; no registry is installed.
- **External contracts:** the 6529 delegation contract, the Chainlink VRF coordinator,
  Permit2, Safe wallets and admitted ERC-20 tokens. The protocol's assumptions about each are
  in [Trust assumptions](trust-assumptions.md).
- **Off-chain systems:** 6529 waves and TDH votes, the curation signer's tooling, the storage
  health monitor, 6529.io and keepers. Their obligations are listed as trust assumptions.
- **The RC1 reference implementation** in the private 6529Stream repository.

## How the figures are measured

```bash
forge build --sizes                            # runtime and initcode sizes, default profile
python tools/check_budgets.py --profile default # total lines, linked libraries, delegatecall, sizes
```

Per-file nSLOC uses `strip_solidity` and `count_code_lines` from `tools/check_budgets.py`.
The two tightest contracts, `EnglishAuction` (127 bytes under EIP-170) and `Renderer`
(179 bytes), leave little room for change; CI fails any change that crosses the limit.

## Related

- [Trust assumptions](trust-assumptions.md) and the [threat model](threat-model.md).
- [Role and permission matrix](roles.md).
- [Invariants](invariants.md) and [known limitations](known-limitations.md).
- [Build, test and budgets](build-and-test.md).
- The [protocol specification](../spec/README.md).
