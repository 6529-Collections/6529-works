# Disputes and statements

`StatementLog` is one append-only, signed log in which artists, owners, curators and the platform
publish statements about a subject. A dispute is decided off chain by a TDH vote and recorded in
the log as a dispute outcome. During a 6529 Stream auction an upheld dispute ends in the
network's `cancel`, which refunds the high bid and burns the work; the network may then release
the content to the rightful artist ([curation](curation.md)). After a sale a dispute produces
only a statement, shown in the work's and its edition's metadata. Contested identity
replacements cite the same outcomes. The log and the auction are **replaceable modules**.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`StatementLog`](../../src/records/StatementLog.sol) ([`IStatementLog`](../../src/interfaces/IStatementLog.sol)) | module | Append paths per role, EIP-712 relay and nonces, the per-subject hash chain, the latest dispute outcome per subject. Holds no value; no pause, edit or delete path. |
| [`HashRef`](../../src/interfaces/types/HashRef.sol), [`StatementKinds`](../../src/interfaces/types/StatementKinds.sol) | types | The content hash type; the well-known kind labels. |
| `Accounts` ([`IArtistRoleResolver`](../../src/interfaces/IArtistRoleResolver.sol)) | module (`Directory.ACCOUNTS`) | The artist resolver (`isArtist`) for ARTIST statements; `resolveContested`, which cites an outcome. |
| [`EnglishAuction`](../../src/sales/EnglishAuction.sol) | module (Stream minter) | The dispute pause, `withdrawBid` while paused, `resume`, the self-ending pause, and `cancel`, which must cite a recorded outcome. |
| [`Stream`](../../src/core/Stream.sol) | permanent | `burn`, only by the sale contract that minted and holds the token, before its sale outcome is recorded. |
| [`Renderer`](../../src/content/Renderer.sol) | module | The `Dispute statement` trait of a work and its edition. |

## Concepts

The glossary defines [statement](../glossary.md#statement), [subject](../glossary.md#subject),
[dispute outcome](../glossary.md#dispute-outcome) and [TDH](../glossary.md#tdh). Disputes are
filed in a 6529 disputes wave and decided by TDH vote, off chain
([ADR 0001 §12](../adr/0001-v1-scope.md#12-disputes)); the network executes the result.

### Subjects and kinds

A subject is `(token, id)`, keyed `subjectKey(token, id) = keccak256(abi.encode(token, id))`;
each has its own hash chain. The log accepts any `token`, so readers key on the official
addresses.

| Subject | `token` | `id` |
| --- | --- | --- |
| A minted 6529 Stream work | the Stream address | the token ID |
| An approved item before its mint | `address(0)` | `uint256(itemHash)` |
| A 6529 Stream Editions edition | the Editions address | the edition ID (never a dispute outcome: those go on the master) |
| An artist | the accounts module's address | the artist ID |
| The governance chain | the AccessManager address | `0` (`GOVERNANCE_MANIFEST` only) |

A kind is any nonzero `bytes32`; three are reserved (DSP-4). Readers read `kind` with `role`.

### Statement kind registry

"Log" means `StatementLog` enforces the writer; "convention" means readers count the kind only
under the writer shown ([declarations and conventions](declarations-and-conventions.md)). A new
kind needs no deployment.

| Kind | `keccak256` of the label | Writer | Enforced by | Document schema (`schema` field) |
| --- | --- | --- | --- | --- |
| `ARTIST_STATEMENT` | `0x5a1580558647bddf43fff3420098de4267da7d1c4ac1e439b13c47bf6b0e09dc` | Any role; an artist statement means ARTIST | Neither | None defined |
| `INTERVIEW` | `0x827b89dd9d548b6bd3e4a96d838c595e26f74c7ba14a3bdcd3313513fcb06408` | Any role | Neither | None defined |
| `EXHIBITION` | `0xd0de5de578371073cdab4ef396f1cde367249833524bbc411074e93617fde767` | Any role | Neither | None defined |
| `CONSERVATION_NOTE` | `0xc0988b7b7e47b20329cd8d95db28dcab9904d0224d1b1f0d4c94bc745db42f54` | Any role | Neither | None defined |
| `STORAGE_COPY` | `0x2bf2b36080bc02996a250bc51a5b82a3ad56e65ec68e9d2e3d02208af2027de1` | Any role | Neither | None defined |
| `FIXITY_CHECK` | `0xa6734f8e667c484f4fef5fa3896406f134daaacfac9f176e4b9fa285a79def89` | Any role | Neither | None defined |
| `ACCESSION` | `0x4dc3a5e33f97bcd06f2d025349086438272d94a398185aca416ae539e36521fb` | Any role | Neither | None defined |
| `DISPUTE_OUTCOME` | `0xd529e5493d4add16d19648888c9742a7c31945a9916c9323f13bc977ebd3526b` | PLATFORM | Log (DSP-4, DSP-11) | None defined |
| `CURATION_EVIDENCE` | `0x10d8533be598105124a4fa93ecc6c1d4ed7e4d89809f2b02043c2b39f503a604` | CURATOR | Log (DSP-4) | None defined; its `conservationFloor` member holds [`floor-result.v1`](schemas/floor-result.v1.schema.json) objects (DCL-33) |
| `GOVERNANCE_MANIFEST` | `0xda3e4cfef33ef5fdea6a80cfd6c21354d7614a38addf188d0edad56c431651fc` | `appendGovernanceManifest` only | Log (DSP-4, DSP-5) | None defined |
| `CONTENT_CHANGE_PROPOSAL` | `0x839c052e9a5afc8f0beebb6265e5e0e47a21abf374d6747f389fe5dadc871554` | ARTIST, about a 6529 Stream token | Convention (DCL-10) | [`content-change-proposal.v1`](schemas/content-change-proposal.v1.schema.json): `0x9068b0e8f5eadecb75e1a26c81b62e4706d7699d85703af4ef6b965a5c47cbff` |
| `CONTENT_CHANGE_ACCEPTANCE` | `0x9d9eeba312ac7b3dc65b165a03f3b1eaf64f62cfd0ef22119dad7fdd6bc17f11` | OWNER, about the same token | Convention (DCL-11) | [`content-change-acceptance.v1`](schemas/content-change-acceptance.v1.schema.json): `0x592d278e78a6c95da74c031a22924283e71403c574e99c71d3cea20f96d04ea8` |
| `CATALOGUE_ENTRY` | `0xaacce03f8117fda5561145df82472ae33d3859d463cf544fdb49c147f4c86dff` | ARTIST, about a 6529 Stream token | Convention (DCL-16) | [`catalogue-entry.v1`](schemas/catalogue-entry.v1.schema.json): `0xbf2d196eb14af6610f731afd5975b50f99ba31511bf665edc17752a35d476f72` |
| `CITATION` | `0xe6c8d7dd9d949fc9fbac776ad88a44d7eba3ab1f7f24cdd6232df6c94c9f86fe` | ARTIST, about the citing 6529 Stream token | Convention (DCL-18) | [`citation.v1`](schemas/citation.v1.schema.json): `0x4630ac779b2d22e7b042c5f45efd6dfcf5da2f5c774668b35678975f1fa29de1` |
| `CUSTODY_ATTESTATION` | `0x86aca35bbe17a3ae9d833091d08756c7bfdcafa66f069af4d27b38534b5a5462` | OWNER, ARTIST or PLATFORM, carrying a custodian's signature | Convention (DCL-20) | [`custody-attestation.v1`](schemas/custody-attestation.v1.schema.json): `0xc91341028bdd4590fffcab18e8c2864818fc07a8d664a1c1a22b44942f1cee54` |
### Who may write

| Role | Entry points | Who qualifies |
| --- | --- | --- |
| ARTIST | `append(Role.ARTIST, s)`, `appendSigned` | `isArtist(token, id, signer)` on the installed resolver (code hash checked at every use): any wallet of the lead artist's account for a Stream work, or for an edition through its master. A zero resolver disables ARTIST statements. |
| OWNER | `append(Role.OWNER, s)`, `appendSigned` | ERC-721 `ownerOf(id) == signer`, else ERC-1155 `balanceOf(signer, id) > 0`. |
| CURATOR | `appendCurator(s)`, `appendSigned` | A holder of the role mapped to `appendCurator` (`CURATOR`, no delay). |
| PLATFORM | `appendPlatform(s)`, `appendSigned` | A holder of the role mapped to `appendPlatform` (`PLATFORM`, no delay). |
| PLATFORM, signed by the AccessManager | `appendGovernanceManifest(s)` | A scheduled operation (SUCCESSOR_SETTER, 7 days); subject `(authority(), 0)` only. |

Every path but `appendGovernanceManifest` refuses the AccessManager as signer. No governance role
writes an ARTIST or OWNER entry (DSP-6). Each ARTIST entry records its resolver, so a reader can
discard the entries of a resolver it does not trust. A URI is at most 8,192 bytes of UTF-8.

### Dispute outcome

A `DISPUTE_OUTCOME` statement records the result of a TDH vote; its document states the result.
On an auction the network's `cancel` is the decision and the outcome is the record it must cite.
A correction is a new entry citing the earlier one in `supersedes`.

- `disputeOutcomeOf(token, id)`: the subject's own latest outcome and its index in the chain
  (read by the auction).
- `latestDisputeOutcome(token, id)`: the own latest outcome; if none, for a token that declares
  `IStream` by ERC-165, the latest outcome about the item it was minted from (`itemHashOf`).
  Read by the renderer for the `Dispute statement` trait.

## Flows

### Upheld dispute during an auction

The pause lasts at most `MAX_PAUSE` (3 days, compiled in the auction).

1. A pauser key calls `pause(saleId, disputeRef)` on a live auction (once per auction). Nobody
   bids or settles; the high bidder may `withdrawBid` (credited; the amount stays as the reserve).
2. PLATFORM records a `DISPUTE_OUTCOME` about the token.
3. The network calls `cancel(saleId, outcomeRef)` within the pause, citing that outcome: the high
   bid is credited and the token burned.
4. The network calls `PackageRegistry.releaseContent` for the rightful artist, who can then start
   a work with the same content.

### Rejected dispute, or no decision

The network calls `resume(saleId)`, or the pause lapses by itself after 3 days. The auction runs
on for at least the longer of the governed duration and its anti-snipe window, or its remaining
time if longer.

### After a sale

Nothing moves: no path burns or transfers a settled work. The outcome shows in metadata.

<a id="relayed-artist-statement"></a>

### Relayed statements

Any role's statement may be signed off chain and relayed by anyone (`appendSigned`) with a
deadline and a per-signer nonce; the signer may revoke an unused nonce (`revokeNonce`).

### Identity contest

A contested replacement in the accounts module runs only if the network upholds it with
`resolveContested(artistId, true, outcomeRef)`, citing the artist's latest outcome recorded after
the contest began ([identity](identity-and-recovery.md)).

| Action | Caller | Role delay at genesis |
| --- | --- | --- |
| `pause(saleId, disputeRef)` | PAUSER | none |
| `resume`, `cancel` | the network | none |
| `appendPlatform` (the outcome) | PLATFORM | none |
| `releaseContent`, `resolveContested` | the network (PARAMETER_SETTER) | 24 hours |

## Rules and invariants

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| DSP-1 | The log is append-only: no entry is edited or deleted, and each subject's count and head match the events emitted for it. | `StatementLog._write` (the only write path) | `invariant_CountAndHeadMatchEmittedEvents`; `test_Supersession_IsANewEntryAndNothingIsOverwritten`, `test_HashChainRebuiltFromEventsEqualsStoredHeads`; `check_head_followsTheFormula` |
| DSP-2 | Every entry has a subject other than `(0, 0)`, a non-zero kind and schema, a `HashRef` with a non-zero algorithm ID (recorded, never interpreted) and a non-zero digest, exactly one locator, and a URI of at most 8,192 bytes of UTF-8. | `StatementLog._validate` | `test_Validation_RejectsMalformedStatements`, `test_Validation_Locators`, `test_Validation_UriMustBeUtf8`, `test_Validation_AcceptsEveryRecognisedAlgorithm`, `test_Validation_AcceptsUnknownAlgorithmIds`, `testFuzz_Validation_RecordsAnyNonZeroAlgorithmUninterpreted` |
| DSP-3 | `append` serves only ARTIST and OWNER. CURATOR and PLATFORM write through their restricted functions, or by relay only when the signer holds the role with zero execution delay; a delayed holder cannot write at once or by relay. | `StatementLog.append`, `_isAuthorized` | `test_Append_RefusesCuratorPlatformAndNoneRoles`, `test_CuratorAndPlatform_RejectStrangersAndTheOtherRole`, `test_Curator_DelayedRoleCannotWriteDirectlyOrByRelay`, `test_Relay_CuratorSignerWithoutTheRoleIsRejected`; `check_append_servesOnlyArtistAndOwner` |
| DSP-4 | `DISPUTE_OUTCOME` is written only as PLATFORM (`appendPlatform`, or `appendSigned` signed by a PLATFORM holder), `CURATION_EVIDENCE` only as CURATOR, `GOVERNANCE_MANIFEST` only by `appendGovernanceManifest`. | `StatementLog._validate`, `_append`, `appendGovernanceManifest` | `test_ReservedKinds_DisputeOutcomeIsPlatformOnly`, `test_ReservedKinds_CurationEvidenceIsCuratorOnly`, `test_ReservedKinds_AlsoHoldForRelayedStatements`, `test_GovernanceManifest_EveryOtherPathRejectsTheKind`; `invariant_RolesAreSpokenOnlyByTheirHoldersAndReservedKindsStayReserved`; `check_outcomeKinds_onlyFromTheirRole` |
| DSP-5 | No entry names the AccessManager as signer, except a governance manifest with subject `(authority(), 0)`. | `StatementLog._append` (`AuthorityCannotSign`), `appendGovernanceManifest` | `test_Manager_CannotBeTheRecordedSignerOnAnyPath`, `test_GovernanceManifest_MustBeAboutTheManagerWithTheGovernanceKind`, `test_GovernanceManifest_ManagerStillCannotSignOnOtherPaths`; `test_Curator_ScheduledExecutionCannotBeAttributedToTheManager`; `check_noEntryNamesTheManager` |
| DSP-6 | No governance role writes an ARTIST or OWNER entry, directly or by relay. | `StatementLog._isAuthorized` (ARTIST and OWNER never consult the AccessManager) | `test_Admin_CannotWriteArtistOrOwner`, `test_Admin_HoldingEveryGovernedRoleStillCannotWriteArtistOrOwner`, `test_Admin_RelayedArtistOrOwnerSignatureIsRejected`, `test_Curator_CannotWriteArtistOrOwner` |
| DSP-7 | An ARTIST entry needs the installed resolver, with its pinned code hash, to vouch for the signer, and records that resolver in its hash and event; other roles record zero. | `StatementLog._isAuthorized`, `_write` | `test_Artist_AResolverWhoseCodeChangedIsRefused`, `test_Artist_DisabledWhenResolverUnset`; `test_ResolverIsPartOfTheEntryHash`, `test_OwnerAndPlatformEntriesCarryNoResolver`; `invariant_ArtistEntriesBindTheActiveResolver` |
| DSP-8 | `setArtistResolver` is restricted and compare-and-set, and installs only a contract with code, no EIP-7702 delegation, ERC-165 support and the reviewed code hash; zero disables ARTIST statements. | `StatementLog.setArtistResolver`, `_installResolver` | `test_SetArtistResolver_IsRestricted`, `test_SetArtistResolver_SwapsAndEmits`, `test_SetArtistResolver_StaleExpectedValueReverts`, `test_SetArtistResolver_RejectsUnsuitableResolvers`, `test_SetArtistResolver_ZeroDisablesArtistStatements` |
| DSP-9 | A relayed entry needs an unexpired deadline (inclusive), an unused nonce of the signer, a valid signature over the full authorization under this log and chain, and the signer's role; a nonce is spent once, a failed append spends none. | `StatementLog.appendSigned`, `_spendNonce`, `revokeNonce` | `test_Relay_ReplayIsRejected`, `test_Relay_DeadlineIsInclusive`, `test_Relay_RevokeBeforeUse`, `test_Relay_WrongChainIsRejected`, `test_Relay_WrongContractIsRejected`, `test_Relay_AnyTamperedFieldIsRejected`, `test_Relay_FailedAppendDoesNotSpendTheNonce`; `invariant_SpentNoncesStaySpent`; `check_relay_deadlineNonceAndSigner` |
| DSP-10 | Type hashes, the domain, the entry hash and the head follow the formulas on this page. | `StatementLog._statementHash`, `_authorizationHash`, `_write` | [`StatementLogGolden.t.sol`](../../test/records/StatementLogGolden.t.sol) `test_Golden_TypeHashesAndDomainTags`, `test_Golden_DigestMatchesForgeTypedDataEncoder`, `test_Golden_EntryHashAndHead`; `check_head_followsTheFormula` |
| DSP-11 | A `DISPUTE_OUTCOME` about an ERC-721 token needs the token to exist; any ERC-1155 subject is refused. | `StatementLog._checkDisputeSubject` | `test_DisputeOutcome_SubjectRules` |
| DSP-12 | `latestDisputeOutcome` returns the subject's own latest outcome, else, only for a token that declares `IStream`, its item's (a token that does not declare it reads zero, whatever its `itemHashOf` answers); a failed item read of a token that declares `IStream` reverts, except OpenZeppelin's `ERC721NonexistentToken` (no item), and a read that runs short reverts with `BoundedCallShortfall` (DSP-26); `disputeOutcomeOf` returns the own latest outcome and its index, with no fallback. | `StatementLog.latestDisputeOutcome`, `disputeOutcomeOf` | `test_LatestDisputeOutcome_TracksOnlyDisputeEntries`, `test_DisputeOutcomeOf_IsTheOwnLatestOutcomeAndItsPosition`, `test_LatestDisputeOutcome_AStreamWhoseCoreReadFailsReverts`, `test_LatestDisputeOutcome_ANonStreamTokenStillReadsZero`, `test_LatestDisputeOutcome_AnUndeclaredTokensAnswerNamesNoItem`; `invariant_LatestDisputeOutcomeMatchesEvents` |
| DSP-13 | Only a pauser key pauses, only a live auction, and only once. | `EnglishAuction.pause` | |
| DSP-14 | A pause is live through `pausedAt + 3 days` inclusive and then ends by itself (`MAX_PAUSE`, compiled). | `EnglishAuction._state`, `_require`, `_endPause` | |
| DSP-15 | While paused, nobody bids or settles; only the high bidder may withdraw, and the withdrawn amount stays as the reserve the next bid must reach. | `EnglishAuction._bid`, `settle`, `withdrawBid`, `_minimumBid`, `_refundHighBid` | |
| DSP-16 | `resume` and `cancel` are the network's, with no wait of their own: either may land at any moment of the live pause. | `EnglishAuction.resume`, `cancel` | |
| DSP-17 | A resumed or lapsed auction runs for at least the longer of the governed duration and its anti-snipe window, or its remaining time if longer. | `EnglishAuction._resumedEnd`, `_reopening` | |
| DSP-18 | `cancel` cites the token's own latest outcome, recorded after the pause; an earlier outcome, a superseded one or an item outcome cannot cancel. | `EnglishAuction.pause` (`outcomeFrom`), `cancel`, `_ownOutcome` | |
| DSP-19 | `cancel` runs only while the pause is live, credits the high bid and burns the token. | `EnglishAuction.cancel`, `Stream.burn` | |
| DSP-20 | Only a sale contract that is or was a minter burns a token, while holding it and before any sale outcome is recorded. | `Stream.burn` | |
| DSP-21 | `releaseContent` is the network's, needs the token `tokenOfContent` names to be burned and a registered beneficiary, reserves the content for the beneficiary's items and bars the burned item. | `PackageRegistry.releaseContent` | |
| DSP-22 | After a sale, a dispute moves nothing: no path burns or transfers a settled work. | `Stream.burn` (`NotInPrimarySale`) | `Stream.t.sol` |
| DSP-23 | Through pauses, withdrawals, resumptions and cancels, the auction's balance covers every live bid and credit, value is conserved, and custody is exact. | `EnglishAuction` | |
| DSP-24 | Metadata shows the display rule's answer for a work, and the master's for an edition, and fails closed when the log cannot be read. | `Renderer._chainTraits` | [`Renderer.t.sol`](../../test/content/renderer/Renderer.t.sol) `test_Dispute_ShownWhenTheLogHasAnOutcome`, `test_Dispute_ReadsTheMastersSubjectForAnEdition`, `test_Dispute_ABrokenLogFailsClosed` |
| DSP-25 | A contest resolves only with the artist's latest outcome, recorded after the contest began. | `Accounts.resolveContested` | `test_Contest_UpheldByAVoteRecordedAfterIt`, `test_Contest_VoidedByAVote` |
| DSP-26 | The log compiles in no gas number. Every call out (the ERC-165 probes, `ownerOf`, `balanceOf`, `itemHashOf` and the ERC-1271 check) forwards all the gas EIP-150 allows, and one that fails while leaving at most 1/8 of the gas held before it reverts with `BoundedCallShortfall(target)`: running short never yields "no outcome", an unchecked dispute subject, "not the owner" or "invalid signature". The answer does not depend on what a dependency costs. | `StatementLog.latestDisputeOutcome`, `_checkDisputeSubject`, `_owns`; `BoundedCall` forward-all family; `SignatureVerifier.isValidERC1271` | [`StatementLogGasRule.t.sol`](../../test/records/StatementLogGasRule.t.sol) `test_GasRule_LatestDisputeOutcome_ItemOutcomeAtEveryCostNeverZeroWhenShort`, `test_GasRule_LatestDisputeOutcome_UnknownWorkAtEveryCost`, `test_GasRule_DisputeSubject_NonexistentTokenRefusedAtEveryCostNeverAccepted`, `test_GasRule_Owner_Erc721OwnerAuthorisedAtEveryCostNeverRefusedWhenShort`, `test_GasRule_Owner_Erc1155HolderAuthorisedAtEveryCostNeverRefusedWhenShort`, `test_GasRule_Relay_Erc1271SignerAcceptedAtEveryCostNeverInvalidWhenShort`; `test_Owner_HostileTokensRevertWithTheShortfallError` |
## Events

Signatures and topic0 are on the [events page](../integrators/events-and-indexing.md), under
[StatementLog](../integrators/events-and-indexing.md#statementlog) and
[EnglishAuction](../integrators/events-and-indexing.md#englishauction). A dispute outcome emits
no ERC-4906 event: an indexer refreshes metadata on `StatementAppended` with
`kind == DISPUTE_OUTCOME` about the work, its item or its master.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| The cancel lands after the pause lapsed. | `InvalidAuctionState`; the auction continues and may sell. | The after-sale path. |
| The cited outcome predates the pause, is about the item, or is no longer the latest. | `OutcomeNotRecorded(saleId, outcomeRef)`. | Record an outcome about the token and cancel again, within the pause. |
| A second dispute on the same auction. | `PauseExhausted(saleId)`. | The after-sale path. |
| A release names an artist with no identity. | `UnknownArtist(beneficiary)`. | Wait for the artist's first package acceptance. |
| A wrong statement is appended. | It stays in the log forever. | A correction whose `supersedes` cites it; the network revokes a misused CURATOR or PLATFORM key at once. |
| The resolver's code changes after install. | ARTIST appends revert (`DependencyCodeChanged`). | `setArtistResolver` to a reviewed resolver (7 days). |
| The lead artist's account is frozen or being replaced. | ARTIST appends revert. | Wait for the freeze or replacement to end. |
| A token read or an ERC-1271 check runs short of gas. | `BoundedCallShortfall(target)`; nothing is written. | Resend with more gas. |

## Parameters and limits

| Parameter | Value | Source |
| --- | --- | --- |
| Dispute pause | at most 3 days, once per auction | `EnglishAuction.MAX_PAUSE` |
| URI length | 8,192 bytes | `StatementLog.MAX_URI_BYTES` |
| Relay nonces | one bitmap per signer, 256 per word | `StatementLog` |
| EIP-712 domain | `"6529 Works Statement Log"`, version `"1"` | `StatementLog` constructor |

## References

- Code: [`StatementLog.sol`](../../src/records/StatementLog.sol),
  [`src/records/README.md`](../../src/records/README.md),
  [`EnglishAuction.sol`](../../src/sales/EnglishAuction.sol),
  [`PackageRegistry.sol`](../../src/curation/PackageRegistry.sol),
  [`Accounts.sol`](../../src/identity/Accounts.sol), [`Renderer.sol`](../../src/content/Renderer.sol).
- ADRs: [ADR 0001 §12](../adr/0001-v1-scope.md#12-disputes),
  [ADR 0003](../adr/0003-build-time-decisions.md#disputes-and-statements-amends-adr-0001-12).
- Tests: [`test/records/`](../../test/records/), [`test/sales/`](../../test/sales/); how to run
  them: [testing](../testing/README.md).
- Related: [declarations and conventions](declarations-and-conventions.md),
  [stream and auctions](stream-and-auctions.md), [curation](curation.md),
  [identity and recovery](identity-and-recovery.md), [rendering](rendering-and-tokenuri.md).
