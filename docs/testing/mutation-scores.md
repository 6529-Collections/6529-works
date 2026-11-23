# Mutation scores

The kill rate of every `src/` contract after the plain-core restructuring
([ADR 0010](../adr/0010-plain-permanent-core.md)), measured on 23 November 2026, with the
survivors of the permanent contracts and of the modules that hold money or authorise mints
triaged one by one. The floors in [`tools/mutation-floors.json`](../../tools/mutation-floors.json)
come from this page. How a campaign works and how to run one is in the
[testing guide](README.md#mutation-testing); the campaigns on the earlier contracts are in the
[historical baseline](mutation-baseline.md).

## How it was measured

- **Code.** Commit 149ac3c8, the plain core before its last review fixes. Line numbers below
  are that commit's. The fixes merged afterwards (#119) changed six of the measured files:
  `Modules` (a zero minter is refused), `PackageRegistry` (`preview`), `StreamTerms`
  (`lowerFeeShare`), `IndependentEditionAuction` (`settle`), `IndependentStreamEditions6529` and
  `IndependentStreamMembership`. Their scores were not measured again: each floor stays as
  measured, two points under, until the weekly run measures the merged code. Every test added
  here passes on the merged code.
- **Three small files measured with the fixed tool.** `IWorkPowers.sol`, `CoreTypes.sol` and
  `SaleTypes.sol` hold only libraries not named like their file; their rows are whole-file runs
  of the tool after the fix described below.
- **Tools.** slither-analyzer 0.11.6 (`slither-mutate`) through `tools/mutation.py`, Foundry
  1.7.1, solc 0.8.37, tests under the `lite` profile; three rented 96-core machines for about 3.7
  hours each (485 parts, 203 hours of part time in all).
- **Mutants.** The tool's own mutants per file: every operator for most files, the reduced
  set (statements, arithmetic, logical and unary operators, two relational replacements per
  comparison, `if` conditions) for the files in `SPLIT_FILES`, and the constant rule. To fit
  the night, each file's groups ran as parts of about 45 mutants in separate checkouts, a
  part taking every n-th mutant of each operator. slither-mutate skips the lines whose revert
  or comment mutant survived earlier in the same run, and a part knows only its own
  survivors. So a few more mutants ran here than one whole-file run makes, which lowers a
  rate if anything. And where a revert mutant survived in a statements part, that part's
  list of comment mutants moved up by one from there on, so some comment mutants ran in two
  parts and others in none. That happened in seven files; two were measured again
  ([The statements parts](#the-statements-parts)).
- **Every contract of a file.** slither-mutate mutates one contract per file, the one named
  like the file. Three base contracts declared beside their concrete contract had therefore
  never been mutated: `ModuleSlots` (in `Modules.sol`), `UniformEditionAuctionBase` and
  `UniformEditionAuctionLensBase`, which hold nearly all the code of their files. This campaign
  ran them by name, and `tools/mutation.py` now runs every contract a file declares.
- **Two stages.** Each mutant ran its module's tests with `--fail-fast`; each survivor then
  ran the whole suite (2,998 tests passing on the unmutated code, 7 skipped).
- **Timeouts.** A mutant whose tests run past 20 minutes counts as killed, as slither-mutate
  counts it. The table lists how many there were.
- **New tests.** Each test written for a survivor was run on the same machines against the
  real code (it passes) and against its mutant (it fails).

## Kill rate per contract

"Score" is the campaign's rate; "final" adds the survivors a new test kills. A floor is the
final score minus two points, rounded down.

### Permanent contracts

<!-- generated:scores tier=1 -->

| Contract | Mutants | Killed | Survived | Timed out | Score | Killed by new tests | Final | Floor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `src/content/ContentStore.sol` | 747 | 699 | 48 | 0 | 93.6% | 2 | 93.8% | 91 (was 92) |
| `src/core/EditionsBase.sol` | 267 | 262 | 5 | 0 | 98.1% | 5 | 100.0% | 98 (was 93) |
| `src/core/Modules.sol` | 209 | 205 | 4 | 0 | 98.1% | 1 | 98.6% | 96 (was 94) |
| `src/core/Stream6529.sol` | 48 | 44 | 4 | 0 | 91.7% | 0 | 91.7% | 89 (was 90) |
| `src/core/StreamBase.sol` | 327 | 317 | 10 | 0 | 96.9% | 2 | 97.6% | 95 (was 90) |
| `src/core/StreamDirectory6529.sol` | 46 | 42 | 4 | 0 | 91.3% | 4 | 100.0% | 98 (was 94) |
| `src/core/StreamEditions6529.sol` | 46 | 40 | 6 | 0 | 87.0% | 2 | 91.3% | 89 (was 93) |
| `src/core/StreamWorkFacts6529.sol` | 299 | 283 | 16 | 0 | 94.6% | 2 | 95.3% | 93 (was 89) |
| `src/economics/RevenueEscrow.sol` | 412 | 403 | 9 | 0 | 97.8% | 1 | 98.1% | 96 |
| `src/economics/SplitLedger.sol` | 626 | 606 | 20 | 0 | 96.8% | 0 | 96.8% | 94 |
| `src/economics/Splits.sol` | 155 | 145 | 10 | 0 | 93.5% | 0 | 93.5% | 91 (was 88) |
| `src/independent/IndependentStream6529.sol` | 179 | 165 | 14 | 0 | 92.2% | 14 | 100.0% | 98 (was 92) |
| `src/independent/IndependentStreamEditions6529.sol` | 35 | 33 | 2 | 0 | 94.3% | 1 | 97.1% | 95 |
| `src/records/StatementLog.sol` | 496 | 472 | 24 | 0 | 95.2% | 0 | 95.2% | 93 |
| **Total** | **3892** | **3716** | **176** | **0** | **95.5%** | **34** | **96.4%** | |

<!-- /generated -->

### Modules that hold money or authorise mints

<!-- generated:scores tier=2 -->

| Contract | Mutants | Killed | Survived | Timed out | Score | Killed by new tests | Final | Floor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `src/curation/PackageRegistry.sol` | 576 | 532 | 44 | 0 | 92.4% | 9 | 93.9% | 91 (was 94) |
| `src/identity/Accounts.sol` | 562 | 532 | 30 | 0 | 94.7% | 13 | 97.0% | 94 |
| `src/independent/IndependentEditionAuction.sol` | 35 | 29 | 6 | 0 | 82.9% | 5 | 97.1% | 95 (was 92) |
| `src/independent/IndependentStreamRegistry.sol` | 941 | 832 | 109 | 0 | 88.4% | 37 | 92.3% | 90 (was 89) |
| `src/records/WorkRules.sol` | 373 | 353 | 20 | 0 | 94.6% | 12 | 97.9% | 95 (was 89) |
| `src/sales/EnglishAuction.sol` | 683 | 602 | 81 | 0 | 88.1% | 60 | 96.9% | 94 (was 90) |
| `src/sales/UniformClearing.sol` | 278 | 276 | 2 | 0 | 99.3% | 0 | 99.3% | 97 (was 93) |
| `src/sales/UniformEditionAuction.sol` | 1113 | 1019 | 94 | 0 | 91.6% | 27 | 94.0% (measured again) | 91 |
| `src/terms/StreamTerms.sol` | 170 | 160 | 10 | 0 | 94.1% | 9 | 99.4% | 97 (was 90) |
| **Total** | **4731** | **4335** | **396** | **0** | **91.6%** | **172** | **95.3%** | |

<!-- /generated -->

### Everything else

<!-- generated:scores tier=3 -->

| Contract | Mutants | Killed | Survived | Timed out | Score | Killed by new tests | Final | Floor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `src/content/Base64Validator.sol` | 16 | 13 | 3 | 0 | 81.2% | 0 | 81.2% | 79 (was 74) |
| `src/content/DataUri.sol` | 43 | 41 | 2 | 0 | 95.3% | 0 | 95.3% | 93 |
| `src/content/DependencyRegistry.sol` | 119 | 109 | 10 | 0 | 91.6% | 0 | 91.6% | 89 (was 85) |
| `src/content/HtmlScript.sol` | 48 | 42 | 6 | 0 | 87.5% | 0 | 87.5% | 85 |
| `src/content/JsonScan.sol` | 421 | 347 | 74 | 0 | 82.4% | 0 | 82.4% | 80 (was 79) |
| `src/content/Renderer.sol` | 874 | 775 | 99 | 0 | 88.7% | 0 | 88.7% | 86 (was 84) |
| `src/curation/Eip712CurationVerifier.sol` | 165 | 161 | 4 | 0 | 97.6% | 0 | 97.6% | 95 (was 94) |
| `src/economics/AssetAllowlist.sol` | 88 | 80 | 8 | 0 | 90.9% | 0 | 90.9% | 88 (was 91) |
| `src/economics/ClaimRouter.sol` | 261 | 230 | 31 | 0 | 88.1% | 0 | 88.1% | 86 |
| `src/economics/EconomicsResolver.sol` | 267 | 247 | 20 | 0 | 92.5% | 0 | 92.5% | 90 |
| `src/economics/GovernedVault.sol` | 126 | 123 | 3 | 0 | 97.6% | 0 | 97.6% | 95 |
| `src/economics/RevenuePayment.sol` | 29 | 26 | 3 | 0 | 89.7% | 0 | 89.7% | 87 (was 84) |
| `src/economics/SplitVault.sol` | 0 | 0 | 0 | 0 | n/a | 0 | n/a | none |
| `src/economics/TokenTransfer.sol` | 153 | 130 | 23 | 0 | 85.0% | 0 | 85.0% | 82 (was 90) |
| `src/editions/EditionRules.sol` | 16 | 12 | 4 | 0 | 75.0% | 0 | 75.0% | 73 (was 85) |
| `src/entropy/VrfEntropyModule.sol` | 589 | 537 | 52 | 0 | 91.2% | 0 | 91.2% | 89 (was 90) |
| `src/governance/BoundedParameter.sol` | 57 | 57 | 0 | 0 | 100.0% | 0 | 100.0% | 98 (was 94) |
| `src/governance/GovernanceConfig.sol` | 307 | 259 | 48 | 0 | 84.4% | 0 | 84.4% | 82 (was 83) |
| `src/governance/GovernanceConfigurator.sol` | 22 | 22 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |
| `src/governance/Roles.sol` | 250 | 233 | 17 | 0 | 93.2% | 0 | 93.2% | 91 |
| `src/governance/WorksAccessManager.sol` | 126 | 122 | 4 | 0 | 96.8% | 0 | 96.8% | 94 |
| `src/identity/ConsolidationAdapter.sol` | 75 | 56 | 19 | 0 | 74.7% | 0 | 74.7% | 72 (was 83) |
| `src/independent/IndependentEditionAuctionLens.sol` | 48 | 38 | 10 | 0 | 79.2% | 0 | 79.2% | 77 (was 83) |
| `src/independent/IndependentStreamDeployer.sol` | 100 | 94 | 6 | 0 | 94.0% | 0 | 94.0% | 92 |
| `src/independent/IndependentStreamMembership.sol` | 65 | 61 | 4 | 0 | 93.8% | 0 | 93.8% | 91 (was 92) |
| `src/interfaces/IWorkPowers.sol` | 16 | 12 | 4 | 0 | 75.0% | 0 | 75.0% | 73 (was 98) |
| `src/interfaces/core/CoreTypes.sol` | 12 | 11 | 1 | 0 | 91.7% | 0 | 91.7% | 89 |
| `src/interfaces/types/HashRef.sol` | 6 | 6 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |
| `src/interfaces/types/Limits.sol` | 36 | 27 | 9 | 0 | 75.0% | 0 | 75.0% | 73 |
| `src/interfaces/types/SaleTypes.sol` | 4 | 4 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |
| `src/interfaces/types/StatementKinds.sol` | 15 | 15 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |
| `src/interfaces/types/StepLadder.sol` | 216 | 205 | 11 | 0 | 94.9% | 0 | 94.9% | 92 |
| `src/interfaces/types/Typehashes.sol` | 26 | 26 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |
| `src/interfaces/types/WorksHashing.sol` | 47 | 43 | 4 | 0 | 91.5% | 0 | 91.5% | 89 (was 87) |
| `src/libraries/AgedCredits.sol` | 24 | 22 | 2 | 0 | 91.7% | 0 | 91.7% | 89 (was 90) |
| `src/libraries/BoundedCall.sol` | 282 | 261 | 21 | 0 | 92.6% | 0 | 92.6% | 90 (was 91) |
| `src/libraries/DelegatedEOA.sol` | 47 | 41 | 6 | 0 | 87.2% | 0 | 87.2% | 85 |
| `src/libraries/Dependency.sol` | 42 | 42 | 0 | 0 | 100.0% | 0 | 100.0% | 98 (was 95) |
| `src/libraries/JsonEscape.sol` | 90 | 76 | 14 | 0 | 84.4% | 0 | 84.4% | 82 (was 79) |
| `src/libraries/ProtocolContracts.sol` | 5 | 5 | 0 | 0 | 100.0% | 0 | 100.0% | 98 |
| `src/libraries/SSTORE2.sol` | 125 | 117 | 8 | 0 | 93.6% | 0 | 93.6% | 91 |
| `src/libraries/SignatureVerifier.sol` | 88 | 75 | 13 | 0 | 85.2% | 0 | 85.2% | 83 (was 80) |
| `src/libraries/Utf8.sol` | 118 | 102 | 16 | 0 | 86.4% | 0 | 86.4% | 84 |
| `src/sales/SaleStarter.sol` | 20 | 19 | 1 | 0 | 95.0% | 0 | 95.0% | 93 (was 98) |
| `src/sales/UniformEditionAuctionLens.sol` | 1134 | 994 | 140 | 0 | 87.7% | 0 | 88.0% (measured again) | 85 (was 87) |
| `src/stream/SpdxId.sol` | 114 | 106 | 8 | 0 | 93.0% | 0 | 93.0% | 90 |
| `src/stream/WorkDelivery.sol` | 567 | 496 | 71 | 0 | 87.5% | 0 | 87.5% | 85 (was 88) |
| **Total** | **7299** | **6520** | **779** | **0** | **89.3%** | **0** | **89.4%** | |

<!-- /generated -->

A file with no mutants (constants of other types, or declarations only) needs no floor.

### The statements parts

The statements group (revert a body, comment out a statement) was cut into parts by position
in each operator's list. slither-mutate makes no comment mutant on a line whose revert mutant
survived, so a surviving revert mutant shortened the comment list of its own part only, and
the parts no longer fitted together: some comment mutants ran twice and others not at all.
The table counts them from the campaign's own results, before compiling (slither-mutate
drops the mutants that do not compile, so fewer than these were tested). In every other
file whose statements ran in parts no surviving revert mutant moved a list, and the parts
are exactly the whole group.

| Contract | Comment mutants of a whole run | Ran twice | Not run | Ran on a line a whole run skips |
| --- | ---: | ---: | ---: | ---: |
| `src/curation/PackageRegistry.sol` | 288 | 36 | 36 | 1 |
| `src/independent/IndependentEditionAuctionLens.sol` | 8 | 2 | 3 | 11 |
| `src/independent/IndependentStream6529.sol` | 55 | 0 | 0 | 2 |
| `src/libraries/BoundedCall.sol` | 127 | 17 | 18 | 2 |
| `src/sales/EnglishAuction.sol` | 368 | 22 | 21 | 2 |
| `src/sales/UniformEditionAuction.sol` | 572 | 30 | 30 | 2 |
| `src/sales/UniformEditionAuctionLens.sol` | 618 | 171 | 167 | 2 |

`tools/mutation.py` now cuts a statements group by source line: a line's revert and comment
mutants run in the same part, so the parts together are the mutants of the whole group
whatever survives. The two files the tool itself runs in parts were measured again that way,
every group, at commit a39245e3 (the contracts as merged, with the tests added here):

| Contract | Mutants | Killed | Survived | Timed out | Score | Floor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `src/sales/UniformEditionAuction.sol` | 1112 | 1045 | 67 | 0 | 94.0% | 91 |
| `src/sales/UniformEditionAuctionLens.sol` | 1113 | 979 | 134 | 0 | 88.0% | 85 |

These figures are the two files' "final" and floor in the tables above; the other columns of
their rows stay as the campaign measured them. Two survivors of `UniformEditionAuctionLens`
were not run against the whole suite before their shard's time budget ended; they count as
survived, so that score is a lower bound.

The other five files in this section's first table were not measured again: their rows are the
campaign's, with comment mutants that are a slightly different sample of the same code, and
a mutant their parts never ran may yet survive (one did in `UniformEditionAuction`, below).
The tool runs the statements group of each of them as one whole run, so the weekly run
measures them without this effect.

## The tests added

<!-- generated:tests -->

119 test functions, each shown to fail on the mutants it is listed with:

- `test/content/ContentStorePermanence.t.sol`
  - `test_Source_ARangeCheckKeepsMemoryAtOneChunk` (ContentStore L584)
  - `test_Source_TheStoreItselfIsCheckedWithoutACall` (ContentStore L226)
- `test/core/Directory.t.sol`
  - `test_SupportsInterface_NothingBelowTheSupportedIds` (StreamDirectory6529 L66)
- `test/core/Editions.t.sol`
  - `test_Create_AcceptsARateOfExactlyTheDenominatorAndNotOneMore` (EditionsBase L75)
  - `test_EmitMetadataUpdate_ADescendingRangeIsLoggedAsARange` (EditionsBase L174)
  - `test_SetRoyalty_AZeroReceiverWithAZeroRateClearsTheRoyalty` (EditionsBase L160)
  - `test_SupportsInterface_NothingBelowTheSupportedIds` (EditionsBase L234, StreamEditions6529 L46)
- `test/core/Modules.t.sol`
  - `test_RemoveMinter_AgainBeforeTheNewWaitStillCountsAsOnceActive (also test_RecordPrimarySale_AMinterRemovedTwiceStillSettlesItsSales in test/core/Stream.t.sol)` (Modules L143)
- `test/core/Stream.t.sol`
  - `test_EmitMetadataUpdate_ADescendingRangeIsLoggedAsARange` (StreamBase L229)
  - `test_SetRoyalty_AcceptsARateOfExactlyTheDenominator` (StreamBase L203)
- `test/core/WorkFacts.t.sol`
  - `test_MarkOnChainComplete_TheTokenLogsAMetadataUpdate` (StreamWorkFacts6529 L110)
- `test/core/WorkFactsFixes.t.sol`
  - `test_Pin_TwentyThreeBytesAboveTheDesignatorPrefix` (StreamWorkFacts6529 L233)
- `test/curation/PackageRegistry.t.sol`
  - `test_bindStream_refusesALowerOrHigherCc0Text` (PackageRegistry L180)
  - `test_constructor_rejectsBadEconomics` (PackageRegistry L166)
  - `test_invalidItem_cc0TextBelowOrAboveTheDeployments` (PackageRegistry L522)
  - `test_preview_anArtistItemQuotesItsSeed` (PackageRegistry L340, PackageRegistry L341)
  - `test_preview_nonCc0LicencesMayNameAnyText` (PackageRegistry L522)
  - `test_preview_requestLengthBoundary` (PackageRegistry L489)
  - `test_revokeMove_first255NoncesShareOneSlot` (PackageRegistry L92)
- `test/economics/RevenueEscrow.t.sol`
  - `test_Recover_ReentryIsBlocked` (RevenueEscrow L147)
- `test/identity/Accounts.t.sol`
  - `test_OwnChange_CurrentBehaviour_APayoutAnsweringTrueToEveryProbeIsAccepted` (Accounts L663)
  - `test_OwnChange_TheAccountStillActsWhileItsOwnChangeWaits` (Accounts L695)
  - `test_Register_LogsTheNewAccount` (Accounts L569)
  - `test_Register_RefusesARootAPendingChangeReserves` (Accounts L564)
- `test/identity/AccountsResolvers.t.sol`
  - `test_IsArtist_AMasterAtTheHighestAddressCounts` (Accounts L426)
  - `test_IsArtist_AnEditionAnswerThatIsNotOneCleanAddressIsNo` (Accounts L424, Accounts L426, Accounts L427)
  - `test_IsArtist_TheHighestArtistIdCounts` (Accounts L578)
  - `test_RegisterIndependent_RefusesAnExpiredAcceptance` (Accounts L197)
- `test/independent/IndependentEditionAuctionMutation.t.sol`
  - `test_Raise_MovesTheBidUpForTheDifference` (IndependentEditionAuction L70, IndependentEditionAuction L71)
  - `test_Settle_AClearingThatPaidStandsThroughADelisting` (IndependentEditionAuction L82)
  - `test_Settle_AListedSalesScanFinishesOnALaterCall` (IndependentEditionAuction L82)
  - `test_Settle_ASaleVoidedDuringTheScanRefusesLaterCalls` (IndependentEditionAuction L82)
- `test/independent/IndependentStream6529.t.sol`
  - `test_ActivateModule_RefusedWithNothingAnnounced` (IndependentStream6529 L112)
  - `test_ActivateModule_StillInstallsAfterTheReadyTime` (IndependentStream6529 L112)
  - `test_CancelModule_RefusedWithNothingAnnouncedForOthersAndForASharedSlot` (IndependentStream6529 L123)
  - `test_CancelModule_TheArtistWithdrawsTheAnnouncement` (IndependentStream6529 L122, IndependentStream6529 L125)
  - `test_Constructor_LogsTheFirstModuleDelay` (IndependentStream6529 L72)
  - `test_Constructor_WithoutARendererLogsNoModuleSet` (IndependentStream6529 L74)
  - `test_Mint_RecordsTheMintingContractWhateverTheTransactionOrigin` (IndependentStream6529 L160)
  - `test_PendingModule_OnlyTheRendererSlotReadsTheAnnouncement` (IndependentStream6529 L86)
  - `test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn` (IndependentStream6529 L144)
- `test/independent/IndependentStreamEditions6529.t.sol`
  - `test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn` (IndependentStreamEditions6529 L71)
- `test/independent/IndependentStreamRegistryMutation.t.sol`
  - `test_Authorize_APayeeOutsideSeveralPartiesIsRefused` (IndependentStreamRegistry L641, IndependentStreamRegistry L645, IndependentStreamRegistry L648)
  - `test_Authorize_AnOriginalMintsWithoutActiveEditions` (IndependentStreamRegistry L585)
  - `test_Authorize_AnswersTheItemsSaleParams` (IndependentStreamRegistry L572)
  - `test_Authorize_Cc0RefusesATextAboveOrBelowTheDeploymentsText` (IndependentStreamRegistry L603)
  - `test_Authorize_EachCollaboratorsOwnConsentIsChecked` (IndependentStreamRegistry L639)
  - `test_Authorize_OtherLicensesMintWithTheirOwnText` (IndependentStreamRegistry L603)
  - `test_Authorize_RefusesAContentHashAboveThePrimaryDigest` (IndependentStreamRegistry L585)
  - `test_Authorize_RefusesAFirstPartyNextToTheArtist` (IndependentStreamRegistry L628)
  - `test_Authorize_RefusesAMediaHashAboveTheFilesHash` (IndependentStreamRegistry L585)
  - `test_Authorize_RefusesAStatedDigestBelowTheStoredOne` (IndependentStreamRegistry L596)
  - `test_Authorize_SixteenPartiesMint` (IndependentStreamRegistry L628)
  - `test_Authorize_SixtyFourPayeesMint` (IndependentStreamRegistry L628)
  - `test_ListingSubject_IsTheAbiEncodedDomainAndFields` (IndependentStreamRegistry L324)
  - `test_Preview_AtZeroShareTheRoyaltyReceiverIsTheSeller` (IndependentStreamRegistry L427)
  - `test_Register_AStreamWritesNoListingAtTheZeroAddress` (IndependentStreamRegistry L312)
  - `test_Register_RefusesATokenNamingAnotherAccountsRoot` (IndependentStreamRegistry L683)
  - `test_Register_RefusesEditionsOfAnotherArtistsStreamEitherWay` (IndependentStreamRegistry L297)
  - `test_ReleaseContent_RefusesABeneficiaryNextToTheArtist` (IndependentStreamRegistry L267)
  - `test_ReleaseContent_RefusesAnEarlierBurnedTokenOfTheContent` (IndependentStreamRegistry L267)
  - `test_ReleaseContent_RefusesAnUnlistedContract` (IndependentStreamRegistry L267)
  - `test_RevokeTemplate_Logs` (IndependentStreamRegistry L171)
  - `test_SetStatus_TakesExactly256Contracts` (IndependentStreamRegistry L68)
  - `test_SupportsInterface_OnlyTheExactIds` (IndependentStreamRegistry L533)
  - `test_Templates_SuspendResumeReinstateLog` (IndependentStreamRegistry L736)
- `test/records/WorkRules.t.sol`
  - `test_Constructor_AnnouncesTheFirstDelivery` (WorkRules L147)
  - `test_FileStore_OnlyTheWorksOwnFilesAndTheMetadataIsRefreshed` (WorkRules L363, WorkRules L377)
  - `test_RefreshAllMetadata_ATokenWithoutEditionsIsRefreshedAlone` (WorkRules L408)
  - `test_Relicense_RefreshesTheMetadata` (WorkRules L259)
  - `test_Renounce_TheRoyaltyPowerAloneNeverTouchesTheRecordLocks` (WorkRules L236)
  - `test_RepinRenderer_MovesTheVersionAndRefreshesTheMetadata` (WorkRules L306, WorkRules L307)
  - `test_SetRecord_AFinalizedWorkRefusesBeforeAnyOtherCheck` (WorkRules L162)
  - `test_SetRoyaltyRate_NeedsAnOpenRecord` (WorkRules L274)
  - `test_Stores_ACodeHashAboveTheStoresOwnIsRefused` (WorkRules L328)
  - `test_Stores_EachIdNamesItsOwnStore` (WorkRules L564)
- `test/sales/auction/EnglishAuctionMutation.t.sol`
  - `test_Bid_TheLargest96BitBidIsAccepted` (EnglishAuction L647)
  - `test_Cancel_OnlyTheRecordedOutcomeAtAnyLaterPosition` (EnglishAuction L414)
  - `test_Constants_GasValues` (EnglishAuction L79, EnglishAuction L82, EnglishAuction L84)
  - `test_Constructor_ChecksTheEscrowAndTheRefusalGasBounds` (EnglishAuction L170, EnglishAuction L96, EnglishAuction L97)
  - `test_Constructor_ChecksTheResolverTheAllowlistAndTheStatementLog` (EnglishAuction L169, EnglishAuction L171, EnglishAuction L173)
  - `test_OnERC721Received_AcceptsAMintIntoCustodyDuringAStart` (EnglishAuction L584, EnglishAuction L587)
  - `test_Pause_IsLiveThroughItsLastSecond` (EnglishAuction L742, EnglishAuction L775)
  - `test_Restart_ForgetsTheRefundedBid` (EnglishAuction L227)
  - `test_Restart_RefusesACancelledSale` (EnglishAuction L213)
  - `test_Restart_RefusesAShareAboveTheWhole` (EnglishAuction L220)
  - `test_Resume_KeepsTheRemainingTimeWhenLongerThanTheDuration` (EnglishAuction L786)
  - `test_SetConfig_EachParameterIsComparedExactly` (EnglishAuction L471)
  - `test_SetConfig_TakesEveryBoundItself` (EnglishAuction L813, EnglishAuction L95)
  - `test_SettleOrRefund_AllowedAfterTheDelayToo` (EnglishAuction L357)
  - `test_Settle_AFeeWithNoRecipientIsRefused` (EnglishAuction L687)
  - `test_Settle_AGasShortfallRevertsInsteadOfDeliveringWithLess` (EnglishAuction L705, EnglishAuction L706)
  - `test_Settle_AZeroFeeNamesNoFeeRecipient` (EnglishAuction L308)
  - `test_StartWithBid_APolicyCannotReenter` (EnglishAuction L199)
  - `test_Start_RefusesEveryOtherSaleKind` (EnglishAuction L609)
  - `test_SupportsInterface_RefusesALowerId` (EnglishAuction L592)
  - `test_WithdrawBid_ABidForARecipientIsCreditedAndTheRecipientCleared` (EnglishAuction L726, EnglishAuction L727, EnglishAuction L728)
- `test/sales/edition/UniformEditionAuctionAdopt.t.sol`
  - `test_Adopt_RunsOnItsOwn_BidsAndSettlesByItsOwnCloseOnly` (UniformEditionAuction L1347, UniformEditionAuction L719)
- `test/sales/edition/UniformEditionAuctionMutation.t.sol`
  - `test_Abandon_APaidSaleIsNeverVoidedWhateverTheLensAnswers` (UniformEditionAuction L566)
  - `test_Abandon_ASaleAbandonedMidScanIsNotAbandonedAgain` (UniformEditionAuction L566)
  - `test_Bid_ASoftEndAtTheLastClockSecondIsAccepted` (UniformEditionAuction L1241)
  - `test_Bid_ExactlyASoftWindowBeforeTheEndStoresNoSoftEnd` (UniformEditionAuction L691)
  - `test_Bid_TheLastBidIdIsAccepted` (UniformEditionAuction L361)
  - `test_ClaimBidFor_WithoutARefundCreditsNothing` (UniformEditionAuction L507)
  - `test_CloseEdition_RefusesAnotherTokenAndAnUnlistedOne` (UniformEditionAuction L276)
  - `test_Constructor_RejectsAnEnglishAuctionWithoutCode` (UniformEditionAuction L210)
  - `test_ExpireCredit_AnyTimeAfterTheExpiry` (UniformEditionAuction L542)
  - `test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund` (UniformEditionAuction L244, UniformEditionAuction L261, UniformEditionAuction L353, UniformEditionAuction L395, UniformEditionAuction L533)
  - `test_SetConfig_RefusedOnceTheTermsCounterIsFull` (UniformEditionAuction L1215)
  - `test_SetLimits_RefusesAHigherExpectedValueAndAcceptsTheCurrentGas` (UniformEditionAuction L1228, UniformEditionAuction L601)
  - `test_Settle_OnceBegunNoLongerReadsTheOneOfOne` (UniformEditionAuction L457)
  - `test_Settle_RefusesAnIndexThatReachesAnotherStepsDepartureLog` (UniformEditionAuction L899)
  - `test_Settle_StoresTheOneOfOneEndItRead` (UniformEditionAuction L750)
- `test/terms/StreamTerms.t.sol`
  - `test_Constructor_WithoutEditionsPairsNothing` (StreamTerms L73)
  - `test_LowerFeeShare_NeedsALiveWork` (StreamTerms L130)
  - `test_LowerFeeShare_NeverDeploysTheOldVault` (StreamTerms L235)
  - `test_Pairing_APairSetHereNeverAsksTheIndependentStreamModule` (StreamTerms L138, StreamTerms L171, StreamTerms L188)
  - `test_Pairing_AnEmptyIndependentStreamSlotListsNoPair` (StreamTerms L217)
- `test/terms/StreamTermsFixes.t.sol`
  - `test_IndependentPair_OnlyAnErc1155ListingNamesTheTokenOfEditions` (StreamTerms L191)

<!-- /generated -->

No survivor showed a defect in a contract.

## Survivors, triaged

One row per surviving mutant of the permanent contracts and the money and mint modules.
"Killed" names the new test; "equivalent" mutants cannot change behaviour; "gas" and
"defensive" ones change only gas, or only what a trusted contract could make happen by lying;
"open" is a real gap left without a test.

<!-- generated:survivors -->

### `src/content/ContentStore.sol`

48 survivors: 45 equivalent, 2 killed, 1 gas.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 120 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 120 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 129 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 139 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 181 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 181 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 201 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound (completeThrough is only ever set to a stop <= chunkCount) |
| 201 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 210 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 210 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 213 | ROR | equivalent | `>` vs `>=` on a running maximum: at equality the value assigned equals the old value |
| 224 | ROR | equivalent | cap of `to` at chunkCount: at equality the value assigned equals the old value |
| 225 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 226 | MIA | killed | `test_Source_TheStoreItselfIsCheckedWithoutACall`: own-store shortcut: without it firstMissing asks itself through chunkData, same answer at more gas; pinned by expecting zero chunkData calls |
| 236 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 236 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 256 | ROR | equivalent | `== 0` vs `<= 0` on an unsigned bytes32 |
| 293 | ROR | equivalent | at equality validated + maxChunks equals count, so both branches give the same stop |
| 296 | ROR | equivalent | `==` vs `>=`: stop is never above count |
| 314 | ROR | equivalent | `==` vs `>=`: completeThrough is never above chunkCount |
| 315 | ROR | equivalent | at equality from + maxChunks equals count, so both branches give the same stop |
| 316 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound (stop >= from; maxChunks 0 gives stop == from) |
| 316 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 320 | ROR | equivalent | `==` vs `>=`: stop is never above count |
| 342 | ROR | equivalent | `<` vs `!=`: each take is clamped to what remains, so done lands exactly on length |
| 343 | AOR | equivalent | the clamp only matters on the last piece; the over-copy lands past the returned length in released memory and the ABI encoder zeroes the padding word, so the returned bytes are identical |
| 365 | ROR | equivalent | `== 0` vs `<= 0` on an unsigned bytes32 |
| 409 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 409 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 413 | ROR | equivalent | `j + 1 < k` vs `!=` inside a loop where j < k, so j + 1 <= k |
| 422 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 450 | MIA | equivalent | no clamp: the over-copy lands past the returned length in released memory, done only overshoots and ends the loop; returned bytes identical |
| 450 | ROR | equivalent | clamp of take to remaining: at equality the value assigned equals the old value |
| 468 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound (to is the stop, never below the validated count) |
| 468 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 475 | ROR | equivalent | at equality strictEnd - start is 0, the same as the other branch |
| 476 | ROR | equivalent | clamp of strict to the chunk length: at equality the value assigned equals the old value |
| 498 | ROR | equivalent | `n > 1` vs `n != 1`: a file chunk is never empty, and tail[n - 1] on the line above already needs n >= 1 |
| 502 | CR | gas | free-pointer release in _padding: without it attestBase64 holds one or two extra chunk buffers once (a few thousand gas), no behaviour change |
| 533 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 533 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 536 | ROR | equivalent | `!=` vs `<`: parts are immutable code whose sizes summed to the recorded length at linking, so filled always equals data.length |
| 584 | CR | killed | `test_Source_ARangeCheckKeepsMemoryAtOneChunk`: free-pointer release in _served: without it memory grows by one chunk per chunk checked (quadratic gas); pinned by a 64-vs-16 chunk gas ratio |
| 602 | ROR | equivalent | at equality remaining is CHUNK_SIZE, so both branches return the same value |
| 617 | ROR | equivalent | `<` vs `!=` on a counter that steps by one from a start never above the bound |
| 617 | UOR | equivalent | ++i vs i++ as a loop increment whose value is unused |
| 620 | ROR | equivalent | `==` vs `>=`: the loop index is never above m.length - 1 |
| 621 | UOR | equivalent | ++slashes vs slashes++ as a statement whose value is unused |

### `src/core/EditionsBase.sol`

5 survivors: 5 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 75 | ROR | killed | `test_Create_AcceptsARateOfExactlyTheDenominatorAndNotOneMore`: create with a rate of exactly 100,000 (the denominator) was not pinned |
| 160 | ROR | killed | `test_SetRoyalty_AZeroReceiverWithAZeroRateClearsTheRoyalty`: setRoyalty(zero receiver, zero rate) on an edition was not pinned |
| 174 | ROR | killed | `test_EmitMetadataUpdate_ADescendingRangeIsLoggedAsARange`: emitMetadataUpdate with from > to (logged as a range, not one update) was not pinned |
| 234 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below 0x49064906 |
| 234 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below ERC-2981's |

### `src/core/Modules.sol`

4 survivors: 3 equivalent, 1 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 114 | SBR | equivalent | memory/storage on a read-only reference in a function that writes nothing through it (gas only) |
| 122 | SBR | equivalent | memory/storage on a read-only reference in a function that writes nothing through it (gas only); `_addMinter` is called after the last read |
| 142 | SBR | equivalent | memory/storage on a read-only reference in a function that writes nothing through it (gas only) |
| 143 | ROR | killed | `test_RemoveMinter_AgainBeforeTheNewWaitStillCountsAsOnceActive (also test_RecordPrimarySale_AMinterRemovedTwiceStillSettlesItsSales in test/core/Stream.t.sol)`: a minter removed, added again and removed before its new start must still count as once active (settle its sales); no test reached that state |

### `src/core/Stream6529.sol`

4 survivors: 4 equivalent.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 40 | ROR | equivalent | loop counter that steps by one from zero up to the length: same iterations |
| 40 | SBR | equivalent | narrower counter/return type for a value that never exceeds 32 bits (or a short array length): same value |
| 40 | SBR | equivalent | narrower counter/return type for a value that never exceeds 32 bits (or a short array length): same value |
| 40 | UOR | equivalent | `++i` vs `i++` as a loop step |

### `src/core/StreamBase.sol`

10 survivors: 8 equivalent, 2 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 84 | ROR | equivalent | `<= 0` on a bytes32 is `== 0` |
| 84 | ROR | equivalent | `<= 0` on a bytes32 is `== 0` |
| 112 | ROR | equivalent | `> 0` on a bytes32 is `!= 0` |
| 136 | UOR | equivalent | `++x` vs `x++` as a statement |
| 155 | ROR | equivalent | Outcome.NONE is the enum's zero: `> NONE` is `!= NONE` |
| 203 | ROR | killed | `test_SetRoyalty_AcceptsARateOfExactlyTheDenominator`: setRoyalty with a rate of exactly 100,000 (the denominator) was not pinned |
| 229 | ROR | killed | `test_EmitMetadataUpdate_ADescendingRangeIsLoggedAsARange`: emitMetadataUpdate with from > to (logged as a range, not one update) was not pinned |
| 266 | SBR | equivalent | storage/memory on a read-only reference in a view (gas only) |
| 307 | SBR | equivalent | the collection ID is cast to 32 bits before it is returned: uint128 holds it |
| 320 | ROR | equivalent | Outcome.NONE is the enum's zero: `> NONE` is `!= NONE` |

### `src/core/StreamDirectory6529.sol`

4 survivors: 4 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 66 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below ERC-165's |
| 66 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below IArtistPayoutResolver's |
| 66 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below IModuleSlots' |
| 66 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below IDirectory's |

### `src/core/StreamEditions6529.sol`

6 survivors: 4 equivalent, 2 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 39 | ROR | equivalent | loop counter that steps by one from zero up to the length: same iterations |
| 39 | SBR | equivalent | narrower counter/return type for a value that never exceeds 32 bits (or a short array length): same value |
| 39 | SBR | equivalent | narrower counter/return type for a value that never exceeds 32 bits (or a short array length): same value |
| 39 | UOR | equivalent | `++i` vs `i++` as a loop step |
| 46 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below IModules' |
| 46 | ROR | killed | `test_SupportsInterface_NothingBelowTheSupportedIds`: supportsInterface was never asked an unsupported ID below IModuleSlots' |

### `src/core/StreamWorkFacts6529.sol`

16 survivors: 13 equivalent, 2 killed, 1 defensive.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 38 | SBR | equivalent | constant vs immutable of the same value: same getter, same uses |
| 38 | SBR | equivalent | uint128 constant 16: the getter's ABI word and every comparison are the same |
| 83 | ROR | equivalent | loop counter that steps by one from zero up to the length: same iterations |
| 83 | SBR | equivalent | uint128 counter over at most MAX_MEDIA_FILES entries: same values |
| 83 | SBR | equivalent | uint128 counter over at most MAX_MEDIA_FILES entries: same values |
| 83 | UOR | equivalent | `++i` vs `i++` as a loop step |
| 103 | ROR | equivalent | loop counter that steps by one from zero up to the length: same iterations |
| 103 | SBR | equivalent | uint128 counter over at most MAX_MEDIA_FILES entries: same values |
| 103 | SBR | equivalent | uint128 counter over at most MAX_MEDIA_FILES entries: same values |
| 103 | UOR | equivalent | `++i` vs `i++` as a loop step |
| 110 | CR | killed | `test_MarkOnChainComplete_TheTokenLogsAMetadataUpdate`: the token's ERC-4906 update on markOnChainComplete was not asserted |
| 157 | ROR | defensive | differs only for a file of zero chunks, which ContentStore never reports (registration needs 1+ chunks, an unknown file reverts); the content store is an immutable trusted contract |
| 203 | SBR | equivalent | storage/memory on a read-only reference in a view (gas only) |
| 233 | ROR | equivalent | differs only for code with the 0xef0100 prefix at a length other than 23 bytes, which cannot exist on chain (EIP-3541 forbids deploying 0xef code; EIP-7702 designators are exactly 23 bytes; the test EVM's vm.etch refuses it too) |
| 233 | ROR | equivalent | differs only for code with the 0xef0100 prefix at a length other than 23 bytes, which cannot exist on chain (EIP-3541 forbids deploying 0xef code; EIP-7702 designators are exactly 23 bytes; the test EVM's vm.etch refuses it too) |
| 233 | ROR | killed | `test_Pin_TwentyThreeBytesAboveTheDesignatorPrefix`: a 23-byte contract whose first bytes sort above 0xef0100 (e.g. starting 0xfe) must be pinnable; untested |

### `src/economics/RevenueEscrow.sol`

9 survivors: 1 killed, 7 equivalent, 1 gas.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 147 | CR | killed | `test_Recover_ReentryIsBlocked`: recover's reentrancy guard was unpinned: an authorised account re-entering recover from a flush that pays it |
| 151 | ROR | equivalent | bytes32 `!= 0` vs `> 0`: unsigned, identical |
| 222 | SBR | gas | storage/memory on a read-only reference in a view; only the copy costs gas |
| 234 | ROR | equivalent | at time == block.timestamp the assignment stores the same value |
| 293 | ROR | equivalent | with maturing == 0 the branch adds 0 and zeroes a zero |
| 297 | ROR | equivalent | recent == 0 implies maturingLastAt == lastAt (recent is zeroed only by this branch or a delete; lastAt changes only in _add, which makes recent non-zero), so the branch adds 0, re-stores the same time and repeats the first branch's test |
| 298 | ASOR | equivalent | maturing is always 0 here: maturingLastAt <= openedAt and one period per roll, so the first branch aged it; `=` equals `+=` |
| 298 | ASOR | equivalent | maturing is always 0 here (as ASOR_0), so `\|=` equals `+=` |
| 298 | ASOR | equivalent | maturing is always 0 here (as ASOR_0), so `^=` equals `+=` |

### `src/economics/SplitLedger.sol`

20 survivors: 19 equivalent, 1 gas.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 59 | SBR | equivalent | constant vs immutable: same value from the same getter |
| 121 | ROR | equivalent | bytes32 `!= 0` vs `> 0`: unsigned, identical |
| 130 | ROR | equivalent | bytes32 `!= 0` vs `> 0`: unsigned, identical |
| 213 | ROR | equivalent | bytes32 `== 0` vs `<= 0`: unsigned, identical |
| 249 | SBR | equivalent | storage/memory on a read-only reference in a view |
| 318 | ROR | equivalent | `== type(uint256).max` vs `>=`: nothing is above the maximum |
| 324 | ROR | equivalent | `_due` just reverted on current < recorded, so `!=` and `>` agree |
| 324 | ROR | gas | `>=` only adds a write of the value already stored when current == recorded |
| 347 | SBR | equivalent | the sum is uint48 + uint48 (checked in uint48) either way; uint128 holds it as uint256 does |
| 353 | ROR | equivalent | at done == target both arms give 0 |
| 355 | ROR | equivalent | at amount == due the assignment stores the same value |
| 383 | ROR | equivalent | `lowerBound` never returns more than the list length |
| 425 | ROR | equivalent | differs only if a vault's ETH fell by more than the instructed amount; a vault moves ETH only on the ledger's instruction, and the wallet's lock bars a second one |
| 431 | ROR | equivalent | for 1..31 return bytes `bytes32(data)` is right-padded, its last byte is 0, so `!= 1` refuses as `!= 32` did |
| 431 | ROR | equivalent | `BoundedCall._outcome` returns (false, empty) for more than 32 bytes, so data.length > 32 never reaches here |
| 464 | MIA | equivalent | `recordedObserved[wallet][address(0)]` is never written (L324 guard), so the ETH check reads 0 and cannot revert; one extra SLOAD |
| 499 | ROR | equivalent | bytes32 `== 0` vs `<= 0`: unsigned, identical |
| 505 | SBR | equivalent | `abi.encode` and `abi.encodePacked` of two bytes32 give the same 64 bytes |
| 512 | BOR | equivalent | the line above reverted unless the bit is clear, so `\|` and `^` both set it |
| 536 | SBR | equivalent | the lock word is only ever 0 or 1, which fits uint128 |

### `src/economics/Splits.sol`

10 survivors: 10 equivalent.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 17 | SBR | equivalent | MAX_PAYEES = 64 fits uint128; every use widens it to uint256 |
| 33 | LIR | equivalent | the literal 0 replaced by the type's minimum, which is 0 |
| 33 | MVIV | equivalent | an uninitialised uint256 is zero |
| 33 | SBR | equivalent | at most 64 shares of 32 bits each: the sum fits uint128 |
| 36 | ROR | equivalent | `<` vs `!=` on a counter that starts at 0 and steps by one up to count |
| 36 | SBR | equivalent | the counter is at most 64 |
| 36 | UOR | equivalent | `++i` vs `i++` as a loop step |
| 44 | ROR | equivalent | at i = 0 the last pair is (0, 0) and L40 lets through only a payee with exactly one of id and account nonzero, which sorts above it |
| 44 | ROR | equivalent | `lastId <= id` differs from `==` only when lastId < id, which the first disjunct already accepts |
| 82 | ROR | equivalent | binary search keeps low <= high, so `<` and `!=` agree |

### `src/independent/IndependentStream6529.sol`

14 survivors: 14 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 72 | CR | killed | `test_Constructor_LogsTheFirstModuleDelay`: constructor's ModuleDelaySet(0, 7 days) was not asserted |
| 74 | MIA | killed | `test_Constructor_WithoutARendererLogsNoModuleSet`: a deployment with no renderer must log no ModuleSet(0, 0) |
| 86 | MIA | killed | `test_PendingModule_OnlyTheRendererSlotReadsTheAnnouncement`: pendingModule of another slot (below and above RENDERER) was never read while an announcement waits |
| 86 | ROR | killed | `test_PendingModule_OnlyTheRendererSlotReadsTheAnnouncement`: pendingModule of another slot (below and above RENDERER) was never read while an announcement waits |
| 86 | ROR | killed | `test_PendingModule_OnlyTheRendererSlotReadsTheAnnouncement`: pendingModule of another slot (below and above RENDERER) was never read while an announcement waits |
| 112 | ROR | killed | `test_ActivateModule_StillInstallsAfterTheReadyTime`: activation was only tried at exactly readyAt, never later |
| 112 | ROR | killed | `test_ActivateModule_RefusedWithNothingAnnounced`: activateModule with nothing announced was untested: the mutant lets anyone empty the renderer slot |
| 122 | SBR | killed | `test_CancelModule_TheArtistWithdrawsTheAnnouncement`: cancelModule had no test: with a storage reference the event names the deleted (zero) module |
| 123 | MIA | killed | `test_CancelModule_RefusedWithNothingAnnouncedForOthersAndForASharedSlot`: cancelModule with nothing announced must revert ModuleNotReady |
| 123 | ROR | killed | `test_CancelModule_RefusedWithNothingAnnouncedForOthersAndForASharedSlot`: cancelModule with nothing announced must revert ModuleNotReady |
| 125 | CR | killed | `test_CancelModule_TheArtistWithdrawsTheAnnouncement`: ModuleCancelled was not asserted |
| 144 | ROR | killed | `test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn`: no unsupported interface id below the token's own ids was checked |
| 144 | ROR | killed | `test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn`: no unsupported interface id below the token's own ids was checked |
| 160 | SBR | killed | `test_Mint_RecordsTheMintingContractWhateverTheTransactionOrigin`: hasMinted must follow the calling contract, not tx.origin (origin that minted before hides the new minter) |

### `src/independent/IndependentStreamEditions6529.sol`

2 survivors: 1 equivalent, 1 killed.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 61 | ROR | equivalent | for a slot above TERMS _sharedModule returns zero anyway: its only other slot, RECORDS, sorts below TERMS |
| 71 | ROR | killed | `test_SupportsInterface_RefusesIdsBelowAndAboveItsOwn`: no unsupported interface id above the membership id was checked |

### `src/records/StatementLog.sol`

24 survivors: 21 equivalent, 1 gas, 2 defensive.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 76 | SBR | equivalent | uint128 constant getter returns the same 32-byte word (8192); only the ABI type label differs |
| 76 | SBR | equivalent | constant vs immutable: same value, only bytecode/gas differs |
| 86 | SBR | equivalent | constant vs immutable on a private hash: same value |
| 87 | SBR | equivalent | constant vs immutable on a private hash: same value |
| 212 | SBR | equivalent | storage vs memory on a read-only reference in a view |
| 242 | ROR | equivalent | `> 0` equals `!= 0` on bytes32 |
| 242 | ROR | gas | `length < 0` is never true, so a codeless token goes on to the ERC-165 probe, which answers false for it: same zero result, more gas |
| 256 | ROR | equivalent | tryReadAll returns revert data only if it fits the 36-byte cap, so length never exceeds 36 |
| 313 | ROR | equivalent | Role.NONE never reaches _write (append refuses it, _isAuthorized answers false), so `<= ARTIST` equals `== ARTIST` |
| 334 | SBR | equivalent | encodePacked of three bytes32 words equals abi.encode of them |
| 358 | ROR | equivalent | unsigned bytes32 compared with zero: the replacement is the same test |
| 360 | ROR | equivalent | PLATFORM is the last Role value, `< PLATFORM` equals `!= PLATFORM` |
| 363 | ROR | equivalent | `<= 0` equals `== 0` on an unsigned bytes32 |
| 364 | ROR | equivalent | unsigned bytes32 compared with zero: the replacement is the same test |
| 369 | ROR | equivalent | unsigned bytes32 compared with zero: the replacement is the same test |
| 370 | ROR | equivalent | unsigned bytes32 compared with zero: the replacement is the same test |
| 388 | ROR | equivalent | unsigned bytes32 compared with zero: the replacement is the same test |
| 405 | ROR | equivalent | ARTIST and OWNER returned earlier; of NONE, CURATOR, PLATFORM only NONE is below CURATOR, and it is still refused |
| 405 | ROR | equivalent | PLATFORM is the last Role value and ARTIST/OWNER returned earlier, so `< PLATFORM` equals `!= PLATFORM` here (NONE, the only other value, is still refused) |
| 406 | ROR | equivalent | only CURATOR or PLATFORM reach this line, so `<= CURATOR` equals `== CURATOR` |
| 419 | LOR | defensive | guard is unreachable in effect: token 0 has no code so both reads fail (not owner), and `who` is msg.sender or a signer SignatureVerifier already refused when zero |
| 419 | MIA | defensive | same guard: a zero token has no code (both reads answer 'not owner') and a zero signer never reaches _owns |
| 427 | ROR | equivalent | unsigned bytes32 compared with zero: the replacement is the same test |
| 434 | BOR | equivalent | the bit was just checked to be clear, so `^` equals `\|` |

### `src/curation/PackageRegistry.sol`

44 survivors: 9 killed, 31 equivalent, 4 defensive.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 92 | CONST | killed | `test_revokeMove_first255NoncesShareOneSlot`: 254 nonces per word keeps every nonce distinct (gas/layout only); the documented 255-per-word layout is now pinned by the slot written |
| 166 | CR | killed | `test_constructor_rejectsBadEconomics`: no test built a registry with an economics address that has no code or declares another interface |
| 180 | ROR | killed | `test_bindStream_refusesALowerOrHigherCc0Text`: `!=` vs `>`: only a Stream whose facts name a higher CC0 text was tried; one naming a lower text was unpinned |
| 200 | ROR | equivalent | `!=` vs `>` NONE, the enum's zero value |
| 204 | ROR | equivalent | `== 0` vs `<= 0` on an unsigned value |
| 215 | ROR | equivalent | `==` vs `>=` REVOKED, the enum's last value |
| 332 | CR | equivalent | `token;` is a no-op expression statement that only silences the unused-parameter warning |
| 340 | MIA | killed | `test_preview_anArtistItemQuotesItsSeed`: no test previewed an ARTIST-seed item, so the quoted seed was unpinned |
| 340 | ROR | equivalent | `<= ARTIST` adds NONE, whose `item.seed` `_checkItem` already forced to zero |
| 341 | CR | killed | `test_preview_anArtistItemQuotesItsSeed`: no test previewed an ARTIST-seed item, so the quoted seed was unpinned |
| 341 | RR | killed | `test_preview_anArtistItemQuotesItsSeed`: no test previewed an ARTIST-seed item, so a revert there went unseen |
| 342 | ROR | equivalent | `==` vs `>=` VRF: `_checkItem` already refused every seed policy above VRF |
| 362 | ROR | equivalent | boundary value that cannot occur: artist ID 2^160-1 needs a registered account at address 0xff..ff |
| 374 | ROR | defensive | `!=` vs `>`: Stream token IDs only grow, so `tokenOfContent` is never below the released token; differs only if the bound Stream lowered it |
| 411 | ROR | equivalent | `>= APPROVED` adds only REVOKED, which is not live and is assigned REVOKED again |
| 421 | ROR | defensive | `==` vs `>=`: a release's token is never above `tokenOfContent` (Stream IDs only grow); differs only if the bound Stream lowered it |
| 489 | ROR | killed | `test_preview_requestLengthBoundary`: the 160-byte boundary of the request length check was unpinned (existing test used 159 zero bytes, refused by the head-offset check) |
| 507 | ROR | equivalent | `== 0` vs `<= 0` on an unsigned value |
| 513 | ROR | equivalent | `!= 0` vs `> 0` on an unsigned value |
| 513 | ROR | equivalent | `>= VRF` adds only policies above VRF, already refused by the first clause of the same condition |
| 522 | ROR | killed | `test_invalidItem_cc0TextBelowOrAboveTheDeployments`: `!=` vs `>`: a CC0 item naming a text file ID below the deployment's CC0 text was unpinned |
| 522 | ROR | killed | `test_preview_nonCc0LicencesMayNameAnyText`: `==` vs `>=`: no test quoted a non-CC0 licence whose key sorts above the CC0 key with another text |
| 568 | ROR | equivalent | `<= ARTIST` adds NONE, whose `item.seed` is zero, the value returned anyway |
| 569 | ROR | equivalent | `!=` vs `<` VRF: policies above VRF were refused by `_checkItem` |
| 588 | ROR | defensive | `!=` vs `<`: a release's token is never above `tokenOfContent` (Stream IDs only grow, never reused); differs only if the bound Stream lowered it |
| 598 | CR | equivalent | without `return false` the catch falls through to the bool default, false |
| 611 | ROR | equivalent | `==` vs `>=`: a package's epoch is a past `_killEpoch`, which only grows, so it is never above it |
| 619 | ROR | equivalent | `== 0` vs `<= 0` on an unsigned value |
| 619 | ROR | equivalent | `== 0` vs `<= 0` on an unsigned value |
| 622 | ROR | equivalent | `==` vs `<=` ORIGINAL, the enum's zero value |
| 623 | ROR | equivalent | `!= 0` vs `> 0` on an unsigned value |
| 646 | ROR | equivalent | `!=` vs `>` ARTIST, the enum's zero value |
| 651 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one from zero |
| 651 | UOR | equivalent | `++i` vs `i++` as a loop increment whose value is unused |
| 655 | ROR | equivalent | `j <= i` also reads `ids[i]`, still zero, against an id already checked nonzero |
| 655 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one from zero |
| 655 | UOR | equivalent | `++j` vs `j++` as a loop increment whose value is unused |
| 662 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one from zero |
| 664 | ROR | equivalent | `>=` adds only `artistId` above the previous one, which the preceding clause already accepts as ordered |
| 681 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one from zero |
| 681 | UOR | equivalent | `++j` vs `j++` as a loop increment whose value is unused |
| 686 | CR | equivalent | without the final `return false` the function returns the bool default, false |
| 686 | CR | equivalent | same mutant as st-1of5:CR_0: falls through to the bool default, false |
| 705 | ROR | defensive | a 20-byte proof naming the root (empty signature) falls to `requireSigned`, which checks the same wallet the same way; differs only as gas or if the accounts module lies |

### `src/identity/Accounts.sol`

30 survivors: 13 killed, 17 equivalent.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 197 | CR | killed | `test_RegisterIndependent_RefusesAnExpiredAcceptance`: registerIndependent accepted an expired acceptance signature (deadline check removed) |
| 214 | ROR | equivalent | ChangeKind.NONE is the lowest enum value, so the comparison is the same |
| 231 | ROR | equivalent | `<= 0` equals `== 0` on an unsigned bytes32 |
| 234 | ROR | equivalent | ChangeKind.REPLACEMENT is the highest enum value, so the comparison is the same |
| 241 | ROR | equivalent | REPLACEMENT already reverted at L234, so `>= OWN` only ever sees OWN |
| 257 | ROR | equivalent | _pendingOf already reverted on NONE, so `<= OWN` only ever sees OWN |
| 272 | ROR | equivalent | ChangeKind.REPLACEMENT is the highest enum value, so the comparison is the same |
| 289 | ROR | equivalent | `<= 0` equals `== 0` on an unsigned bytes32 |
| 405 | ROR | equivalent | ChangeKind.NONE is the lowest enum value, so the comparison is the same |
| 420 | LOR | equivalent | early exit only: a zero token has no code so both reads fail to 'no', and isWallet refuses a zero account |
| 420 | MIA | equivalent | early exit only: a zero token has no code so both reads fail to 'no', and isWallet refuses a zero account |
| 424 | ROR | killed | `test_IsArtist_AnEditionAnswerThatIsNotOneCleanAddressIsNo`: an edition's `stream()` answer longer than one word was read as a master |
| 426 | LOR | killed | `test_IsArtist_AnEditionAnswerThatIsNotOneCleanAddressIsNo`: a `stream()` word with bits above the address was truncated and read as a master |
| 426 | MIA | killed | `test_IsArtist_AnEditionAnswerThatIsNotOneCleanAddressIsNo`: a `stream()` word with bits above the address was truncated and read as a master |
| 426 | ROR | killed | `test_IsArtist_AMasterAtTheHighestAddressCounts`: a master at address(type(uint160).max) was refused (`>=` for `>`) |
| 427 | CR | killed | `test_IsArtist_AnEditionAnswerThatIsNotOneCleanAddressIsNo`: a `stream()` word with bits above the address was truncated and read as a master |
| 564 | ROR | killed | `test_Register_RefusesARootAPendingChangeReserves`: register created an account on a root another account's pending change reserves |
| 569 | CR | killed | `test_Register_LogsTheNewAccount`: ArtistRegistered was not pinned by any test |
| 578 | MIA | equivalent | an ID over 160 bits names no account (isWallet answers false for it), so returning it instead of zero gives the same 'no' |
| 578 | ROR | killed | `test_IsArtist_TheHighestArtistIdCounts`: the artist ID type(uint160).max was read as no artist (`>=` for `>`) |
| 599 | ROR | equivalent | ChangeKind.NONE is the lowest enum value, so the comparison is the same |
| 663 | LOR | killed | `test_OwnChange_CurrentBehaviour_APayoutAnsweringTrueToEveryProbeIsAccepted`: a payout contract that answers true to every ERC-165 probe (so is not ERC-165) was refused as a network contract |
| 663 | MIA | killed | `test_OwnChange_CurrentBehaviour_APayoutAnsweringTrueToEveryProbeIsAccepted`: a payout contract that answers true to every ERC-165 probe (so is not ERC-165) was refused as a network contract |
| 675 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one |
| 675 | UOR | equivalent | `++i` vs `i++` as a loop step whose value is unused |
| 678 | CR | equivalent | the removed `return false` equals the default return value |
| 695 | MIA | killed | `test_OwnChange_TheAccountStillActsWhileItsOwnChangeWaits`: an account's own pending change set `replacing`, so nobody could act for the account while it waited |
| 695 | ROR | killed | `test_OwnChange_TheAccountStillActsWhileItsOwnChangeWaits`: an account's own pending change set `replacing`, so nobody could act for the account while it waited |
| 695 | ROR | equivalent | ChangeKind.REPLACEMENT is the highest enum value, so the comparison is the same |
| 713 | ROR | equivalent | _apply only runs with a pending change (OWN or REPLACEMENT), so `> OWN` equals `!= OWN` |

### `src/independent/IndependentEditionAuction.sol`

6 survivors: 5 killed, 1 equivalent.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 70 | RR | killed | `test_Raise_MovesTheBidUpForTheDifference`: raise on the Independent auction was never called successfully |
| 71 | RR | killed | `test_Raise_MovesTheBidUpForTheDifference`: raise on the Independent auction was never called successfully |
| 82 | LOR | killed | `test_Settle_AListedSalesScanFinishesOnALaterCall`: a still-listed sale's second scan call must clear and pay; the mutant voids every multi-call settlement |
| 82 | ROR | equivalent | _scans is written only while SETTLING and status never returns below it, so status < SETTLING implies _scans == 0 |
| 82 | ROR | killed | `test_Settle_ASaleVoidedDuringTheScanRefusesLaterCalls`: a sale voided mid-scan keeps its scan word: a later settle must revert InvalidAuctionState, not void (and log) again |
| 82 | ROR | killed | `test_Settle_AClearingThatPaidStandsThroughADelisting`: a cleared and paid sale still sweeping departures (SETTLING, scan done) must not void on a delisting |

### `src/independent/IndependentStreamRegistry.sol`

109 survivors: 37 killed, 67 equivalent, 5 defensive.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 68 | CONST | killed | `test_SetStatus_TakesExactly256Contracts`: exact batch bound was read from the contract, not pinned |
| 68 | CONST | killed | `test_SetStatus_TakesExactly256Contracts`: exact batch bound was read from the contract, not pinned |
| 68 | SBR | equivalent | constant 256 fits; the getter's ABI word is identical |
| 68 | SBR | equivalent | constant vs immutable of the same literal: bytecode/gas only |
| 70 | SBR | equivalent | constant vs immutable of the same literal: bytecode/gas only |
| 72 | SBR | equivalent | constant vs immutable of the same literal: bytecode/gas only |
| 73 | SBR | equivalent | constant vs immutable of the same literal: bytecode/gas only |
| 75 | SBR | equivalent | private constant 16: narrower type or immutable changes no comparison |
| 75 | SBR | equivalent | private constant 16: narrower type or immutable changes no comparison |
| 77 | SBR | equivalent | private constant 1: narrower type or immutable changes no stored value |
| 77 | SBR | equivalent | private constant 1: narrower type or immutable changes no stored value |
| 142 | ROR | equivalent | NONE is the lowest and PAIR the highest enum value, so the comparison is unchanged |
| 142 | ROR | equivalent | NONE is the lowest and PAIR the highest enum value, so the comparison is unchanged |
| 171 | CR | killed | `test_RevokeTemplate_Logs`: TemplateSet on a revocation was not asserted |
| 215 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 216 | ROR | equivalent | loop counter form/width over at most 256 entries |
| 216 | SBR | equivalent | loop counter form/width over at most 256 entries |
| 216 | SBR | equivalent | loop counter form/width over at most 256 entries |
| 216 | UOR | equivalent | loop counter form/width over at most 256 entries |
| 218 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 242 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 267 | ROR | killed | `test_ReleaseContent_RefusesAnEarlierBurnedTokenOfTheContent`: releasing an earlier burned token after the content was minted again was untested (only a higher id was) |
| 267 | ROR | killed | `test_ReleaseContent_RefusesABeneficiaryNextToTheArtist`: a beneficiary above the artist ID was untested |
| 267 | ROR | killed | `test_ReleaseContent_RefusesAnUnlistedContract`: release for a contract this module does not list (empty listing: form ERC721, artist 0) was untested |
| 267 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 267 | ROR | equivalent | Form.ERC721 is the lowest enum value, so > equals != |
| 284 | ROR | equivalent | Status.NONE is the lowest enum value, so > equals != |
| 291 | ROR | equivalent | Form.ERC721 is the lowest enum value, so <= equals == |
| 297 | ROR | equivalent | a listed ERC1155 always has a partner, which the next clause refuses, and PAIR is never listed |
| 297 | ROR | equivalent | Form.ERC721 is the lowest enum value, so > equals != |
| 297 | ROR | killed | `test_Register_RefusesEditionsOfAnotherArtistsStreamEitherWay`: editions of another artist's stream were refused in one ID order only |
| 312 | MIA | killed | `test_Register_AStreamWritesNoListingAtTheZeroAddress`: a 1/1 listing must not write a partner at the zero address (readable through listingOf) |
| 324 | SBR | killed | `test_ListingSubject_IsTheAbiEncodedDomainAndFields`: listing subject was only compared with itself; now pinned to abi.encode of domain and fields |
| 421 | SBR | equivalent | storage/memory on a read-only reference in a view |
| 427 | MIA | killed | `test_Preview_AtZeroShareTheRoyaltyReceiverIsTheSeller`: preview at a zero share was untested (authorize was) |
| 427 | ROR | killed | `test_Preview_AtZeroShareTheRoyaltyReceiverIsTheSeller`: preview at a zero share was untested (authorize was) |
| 436 | SBR | equivalent | storage/memory on a read-only reference |
| 437 | ROR | equivalent | token ids only grow, so tokenOfContent never falls below the released id |
| 437 | ROR | equivalent | without a release the beneficiary returned is zero anyway |
| 446 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 462 | ROR | equivalent | a listed contract's template is never NONE, the only status added |
| 462 | ROR | equivalent | a listed contract's template is never NONE, the only status added |
| 476 | ROR | equivalent | no listing has form PAIR (approveTemplate refuses it), so < ERC1155 equals != ERC1155 |
| 494 | ROR | equivalent | TemplateStatus.NONE is the lowest enum value, so <= equals == |
| 505 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 514 | SBR | equivalent | storage/memory on a read-only reference |
| 533 | ROR | killed | `test_SupportsInterface_OnlyTheExactIds`: supportsInterface was only tested false for 0xffffffff, never for an ID below a supported one |
| 533 | ROR | killed | `test_SupportsInterface_OnlyTheExactIds`: supportsInterface was only tested false for 0xffffffff, never for an ID below a supported one |
| 533 | ROR | killed | `test_SupportsInterface_OnlyTheExactIds`: supportsInterface was only tested false for 0xffffffff, never for an ID below a supported one |
| 533 | ROR | killed | `test_SupportsInterface_OnlyTheExactIds`: supportsInterface was only tested false for 0xffffffff, never for an ID below a supported one |
| 572 | CR | killed | `test_Authorize_AnswersTheItemsSaleParams`: sale params were only tested empty |
| 585 | ROR | equivalent | unsigned <= 0 equals == 0 |
| 585 | ROR | killed | `test_Authorize_AnOriginalMintsWithoutActiveEditions`: no test minted an original while the editions were not listed ACTIVE |
| 585 | ROR | killed | `test_Authorize_RefusesAContentHashAboveThePrimaryDigest`: a content hash above the primary digest was untested |
| 585 | ROR | killed | `test_Authorize_RefusesAMediaHashAboveTheFilesHash`: a media hash above the files' hash was untested |
| 585 | ROR | equivalent | Form.ERC721 is the lowest enum value, so > equals != |
| 585 | ROR | equivalent | kind > EDITION_MASTER is refused earlier in the same condition |
| 585 | ROR | defensive | approveItem refuses non-ERC721 listings, so no approved item reaches _checkItem for one |
| 585 | ROR | defensive | a zero content hash needs a stored file whose SHA-256 is zero, and the token refuses it too |
| 593 | ROR | equivalent | loop counter form/width over at most 32 files |
| 593 | SBR | equivalent | loop counter form/width over at most 32 files |
| 593 | SBR | equivalent | loop counter form/width over at most 32 files |
| 593 | UOR | equivalent | loop counter form/width over at most 32 files |
| 596 | ROR | killed | `test_Authorize_RefusesAStatedDigestBelowTheStoredOne`: a stated digest below the stored one was untested |
| 603 | ROR | killed | `test_Authorize_Cc0RefusesATextAboveOrBelowTheDeploymentsText`: CC0 with a text file ID above the deployment's was untested |
| 603 | ROR | killed | `test_Authorize_OtherLicensesMintWithTheirOwnText`: only one non-CC0 license was minted, its key below CC0's |
| 628 | ROR | killed | `test_Authorize_SixteenPartiesMint`: exactly 16 parties were never minted |
| 628 | ROR | killed | `test_Authorize_SixtyFourPayeesMint`: exactly 64 payees were never minted |
| 628 | ROR | killed | `test_Authorize_RefusesAFirstPartyNextToTheArtist`: a first party above the artist ID was untested |
| 638 | ROR | equivalent | loop counter form/width over at most 16 parties |
| 638 | SBR | equivalent | loop counter form/width over at most 16 parties |
| 638 | SBR | equivalent | loop counter form/width over at most 16 parties |
| 638 | UOR | equivalent | loop counter form/width over at most 16 parties |
| 639 | AOR | killed | `test_Authorize_EachCollaboratorsOwnConsentIsChecked`: no test minted with two collaborators, so consents[i-1] was only read at index 0 |
| 641 | ROR | equivalent | != vs < on a loop counter that steps by one |
| 641 | SBR | equivalent | loop counter width over at most 64 payees |
| 641 | SBR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested with one party and no payout address |
| 644 | SBR | equivalent | counter width over at most 16 parties |
| 645 | ROR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested with one party and no payout address |
| 645 | ROR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested with one party and no payout address |
| 645 | ROR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee with an ID above a party's was untested |
| 645 | ROR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested with one party and no payout address |
| 645 | ROR | equivalent | != vs < on a counter that steps by one up to n |
| 645 | ROR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee with an ID below a party's was untested |
| 645 | SBR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested with one party and no payout address |
| 646 | UOR | equivalent | ++j vs j++ as a statement |
| 648 | LOR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested without a payout address, where both operands hold |
| 648 | ROR | killed | `test_Authorize_APayeeOutsideSeveralPartiesIsRefused`: non-party payee was only tested without a payout address |
| 648 | ROR | equivalent | the loop stops at j == n, so j never exceeds n |
| 659 | SBR | equivalent | storage/memory on a read-only reference |
| 660 | ROR | equivalent | a release names the id tokenOfContent named then and token ids only grow, so r.tokenId > existing cannot occur |
| 663 | MIA | defensive | unreachable: releaseContent records only beneficiary == the listing's artist, which never changes |
| 663 | ROR | defensive | unreachable: releaseContent records only beneficiary == the listing's artist, which never changes |
| 663 | ROR | defensive | unreachable: releaseContent records only beneficiary == the listing's artist, which never changes |
| 670 | ROR | equivalent | seedPolicy > SEED_VRF is refused by _checkItem before _seed runs |
| 683 | ROR | killed | `test_Register_RefusesATokenNamingAnotherAccountsRoot`: a token whose artist ID is another account's (replaced-in) root was untested: the mutant lists it on that account's signature |
| 695 | ROR | equivalent | Form.ERC721 is the lowest enum value, so > equals != |
| 695 | ROR | equivalent | an unlisted contract's artist is account 0, which has no wallet, so NotArtist still |
| 695 | ROR | equivalent | Status.NONE is the lowest enum value, so <= equals == |
| 702 | ROR | equivalent | for an unlisted (NONE) listing every caller's other condition already fails: no template, artist 0, early return |
| 707 | ROR | equivalent | a listed contract's template is never NONE, the only status added |
| 723 | MIA | equivalent | value assigned equals the stored value when the listing is already own |
| 723 | ROR | equivalent | value assigned equals the stored value when the listing is already own |
| 723 | ROR | equivalent | value assigned equals the stored value when the listing is already own |
| 729 | MIA | equivalent | value assigned equals the stored value when the template is already own |
| 729 | ROR | equivalent | value assigned equals the stored value when the template is already own |
| 729 | ROR | equivalent | value assigned equals the stored value when the template is already own |
| 736 | CR | killed | `test_Templates_SuspendResumeReinstateLog`: TemplateSet on suspend/resume/reinstate was not asserted |
| 740 | SBR | equivalent | storage/memory on a read-only reference |

### `src/records/WorkRules.sol`

20 survivors: 12 killed, 7 equivalent, 1 defensive.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 147 | CR | killed | `test_Constructor_AnnouncesTheFirstDelivery`: constructor did not have to emit DeliverySet |
| 162 | MIA | killed | `test_SetRecord_AFinalizedWorkRefusesBeforeAnyOtherCheck`: setRecord on a finalized work: refusal order (same record no-op, stranger) was unpinned; WorkFacts still refuses the write itself |
| 185 | ROR | equivalent | Outcome.NONE is the first enum value, `<=` equals `==` |
| 236 | MIA | killed | `test_Renounce_TheRoyaltyPowerAloneNeverTouchesTheRecordLocks`: renouncing only the royalty power called facts.lock(false,false) (an extra Locked event) |
| 255 | ROR | equivalent | `<= 0` equals `== 0` on bytes32 |
| 259 | CR | killed | `test_Relicense_RefreshesTheMetadata`: relicense did not have to emit the ERC-4906 refresh |
| 274 | CR | killed | `test_SetRoyaltyRate_NeedsAnOpenRecord`: setRoyaltyRate on a record that is not open (same-rate no-op, unminted token) was unpinned |
| 306 | CR | killed | `test_RepinRenderer_MovesTheVersionAndRefreshesTheMetadata`: repinRenderer did not have to bump the version (the state hash moved anyway through the renderer) |
| 307 | CR | killed | `test_RepinRenderer_MovesTheVersionAndRefreshesTheMetadata`: repinRenderer did not have to emit the ERC-4906 refresh |
| 328 | ROR | killed | `test_Stores_ACodeHashAboveTheStoresOwnIsRefused`: addStore accepted a code hash above the store's own (only a lower one was tested) |
| 362 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one |
| 362 | UOR | equivalent | `++i` vs `i++` as a loop statement |
| 363 | ROR | killed | `test_FileStore_OnlyTheWorksOwnFilesAndTheMetadataIsRefreshed`: setFileStore accepted any file ID above one of the work's media files (only ID 0 was tested) |
| 371 | ROR | defensive | ContentStore.firstMissing never answers above `to` (clamped to chunkCount), so `<` equals `!=` unless the permanent store lies |
| 377 | CR | killed | `test_FileStore_OnlyTheWorksOwnFilesAndTheMetadataIsRefreshed`: setFileStore did not have to emit the ERC-4906 refresh |
| 408 | MIA | killed | `test_RefreshAllMetadata_ATokenWithoutEditionsIsRefreshedAlone`: refreshAllMetadata for a token without an editions contract was never run (the mutant reverts calling address zero) |
| 546 | ROR | equivalent | `<` vs `!=` on a loop counter that steps by one |
| 546 | UOR | equivalent | `++i` vs `i++` as a loop statement |
| 557 | ROR | equivalent | ContentStore refuses a manifest with zero chunks (ContentChunkCountInvalid), so chunkCount 0 cannot occur for a known file |
| 564 | AOR | killed | `test_Stores_EachIdNamesItsOwnStore`: every store ID answered the first store: tests never added two different stores |

### `src/sales/EnglishAuction.sol`

81 survivors: 60 killed, 19 equivalent, 2 defensive.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 79 | CONST | killed | `test_Constants_GasValues`: PAYOUT_GAS 100,001: the public constant was not pinned (behaviour differs only by one gas) |
| 79 | CONST | killed | `test_Constants_GasValues`: PAYOUT_GAS 99,999: the public constant was not pinned |
| 82 | CONST | killed | `test_Constants_GasValues`: DELIVERY_GAS 300,001: the public constant was not pinned |
| 82 | CONST | killed | `test_Constants_GasValues`: DELIVERY_GAS 299,999: the public constant was not pinned |
| 84 | CONST | killed | `test_Constants_GasValues`: DELIVERY_RESERVE 50,001: the public constant was not pinned |
| 84 | CONST | killed | `test_Constants_GasValues`: DELIVERY_RESERVE 49,999: the public constant was not pinned |
| 95 | CONST | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the smallest increment share, 1,000 |
| 96 | CONST | killed | `test_Constructor_ChecksTheEscrowAndTheRefusalGasBounds`: the constructor accepted a refusal gas of 2,999,999 |
| 97 | CONST | killed | `test_Constructor_ChecksTheEscrowAndTheRefusalGasBounds`: a refusal gas of 15,000,000 was refused |
| 169 | CR | killed | `test_Constructor_ChecksTheResolverTheAllowlistAndTheStatementLog`: constructor accepted an economics resolver that does not declare IEconomicsResolver |
| 170 | CR | killed | `test_Constructor_ChecksTheEscrowAndTheRefusalGasBounds`: constructor accepted an escrow without code |
| 171 | CR | killed | `test_Constructor_ChecksTheResolverTheAllowlistAndTheStatementLog`: constructor accepted a statement log without code |
| 173 | CR | killed | `test_Constructor_ChecksTheResolverTheAllowlistAndTheStatementLog`: constructor accepted an asset allowlist without code |
| 199 | CR | killed | `test_StartWithBid_APolicyCannotReenter`: startWithBid lost its reentrancy guard: a policy could settle another sale from inside the start |
| 213 | ROR | killed | `test_Restart_RefusesACancelledSale`: revert reason only: a CANCELLED sale passed the status test and restart failed on ownerOf of the burned token instead of InvalidAuctionState |
| 213 | ROR | equivalent | Outcome.NONE is the enum's zero: `> NONE` equals `!= NONE` |
| 220 | MIA | killed | `test_Restart_RefusesAShareAboveTheWhole`: restart took a fee share above 100,000 from the gate (only a lying gate answers one; pinned anyway) |
| 220 | ROR | killed | `test_Restart_RefusesAShareAboveTheWhole`: restart refused a full network share of exactly 100,000 |
| 227 | CR | killed | `test_Restart_ForgetsTheRefundedBid`: restart kept the refunded bid as the new sale's reserve (minimum bid stayed at the old bid) |
| 228 | CR | defensive | at a restart pausedAt is already zero and recipient is unread; a stale outcomeFrom matters only if the statement log later answers no outcome for a token it had one for |
| 285 | MIA | defensive | the resolver never names a zero museum (EconomicsResolver._setMuseum refuses it), and the transfer to zero reverts anyway: revert reason only |
| 308 | MIA | killed | `test_Settle_AZeroFeeNamesNoFeeRecipient`: with a zero fee SaleSettled named the network fee recipient instead of zero |
| 357 | ROR | killed | `test_SettleOrRefund_AllowedAfterTheDelayToo`: settleOrRefund worked only in the exact second the delay ended |
| 400 | ROR | equivalent | `> 0` equals `!= 0` on an unsigned bytes32 |
| 407 | AOR | equivalent | `now % pausedAt` equals `now - pausedAt` while now < 2 * pausedAt; a pause is live at most 3 days, so it differs only for a pause begun within 3 days of 1970 |
| 414 | ROR | equivalent | `<= 0` equals `== 0` on an unsigned bytes32 |
| 414 | ROR | killed | `test_Cancel_OnlyTheRecordedOutcomeAtAnyLaterPosition`: cancel accepted any outcome reference numerically above the recorded one |
| 414 | ROR | killed | `test_Cancel_OnlyTheRecordedOutcomeAtAnyLaterPosition`: cancel refused an outcome recorded later than the first position after the pause |
| 471 | LOR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig compared only duration AND window: one stale parameter passed |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected duration above the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected extension window above the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected increment share above the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected refusal gas above the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected refusal gas below the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected duration below the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected extension window below the one in force |
| 471 | ROR | killed | `test_SetConfig_EachParameterIsComparedExactly`: setConfig accepted an expected increment share below the one in force |
| 502 | ROR | equivalent | NONE is the enum's zero: the replacement comparison is the same test |
| 526 | ROR | equivalent | NONE is the enum's zero: the replacement comparison is the same test |
| 533 | ROR | equivalent | NONE is the enum's zero: the replacement comparison is the same test |
| 542 | ROR | equivalent | NONE is the enum's zero: the replacement comparison is the same test |
| 584 | MIA | killed | `test_OnERC721Received_AcceptsAMintIntoCustodyDuringAStart`: onERC721Received refused even a mint into custody during a start (reachable only by a token that mints with a receiver callback; StreamBase does not) |
| 587 | RR | killed | `test_OnERC721Received_AcceptsAMintIntoCustodyDuringAStart`: onERC721Received never returned the selector (same path as above) |
| 592 | ROR | killed | `test_SupportsInterface_RefusesALowerId`: supportsInterface answered true for every ID up to IERC165's |
| 592 | ROR | killed | `test_SupportsInterface_RefusesALowerId`: supportsInterface answered true for every ID up to IEnglishAuction's |
| 592 | ROR | killed | `test_SupportsInterface_RefusesALowerId`: supportsInterface answered true for every ID up to IERC721Receiver's |
| 609 | ROR | killed | `test_Start_RefusesEveryOtherSaleKind`: start accepted any sale kind numerically below ENGLISH_AUCTION |
| 619 | ROR | equivalent | NONE is the enum's zero: the replacement comparison is the same test |
| 647 | ROR | killed | `test_Bid_TheLargest96BitBidIsAccepted`: a bid of exactly 2^96 - 1 wei was refused |
| 659 | MIA | equivalent | when recipientSet is false the branch writes false and zero over false and zero (recipient is zero whenever the flag is false) |
| 661 | CR | equivalent | a stale s.recipient is never read while recipientSet is false, and is rewritten whenever the flag is set |
| 665 | AOR | equivalent | `end % now` equals `end - now` while now < end < 2 * now, which holds for every live sale at a real clock (sales last days) |
| 665 | ROR | equivalent | with exactly the window left the extended end, now + window, is the old end: same value stored and logged |
| 687 | LOR | killed | `test_Settle_AFeeWithNoRecipientIsRefused`: revert reason only: _pay's own guard never fired, a zero fee recipient was refused by RevenuePayment (InvalidWallet) instead of InvalidRecipient; the auction-as-wallet arm needs a lying resolver |
| 687 | MIA | killed | `test_Settle_AFeeWithNoRecipientIsRefused`: revert reason only: same as the LOR mutant on this line |
| 705 | MIA | killed | `test_Settle_AGasShortfallRevertsInsteadOfDeliveringWithLess`: settle no longer refused a gas shortfall before the delivery (a caller could starve the delivery) |
| 706 | CR | killed | `test_Settle_AGasShortfallRevertsInsteadOfDeliveringWithLess`: the DeliveryInsufficientGas revert was removed |
| 706 | CR | killed | `test_Settle_AGasShortfallRevertsInsteadOfDeliveringWithLess`: the DeliveryInsufficientGas revert was removed (same mutant, second shard) |
| 713 | CR | equivalent | `ok;` is a statement with no effect |
| 726 | MIA | killed | `test_WithdrawBid_ABidForARecipientIsCreditedAndTheRecipientCleared`: a refunded bid kept its named recipient: the auction view showed a recipient with no bidder |
| 726 | MIA | equivalent | clearing when recipientSet is false writes false and zero over false and zero |
| 726 | MIA | killed | `test_WithdrawBid_ABidForARecipientIsCreditedAndTheRecipientCleared`: the recipient was cleared only when none was set: a refunded bid kept its recipient |
| 727 | CR | equivalent | with the flag left true the recipient is zero and the bidder is zero, so _recipientOf answers zero either way; the next bid rewrites both |
| 727 | RR | killed | `test_WithdrawBid_ABidForARecipientIsCreditedAndTheRecipientCleared`: refunding a bid placed for a named recipient reverted (withdrawBid, cancel, delisted settle, refusal) |
| 728 | CR | equivalent | a stale s.recipient is never read while recipientSet is false |
| 728 | RR | killed | `test_WithdrawBid_ABidForARecipientIsCreditedAndTheRecipientCleared`: refunding a bid placed for a named recipient reverted |
| 742 | ROR | killed | `test_Pause_IsLiveThroughItsLastSecond`: a pause was written down as over in its last second (pausedAt + MAX_PAUSE): the bidder could no longer withdraw |
| 746 | ROR | equivalent | NONE is the enum's zero: `<=` equals `==` |
| 775 | ROR | killed | `test_Pause_IsLiveThroughItsLastSecond`: the clock views showed a pause as over in its last second while the state was still PAUSED |
| 786 | AOR | equivalent | `endTime % pausedAt` equals `endTime - pausedAt` while pausedAt <= endTime < 2 * pausedAt, true at any real clock |
| 786 | AOR | killed | `test_Resume_KeepsTheRemainingTimeWhenLongerThanTheDuration`: a resumed sale lost its remaining time when that was longer than the duration in force (endTime / pausedAt is 1) |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the shortest duration, 1 hour |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the longest duration, 7 days |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the shortest extension window, 1 minute |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the longest extension window, 1 day |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused a window equal to the duration |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the smallest increment share, 1,000 |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused an increment share of the whole, 100,000 |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused the refusal gas ceiling, 15,000,000 |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused an unchanged refusal gas |
| 813 | ROR | killed | `test_SetConfig_TakesEveryBoundItself`: setConfig refused every refusal gas but exactly double |

### `src/sales/UniformClearing.sol`

2 survivors: 2 equivalent.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 144 | ROR | equivalent | count is min(demand, cap), never above demand, so < and != agree |
| 272 | UOR | equivalent | --i vs i-- as a statement |

### `src/sales/UniformEditionAuction.sol`

94 survivors: 61 equivalent, 27 killed, 6 gas.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 100 | CR | equivalent | ADOPTED_RUN is not used by the adapter (the lens has its own constant); removing it changes no bytecode |
| 100 | CR | equivalent | ADOPTED_RUN is not used by the adapter (the lens has its own constant); removing it changes no bytecode |
| 210 | CR | killed | `test_Constructor_RejectsAnEnglishAuctionWithoutCode`: constructor accepted an English auction with no code when the lens was deployed for the same address |
| 244 | CR | killed | `test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund`: open lost its re-entry guard |
| 261 | CR | killed | `test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund`: adopt lost its re-entry guard |
| 276 | CR | killed | `test_CloseEdition_RefusesAnotherTokenAndAnUnlistedOne`: closeEdition lost its target check (any token, or an unlisted one) |
| 278 | ROR | equivalent | 0 is the lowest status, so > NONE and != NONE (or <= NONE and == NONE) agree |
| 295 | ROR | equivalent | 0 is the lowest status, so > NONE and != NONE (or <= NONE and == NONE) agree |
| 353 | CR | killed | `test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund`: bid lost its re-entry guard |
| 361 | ROR | killed | `test_Bid_TheLastBidIdIsAccepted`: the last bid ID, 2^32 - 1, was refused |
| 371 | ROR | equivalent | step == lowStep rewrites lowStep with the same value |
| 373 | ROR | equivalent | step == highStep rewrites highStep with the same value |
| 395 | CR | killed | `test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund`: raise lost its re-entry guard |
| 409 | ROR | equivalent | newStep == highStep rewrites highStep with the same value |
| 457 | ROR | equivalent | status is OPEN or SETTLING at this point (NONE, SETTLED and VOID left earlier), so <= OPEN is == OPEN |
| 457 | ROR | killed | `test_Settle_OnceBegunNoLongerReadsTheOneOfOne`: a settle call continuing a scan read the 1/1 again (and reverted when it no longer answered) |
| 463 | ROR | equivalent | VOID is the highest status |
| 464 | ROR | equivalent | after _finish the status is SETTLING or SETTLED here (VOID returned on the line before) |
| 507 | MIA | killed | `test_ClaimBidFor_WithoutARefundCreditsNothing`: claimBidFor with no refund emitted Credited(0) and started a credit clock |
| 533 | CR | killed | `test_Reentry_OpenAdoptBidRaiseAndExpireCreditAreRefusedDuringARefund`: expireCredit lost its re-entry guard |
| 542 | ROR | killed | `test_ExpireCredit_AnyTimeAfterTheExpiry`: expireCredit worked only in the exact second of the expiry |
| 566 | LOR | killed | `test_Abandon_APaidSaleIsNeverVoidedWhateverTheLensAnswers`: abandon's own state guard let a cleared, paid SETTLING sale be voided once the lens lets the call through (lens answer mocked) |
| 566 | MIA | killed | `test_Abandon_APaidSaleIsNeverVoidedWhateverTheLensAnswers`: abandon's own state guard removed: a paid sale voided once the lens lets the call through (lens answer mocked) |
| 566 | ROR | equivalent | differs only for NONE, whose scan word is zero, so the guard still refuses it |
| 566 | ROR | killed | `test_Abandon_APaidSaleIsNeverVoidedWhateverTheLensAnswers`: abandon's own state guard refused only NONE: a paid sale voided once the lens lets the call through (lens answer mocked) |
| 566 | ROR | killed | `test_Abandon_APaidSaleIsNeverVoidedWhateverTheLensAnswers`: abandon's own state guard let a never-opened sale through once the lens lets the call through (lens answer mocked) |
| 566 | ROR | killed | `test_Abandon_ASaleAbandonedMidScanIsNotAbandonedAgain`: abandon's own state guard let a sale abandoned mid-scan be abandoned again (lens answer mocked) |
| 601 | ROR | killed | `test_SetLimits_RefusesAHigherExpectedValueAndAcceptsTheCurrentGas`: setLimits accepted an expected value above the current one |
| 685 | ROR | equivalent | CANCELLED is the highest 1/1 state |
| 691 | ROR | killed | `test_Bid_ExactlyASoftWindowBeforeTheEndStoresNoSoftEnd`: a bid exactly a soft window before the end stored a soft end equal to the end |
| 693 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 714 | CR | equivalent | without the assignment the state is NONE (0) when the clock is not read; callers only compare it with PAUSED and CANCELLED on that path |
| 719 | MIA | killed | `test_Adopt_RunsOnItsOwn_BidsAndSettlesByItsOwnCloseOnly`: a sale that runs on its own took the clock's zero end as its 1/1 end: bids near the close refused, settlement early |
| 719 | ROR | equivalent | an equal end rewrites the same end and the same close |
| 719 | ROR | killed | `test_Adopt_RunsOnItsOwn_BidsAndSettlesByItsOwnCloseOnly`: a sale that runs on its own took the clock's zero end as its 1/1 end |
| 726 | AOR | equivalent | soft > backstop cannot occur: softEnd is written at most closeAt + maxExtension and closeAt only moves later, so a larger backstop in _end changes nothing |
| 727 | MIA | equivalent | soft > backstop cannot occur: softEnd is written at most closeAt + maxExtension and closeAt only moves later |
| 727 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 727 | RR | equivalent | soft > backstop cannot occur: softEnd is written at most closeAt + maxExtension and closeAt only moves later |
| 728 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 742 | ROR | equivalent | CANCELLED is the highest 1/1 state |
| 747 | ROR | equivalent | CANCELLED, the only state above SETTLED, returned on the lines before |
| 750 | CR | killed | `test_Settle_StoresTheOneOfOneEndItRead`: the first settle call did not store the 1/1 end it read |
| 769 | ROR | equivalent | scan[7] is never below low |
| 778 | MIA | gas | deleting a scan slot that is already zero: gas only |
| 802 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 805 | ROR | equivalent | count never exceeds demand |
| 853 | MIA | gas | the clearing call starts every sweep, so the settler's slot it now reads is always zero: one extra SLOAD |
| 853 | ROR | equivalent | limit is 16 (_SWEEP_FIRST) or 96, so <= and == agree |
| 859 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 860 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 867 | ROR | equivalent | swept never exceeds total (n is clamped to total - swept) |
| 872 | MIA | gas | deleting a sweep slot that is already zero: gas only |
| 897 | ROR | equivalent | < vs != on a loop counter that steps by one |
| 897 | UOR | equivalent | ++i vs i++ as a loop statement |
| 899 | MIA | killed | `test_Settle_RefusesAnIndexThatReachesAnotherStepsDepartureLog`: with no range check an index far past the clearing step's log read another step's log and was swept as a departure, settling with a wrong cut-off |
| 899 | ROR | killed | `test_Settle_RefusesAnIndexThatReachesAnotherStepsDepartureLog`: an index far past the clearing step's log read another step's log and was swept as a departure, settling with a wrong cut-off |
| 899 | ROR | equivalent | index == total reads an empty entry (quantity 0), which UniformClearing.sweep refuses with the same InvalidSettlementOrder(i) |
| 922 | MIA | equivalent | RevenuePayment.payETH returns at once for a zero amount, and the seller is never zero or the escrow |
| 922 | ROR | equivalent | the fee never exceeds the revenue |
| 952 | ROR | equivalent | the status here is only ever one of the values on which both comparisons agree (CLOSED is never stored) |
| 952 | ROR | equivalent | the status here is only ever one of the values on which both comparisons agree (CLOSED is never stored) |
| 961 | MIA | equivalent | a VOID sale never has a stored result (count 0), so the SETTLED branch computes nothing for it |
| 961 | ROR | equivalent | the status is SETTLED or VOID here |
| 961 | ROR | equivalent | a VOID sale never has a stored result (count 0), so the SETTLED branch computes nothing for it |
| 965 | ROR | equivalent | inside b.step >= r.step, so != and > agree |
| 1009 | AOR | equivalent | a starting decade one too high is lowered by the scan loop (start minus a decade, scale / 10 exactly) before any price is computed |
| 1009 | AOR | equivalent | a starting decade one too high is lowered by the scan loop (start minus a decade, scale / 10 exactly) before any price is computed |
| 1009 | AOR | equivalent | a starting decade one too high is lowered by the scan loop (start minus a decade, scale / 10 exactly) before any price is computed |
| 1013 | ROR | equivalent | the two differ only when the operands are equal, where both branches give the same value |
| 1024 | MIA | gas | an empty book has lowStep = highStep = 0: the scan reads one empty word and gives the same zero result |
| 1025 | CR | equivalent | for an empty book scan[7] already equals low (both 0) |
| 1026 | CR | gas | an empty book has lowStep = highStep = 0: the scan reads one empty word and gives the same zero result |
| 1083 | CR | gas | without w := 0 the outer loop reads the remaining words, but every used step breaks again on demand >= cap: same result, more gas |
| 1088 | MIA | equivalent | the inner loop has the same condition, so the block only re-stores unchanged start and scale |
| 1131 | CR | equivalent | scan[11] (best revenue) is never read after _scanWords returns; a resumed scan recomputes it from the best count and step |
| 1150 | AOR | equivalent | unreachable: a bid enters a step once, so position + quantity never exceeds the sale's live units, already checked below 2^32 in bid |
| 1150 | AOR | equivalent | unreachable: a bid enters a step once, so position + quantity never exceeds the sale's live units, already checked below 2^32 in bid |
| 1150 | AOR | equivalent | unreachable: a bid enters a step once, so position + quantity never exceeds the sale's live units, already checked below 2^32 in bid |
| 1150 | MIA | equivalent | unreachable: a bid enters a step once, so position + quantity never exceeds the sale's live units, already checked below 2^32 in bid |
| 1151 | CR | equivalent | unreachable: a bid enters a step once, so position + quantity never exceeds the sale's live units, already checked below 2^32 in bid |
| 1151 | CR | equivalent | unreachable: a bid enters a step once, so position + quantity never exceeds the sale's live units, already checked below 2^32 in bid |
| 1215 | MIA | killed | `test_SetConfig_RefusedOnceTheTermsCounterIsFull`: a full 24-bit terms counter reverted with Panic(0x11) instead of InvalidConfig |
| 1215 | ROR | equivalent | id is a uint24, never above its maximum |
| 1228 | ROR | killed | `test_SetLimits_RefusesAHigherExpectedValueAndAcceptsTheCurrentGas`: setLimits refused the current payout gas set again |
| 1241 | ROR | killed | `test_Bid_ASoftEndAtTheLastClockSecondIsAccepted`: a soft end at the last 32-bit clock second, 2^32 - 1, reverted with ClockOverflow |
| 1344 | CR | equivalent | settle reads the status from storage, never from the decoded word |
| 1347 | CR | killed | `test_Adopt_RunsOnItsOwn_BidsAndSettlesByItsOwnCloseOnly`: settle read the stored 1/1 end as zero: a sale that runs on its own settled before its close |
| 1349 | CR | equivalent | openedAt is not read on the settlement path |
| 1353 | CR | equivalent | bidCount is not read on the settlement path |
| 1373 | CR | equivalent | stepCount is not read on the settlement path |
| 1375 | CR | equivalent | softWindow is read only when the 1/1 is not read fresh; settlement always reads it fresh |
| 1387 | ROR | equivalent | 0 is the lowest status, so > NONE and != NONE (or <= NONE and == NONE) agree |
| 1390 | ROR | equivalent | callers want OPEN (NONE refused on the line before) or SETTLING (OPEN and SETTLED handled before the call), so > and != agree |

Measured again with the corrected parts ([The statements parts](#the-statements-parts)): 67
survivors. Every mutant marked killed above is killed there. The survivors are the equivalent
and gas mutants above, with line 1151 counted once (it is one mutant, which the campaign's
parts ran twice), and one comment mutant the campaign's parts never ran:

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 1017 | CR | killed | `test_Settle_AResumedScanKeepsTheDemandAlreadyCounted`: a scan resumed in a second settle call forgot the demand counted in the first and sold one copy fewer |

That test was written after the second measurement and shown to fail on the mutant; the
score measured again does not count it.

### `src/terms/StreamTerms.sol`

10 survivors: 9 killed, 1 equivalent.

| Line | Rule | Verdict | Why, or the test |
| ---: | --- | --- | --- |
| 73 | MIA | killed | `test_Constructor_WithoutEditionsPairsNothing`: deploying without an editions contract was never run |
| 130 | CR | killed | `test_LowerFeeShare_NeedsALiveWork`: lowerFeeShare on a token never minted: only the revert reason differs (a burned token is still refused by the token's setRoyalty) |
| 138 | MIA | killed | `test_Pairing_APairSetHereNeverAsksTheIndependentStreamModule`: IStream.setRoyalty and IEditions.setRoyalty share a selector; the mutant differs only by then asking the Independent Stream module about the editions contract |
| 171 | LOR | killed | `test_Pairing_APairSetHereNeverAsksTheIndependentStreamModule`: a pair set by the network must be answered without the Independent Stream module |
| 174 | ROR | equivalent | Form.ERC721 is the first enum value, `<=` equals `==` |
| 188 | LOR | killed | `test_Pairing_APairSetHereNeverAsksTheIndependentStreamModule`: tokenOfEditions of a pair set here must not ask the Independent Stream module |
| 188 | MIA | killed | `test_Pairing_APairSetHereNeverAsksTheIndependentStreamModule`: tokenOfEditions of a pair set here must not ask the Independent Stream module |
| 191 | ROR | killed | `test_IndependentPair_OnlyAnErc1155ListingNamesTheTokenOfEditions`: a listing of form PAIR named a token for an editions contract |
| 217 | MIA | killed | `test_Pairing_AnEmptyIndependentStreamSlotListsNoPair`: an empty INDEPENDENT_STREAM slot was never read (the mutant reverts calling address zero) |
| 235 | MIA | killed | `test_LowerFeeShare_NeverDeploysTheOldVault`: checking the stated current terms deployed the old vault as a side effect |

<!-- /generated -->

## Not triaged

The survivors of the other files (lenses, the renderer and its text libraries, governance, the
entropy module, the smaller libraries) were measured and not triaged: their floors are set from
the campaign's score alone. The weekly workflow lists every survivor in its report.
