# Works and storage

A work has two halves. Its **facts** live in `StreamWorkFacts6529`, a permanent, unowned contract
that serves 6529 Stream and every Independent Stream token, keyed by token contract and token ID.
The **rules** for changing a work (who may edit, when, with whose consent) live in the token's
`RECORDS` module, `WorkRules`, which the network can replace. The bytes of a work live in the
permanent `ContentStore`; where else copies are served from lives in the replaceable `WorkDelivery`.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`StreamWorkFacts6529`](../../src/core/StreamWorkFacts6529.sol) ([`IWorkFacts`](../../src/interfaces/core/IWorkFacts.sol)) | permanent, unowned | Media, descriptive record, license, finalize flag, pinned renderer, locks, on-chain-complete flag. Accepts changes only from the token's RECORDS module, within its own rules. |
| `WorkRules` ([`IWorkRules`](../../src/interfaces/core/IWorkRules.sol)) | module (RECORDS) | Who edits a record and when; finalize timing and its 14-day notice; relicense and royalty-rate consent; repin; renouncing powers; the state hash and version; added stores; the delivery pointer. One instance serves Stream; Independent Stream tokens use the instance in `StreamDirectory6529.INDEPENDENT_RECORDS`. |
| [`WorkDelivery`](../../src/stream/WorkDelivery.sol) ([`ILocators`](../../src/interfaces/core/ILocators.sol)) | module | Locators (Arweave and IPFS addresses) and the preferred copy of each file. |
| [`ContentStore`](../../src/content/ContentStore.sol) | permanent, unowned | Chunks, manifests, file IDs, verified reads, base64 attestation, completeness attestation. |
| [`DependencyRegistry`](../../src/content/DependencyRegistry.sol) | module | Names and versions of script libraries, each one complete file. |

## Concepts

### Facts: what never changes

`StreamWorkFacts6529` holds these whatever any module does:

- A record opens only with the exact item the token was minted from (checked against
  `IStream(token).itemHashOf`), and its media are the files that item committed to. Anyone may
  open it. Media never change.
- After finalize the descriptive record never changes.
- A CC0 license is never left. A locked license never changes.
- Finalize pins the token's current RENDERER module and its code hash. After that the renderer
  changes only by `repin`, and never once the pin is locked. A pinned renderer whose code
  changed is refused, so `tokenURI` reverts rather than show another picture.
- Locks are one-way.
- "On-chain complete" is checked against the content store by anyone: one `isComplete` read
  per media file, after the file has been attested complete (`attestComplete`, in steps of the
  caller's size).

### Rules: who changes a work (WorkRules)

- **Edit and finalize.** Any wallet of the lead artist's account (from the accounts module) sets
  the record and finalizes, before finalize, against the current state hash. Once the first
  sale has an outcome, anyone may record a finalize notice and finalize 14 days later (a
  compiled constant of this module). The artist is never held back by a notice.
- **Relicense and royalty rate.** Need the network's call and every party's signature, counted
  by account, before a deadline and bound to the state hash. CC0 is never left. A rate change
  goes through the TERMS module to the token.
- **Repin.** The network alone may repin a finalized work's renderer until the artist locks it.
- **Renounce.** The artist gives up the royalty-rate, relicense or repin power for good. Giving up
  the royalty or license power also needs the network's call. Renouncing maps to
  `StreamWorkFacts6529.lock` and `ITerms.lockRoyaltyRate`.
- **Replay.** Every applied change bumps the version and the state hash, so no signature applies
  twice. A successor module starts every work at a new state hash.
- **Stores and delivery.** The network adds stores (append-only, code hash pinned) and replaces
  the delivery contract.

### Add a locator and switch the preferred location

The artist (before finalize) and the platform add locators to the delivery module: canonical
`ar://` or `ipfs://` content addresses, 8 per side per file. The storage operator chooses the
preferred copy among the registered ones, or the on-chain bytes of a complete work. Each change
emits ERC-4906 through the token.

## Storage

### Upload and register a file

Uploads are permissionless and in any order. A file is a manifest of chunks of at most 24,575
bytes; its ID commits to the whole manifest and nothing else. Reads check every chunk against its
hash and never return partial data. Large files are attested complete in several transactions;
after that, completeness is one read.

| Limit (compiled) | Value |
| --- | --- |
| Chunk size | 24,575 bytes |
| Chunks per file | 1 to 4,096 |
| Parts per linked chunk | 1 to 256 |
| Media files per work | 1 to 32 |
| Record file | one complete chunk, `Identity`, SHA-256 digest |
| License ID | 1 to 64 bytes of `[A-Za-z0-9.+-]` |
| Locators per file | 16; 8 by the artist and 8 by the platform before finalize |
| Finalize notice | 14 days (WorkRules, replaceable) |

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| WS-1 | Every per-token change of `StreamWorkFacts6529` reverts with `RecordNotOpen` until the record is opened. | `test_ModuleCalls_EveryChangeWaitsForTheRecordToOpen`, `test_ModuleCalls_NeedAnOpenRecord`, `test_MarkOnChainComplete_OnlyWhenEveryFileIsStored` |
| WS-2 | `open` is permissionless and accepts only the item the token was minted from and its committed media: 1 to 32 files, the primary first, each declared SHA-256 equal to the store's. | `test_Open_AnyoneOpensWithTheMintedItemAndItsMedia`, `test_Open_RefusesAnotherItem`, `test_Open_TheMostMediaFilesOpenAndOneMoreIsRefused`, `test_Open_RefusesADigestOtherThanTheStoresDeclaration` |
| WS-3 | A record opens once, for a live token. | `test_Open_RefusesTwice`, `test_Open_RefusesABurnedToken`, `test_Open_RefusesATokenNeverMinted` |
| WS-4 | The approved record file and a non-CC0 license are stored as approved, so neither can keep a minted work from opening. | `test_SetRecord_ApprovedRecordsTheRulesRefuseOpenAndAreFixable`, `test_Open_KeepsAnUnregisteredLicenseTextThatFinalizeRefuses`, `test_Relicense_RepairsAnUnregisteredApprovedText` |
| WS-5 | A CC0 license names the deployment's CC0 text. | `test_Open_ACc0LicenseMustNameTheDeploymentText`, `test_SetLicense_ACc0WorkStaysCc0InAnyCase`, `test_Open_TheCc0TextUnderAnotherIdentifierAndCc0WithAnotherTextEitherWay` |
| WS-6 | The media list never changes after `open`. | `test_Record_MediaNeverChange`, `test_Hostile_ARecordsModuleCannotBreakAnyGuarantee` |
| WS-7 | Any wallet of the lead artist's account sets the record and finalizes, before finalize, against the current state hash; once the first sale has an outcome, anyone finalizes 14 days after a recorded notice. | `test_SetRecord_FollowsTheAccountsWallets`, `test_Finalize_TheArtistsStateHashIsChecked`, `test_Finalize_NobodyElseBeforeTheFirstSaleEnds`, `test_Finalize_AnyoneFourteenDaysAfterANoticeOnceSold` |
| WS-8 | A record file is accepted only if it is registered, `Identity`, SHA-256, one chunk and complete. | `test_SetRecord_Refusals`, `test_SetRecord_ApprovedRecordsTheRulesRefuseOpenAndAreFixable`, `test_Finalize_TheRecordIsOneCompleteChunkStoredAsItIs`, `test_DigestKind_EveryFileNeedsSha256` |
| WS-9 | Finalize needs a complete license text, and pins the token's current RENDERER module with its code hash. | `test_Finalize_TheLicenseTextMustBeStored`, `test_Finalize_PinsTheTokensRendererModuleOnce`, `test_Finalize_TheDeploymentsCc0TextMustBeCompleteToo` |
| WS-10 | The state hash commits to the token, version, record file, license, royalty rate and renderer. | `test_StateHash_Golden`, `test_StateHash_FollowsTheRendererModuleOnlyBeforeFinalize` |
| WS-11 | Every change the rules module applies bumps the work's version; a call that changes nothing (setting the record the work already has) is a no-op that leaves the version. Marking a record complete on-chain and recording a finalize notice, which anyone may do, leave the version and the state hash as they are; the finalize that anyone may make once the notice period has passed is an applied change and bumps the version. | `test_SetRecord_TheArtistReplacesItAndTheVersionMoves`, `test_SetRecord_TheSameRecordIsANoOp`, `test_StateHash_IsThisModulesOwnAndIgnoresPermissionlessActions`, `test_Finalize_ANoticeLeavesTheVersionAndTheStateHash` |
| WS-12 | CC0 is never left, whatever module asks. | `testFuzz_SetLicense_CC0IsNeverLeft`, `test_Relicense_ACc0WorkStaysCc0`, `test_Hostile_ARecordsModuleCannotBreakAnyGuarantee` |
| WS-13 | A relicense needs the network's call and every party's signature, by a wallet of that party's account, before the deadline. | `test_Relicense_WithEveryConsentAndTheNetwork`, `test_Relicense_TheNetworkOnly`, `test_Relicense_RefusesMissingOrBadConsents`, `test_Relicense_RefusesAnExpiredDeadlineAndAStaleState` |
| WS-14 | A royalty-rate change needs the network's call and every party's signature, counted by account; it reaches the token through the TERMS module. | `test_SetRoyaltyRate_WithEveryConsentUpOrDown`, `test_SetRoyaltyRate_TheSameRateIsANoOpAndTheNetworkOnly`, `test_SetRoyaltyRate_EveryPartyByAccountThenThroughTheTermsModule` |
| WS-15 | The network alone repins a finalized work's renderer, against the current state hash, until the pin is locked. | `test_RepinRenderer_TheNetworkAloneAfterFinalize`, `test_RepinRenderer_RefusesAStaleState`, `test_Renounce_TheRepinPowerByTheArtistsSignatureAloneAfterFinalize` |
| WS-16 | A pinned renderer is held with its code hash; a changed code is refused and `tokenURI` fails closed. | `test_Finalize_PinsTheTokensRendererModuleOnce`, `test_RendererOf_RefusesAPinnedRendererWhoseCodeChanged`, `test_RendererOf_RefusesMovedCodeEitherWay` |
| WS-17 | On-chain complete is one-way and set by anyone once every media file reads complete in the content store. | `test_MarkOnChainComplete_OnlyWhenEveryFileIsStored`, `test_ALargeWorkIsAttestedInPiecesThenMarkedComplete` |
| WS-18 | A locator is a canonical `ar://` or `ipfs://` content address; one spelling per address. | `test_AddLocator_RefusesNearMisses`, `test_Locator_OnlyContentAddressesAreAccepted`, `test_Locator_OneSpellingPerAddress` |
| WS-19 | Before finalize 8 locators per file from the artist and 8 from the platform; after finalize only the platform adds, up to 16. | `test_AddLocator_SeparateQuotasThenThePlatformTakesTheRestAfterFinalize`, `test_AddLocator_ThePlatformHasHalfBeforeFinalizeAndTheRestAfter`, `test_AddLocator_TheArtistBeforeFinalizeThePlatformAlways` |
| WS-20 | Locators are append-only and belong to one of the work's files; a locator marked dead is never served again. | `test_AddLocator_Refusals`, `test_MarkLocatorDead_AllDeadServesTheOnChainCopyAndTheUriStaysTaken`, `testFuzz_PreferredLocator_MatchesTheModel` |
| WS-21 | The preferred locator is the file's choice, else the collection's, else the global one, else the first registered, else the on-chain copy of a complete work. | `test_PreferredLocator_TheMostSpecificLiveChoiceWins`, `test_PreferredLocator_TheImplicitOnChainCopyNeverAsksTheStore`, `testFuzz_PreferredLocator_MatchesTheModel` |
| WS-22 | The storage operator chooses only among copies registered for that file, or its on-chain bytes. | `test_Setters_TheStorageOperatorOnlyAndTheyRefresh`, `test_SetFilePreference_RefusesEveryIndexPastTheList`, `test_PreferredLocator_OnChainOnlyOnceRecordedComplete`, `test_Stack_OnlyTheStorageOperatorMarksALocatorDead` |
| WS-23 | Every visible change emits ERC-4906 through the token. | `test_Refresh_EveryVisibleChangeEmitsThroughTheToken`, `test_Open_AnyoneOpensWithTheMintedItemAndItsMedia`, `test_SetRecord_TheArtistReplacesItAndTheVersionMoves`, `test_Setters_RefreshTheTokenAndItsEditions` |
| WS-24 | A chunk is at most `CHUNK_SIZE` bytes; writing is idempotent. | `test_WriteChunk_AcceptsMaxAndRejectsOneMore`, `test_WriteChunk_IsIdempotent` |
| WS-25 | The file ID commits to the whole manifest and nothing else; registering again is a no-op. | `test_FileId_CommitsToWholeManifest`, `test_RegisterManifest_IsIdempotent` |
| WS-26 | A manifest has 1 to 4,096 chunks and a length that fits them. | `test_RegisterManifest_ChunkCountBounds`, `testFuzz_RegisterManifest_LengthFitsIffInRange` |
| WS-27 | A chunk counts only at the length the layout requires; a broken manifest never completes or reads. | `test_WrongLengthChunkNeverCompletesOrReads` |
| WS-28 | Reads fail closed: every chunk is checked against its hash; a missing chunk reverts. | `test_ReadsDetectTamperedChunkCode`, `testFuzz_Read_MatchesReference` |
| WS-29 | Uploads are permissionless and in any order; nothing accepts value. | `test_OutOfOrderUploads_CompleteTheFile`, `test_NothingAcceptsValue` |
| WS-30 | The declared digest is never recomputed; `sha256Of` returns it. | `test_Sha256Of_IsTheDeclaredDigest` |
| WS-31 | `attestBase64` accepts only valid base64 files, resumes across calls, once per file. | `test_Attest_LargeFileTakesSeveralCalls`, `test_Attest_LengthMustBeAMultipleOfFour` |
| WS-32 | Every store operation has a form that fits the transaction gas cap. | `test_Constants_ArePinned`, `test_Attest_AtMaxChunksEveryCallFitsTheTransactionGasCap` |
| WS-33 | The uploader's file IDs, chunk hashes and verdicts equal the contract's. | `test_Inline_ChunkHashesFileIdAndCalldataMatch` |
| WS-34 | A dependency `(name, version)` maps to one complete file forever. | `test_Register_VersionsAreImmutable`, `test_Register_RequiresCompleteContent` |
| WS-35 | Deprecating a dependency is a one-way flag; nothing is deleted. | `test_Deprecate_IsAFlagOnly` |
| WS-36 | The governed selectors of the records and dependency modules match the role map. | `test_RoleMap_EveryRestrictedFunctionIsMapped`, `test_RoleMap_NothingIsMappedThatDoesNotExist`, `test_EveryListedFunctionIsInstalledAndRestricted` |
| WS-37 | `renounce` needs the artist's signature on the current state; the royalty and license powers also need the network. | `test_Renounce_TheRepinPowerByTheArtistsSignatureAloneAfterFinalize`, `test_Renounce_TheRoyaltyAndLicensePowersNeedTheNetwork`, `test_Renounce_TheNetworkAloneCannot`, `test_Renounce_RefusesAnExpiredOrStaleSignatureAndNeverAppliesTwice` |
| WS-38 | A renounced power is gone for that work: its function always reverts. | `test_Renounce_EveryCallOfARenouncedPowerRevertsANoOpIncluded`, `test_Renounce_SurvivesEveryReplacementOfTheModule` |
| WS-39 | The network replaces the delivery contract, compare-and-set; a hostile delivery changes no fact. | `test_SetDelivery_TheNetworkSwapsToASuccessorThatNamesThisModule`, `test_SetDelivery_AHostileDeliveryChangesNoFact`, `test_NoFactChanges` |
| WS-40 | A served locator is printable ASCII without a space, `"` or `\`, from 1 to `Limits.MAX_URI_BYTES` (2,048) bytes; anything else is "no locator". The renderer applies this check. | `test_Delivery_EveryBadAnswerIsNoLocator`, `test_Token_AnOversizedLocatorIsNoLocator` |
| WS-41 | Added stores are append-only with a pinned code hash; a retired store counts nothing new. | `test_Stores_TheNetworkAddsAndRetires`, `test_FileStore_ARetiredStoreKeepsWhatFilesChose`, `test_FileStore_AStoreWhoseCodeChangedIsRefusedEitherWay` |
| WS-42 | Retired: the ranged sync walks are replaced by `attestComplete` in the content store. | |
| WS-43 | Retired: the ranged sync walks are replaced by `attestComplete` in the content store. | |
| WS-44 | `StreamWorkFacts6529` logs every change; its state is rebuilt from its logs alone. | `test_WorkFacts_EveryEventReplaysToTheSameState`, `test_WorkFacts_ReplayFailsOnStateNoLogExplains`, `test_WorkFacts_ReplayFailsOnADroppedLog` |
| WS-45 | Item kinds, seed policies and roles are open `uint8`s, so a future policy's item still opens. | `test_Open_ItemValuesTodaysEnumsDoNotName` |
| WS-46 | Retired: the seed is stored in the token at mint; `open` does not interpret seed policies. | |
| WS-50 | A linked chunk reads exactly as the same bytes written whole. | `test_Link_IsTheSameChunkAsAWholeWrite`, `testFuzz_Link_AnySplitGivesTheSameChunk` |
| WS-51 | `registerManifestList` registers the same file as `registerManifest`. | `test_List_GivesTheSameFileAsOneCall` |
| WS-52 | `firstMissing` returns the first chunk in a range that a source does not serve. | `test_FirstMissing_RangesAndCursor` |
| WS-53 | `chunkData` returns a chunk's verified bytes or reverts. | `test_ChunkData_RevertsForAnUnknownChunk` |
| WS-54 | Encodings and digest kinds are open ids, recorded and part of the file ID. | `testFuzz_RegisterManifest_RecordsAnyEncodingId` |
| WS-55 | A RECORDS module, however hostile, cannot change media, a finalized record, a CC0 license, a locked license or a locked pin. | `test_Hostile_NoSeamPositionReachesACollectorsToken` |

## Events

`StreamWorkFacts6529`: `RecordOpened`, `RecordSet`, `LicenseSet`, `Finalized`, `RendererRepinned`,
`Locked`, `OnChainComplete`. `WorkRules`: `FinalizeNoticeRecorded`, `PowersRenounced`,
`DeliverySet`. Signatures on the [events page](../integrators/events-and-indexing.md).

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| Record file incomplete or wrong shape | `InvalidRecord` | Upload the missing chunks, or set a one-chunk record. |
| License text incomplete | `InvalidLicense` | Upload it; finalize again. |
| A file too large to check in one transaction | `markOnChainComplete` reverts | Call `attestComplete` in steps first. |
| The RECORDS module is missing | Records cannot change; facts and tokens are unaffected | The network installs a module (after `moduleDelay`). |
| A pinned renderer's code changed | `RendererCodeChanged`; `tokenURI` reverts | The network repins, unless the pin is locked. |
