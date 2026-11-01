# Tests

A map of the test tree: where the tests for a contract or a function live, which layer each
directory is, how tests and mocks are named, and what a file's place decides (CI partitions and
mutation testing). How to run each layer, what CI runs, and how strong the suite is measured to be
(coverage floors, mutation testing, Halmos proofs) are in [Testing](../docs/testing/README.md).

The tests are organised like `src/`: one directory per module, one suite per contract, and inside
a suite one section per function. A test's name says what it checks, so a suite reads as a
description of the contract.

## Finding the tests

- **For a contract:** its module's directory, `test/<module>/`, and the suite named after it
  ([the table below](#contracts-and-their-suites)). A large contract has its main suite and a few
  suites for one area each (disputes, payments, gas, hostile callers, the real stack).
- **For a function:** test names start with the function, so one filter finds them all, in every
  suite and on the real stack:

  ```bash
  forge test --match-test "test_Settle_"            # every settle test
  grep -rn "function test_openRecord_" test/        # every openRecord test, with its file
  ```

- **For a review finding:** a regression test carries the finding's ID in a NatSpec line,
  `/// Regression: <ID> (<where the ID is defined>)`. Findings of the October 2026 internal
  review point to [the report](../docs/security/internal-review-2026-10.md); earlier IDs name the
  pull request whose review raised them.

  ```bash
  grep -rn "Regression: MARKET-2" test/             # every test for MARKET-2
  ```

- **For a rule of the specification:** every rule row in [`docs/spec/`](../docs/spec/README.md)
  (`AUC-3`, `WS-17`, ...) cites the tests that pin it, and `tools/check_docs_facts.py` checks that
  each cited test exists.
- **For an end-to-end flow:** [`test/integration/`](integration/README.md) lists the flows on the
  real, wired stack; [`test/fork/`](fork/README.md) runs them against the real external systems.

### Contracts and their suites

| `src/` | Tests |
| --- | --- |
| `stream/Stream.sol` | [`stream/Stream.t.sol`](stream/Stream.t.sol) (by function; `StreamWithRecordsTest` for the cases that need the records satellite bound), `StreamTerms*`, `StreamEconomics`, `StreamGas`, `StreamTxCap`, `StreamInvariant` |
| `stream/WorkRecords.sol` | [`stream/WorkRecords.t.sol`](stream/WorkRecords.t.sol), [`PreferredLocation.t.sol`](stream/PreferredLocation.t.sol); on the real stack [`integration/WorkRecordsStack.t.sol`](integration/WorkRecordsStack.t.sol), `RecordAmendments`, `SyncOnChainResume` |
| `stream/SpdxId.sol` | [`stream/SpdxId.t.sol`](stream/SpdxId.t.sol); the proof in `symbolic/` |
| `sales/EnglishAuction.sol`, `sales/EnglishAuctionLens.sol` | [`sales/auction/EnglishAuction.t.sol`](sales/auction/EnglishAuction.t.sol) (start, bids, settlement, credits, 96-bit arithmetic), `EnglishAuctionLens` (the lens and the fallback), `EnglishAuctionLensDifferential` (every moved view against the pre-lens build in [`legacy/`](sales/auction/legacy/), a test-only copy), `EnglishAuctionDisputes` (pause, withdrawals, resume, cancel, governed setters), `EnglishAuctionFederation`, `EnglishAuctionHostile`, `EnglishAuctionGas`, `invariant/`; on the real stack the `Auction*.t.sol` suites beside them |
| `sales/EnglishAuction.sol`, its pause windows | on the real stack: [`sales/PauseWindow.t.sol`](sales/PauseWindow.t.sol) |
| `sales/UniformClearing.sol` | [`sales/uniform/UniformClearing.t.sol`](sales/uniform/UniformClearing.t.sol) (the ladder domain, the clearing against a brute force over units and against the reference model's golden vectors in `fixtures/edition-auction/`, the quote, the cut step), `UniformClearingGas`; the proofs in `symbolic/` |
| `editions/Editions.sol`, `EditionRules.sol` | [`editions/`](editions/): `Editions`, `EditionRules`, `EditionsGasReport`, `Editions.invariant` |
| `curation/PackageRegistry.sol`, `Eip712CurationVerifier.sol` | [`curation/`](curation/): `PackageRegistry`, `PackageRegistryGas`, `PackageRegistryInvariant`, `Eip712CurationVerifier` |
| `identity/ArtistRegistry.sol` | [`identity/ArtistRegistry.t.sol`](identity/ArtistRegistry.t.sol), [`ArtistRegistryStanding.t.sol`](identity/ArtistRegistryStanding.t.sol) (the standing snapshot and its worst-case gas), `ContestedOverrides`, `RestrainedFlag`, `ArtistRegistry.invariant` |
| `identity/ConsolidationAdapter.sol` | [`identity/ConsolidationAdapter.t.sol`](identity/ConsolidationAdapter.t.sol); against the real contract in `fork/` |
| `records/StatementLog.sol` | [`records/`](records/): `StatementLog`, `StatementLogPolicy`, `StatementLogGolden`, `StatementLogOwnerRead`, `StatementLog.invariant` |
| `content/ContentStore.sol`, `DependencyRegistry.sol`, `Base64Validator.sol` | [`content/`](content/): `ContentStore`, `ContentStoreInvariant`, `DependencyRegistry`, `Base64Attest` |
| `content/Renderer.sol`, `JsonScan.sol`, `DataUri.sol`, `HtmlScript.sol` | [`content/renderer/`](content/renderer/): `Renderer` (metadata, escaping, license, disputes, editions, failing closed), `RendererRecords` (what a record may hold), `RendererMedia`, `RendererHostile`, `RendererGas`, `RendererOracles`, `JsonScan`, `TextHelpers` |
| `economics/*` | [`economics/`](economics/): one suite per contract (`AssetAllowlist`, `ClaimRouter`, `EconomicsResolver`, `ReleaseVerifier`, `RevenueEscrow`, `RevenuePayment`, `SplitFactory`, `SplitWallet`), `SplitMath` (`Splits`), `HostileTokens` (`TokenTransfer` and hostile ERC-20s), `GasCap`, `invariant/` |
| `entropy/VrfEntropyModule.sol` | [`entropy/`](entropy/): `VrfEntropyModule`, `VrfEntropyFuzz`, `VrfEntropyGovernance`, `VrfEntropyManaged`, `VrfEntropyInvariant` |
| `governance/*` | [`governance/`](governance/): `GuardianCancel`, `Suspension`, `Hardening` and `GovernanceInvariant` (`WorksAccessManager`), `GovernanceConfigurator`, `GenesisConfig`, `GenesisWiring` (`GovernanceConfig`), `BoundedParameter`, `Roles`; on the real stack `integration/GovernanceRecovery.t.sol` |
| `libraries/*` | [`libraries/`](libraries/): one suite per library; the proofs in `symbolic/` |
| `interfaces/*` | [`interfaces/`](interfaces/): pinned interface IDs, typehashes, `WorksHashing` |
| `script/` | [`deploy/`](deploy/): `DeployV1` (the deploy library), `DeployScript` (the deploy and Verify scripts and their guards), `GenesisFlows` |

## The tree

| Directory | What lives there | Layers |
| --- | --- | --- |
| `content/`, `curation/`, `economics/`, `editions/`, `entropy/`, `governance/`, `identity/`, `interfaces/`, `libraries/`, `records/`, `stream/` | The suites of one `src/` module each, with the module's base or fixture (`*Base.sol`, `*Fixture.sol`) and its invariant handlers (`*Handler.sol`) | unit, fuzz, invariant, gas |
| `sales/` | The sale adapters: `auction/` for the English auction; at the top, suites on the real stack through [`SalesStackBase.sol`](sales/SalesStackBase.sol) | unit, fuzz, invariant, gas, integration |
| `sales/auction/Auction*.t.sol` | The auction's regression suites on the real stack: currency freeze, dispute pause and cancel, payout failures, custody, federated tokens | integration |
| `*/invariant/` | Larger stateful campaigns, each test contract with its handler | invariant |
| `content/tooling/` | The Python uploader's and the CID helper's golden vectors against the real `ContentStore` | differential |
| `integration/` | The real, wired v1 stack, deployed by the deploy library with the committed genesis ([its README](integration/README.md)); the gas report and its harness; `invariant/` runs a campaign on the same stack | integration, gas, invariant |
| `deploy/` | The deploy library, the deploy and Verify scripts, genesis | integration |
| `fork/` | The stack against the real delegation contract, Permit2 and the VRF coordinator; skipped without an RPC URL ([its README](fork/README.md)) | fork |
| `symbolic/` | Halmos proofs (`check_*`), compiled only under the `symbolic` profile | symbolic |
| `helpers/` | Shared fixtures (`GovernanceFixture`), oracles (`TextOracles`, the frozen RC1 code in `Pr744Utf8` and `Pr744Escape`), the state-growth meter (`StateGrowth`, with its own test), revert data (`SignatureReverts`) and locator builders (`ContentAddresses`) | support |
| `mocks/` | Stand-ins and adversaries, by module ([below](#mocks)) | support |
| `fixtures/` | Byte-exact data: the CC0 legal code, Permit2's mainnet runtime code, and the oracle vectors from `tools/content/oracles.py` | support |

A file may hold more than one test contract when tests of one subject need different fixtures:
`Stream.t.sol` has `StreamTest` and `StreamWithRecordsTest`, `PauseWindow.t.sol` has
`PauseWindowTest` (the bare stack) and `PauseWindowSalesStackTest` (the sales package).

## Naming

**Files.** `<Contract>.t.sol` is a contract's main suite and `<Contract><Area>.t.sol` one area
of it (`EnglishAuctionDisputes`, `EnglishAuctionHostile`, `RendererRecords`,
`ArtistRegistryStanding`). Real-stack suites are named for the behaviour they pin
(`AuctionCurrencyFreeze`, `PauseWindow`). Invariant suites are `*Invariant.t.sol` or
`*.invariant.t.sol`, beside their `*Handler.sol`. Gas suites are `*Gas.t.sol`, `*GasCap.t.sol`
and `*GasReport.t.sol`.

**Tests.**

| Kind | Name | Example |
| --- | --- | --- |
| Unit | `test_<Function>_<Behaviour>` | `test_Cancel_RefusesAnOutcomeRecordedBeforeThePause` |
| Fuzz | `testFuzz_<Function>_<Property>` | `testFuzz_Bid_IncrementIsMaxOfShareAndFloor` |
| Invariant | `invariant_<Property>` | `invariant_BalanceCoversOwed` |
| Symbolic | `check_<property>`, in `test/symbolic` | `check_spdxId_matchesTheRuleForEveryInput` |
| Gas | `test_Gas_*`, `test_WorstCase_*`, `test_Budget_*` | `test_Gas_Table` |
| Scenario | a sentence, in `integration/`, `governance/` and `deploy/` | `test_ColdAdminRemovesAHotAdminAndAGuardianActingTogether` |
| Open finding | `test_Finding_*`, passing while the finding stands ([integration README](integration/README.md#findings)) | |

The function part matches the contract's function as the suite writes it: most suites capitalise
it (`test_Settle_`, `test_Bid_`), the Stream, WorkRecords and curation suites keep its case
(`test_mint_`, `test_openRecord_`, `test_isApproved_`). Some suites name an area instead of one
function (`test_Standing_`, `test_Relay_`, `test_HostileToken_`). A name never carries a review
ID; the ID goes on the NatSpec line above it:

```solidity
/// Regression: LIFECYCLE-4 (docs/security/internal-review-2026-10.md)
function test_Cancel_RefusesAnOutcomeRecordedBeforeThePause() public {
```

A finding raised in a pull request's review names that review instead, for example
`/// Regression: L-4 in the review of #21`.

## Mocks

A mock lives in `test/mocks/<module>/`, under the module of the tests that use it; a mock shared
by several modules lives under the module of the contract it stands in for (`StreamMock` in
`mocks/stream/`, `MockPermit2` in `mocks/sales/`). Each contract name means one behaviour: when
two consumers need different stand-ins for the same contract, the name says whose view it is
(`RendererWorkRecordsMock`, `EntropyPackageRegistryMock`, `CurationArtistRegistryMock`).

| Directory | Contents |
| --- | --- |
| [`mocks/stream/`](mocks/stream/) | `StreamMocks.sol`: Stream's dependencies (package and artist registries, economics, entropy, renderer, sale adapter, records, editions); `StreamMock.sol`: the minimal Stream stand-in |
| [`mocks/sales/`](mocks/sales/) | `SaleMocks.sol`: an edition-like mint target, escrow, allowlist and economics stand-ins, the federation registry, a faithful Permit2 and an EIP-2612 token, shared by the sale suites and the integration stack; `AuctionMocks.sol`: an ERC-721 mint target and hostile bidders for the auction; `LeanStartStack.sol`: the lean start-path model the auction's gas tests measure |
| [`mocks/economics/`](mocks/economics/) | `MockERC20` and the hostile tokens (fee on transfer, rebasing, no return, blocklists, gas burners), wallets and payees |
| [`mocks/content/`](mocks/content/) | What the renderer reads (`Renderer*Mock`) and hostile stores and satellites |
| [`mocks/editions/`](mocks/editions/) | Editions' dependencies, among them `EditionsStreamMock` (masters, settlement and the edition link, with faults), and hostile ERC-1155 receivers |
| [`mocks/identity/`](mocks/identity/) | The delegation contract's faithful reduction, a repriced variant, and the artist registry's dependencies |
| [`mocks/curation/`](mocks/curation/), [`mocks/entropy/`](mocks/entropy/), [`mocks/records/`](mocks/records/), [`mocks/governance/`](mocks/governance/) | Each module's dependencies and adversaries |
| [`mocks/libraries/`](mocks/libraries/) | Adversarial call targets (return bombs, gas burners, ERC-1271 wallets) for the bounded-call and signature libraries and their callers |
| [`mocks/integration/`](mocks/integration/) | A refusing wallet for the integration flows |

Stream has four kinds of stand-in, each for one job: the real contract (`StreamFixture`) for its
own suites; `StreamMock` for contracts that only read it (the renderer, the artist registry);
`EditionsStreamMock` for Editions, which needs masters that settle and links that misbehave; and
`LeanStream`, the start-path model of the auction's gas tests. Anything that crosses modules
runs on the real stack (`IntegrationBase`).

## What a file's place decides

- **CI.** The three "Tests" jobs split `forge test` by name: `--no-match-test ^invariant` (unit,
  fuzz and integration), the `EconomicsInvariant*` contract's invariants, and every other
  invariant ([`ci.yml`](../.github/workflows/ci.yml)). A new invariant must be named
  `invariant_*`, or it runs with the unit tests; an economics invariant belongs in
  `EconomicsInvariantTest`, or it runs with the others.
- **Mutation testing.** [`tools/mutation.py`](../tools/mutation.py) first runs a mutant of
  `src/<module>/` against `test/<module>/` (governance also against `deploy/`, the libraries and
  interfaces against each other and `helpers/`), then reruns every survivor against the whole
  suite. A test placed in its module's directory kills mutants in the first, fast pass.
- **Coverage** counts every test, wherever it lives.
