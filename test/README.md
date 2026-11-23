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
  review point to the report; earlier IDs name the
  pull request whose review raised them.

  ```bash
  grep -rn "Regression: MARKET-2" test/             # every test for MARKET-2
  ```

- **For a rule of the specification:** every rule row in [`docs/spec/`](../docs/spec/README.md)
  (`AUC-3`, `WS-17`, ...) cites the tests that pin it. `tools/check_rules.py` requires every
  rule to cite at least one test that exists (a rule without one must be listed in
  `tools/rules-uncovered.txt`), and every invariant in
  [`docs/audit/invariants.md`](../docs/audit/invariants.md) to name its function;
  `tools/check_docs_facts.py` checks every test name any page cites.
- **For an end-to-end flow:** [`test/integration/`](integration/README.md) lists the flows on the
  real, wired stack; [`test/fork/`](fork/README.md) runs them against the real external systems.

### Contracts and their suites

| `src/` | Tests |
| --- | --- |
| `core/` (`Stream6529`, `StreamEditions6529`, `StreamDirectory6529`, `StreamWorkFacts6529`, `Modules`) | [`core/`](core/): `Stream6529`, `StreamSettings`, `StreamHostile`, `StreamEditions6529`, `EditionsHostile`, `EditionsInvariant` with `EditionsHandler`, `StreamDirectory6529`, `Modules`, `StreamWorkFacts6529`, `WorkFactsPorted`, `WorkFactsRules`, `WorkFactsInvariant`, `CoreSeam` (the seams between the tokens and their modules), `CoreTokenFixes` and `WorkFactsFixes` (review fixes); the proofs `symbolic/StreamCoreSymbolic`, `EditionsCoreSymbolic`, `WorkFactsSymbolic`, `ModulesSymbolic`; the harnesses `medusa/StreamCoreMedusa`, `WorkFactsMedusa`; the replays `replay/LogReplayStream`, `LogReplayEditions`, `LogReplayWorkFacts` |
| `records/WorkRules.sol`, `stream/WorkDelivery.sol`, `stream/SpdxId.sol` | [`records/`](records/): `WorkRules`, `WorkRulesPorted`, `WorkRulesHostile`, `WorkRulesRules`, `WorkRulesMetadata` (ERC-4906 on every visible change); [`stream/`](stream/): `WorkDelivery`, `WorkDeliveryPorted`, `WorkDeliveryRules`, `PreferredLocation`, `SpdxId`; on the real stack `integration/WorkRecordsStackPorted`, `RecordLifecycle`, `SyncOnChainResumePorted` |
| `terms/StreamTerms.sol` | [`terms/`](terms/): `StreamTerms`, `StreamTermsFixes`, `StreamTermsRules`; on the real stack `integration/LoweredShareRoyalties` |
| `sales/EnglishAuction.sol`, `SaleStarter.sol` | [`sales/auction/`](sales/auction/): `EnglishAuction`, `EnglishAuctionCredits`, `EnglishAuctionDisputes`, `EnglishAuctionIndependent`, `EnglishAuctionIndependentFixes`, `EnglishAuctionHostile`, `EnglishAuctionPorted`, `EnglishAuctionEndToEnd`, `EnglishAuctionRules`, `EnglishAuctionDisputeRules`; [`sales/PauseWindow.t.sol`](sales/PauseWindow.t.sol) |
| `sales/UniformEditionAuction.sol`, `UniformEditionAuctionLens.sol`, `independent/IndependentEditionAuction*.sol` | [`sales/edition/`](sales/edition/): `UniformEditionAuction`, `UniformEditionAuctionLens`, `UniformEditionAuctionSettlement`, `UniformEditionAuctionWindow`, `UniformEditionAuctionAbandon`, `UniformEditionAuctionRestart`, `UniformEditionAuctionAdopt`, `UniformEditionAuctionHoldings`, `UniformEditionAuctionHostile`, `UniformEditionAuctionVectors`, `UniformEditionAuctionGasRule`, `UniformEditionAuctionPorted`, `SweepSkipRegression`, `EditionAuctionFixes`, `IndependentEditionAuction`, `IndependentEditionAuctionFixes` |
| `sales/UniformClearing.sol`, `interfaces/types/StepLadder.sol` | [`sales/uniform/`](sales/uniform/): `UniformClearing`, `UniformClearingGas`; [`interfaces/StepLadder.t.sol`](interfaces/StepLadder.t.sol); the proofs in `symbolic/UniformClearingSymbolic` |
| `curation/PackageRegistry.sol`, `Eip712CurationVerifier.sol` | [`curation/`](curation/): `PackageRegistry`, `PackageRegistryFixes`, `PackageRegistryGas`, `PackageRegistryInvariant`, `Eip712CurationVerifier`, `CurationSignerInvariant`, `ConsolidatedAccounts`; `symbolic/CurationEpochSymbolic` |
| `identity/Accounts.sol`, `ConsolidationAdapter.sol` | [`identity/`](identity/): `Accounts`, `AccountsFreeze`, `FreezeAndContest`, `AccountsResolvers`, `AccountsWiring`, `AccountsGasRule`, `Accounts.invariant`, `SignatureAgility`, `ConsolidationAdapter`; on the real stack `integration/IdentityRecovery`, `AccountsSuccessor`; against the real delegation contract in `fork/` |
| `records/StatementLog.sol` | [`records/`](records/): `StatementLog`, `StatementLogPolicy`, `StatementLogGolden`, `StatementLogOwnerRead`, `StatementLogCoreStream`, `StatementLogGasRule`, `StatementLog.invariant`; `symbolic/StatementLogSymbolic`, `medusa/LogMedusa`, `replay/LogReplayStatements` |
| `content/ContentStore.sol`, `DependencyRegistry.sol`, `Base64Validator.sol` | [`content/`](content/): `ContentStore`, `ContentStoreAttestComplete`, `ContentStoreCompletenessGas`, `ContentStorePermanence`, `ContentStoreInvariant`, `Base64Attest`, `DependencyRegistry`; `symbolic/Base64ValidatorSymbolic`, `replay/LogReplayContent` |
| `content/Renderer.sol`, `JsonScan.sol`, `DataUri.sol`, `HtmlScript.sol` | [`content/renderer/`](content/renderer/): `Renderer`, `RendererCore`, `RendererRecords`, `RendererMedia`, `RendererHostile`, `RendererGas`, `RendererOracles`, `JsonScan`, `TextHelpers`; `symbolic/TextSymbolic`; the budget on the real stack in `integration/TokenUriBudget` |
| `economics/*` | [`economics/`](economics/): one suite per contract (`AssetAllowlist`, `EconomicsResolver`, `ClaimRouter`, `GovernedVault*`, `RevenueEscrow*`, `RevenuePayment`, `SplitFactory`, `SplitVault`, `SplitWallet`, `SplitMath`), `HostileTokens`, `LedgerEdgeCases`, `NetworkShare`, `GasCap`, `SplitLedgerStress`, `SplitLedgerUnclaimedPeriod`, `SplitLedgerMarkLayout`, `SplitsLowerBoundDifferential`, `SplitVaultDifferential` (the 66 bytes against `SplitVaultReference`), and [`invariant/`](economics/invariant/); `symbolic/LedgerSymbolic`, `EscrowSymbolic`, `SplitsSymbolic`; `medusa/LedgerMedusa`; `replay/LogReplayLedger` |
| `independent/*` | [`independent/`](independent/): `IndependentStream6529`, `IndependentStreamEditions6529`, `IndependentStreamDeployer`, `IndependentHostile`, `IndependentFlow`, `IndependentStreamRegistryGovernance`, `IndependentStreamRegistryListing`, `IndependentStreamRegistryPolicy`, `IndependentStreamRegistryFixes`, `IndependentStreamRegistryRules`, `IndependentStreamRegistryTemplateEvents`, and [`invariant/`](independent/invariant/); `symbolic/IndependentSymbolic`, `replay/LogReplayIndependent`; on the real stack `integration/IndependentPair`, `IndependentEditionSale` |
| `entropy/VrfEntropyModule.sol` | [`entropy/`](entropy/): `VrfEntropyModule`, `VrfEntropyManaged`, `VrfEntropyIndependent` (the paid draw of an Independent Stream contract), `VrfEntropyGovernance`, `VrfEntropySetters`, `VrfEntropyFuzz`, `VrfEntropyInvariant`; on the real stack `integration/VrfWork` |
| `governance/*` | [`governance/`](governance/): `NetworkAndBrake`, `GovernanceInvariant`, `GovernanceConfigurator`, `Roles`, `BoundedParameter`, `CoreNetwork`, `CoreRoleMap`, `RoleMapComplete`, `GenesisConfig*`, `GenesisWiring*` |
| `libraries/*` | [`libraries/`](libraries/): one suite per library; the proofs in `symbolic/` |
| `interfaces/*` | [`interfaces/`](interfaces/): pinned interface IDs, typehashes, `WorksHashing` |
| `script/` | [`deploy/`](deploy/): `DeployCore` (the deploy library and the whole-stack readback), `DeployCoreSafety` (the one-call factory and the runtime-code comparison) |

## The tree

| Directory | What lives there | Layers |
| --- | --- | --- |
| `content/`, `core/`, `curation/`, `economics/`, `entropy/`, `independent/`, `governance/`, `identity/`, `interfaces/`, `libraries/`, `records/`, `stream/`, `terms/` | The suites of one `src/` module each, with the module's base or fixture (`*Base.sol`, `*Fixture.sol`) and its invariant handlers (`*Handler.sol`) | unit, fuzz, invariant, gas |
| `sales/` | The two sale adapters: `auction/` for the English auction and `edition/` for the edition auction; `uniform/` for the clearing library; at the top, `PauseWindow` | unit, fuzz, invariant, gas, integration |
| `*/invariant/` | Larger stateful campaigns, each test contract with its handler | invariant |
| `integration/` | The real, wired v1 stack, deployed by the deploy library with the committed genesis ([its README](integration/README.md)); the gas report and its harness; `invariant/` runs a campaign on the same stack | integration, gas, invariant |
| `deploy/` | The deploy library, the deploy and Verify scripts, genesis | integration |
| `fork/` | The stack against the real delegation contract, Permit2 and the VRF coordinator, and Safe v1.4.1 wallets in the network's, an artist's and holders' roles (`Safe*`); skipped without an RPC URL ([its README](fork/README.md)) | fork |
| `symbolic/` | Halmos proofs (`check_*`), compiled only under the `symbolic` profile: the pure libraries, and the permanent contracts' state rules (`LedgerSymbolic`, `EscrowSymbolic`, `StatementLogSymbolic`, `StreamCoreSymbolic`, `EditionsCoreSymbolic`, `WorkFactsSymbolic`, `ModulesSymbolic`, `IndependentSymbolic`, with stand-ins named `Sym*`) | symbolic |
| `medusa/` | Cheatcode-free harnesses with their own model of the rules (`LedgerMedusa`, `StreamCoreMedusa`, `LogMedusa`, `WorkFactsMedusa`, on `MedusaBase`), run by Medusa (`medusa.json`) and by a Forge runner each (`*Medusa.t.sol`); `MedusaClock` is the Forge runner's clock | second fuzzer |
| `replay/` | Reference indexers that rebuild each permanent contract from its logs alone (`*Indexer.sol`), the replay suites (`LogReplay*.t.sol`) and the real-data vectors (`RealVectors.t.sol`) | replay, real data |
| `helpers/` | Shared fixtures (`GovernanceFixture`), `HandlerReach` (the handler self-test driver: each action's state diff against its expectation), oracles (`TextOracles`, the frozen RC1 code in `Pr744Utf8` and `Pr744Escape`, and `UniformClearingReference`, the edition auction's brute-force clearing and FIFO fill, with its own test), the state-growth meter (`StateGrowth`, with its own test), the gas-rule stress harness (`GasRule`: a `Burner` that makes a dependency cost a multiple of a base, and `GasRuleAssertions`), revert data (`SignatureReverts`) and locator builders (`ContentAddresses`) | support |
| `mocks/` | Stand-ins and adversaries, by module ([below](#mocks)) | support |
| `fixtures/` | Byte-exact data: the CC0 legal code, Permit2's mainnet runtime code, the oracle vectors from `tools/content/oracles.py`, and in `real/` the 6529 Network Museum record and the event topics the replay suites read (`tools/make_vectors.py`) | support |
| `snapshots/` | Generated JSON, not Solidity: `abi/<Contract>.json` (every function, event and error with its selector or topic) for every `src/` contract and library, and `storage/<Contract>.json` (every state variable and stored struct member) for every contract; rewritten only by `python tools/check_snapshots.py --update` | interface |

A file may hold more than one test contract when tests of one subject need different fixtures.

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
| Open finding | `test_Finding_*`, passing while the finding stands ([integration README](integration/README.md#open-findings)) | |

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
by several modules lives under the module of the contract it stands in for. Each contract name
means one behaviour: when two consumers need different stand-ins for the same contract, the name
says whose view it is (`CurationArtistRegistryMock`).

| Directory | Contents |
| --- | --- |
| [`mocks/core/`](mocks/core/) | `CoreFixture.sol` (the tokens with their modules), `CoreMocks.sol` and `StreamCoreMocks.sol`: stand-ins for the modules, minters and gates the tokens call |
| [`mocks/sales/`](mocks/sales/) | `SaleMocks.sol`: mint targets, escrow, allowlist and economics stand-ins shared by the sale suites; `EnglishAuctionRulesMocks.sol`: a mint policy with settable terms and a token that reports the auction's receiver answer |
| [`mocks/economics/`](mocks/economics/) | `MockERC20` and the hostile tokens (fee on transfer, rebasing, no return, blocklists), wallets and payees |
| [`mocks/content/`](mocks/content/) | What the renderer reads, and hostile stores and chunk sources |
| [`mocks/editions/`](mocks/editions/) | Stand-ins the mutation tests of the editions code use |
| [`mocks/identity/`](mocks/identity/) | The delegation contract's faithful reduction, the accounts module's dependencies, and `ReadThroughAccounts`, a successor accounts module that reads through the genesis one |
| [`mocks/curation/`](mocks/curation/), [`mocks/entropy/`](mocks/entropy/), [`mocks/records/`](mocks/records/), [`mocks/governance/`](mocks/governance/) | Each module's dependencies and adversaries |
| [`mocks/libraries/`](mocks/libraries/) | Adversarial call targets (return bombs, gas burners, ERC-1271 wallets) for the bounded-call and signature libraries and their callers |

## What a file's place decides

- **CI.** The four "Tests" jobs split `forge test` by name: `--no-match-test ^invariant` (unit,
  fuzz, integration, replay and the Medusa harnesses' self-tests), the `EconomicsInvariant*`
  contract's invariants, the four campaigns of the November 2026 testing build
  (`WorkDeliveryInvariant`, `GovernedVaultInvariant`, `IndependentStateInvariant`,
  `CurationSignerInvariant`), and every other invariant, the Medusa harnesses' Forge runners
  included ([`ci.yml`](../.github/workflows/ci.yml)). A new invariant must be named
  `invariant_*`, or it runs with the unit tests; an economics invariant belongs in
  `EconomicsInvariantTest`, or it runs with the others.
- **Mutation testing.** [`tools/mutation.py`](../tools/mutation.py) first runs a mutant of
  `src/<module>/` against `test/<module>/` (governance also against `deploy/`, the libraries and
  interfaces against each other and `helpers/`), then reruns every survivor against the whole
  suite. A test placed in its module's directory kills mutants in the first, fast pass.
- **Coverage** counts every test, wherever it lives.
