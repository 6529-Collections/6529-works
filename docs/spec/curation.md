# Curation

Curation decides which works may ever mint on 6529 Stream. Main Stage is the only way in
([ADR 0001's amendment of 1 November 2026](../adr/0001-v1-scope.md#amendments)): the artist's
submission carries the work's package (a Merkle root of items) before the vote, so voters approve
exactly what would mint. The routing rule that makes a submission Stream-eligible is a network
rule decided by TDH vote, not contract code.

On chain, a curation signer attests the approval, anyone registers the root, every party named by
an item accepts it, and the lead artist signs a revocable move. At the auction start the sale
contract asks the mint policy (`authorize`), which checks all of this and answers the mint facts
and the sale terms. The mint policy is a **replaceable module**: `PackageRegistry` today,
installed in the sale contract (`EnglishAuction.setStreamPolicy`), with
`Eip712CurationVerifier` behind it.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`PackageRegistry`](../../src/curation/PackageRegistry.sol) ([`IPackageRegistry`](../../src/interfaces/IPackageRegistry.sol), [`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol)) | module | Approved roots, party acceptances, the item rules, move nonces, the VRF delivery check, the terms of each new work; content release after an upheld dispute; the verifier swap. |
| [`Eip712CurationVerifier`](../../src/curation/Eip712CurationVerifier.sol) ([`ICurationVerifier`](../../src/interfaces/ICurationVerifier.sol)) | module | Accepts a `PackageApproval` signed by an active curation signer at its current signer epoch; per-signer disable. |
| [`StreamHashing`](../../src/interfaces/types/StreamHashing.sol), [`Typehashes`](../../src/interfaces/types/Typehashes.sol) | library | The item hash, Merkle leaf, media hash and every EIP-712 typehash. |
| [`EditionRules`](../../src/editions/EditionRules.sol) | library | Valid edition terms, applied when an `EDITION_MASTER` item is authorized. |
| [`PackageTypes`](../../src/interfaces/types/PackageTypes.sol) | types | `PackageItem`, `Party`, `License`, `SaleTerms`, `EditionTerms`, `PartyAcceptance`, `MoveAuthorization`, `StreamMintRequest`. |

## Concepts

The glossary defines [package](../glossary.md#package), [package root](../glossary.md#package-root),
[item hash](../glossary.md#item-hash), [curation signer](../glossary.md#curation-signer),
[acceptance](../glossary.md#acceptance) and [move](../glossary.md#move). What this page adds:

- A root names no chain or contract, so it is the same on every chain. Until a verifier backed by
  the 6529 chain replaces the v1 verifier, the contracts trust the curation signer's attestation
  of the vote.
- **Single use.** An item mints once because Stream refuses a second live token with the same
  content hash ([AUC-44](stream-and-auctions.md#rules-and-invariants)). A burned work's content
  mints again only after the network released it (`releaseContent`), only for an item led by the
  artist the release names, and never by the burned item, which the release bars (`isBarred`).
- **Accounts.** An artist or collaborator is a consolidated account: any wallet of the account
  accepts, signs the move and revokes a move nonce, checked by the accounts module
  (`requireSigned`, `isWallet`). While the account is frozen or a replacement of its root is
  pending, none of these verify (CUR-19).
- **Terms.** Every work takes the economics in force at its start
  (`IEconomicsResolver.newWorkTerms`): the seller (the split wallet of the item's payees), the
  network's fee recipient and share, the royalty receiver and the rate. No party signs the rate.

### The package item

Every field of `PackageItem` enters the item hash, so voters approve and parties sign exactly
these values.

| Field | Meaning | Checked |
| --- | --- | --- |
| `kind` | `ORIGINAL` or `EDITION_MASTER` (a 1/1 that anchors one edition). | An original has empty edition terms; a master's pass `EditionRules.isValid`. |
| `collectionId` | A 6529 Stream collection. | Stream `mint`: the collection exists. |
| `contentHash` | SHA-256 of the primary media; the uniqueness key. | Nonzero; no live token holds it. `StreamWorkFacts6529.open`: equals the primary file's SHA-256. |
| `mediaHash` | Hash over every media file (file ID, SHA-256, role), primary first. | `StreamWorkFacts6529.open`. |
| `recordFileId` | Content-store file of the JSON record; replaceable until finalize. | At `setRecord` and `finalize`. |
| `parties` | 1 to 16 `(account, role)` entries, lead `ARTIST` first. | CUR-6. |
| `payees` | The payee list of the artist portion. | CUR-8. |
| `license` | SPDX ID and the content-store file of the full text. | `SpdxId`; CC0 names the deployment's CC0 text. |
| `seedPolicy`, `seed` | `NONE`, `ARTIST` (nonzero seed) or `VRF` ([entropy](entropy.md)). | CUR-9; `VRF` needs a delivered seed. |
| `sale` | `SaleTerms`: how the work is first sold. | A nonzero sale kind. |
| `edition` | `EditionTerms` of a master's edition. | `EditionRules.isValid`. |

Payee order is strictly increasing `(artistId, account)`. The lead artist is paid only through its
account (an artist-resolved payee), never as a fixed payee, so a freeze holds its payout.

### EIP-712 messages

Each signing contract uses the domain `(name, "1", chainid, itself)`.

| Message | Domain | Signed by | Replay protection |
| --- | --- | --- | --- |
| `PackageApproval(bytes32 packageRoot,bytes32 evidenceHash,uint256 signerEpoch)` | `6529 Stream Curation Verifier` | a curation signer | a root registers once; the signer epoch |
| `PackageAcceptance(bytes32 packageRoot,address account,bytes32 profileId,bytes32 profileDocHash,uint64 deadline)` | `6529 Stream Package Registry` | the account, or any wallet of it once it has an artist ID | once per `(root, account)`; a deadline |
| `MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)` | `6529 Stream Package Registry` | any wallet of the lead artist's account | a per-artist nonce; a deadline |

The verifier accepts only canonical `abi.encode(address signer, bytes signature)` attestations and
returns false on anything else. Signatures go through
[`SignatureVerifier`](../../src/libraries/SignatureVerifier.sol) (low-s ECDSA, ERC-2098,
ERC-1271, EIP-7702). `signerEpoch(signer)` changes on every grant, revocation, disable and
enable of the signer, so an approval made before any of them never counts again. Move nonces are a
per-artist bitmap of 255 per word; tools use nonces 0, 1, 2 and so on.

<a id="trust-obligations-of-the-curation-signer"></a>

### What the curation signer's tooling checks

The contracts cannot check these; the signer's tooling does before it attests:

- every declared SHA-256 against the decoded bytes, including the content hash;
- a simulation of `StreamWorkFacts6529.open` for every item: its media checks do not run at mint, so
  a mis-committed item mints and its record never opens;
- strict Base64 (as `ContentStore.attestBase64` checks);
- the conservation floor when the wave's policy runs it
  ([DCL-5](declarations-and-conventions.md#the-conservation-floor)), published per item as
  `floor-result.v1` in the curation evidence (DCL-33);
- before revising a VRF work's media, the network revokes the old root (a new content hash draws a
  new seed).

## Flows

1. **Approve and register.** A curation signer signs `PackageApproval`; anyone calls
   `registerPackage(root, evidenceHash, attestation)`. The CURATOR publishes the matching
   `CURATION_EVIDENCE` statement.
2. **Accept.** Each party's signed `PackageAcceptance` is relayed by anyone to `acceptPackage`.
   A first acceptance creates the artist's identity in the accounts module.
3. **Move and start.** The lead artist signs `MoveToStream`; a sale contract that is an active
   minter of Stream calls `authorize(stream, abi.encode(StreamMintRequest))`, which checks the
   root, proof, item rules, acceptances and move (spending the nonce), the content rules and a VRF
   seed, then answers the mint facts and terms. The sale contract mints.
4. **Revoke.** The network revokes a root (`revokePackage`), disables a signer in the verifier
   (`disableSigner`), and stops every root a signer registered so far (`killSignerApprovals`).
   Minted works are untouched.
5. **Release after an upheld dispute.** After the sale contract burned the token
   ([disputes](disputes-and-statements.md)), the network calls `releaseContent(stream, tokenId,
   contentHash, beneficiary)`: the content is reserved for items led by the beneficiary and the
   burned item is barred. A later release of the same burned token replaces the beneficiary.

| Action | Caller | Role delay at genesis |
| --- | --- | --- |
| `registerPackage`, `acceptPackage` | anyone | none |
| `revokeMove` | a wallet of the lead's account | none |
| `revokePackage`, `killSignerApprovals`, `disableSigner` | the network | none |
| `releaseContent` | the network (PARAMETER_SETTER) | 24 hours |
| `enableSigner`, `setVerifier`, `setEntropyModule` | the network (SUCCESSOR_SETTER) | 7 days |

Delays are from [`config/genesis.core.example.json`](../../config/genesis.core.example.json); the
full matrix is [roles.md](../audit/roles.md).

## Rules and invariants

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| CUR-1 | Only an item of an `APPROVED` root, placed by a proof of at most 32 nodes, can be authorized. | `PackageRegistry.authorize` | `test_revokePackage_blocksUnconsumedItems`, `test_consume_revertsItemNotInPackage`, `test_consume_proofLengthCap`, `testFuzz_merkle_proofs` |
| CUR-2 | A root registers at most once; a revoked root, including one revoked in advance, never registers. | `PackageRegistry.registerPackage`, `revokePackage` | `test_registerPackage_onceOnly`, `test_revokePackage_inAdvance`, `test_revokePackage_revertsOnlyWhenRevoked` |
| CUR-3 | Registration needs the current verifier with its pinned code hash, the verifier's approval, and a nonzero evidence hash. Anyone may submit. | `PackageRegistry.registerPackage` | `test_registerPackage_permissionless`, `test_registerPackage_revertsNotApproved`, `test_registerPackage_revertsZeroEvidence`, `test_registerPackage_refusesAVerifierWhoseCodeChanged` |
| CUR-4 | An approval counts only from a signer that holds `CURATION_SIGNER` with no execution delay, is not disabled, and signed over its current epoch, in this verifier's domain on this chain. | `Eip712CurationVerifier.isApproved`, `isSignerActive`, `signerEpoch` | `test_isApproved_onlyAtTheCurrentEpoch`, `test_isApproved_reEnablingDoesNotReviveOlderApprovals`, `test_isApproved_regrantingDoesNotReviveOlderApprovals`, `test_isApproved_anApprovalSignedWhileDisabledCannotNameTheNextEpoch`, `test_isApproved_signerWithExecutionDelayDoesNotCount`, `test_isApproved_rejectsWrongChain`, `testFuzz_isApproved_onlyActiveSignersCount` |
| CUR-5 | The verifier accepts only the canonical attestation encoding and never reverts on a malformed one. | `Eip712CurationVerifier._decode` | `test_isApproved_rejectsNonCanonicalEncodings`, `test_isApproved_malformedAttestationsReturnFalse`, `testFuzz_isApproved_neverRevertsOnGarbage` |
| CUR-6 | Every party of an authorized item accepted the root, and the parties are distinct artists. | `PackageRegistry._checkParties` | `test_consume_revertsMissingCollaboratorAcceptance`, `test_invalidItem_parties`, `test_invalidItem_sameArtistUnderTwoAccounts`, `test_invalidItem_tooManyParties` |
| CUR-7 | An acceptance is signed by the account (no identity yet) or any wallet of its account, unexpired, with a matching profile; it is recorded once per `(root, account)`, and only a first acceptance creates an identity. | `PackageRegistry.acceptPackage` | `test_acceptPackage_createsIdentity`, `test_acceptPackage_replayIsNoop`, `test_acceptPackage_afterRecoverySignedByNewAuthority`, `test_acceptPackage_revertsProfileMismatch`, `test_acceptPackage_relayOrderPicksProfile`, `test_acceptPackage_revertsExpired` |
| CUR-8 | The payee list is canonical, nonempty, no longer than the party list, pays only parties, never names the lead artist's account as a fixed payee, and sums to 100,000. | `PackageRegistry._checkParties` | `test_invalidItem_payees`, `test_invalidItem_duplicatePayee`, `test_validItem_partyPaidBothWays`, `test_invalidItem_leadPaidAsAFixedPayee` |
| CUR-9 | An authorized item has a nonzero content hash, a seed exactly under `ARTIST`, empty edition terms if `ORIGINAL`, and terms `EditionRules.isValid` accepts if `EDITION_MASTER`; a kind, seed policy or party role value the policy does not know is refused. | `PackageRegistry._checkItem`, `_checkTerms` | `test_invalidItem_seedPolicy`, `test_invalidItem_valuesTodaysEnumsDoNotName`, `test_invalidItem_zeroContentHash`, `test_invalidItem_originalWithEditionTerms`, `test_invalidItem_masterEditionTerms`, `test_invalidItem_masterEditionTermsSharedRule` |
| CUR-10 | A move is signed by a wallet of the lead's account over this registry's `MoveToStream` digest for this item, unexpired, on an unused nonce; the nonce is spent whatever the signature encoding. | `PackageRegistry._useMove`, `_spendMoveNonce` | `test_move_revertsExpired`, `test_move_revertsWrongSigner`, `test_move_revertsWrongChain`, `test_move_bindsItem`, `test_move_signedByCurrentAuthorityAfterRecovery`, `test_move_nonceSpentWhateverTheSignatureForm`, `test_Move_AnyWalletOfTheLeadAccount` |
| CUR-11 | Only a wallet of the artist's account revokes its unused move nonces; a used or revoked nonce reverts; nonces are isolated per artist and bit. | `PackageRegistry.revokeMove` | `test_revokeMove_beforeUse`, `test_revokeMove_onlyCurrentAuthority`, `test_revokeMove_revertsWhenUsedOrRevoked`, `testFuzz_revokeMove_bitmapIsolation` |
| CUR-12 | An item mints at most once, through any root; Stream holds at most one live token per content hash. | `PackageRegistry.authorize`, `Stream6529.mint` | `test_consume_revertsDoubleConsume`, `test_consume_itemIsSingleUseAcrossPackages`, `invariant_itemConsumedAtMostOnce` |
| CUR-13 | Retired: the registry no longer records edition claims. The ID is not reused. | none | none |
| CUR-14 | A release is the network's, needs the token `tokenOfContent` names to be burned and a registered beneficiary, reserves the content for items led by that artist, and bars the burned item. | `PackageRegistry.releaseContent` | `test_releaseContent_onlyTheNetwork`, `test_releaseContent_refusesAnythingButABurnedTokensOwnContent`, `test_releaseContent_recordsTheReleaseAndBarsTheItem`, `test_releasedContent_mintsOnlyForTheBeneficiary`, `test_Dispute_ReleasedContentIsReservedForTheNamedArtist` |
| CUR-15 | Only an active minter of the bound Stream (`IModules(token).isMinter`) calls `authorize`. | `PackageRegistry.authorize` | `test_unboundRegistryRefusesEveryone` |
| CUR-16 | Revocation is the network's (no delay), final and per root. | `PackageRegistry.revokePackage`; genesis role map | `test_revokePackage_onlyGuardian`, `test_revokePackage_isPerRoot` |
| CUR-17 | Disabling a signer is the network's (no delay), possible in advance, and stops only future registrations; re-enabling is SUCCESSOR_SETTER (7 days). | `Eip712CurationVerifier.disableSigner`, `enableSigner` | `test_disableSigner_immediateAndOneWay`, `test_disableSigner_inAdvance`, `test_disableSigner_survivesRoleRegrant`, `test_enableSigner_thirtyDayClass`, `test_registerPackage_revertsAfterSignerDisabled`, `test_disabledSigner_registeredRootsStayUsable` |
| CUR-18 | A verifier swap is compare-and-set, pins the code hash, never installs the current or a retired verifier, and leaves registered approvals intact. | `PackageRegistry.setVerifier` | `test_setVerifier`, `test_setVerifier_compareAndSet`, `test_setVerifier_refusesARetiredVerifier`, `test_setVerifier_keepsRegisteredApprovals`, `test_setVerifier_onlySuccessorSetter` |
| CUR-19 | While the account is frozen or its root is being replaced, its acceptances and moves do not verify and it cannot revoke moves. | `PackageRegistry.acceptPackage`, `_useMove`, `revokeMove` (through the accounts module) | `test_Move_RefusedWhileTheAccountIsFrozen` |
| CUR-20 | Item hashes, leaves, media hashes and typehashes match independently computed golden vectors and do not depend on the chain. | `StreamHashing`, `Typehashes` | `test_itemHash_golden`, `test_mediaHash_golden`, `testFuzz_itemHash_independentOfChain`, `test_threeItemPackage_proofs`, `test_domainConstants`, `test_signedPayloadTypehashes`, `test_golden_typehashes`, `test_golden_digests`, `testFuzz_consume_itemHashMatchesStreamHashing` |
| CUR-21 | Governed functions are non-payable. | `PackageRegistry`, `Eip712CurationVerifier` | `test_governedFunctionsAreNonPayable` |
| CUR-22 | `authorize` stays within its gas ceiling and the worst case fits the per-transaction cap. | `PackageRegistry.authorize` | `test_txCap_consumeWorstCase` |
| CUR-23 | `killSignerApprovals` (the network, no delay) stops every package the signer registered before it: their unminted items no longer mint, open an edition sale or accept parties; other signers' packages, later packages and minted works are untouched. | `PackageRegistry.killSignerApprovals`, `_isLiveRoot` | `test_KillSignerApprovals_StopsPackagesRegisteredBefore`, `test_KillSignerApprovals_LeavesMintedItems` |
| CUR-24 | `isApprovedItem(root, itemHash, proof)` is true only for a live package (approved, not revoked, signer not killed since, not reported as revoked by a replaced policy) that contains the item under a proof of at most 32 nodes. | `PackageRegistry.isApprovedItem` | `test_IsApprovedItem`, `test_successor_aLaterRevocationInThePredecessorStopsARootRegisteredHere` |
| CUR-25 | A policy deployed with `previous` never registers, and never treats as live, a root the replaced policy reports as revoked (`isRevoked`: revoked, revoked in advance, registered by a signer whose approvals were killed since, or revoked in a policy further back), whenever the revocation was made. A root never revoked registers again with the attestation it has. Its own revocations do not reach the replaced policy. | `PackageRegistry.registerPackage`, `_isLiveRoot`, `isRevoked`, `packageOf` | `test_successor_refusesARootRevokedInThePredecessor`, `test_successor_refusesARootRevokedInAdvanceInThePredecessor`, `test_successor_refusesTheRootsOfAKilledSigner`, `test_successor_aLaterRevocationInThePredecessorStopsARootRegisteredHere`, `test_successor_registersARootThePredecessorNeverRevoked`, `test_successor_itsOwnRevocationsDoNotReachThePredecessor`, `test_successor_aThirdPolicyRefusesWhatEitherBeforeItRevoked`, `test_successor_theFirstPolicyReplacesNone`, `test_MintPolicySuccessor_*`, `test_ModuleSwap_TheMintPolicyComesOnlyFromTheNewRegistry` |
| CUR-26 | The replaced policy must declare `IRevokedRoots`. Only its answer of one zero word lets a root through: a revert, no data, the wrong size or any other word refuses every root, and a read that runs short of gas reverts. | `PackageRegistry` constructor, `_revokedBefore` | `test_successor_thePredecessorMustDeclareRevokedRoots`, `test_successor_aPredecessorThatDoesNotAnswerNoRefusesEveryRoot`, `test_GasRule_AReadOfTheReplacedPolicyNeverAnswersForGas` |
| CUR-27 | `preview(token, request)` is the check to run on an item before anyone signs. It runs every item check of `authorize` (CUR-8, CUR-9, and the distinct parties and roles of CUR-6) with the same errors, and none of the others: an approved root, a proof, the acceptances, the move, a delivered seed, and the content rules (content a live token already holds, or content reserved after a burn: `ContentUsed`, `ContentReserved`), which depend on what was minted and not on the item. A party that has not accepted the root counts as the artist it would be accepted as (its artist ID, or its address as a number while it has none), so it answers before the lead's first acceptance. The creator is the lead's active authority now when the lead has an identity (after a recovery that is not the lead's listed address), and the lead's own address while it has none. It consumes nothing. | `PackageRegistry.preview`, `_checkParties` | `test_preview_beforeAnyAcceptance`, `test_preview_resolvesAKnownPartysArtistId`, `test_invalidItem_payees`, `test_invalidItem_leadPaidAsAFixedPayee`, `test_invalidItem_parties`, `test_preview_quotesWithoutConsuming` |

## Events

Signatures and topic0 are under [PackageRegistry](../integrators/events-and-indexing.md#packageregistry).
A move nonce spent by `authorize` emits nothing of its own, and a repeat acceptance emits no
`PackageAccepted`: read `isMoveNonceUsed` and `acceptedAs`.

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| A curation signer key is compromised. | It can attest new roots. | `disableSigner` and `killSignerApprovals` together; grant the role to a fresh key. |
| A root with a bad item is approved. | Its items can start. | Revoke that root and every other root listing the item; works already started go to the dispute path. |
| The verifier's code no longer has the pinned hash. | `registerPackage` reverts; registered roots keep working. | `setVerifier` to a reviewed verifier (7 days). |
| Pre-signed acceptances differ in profile fields. | The first relayed sets a new identity's profile; the others revert (`ProfileMismatch`). | The artist re-signs with the recorded profile. |
| An unwanted move signature exists. | Anyone holding it can start the work before its deadline. | `revokeMove`, or let the deadline pass. |
| An item's media commitments do not match the content store. | It mints, but its record never opens. | None on chain; the signer's `StreamWorkFacts6529.open` simulation is the control. |
| A copier's work is minted from another artist's content. | During the auction an upheld dispute burns it; after the sale, a statement only. | `releaseContent` reserves the content for the rightful artist. |
| A release names an artist with no identity. | `UnknownArtist`. | The rightful artist registers first, by a first acceptance. |
| The mint policy is replaced. | The new policy decides future mints. It refuses every root the replaced policy revoked (CUR-25); approvals, acceptances, moves, releases and barred items are its own. | Roots still wanted are registered again with the attestations they have, parties accept and sign again, and the network makes again the releases it needs ([Replacing a module](../operations/replacing-modules.md#mint-policy-packageregistry); LIM-GV-32). |

## Parameters and limits

| Parameter | Value | Source |
| --- | --- | --- |
| Parties (and payees) per item | 1 to 16 | `Limits.MAX_PARTIES` |
| Merkle proof nodes | at most 32 | `Limits.MAX_PROOF_DEPTH` |
| Share denominator | 100,000 | `Splits.DENOMINATOR` |
| Move nonces per bitmap word | 255 | `PackageRegistry.NONCES_PER_WORD` |
| EIP-712 domain version | `"1"` | `Typehashes.DOMAIN_VERSION` |

## References

- Code: the sources under [Contracts](#contracts), [`src/curation/README.md`](../../src/curation/README.md).
- ADRs: [ADR 0001 §3](../adr/0001-v1-scope.md#3-curation-and-approved-packages),
  [ADR 0003](../adr/0003-build-time-decisions.md#package-format-and-curation-amends-adr-0001-3),
  [ADR 0010](../adr/0010-plain-permanent-core.md).
- Tests: [`test/curation/`](../../test/curation/); how to run them: [testing](../testing/README.md).
- Related: [stream-and-auctions.md](stream-and-auctions.md), [editions-and-sales.md](editions-and-sales.md),
  [identity-and-recovery.md](identity-and-recovery.md), [disputes-and-statements.md](disputes-and-statements.md),
  [entropy.md](entropy.md).
