# Federation

6529 Stream Federated: an artist's own token contracts, full copies of the network's
governance-approved templates, listed in the network's permanent directory without curation, sold through the
network's shared sale adapters, paying the network a locked 10% of primary sales and royalties,
and earning no TDH ([ADR 0008](../adr/0008-federation.md)).

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Role | Permanence |
| --- | --- | --- |
| `FederatedStream` | The 1/1 template (ERC-721, `IMintTarget`, ERC-2981, ERC-4906) | Permanent for its artist once deployed; no network power over it |
| `FederatedEditions` | The pair's ERC-1155 template | Same |
| `FederationRegistry` | Template versions (runtime code hash bound to creation code), published creation code, admitted adapters, joining, delisting | Replaceable, governed |
| `FederatedEditionAuction` and its lens | The uniform-price edition auction for federated pairs | Replaceable adapter |
| `Renderer` | The shared default renderer: reads a federated work as it reads a 6529 Stream work (FED-61) | Pinned per work at finalize |
| `ArtistRegistry` (directory) | The permanent, logs-only list of every federated contract (ID-33 to ID-39) | Permanent |
| `EnglishAuction` | Sells federated 1/1s (AUC-28, AUC-45 to AUC-48) | Replaceable adapter |
| `SplitLedger` | Derives and deploys every payout vault; the network pulls its royalty share there | Permanent |

## Concepts

### What the registry bargain guarantees

The 10% is what an artist pays for the registry: the listing, the shared adapters and
infrastructure, recognition. A contract that is listed pays it on everything it sells through a
network adapter (the adapter computes the fee from data locked at start and pays it to the
network's recipient itself) and on every royalty paid for a work minted while listed (the
royalty receiver is a split-ledger vault paying the network's governed fee vault 10%, fixed at
deployment). It cannot stay listed while routing around it: its code is a reviewed template
version, deployed from that version's creation code (so its starting storage is the
constructor's), with no setter for either term and no other way to mint. An
artist who does not want to pay may deploy any contract outside the registry; nothing here
restricts that. Exit is one-way and leaves tokens, ownership and funds owed untouched.

### A genuine template, without a factory with power

Templates carry no immutables: every deployment of a version has the same runtime code hash. A
code hash does not fix the storage a constructor leaves, so a copy joins only if its version's
deployer recorded it (FED-64): one ownerless `FederatedDeployer` per version, which holds that
version's creation code in data contracts written at genesis, CREATE2s it with the constructor
arguments any caller gives (under a caller-bound salt) and records every address it created. A
contract deployed any other way, at any address, is never recorded. The token itself initiates
its listing (`joinFederation`) and confirms it in the same transaction (`FederationJoined`), so
a listing made by anyone else first is never its own; and the permanent artist registry lists
nothing without the artist's own signature for that contract and its facts (FED-65).

### Entries composed on read

The registry stores no entry. `entry(token)` is composed from the artist registry's directory
(artist, status), the token's locked storage (fee share, partner) and the template table (form,
version), and only for a known code hash. A replacement registry inherits every listing. A
contract that left has no entry: every shared adapter locks a new sale's fee from the entry and
requires its code hash to be the token's, so a left contract starts no new sale there, while
`isActive` still serves the sales it started before the exit (FED-59).

### What a federated work has, and does not have

It has: an item hash (`WorksHashing.itemHash` of a `PackageItem`), the record file (changeable
by the artist until finalize), the media list (checked against the content store at mint), a
license (fixed by the item, its ID under the mint rule), an artist seed or none, a royalty rate
(lowered only), artist-set locators (printable ASCII), an on-chain-complete flag
(`syncOnChain`), the contract as its one collection with the work ID as its serial, and a
renderer pinned at finalize.

Compared with a canonical 6529 Stream work it lacks:

| Canonical work has | A federated work |
| --- | --- |
| Curation: a registered package root, the curation signer's approval | None: the artist alone approves an item on chain (`approveItem`) |
| Every party's signed consent (`PartyAcceptance`) | No party consents on chain, so an item may name no one but the contract's artist (FED-60); collaborators appear only as fixed payees (accounts the artist pays) or in the record (the artist's own words) |
| Collections and serials curated in 6529 Stream | One collection, the contract (its ERC-721 name), the work ID as the serial |
| VRF seeds | An artist seed or none |
| Governed amendments (relicensing, errata repin) and the delivery satellite | None; one artist-set locator per media file |
| Added stores beside the content store | The content store only |
| Network-wide content uniqueness (one work per primary SHA-256) | Uniqueness within the network is not checked; within the contract, one work per item |
| Statement-log artist resolution, the museum and rescue | None: an unsold work stays with the template; there is no rescue |
| A permanent home (6529 Stream is never redeployed) | The artist's own contract: a template version's bug stays in its copies |
| TDH and the network's consensus weight | None |

### What a logs-only reader should show

A federated contract is the artist's only when the directory's `FederatedContractListed` is
followed in the same transaction by the token's own `FederationJoined` with the same artist, fee
share, fee recipient and partner, and by the registry's `Registered(token, artistId, codeHash,
deployer)`, from a registry the artist registry named then, whose `TemplateSet` approved that
code hash with that deployer; the deployer's `Deployed(token, caller, salt, config)` and
`CreationCodeStored` show the token was created from the approved creation code with `config`,
which proves its starting storage (ADR 0008 §12). The artist's consent to those facts needs no
log: the artist registry lists nothing without it. A `FederationTermsLocked` from a contract never so listed attributes nothing
to anyone; a status LEFT or LEFT_DELISTED ends the listing. A federated work's `WorkOpened` names the whole item: its parties
can only be the contract's artist (its ID's account) and its artist-resolved payees only the
artist's ID (FED-60), so a reader credits the work to that artist alone. A fixed payee is a
payout address, not a credit; collaborators named in the record file are the artist's
statement, unverified on chain. A reader shows federated works apart from 6529 Stream's (the
contract is not 6529 Stream, the collection is the contract), never as curated, and counts them
for no TDH. A `FederationLeft` ends the listing for new sales; earlier works keep their 90/10
royalty vault.

## State machines

### A federated contract

```mermaid
stateDiagram-v2
    [*] --> Deployed : artist deploys a template copy
    Deployed --> Active : joinFederation (registry lists, token confirms)
    Deployed --> Left : leaveFederation (no directory entry)
    Active --> Delisted : vote, PARAMETER_SETTER 48h, or a revoked template propagated
    Delisted --> Active : vote
    Active --> Left : leaveFederation (token writes LEFT)
    Delisted --> LeftDelisted : leaveFederation (token writes LEFT_DELISTED; nothing served)
    Left --> LeftDelisted : vote delists after the exit (lands; nothing served)
    Left --> [*]
    LeftDelisted --> [*]
```

### A federated 1/1 token

```mermaid
stateDiagram-v2
    [*] --> InSale : approved item minted into an adapter's custody
    InSale --> Sold : settle with a bid (fee paid)
    InSale --> Unsold : settle unbid or frozen out (to the template)
    InSale --> Returned : refused settlement, then reclaim (to the template)
    InSale --> Burned : upheld dispute, cancel
    Unsold --> InSale : fresh approval, restart (next token ID)
    Returned --> InSale : fresh approval, restart (next token ID)
    Sold --> [*]
```

## Rules and invariants

| ID | Rule | Enforced in | Tested by |
| --- | --- | --- | --- |
| FED-1 | A template carries no immutable; every deployment of a version has one runtime code hash, its compiled runtime code's; a version is that hash bound to its deployer (FED-64) | templates | `test_Template_EveryCopyRunsTheCompiledRuntimeCode` |
| FED-2 | The artist registry, split ledger, artist, fee share and fee recipient are fixed at construction (`FederationTermsLocked`); no setter | `FederatedMembership` | `test_Join_RefusesAnUnapprovedCopyAndWrongFeeTerms` |
| FED-3 | Every artist power is checked against the artist registry's active authority of the locked artist (nobody while restrained); before the artist has an identity, the account whose address is the artist ID acts | `_onlyArtist` | `test_Join_OnlyTheArtist`, `test_GasRule_ArtistActionsReadTheArtistRegistryWithAllGas` |
| FED-4 | No restricted function exists on a deployed template. Two governed powers still reach it: the artist registry's governed recovery override (PARAMETER_SETTER, 48 hours, contestable) decides who holds the artist's powers, and the replaceable registry decides which adapters may mint new works while it is listed (`canMint`) | templates | (no restricted function exists); `test_Adapters_RemovalStopsNewWorksButTheAdapterStillSettles` |
| FED-5 | Before joining, nothing mints | `isAdmittedMinter` | `test_Mint_OnlyAfterJoiningAndOnlyAnApprovedItem` |
| FED-6 | `joinFederation(Join)` lists the token through the current registry, passing its CREATE2 salt, constructor arguments, identity fields and the artist's signatures, and requires that it was unlisted before and is listed now under its artist, ACTIVE (`FederationStateInvalid`), then emits `FederationJoined` | `FederatedMembership` | `test_Join_CreatesTheIdentityAndListsTheTokenWithItsTrueFacts`, `test_Join_AListingSomeoneElseMadeFirstIsNeverConfirmed` |
| FED-7 | While joined and not left, a mint needs the registry's `canMint` for the calling adapter | `isAdmittedMinter` | `test_Suspension_IsImmediateAndStopsOnlyNewWorks`, `test_Adapters_RemovalStopsNewWorksButTheAdapterStillSettles` |
| FED-8 | `leaveFederation` is one-way; it writes LEFT through the token if listed; running sales finish; works minted before keep their terms; no shared adapter starts a new sale (FED-59) | `FederatedMembership` | `test_Exit_IsOneWayRunningSalesFinishAndOldWorksKeepTheirSplit`, `test_Exit_BeforeJoiningNeedsNoDirectory` |
| FED-9 | After the exit, the artist admits its own minters (refused before); new works and sales carry no network share | `setAdmittedMinter`, `_feeTerms` | `test_Exit_TheArtistAdmitsItsOwnMintersAndNewWorksPayNoFee` |
| FED-10 | A work is a `PackageItem` with its media list; `itemHash` is `WorksHashing.itemHash` | `FederatedStream.mint` | `test_Mint_OnlyAfterJoiningAndOnlyAnApprovedItem` |
| FED-11 | `approveItem` approves one mint (or restart) and sets a new work's royalty rate (at most 100,000, no floor); `revokeItem` withdraws it. Anyone may start an approved item, at any time, through any admitted adapter of its sale kind (a keeper): the artist times a sale by when it approves | `FederatedStream` | `test_Unbid_StaysInTheTemplatesCustodyAndRestarts` |
| FED-12 | `mint` takes `to == msg.sender`, `id` 0, `amount` 1 and `abi.encode(FederatedMint)` of an approved ETH item; anything else reverts `InvalidMintRequest` | `FederatedStream.mint` | `test_Mint_NeverDirectly`, `test_Mint_OnlyAfterJoiningAndOnlyAnApprovedItem` |
| FED-13 | The first mint checks the media list against the item's commitment and each file's SHA-256 against the content store, at most 32 files, kind ORIGINAL or EDITION_MASTER (a master needs a partner listed ACTIVE, unless the contract left, FED-67), seed NONE or ARTIST, a license ID under the mint rule (`SpdxId`: 1 to `MAX_LICENSE_ID_BYTES` of `[A-Za-z0-9.+-]`), so the renderer can always show it, and a license text that is a registered SHA-256 content-store file of at most 16 chunks (`InvalidLicenseText`), the rule 6529 Stream's records apply to a frozen license, since a federated license never changes | `_open` | `test_GasRule_MintReadsTheContentStoreWithAllGas`, `test_Mint_TheItemNamesOnlyTheArtist`, `test_License_TheTextIsARegisteredSha256FileOfAtMostSixteenChunks` |
| FED-14 | The first mint deploys the seller vault of the item's payees and, while listed, the 90/10 royalty vault | `_open` | `test_Mint_DeploysThePayoutVaultsBeforeAnythingIsOwed` |
| FED-15 | The terms a sale gets are fixed at mint: seller vault, the locked fee terms (zero after the exit), the template as creator, ETH | `mint`, `settlePrimary`, `primaryTerms` | `test_Sold_TheNetworkGetsItsLockedTenPercentAndTheSellerTheRest` |
| FED-16 | Only the minting adapter settles a token, once; SOLD needs a buyer; settlement makes no external call and reads no identity state | `settlePrimary` | `test_SettlePrimary_OnlyTheMintingAdapterOnce`, `test_RealTemplate_SettlementFitsTheRefusalGasBudget` |
| FED-17 | UNBID and FROZEN_OUT move the token into the template's own custody (no receiver call), never to a person | `settlePrimary` | `test_Unbid_StaysInTheTemplatesCustodyAndRestarts`, `test_Revocation_EndsRunningSalesUnsoldAndTheWorkStaysHome` |
| FED-18 | A restart needs a fresh approval, burns the unsold token held by the template and mints the next token ID for the same work; refused for a sold work, for a dispute-cancelled work (no live token: the upheld dispute is final), for an edition master whose edition sale began (a refused master whose edition sale bound is never settled, so its edition is never created; that sale voids with refunds), and for an edition master while its editions are not listed ACTIVE and the contract has not left (FED-67) | `_restart` | `test_Unbid_StaysInTheTemplatesCustodyAndRestarts`, `test_Restart_RefusedForASoldWork`, `test_Pair_AMasterWhoseEditionSaleBeganNeverRestarts`, `test_Pair_AMasterRestartsOnlyWhileItsEditionsAreListed` |
| FED-19 | A refused settlement's work is claimable only by the template (`reclaim`), back into its custody (`WorkReturned`) | `reclaim`, `onERC721Received` | `test_FaultyTemplate_RefusedSaleCreditsTheBidAndTheWorkComesHome`, `test_Reclaim_OnlyAnUnsettledTokenHeldByItsAdapter` |
| FED-20 | The template accepts no ERC-721 safe transfer but its own token's return from its minting adapter | `onERC721Received` | `test_OnERC721Received_RefusesEverythingButItsOwnReturn` |
| FED-21 | `primarySale` answers NONE until the minting adapter settles (guarantee 2) | `primarySale` | `test_FaultyTemplate_RefusedSaleCreditsTheBidAndTheWorkComesHome` |
| FED-22 | The minting adapter burns a token in its custody before settlement (dispute cancel); the work keeps its record and has no live token | `burn` | `test_Burn_OnlyTheMintingAdapterBeforeSettlement` |
| FED-23 | `royaltyInfo`: the 90/10 vault for works minted while listed, else the seller vault; exact `floor(price * rate / 100,000)` | `royaltyInfo` | `test_Royalty_RoutesNinetyTenThroughTheLedger` |
| FED-24 | The royalty rate only falls | `setRoyaltyRate` | `test_Royalty_OnlyFalls` |
| FED-25 | The record file changes until finalize; finalize needs the license text complete in the content store (anyone may write its chunks, so no work is stuck) and pins the default renderer with its code hash; `rendererOf` fails closed on a changed code hash | `setRecord`, `finalize`, `rendererOf` | `test_Record_ChangesUntilFinalizeThenThePinHolds`, `test_License_FinalizeNeedsTheTextOnChain` |
| FED-26 | The record surface the renderer reads: `coreOf`, `extsload` (FED-61), `workRecords()` (itself), `isOpen`, `record`, `mediaOf`, `preferredLocator`, `licenseOf`, `seedOf`, `rendererOf`; `work` and `collection(1)` answer integrators as `IStreamViews` does | `FederatedStream` | `test_Render_TheSharedRendererReadsTheTemplatesRecord` |
| FED-27 | Locators: one per media file, set by the artist (kind zero clears); a URI is at most `Limits.MAX_URI_BYTES` of printable ASCII (`0x21` to `0x7e`) without `"` or `\` (`InvalidLocator`), WS-40's rule, so no locator can break the work's metadata | `setLocator` | `test_Locator_TheArtistPointsEachFileSomewhere`, `test_Locator_OnlyPrintableAsciiWithinTheBound` |
| FED-28 | `syncOnChain` marks a work on-chain complete once every file is complete in the content store; permissionless | `syncOnChain` | `test_SyncOnChain_OnlyOnceEveryFileIsComplete` |
| FED-29 | `linkEditions` names the pair's editions once, before joining | `linkEditions` | `test_Pair_*` |
| FED-30 | Every call out forwards all gas and reverts on any failure: a dependency costing 1x to 100x changes no outcome; a shortfall never answers | templates | `test_GasRule_*` |
| FED-31 | An edition's ID is its master's token ID; `createEdition` is permissionless once the master's sale settled, with the master's item | `FederatedEditions` | `test_Pair_EditionSalePaysTheLockedShareAndMintsWithinTheSeal` |
| FED-32 | An edition binds to the first admitted adapter that opens it, whose sale kind must be the item's; no other adapter binds or mints it | `bindMinter` | `test_Pair_TheEditionsBindToOneAdapter` |
| FED-33 | The bound adapter seals the supply once, at its sale's count; a mint past the maximum reverts | `sealSupply`, `mint` | `test_Pair_EditionSalePaysTheLockedShareAndMintsWithinTheSeal` |
| FED-34 | Mints carry ETH and the unit price (`EditionPrimaryMint`); a bound adapter no longer admitted mints only after its seal; effects precede the ERC-1155 acceptance call, so a re-entered mint (only the bound adapter mints) sees the raised count and the maximum holds without a guard | `mint` | `test_Pair_EditionSalePaysTheLockedShareAndMintsWithinTheSeal` |
| FED-35 | An edition pays the master's seller vault, the locked share while listed, and royalties to the master's 90/10 vault at the master's current rate | `_lock`, `_terms` | `test_Pair_EditionSalePaysTheLockedShareAndMintsWithinTheSeal` |
| FED-36 | `uri` is the master's renderer's | `uri` | `test_Pair_EditionSalePaysTheLockedShareAndMintsWithinTheSeal` |
| FED-41 | The registry stores no entry; `entry`, `isActive`, `canMint` are composed from the directory, the token's locked storage and the template table | `FederationRegistry` | `test_Replacement_InheritsEveryListingWithNothingToMigrate` |
| FED-42 | `isActive`: listed ACTIVE or LEFT, template approved or suspended (never LEFT_DELISTED). `canMint`: admitted adapter, listed ACTIVE, template approved, and for an editions contract its partner listed ACTIVE. `entry`: none (all zero) for a contract not listed, of an unknown code hash, or that left | `FederationRegistry` | `test_Suspension_IsImmediateAndStopsOnlyNewWorks`, `test_Revocation_EndsRunningSalesUnsoldAndTheWorkStaysHome`, `test_Exit_ALeftContractStartsNoSaleThroughTheSharedAuction` |
| FED-43 | `register` (called by the token): approved unsuspended code hash, the provenance of FED-64, canonical artist registry, ledger and (1/1) content store, the resolver's federated fee share and recipient now, a consistent pair whose 1/1 half joins after its editions; creates the identity from the artist's signature if needed; lists the token with the artist's consent to its facts (FED-65); logs `Registered` with the deployer | `register` | `test_Join_*`, `test_Provenance_*` |
| FED-44 | A template code hash is approved once, bound to its deployer (SUCCESSOR_SETTER, 30 days); suspension and revocation act on the code hash, so on every copy its deployer recorded | `approveTemplate` | `test_Templates_ApprovedOnceAndOnlyByGovernance` |
| FED-45 | Suspension (GUARDIAN, immediate) stops new joins and works; running sales finish; lifted by PARAMETER_SETTER (48 hours) | `suspendTemplate`, `resumeTemplate` | `test_Suspension_IsImmediateAndStopsOnlyNewWorks` |
| FED-46 | Revocation (SUCCESSOR_SETTER, 30 days) is terminal: the contracts are no longer served; running sales end unsold with refunds | `revokeTemplate` | `test_Revocation_EndsRunningSalesUnsoldAndTheWorkStaysHome` |
| FED-47 | `propagateRevocation` writes a revoked template's ACTIVE listings DELISTED (reference: the code hash); permissionless, batched (at most `MAX_BATCH`, 256, per call: `BatchTooLarge`), idempotent | `propagateRevocation` | `test_Revocation_EndsRunningSalesUnsoldAndTheWorkStaysHome`, `test_Batch_BoundedAtMaxBatch`, `test_Batch_TheWorstElementFitsTheBound` |
| FED-48 | Delisting and relisting by vote (PARAMETER_SETTER, 48 hours), batched (at most `MAX_BATCH`, 256, per call, so a scheduled batch always fits a transaction); a batch skips what it cannot change (an unlisted contract, or one that left asked to be ACTIVE) instead of reverting; a delisting of a contract that left lands as LEFT_DELISTED; nothing reverses an exit | `setStatus`, `setFederatedStatus` | `test_Delisting_ByVoteStopsSalesAndRelistingRestores`, `test_Exit_IsOneWayRunningSalesFinishAndOldWorksKeepTheirSplit`, `test_Delisting_ABatchSkipsWhatItCannotChange`, `test_Batch_BoundedAtMaxBatch` |
| FED-49 | Adapter admission (SUCCESSOR_SETTER, 30 days), ERC-165 `ISaleAdapter`; removal stops new works only | `setAdapter` | `test_Adapters_*` |
| FED-50 | A delisting or revocation never touches tokens, ownership, records, vaults or credits | (by construction) | `test_Delisting_ByVoteStopsSalesAndRelistingRestores` |
| FED-51 | Federation never changes 6529 Stream, a curated artist's identity or canonical state | (by construction) | `invariant_FederationNeverTouchesCanonicalState` |
| FED-52 | On every sold federated sale the network receives exactly price × the locked share, and nothing on any other outcome; the auction holds exactly its credits and live bids | `EnglishAuction` | `invariant_TheNetworkIsPaidItsShareExactlyOnSoldSales`, `invariant_TheAuctionHoldsExactlyCreditsAndLiveBids`, `testFuzz_Sold_FeeIsExactlyTheLockedShare` |
| FED-53 | The federated edition auction sells any contract the current registry serves, recorded per sale; its master is the contract's partner | `FederatedEditionAuction`, lens | `test_Pair_OnlyServedContractsOpen` |
| FED-54 | Its fee is the registry entry's share paid to the resolver's federated recipient, both locked at open, never the token's answer; a later governance change of the recipient never redirects a running sale (the English auction likewise locks it at start); the lens deploys a sale's wallets only through the canonical split ledger, refusing a token that names another | lens `feeTerms`, `_factory` | `test_Pair_ATokenThatReportsNoFeeStillPaysTheRegistryShare`, `test_Pair_TheEditionTakesTheFeeFromTheRegistryNotTheToken`, `test_Pair_TheEditionFeeRecipientIsLockedAtOpen`, `test_FeeRecipient_LockedAtStartWhateverGovernanceSetsLater`, `test_Pair_ATokenNamingAnotherLedgerOpensNoSale` |
| FED-55 | A sale of a contract the registry stops serving reads its 1/1 as cancelled and voids with full refunds; every bid and raise checks the registry, so bidding closes at the delisting, not only near the close (`BiddingClosed`, end zero); a settle call while the scan has paid nothing checks it again, so a delisting between settle calls still voids the sale, and once the clearing call has paid the clearing stands | lens `clock`, `isTarget`; `bid`, `raise`, `settle` | `test_Pair_ADelistingVoidsTheRunningEditionSaleWithRefunds`, `test_Pair_ADelistedSaleTakesNoBidOrRaiseLongBeforeTheClose`, `test_Pair_ADelistingMidScanVoidsBeforeAnyPayout` |
| FED-56 | An abandoned sale's seal at zero is best effort; a shortfall reverts | `_sealVoid` | `test_Abandon_AFederatedSaleWaitsOnlyItsLockedDelay` |
| FED-57 | Every other rule of the edition auction is the shared base's (EA-1 onward) | `UniformEditionAuctionBase` | the edition auction suites |
| FED-58 | Its lens views read the English auction directly; a delisted sale's views show its 1/1 as it is, while bids and settlement treat it as cancelled | lens | (documented) |
| FED-59 | A contract that left has no registry entry: the English auction (`_lockTerms`) and the federated edition auction (`feeTerms`) refuse a new sale of it (`InvalidSaleTerms`), even through an adapter its artist admits as its own minter, so no network fee is ever locked for it again; a sale started before the exit finishes and pays the share it locked (`isActive` serves LEFT) | `FederationRegistry.entry` | `test_Exit_ALeftContractStartsNoSaleThroughTheSharedAuction`, `test_Exit_ALeftPairOpensNoEditionSaleAndARunningOneSettles` |
| FED-60 | An item names no one but the contract's artist: every party's account is the artist's ID as an address, every artist-resolved payee is the artist's ID (`InvalidMintRequest`); fixed payees are accounts the artist pays. No other artist's payout, standing or directory entry is touched by a federated work | `_open` | `test_Mint_TheItemNamesOnlyTheArtist` |
| FED-61 | The shared renderer reads a federated work through the native path it uses for 6529 Stream, never through a replaceable contract: `coreOf`, and `extsload` at `StreamLayout`'s slots, where the template keeps its token words (slot 18: the minting adapter in bits 0-159, the work ID, shown as the serial, in 160-191) and its one collection (slot 17: the ERC-721 name two slots into the entry, written at construction). A template version's code, and so this layout, never changes | `FederatedStream` storage | `test_Layout_TheTemplateAnswersTheRenderersNativeReads` |
| FED-62 | The edition auction's abandonment floor adds what the master's rescue delay adds to 6529 Stream's 90-day floor, capped by `rescueCapDays` (EA-18, EA-19); a federated 1/1 has no rescue, so a federated sale waits its end plus its locked delay alone, in the lens and the adapter, whatever Stream's rescue delay, and no 6529 Stream slot is read for it | `_rescueLengthening` | `test_Abandon_AFederatedSaleWaitsOnlyItsLockedDelay` |
| FED-63 | Genesis wires the federation: the artist registry's one-shot bind, the English auction's registry (code hash pinned), both shared adapters admitted, and the two v1 template versions approved, each code hash computed from the build (`DeployV1.templateCodeHash`, never a literal) bound to its deployer, which genesis deploys with the build's creation code; `VerifyV1.checkFederation` reads each back and `checkTemplate` checks the deployer's code is the build's `FederatedDeployer` and rehashes its creation code, so a rebuilt artifact or another deployer fails | `DeployV1`, `VerifyV1`, `GovernanceConfig.isGenesisSelector` | `test_GenesisWiresTheFederation`, `test_CheckTemplate_RefusesARebuiltArtifact` |
| FED-64 | A copy joins only if its version's approved deployer recorded it: the deployer, ownerless and immutable (no owner, role, fee, upgrade, delegatecall or selfdestruct), holds one creation code in data contracts it wrote at construction, deploys it for anyone with the caller's constructor arguments under the salt `keccak256(caller, salt)`, records each address and emits `Deployed`; so a listed copy's starting storage is its constructor's, whatever any other initcode wrote at any address (immune to CREATE2 address collisions) | `FederatedDeployer`, `register` | `test_Provenance_ACopyNotRecordedByTheApprovedDeployerNeverJoins`, `test_Provenance_OnlyTheApprovedDeployersRecordCounts`, `test_Deployer_DeploysOnlyItsCodeAndRecordsEveryCopy`, `test_Provenance_ACopyAnyoneDeploysIsInertUntilItsArtistJoins`, `test_Gas_DeployThroughTheDeployer` |
| FED-65 | The artist registry lists a contract only with the artist's active authority's `FederatedListing(artistId, token, form, partner, feeShare, feeRecipient, deadline)` signature, verified there (ECDSA, EIP-7702 or ERC-1271), so no federation registry, however hostile, lists a contract under an artist who did not sign for it, nor with facts the artist did not sign | `ArtistRegistry.listFederatedContract` | `test_Directory_NoRegistryListsUnderAnArtistWhoDidNotSign`; FD `test_List_TheConsentCoversTheFacts`, `test_List_*` |
| FED-66 | An exit from DELISTED, or a delisting after an exit, is LEFT_DELISTED in the directory, terminal and served by nothing: neither an exit nor its timing revives a sale a delisting stopped, on either shared adapter or lens | `ArtistRegistry.recordFederationExit`, `setFederatedStatus`, `isActive` | `test_Exit_AfterADelistingRevivesNoSale`, `test_Delisting_ScheduledBeforeAnExitStillLands`, `test_Pair_EditionsLeavingWhileDelistedReviveNoEditionSale`, FD `test_Exit_ByTheTokenIsTerminal`, `test_Status_ADelistingOfALeftEntryLandsAsLeftDelisted` |
| FED-67 | The pair as one: the 1/1 half joins only after its editions are listed ACTIVE under the same artist; an editions contract mints through the registry only while its partner is listed ACTIVE; a 1/1 contract mints or restarts an EDITION_MASTER only while its editions are listed ACTIVE (or after its own exit); an editions contract's own minters mint only once its partner is unlisted, LEFT or LEFT_DELISTED. So an edition sells only while both halves are ACTIVE (always on fee-bearing terms) or after both are out | `register`, `canMint`, `_open`, `_restart`, `_ownMinters` | `test_Pair_The1of1JoinsOnlyAfterItsEditions`, `test_Pair_EditionsThatLeaveFirstSellNothingWithoutTheFee`, `test_Pair_AMasterRestartsOnlyWhileItsEditionsAreListed`, `test_Pair_EditionsWithoutAListed1of1MintNothing` |
| FED-68 | A 1/1 template names its content store at construction (`ContentStoreSet`, `contentStore()`); the registry lists only one naming the canonical store | `FederatedStream`, `register` | `test_Join_RefusesAContentStoreOtherThanTheCanonicalOne` |
| FED-69 | Once replaced in the artist registry, a registry answers `entry`, `isActive` and `canMint` as the current one does (unless the current one asks), so the English auction's own pointer never disagrees with the templates' | `FederationRegistry._forwards` | `test_Replacement_TheEnglishAuctionAnswersAsTheCurrentRegistry`, `test_GasRule_MintReadsTheRegistryWithAllGas` |
| FED-70 | Each genesis setter reaches only a target declaring its interface (ERC-165): the sale adapters' `setFederationRegistry` and `setTarget` need `ISaleAdapter`, the registry's `setAdapter` and `approveTemplate` `IFederationRegistry`, `setAdmittedMinter` `IMintTarget`; the artist registry's `setFederationRegistry` is never wired | `GovernanceConfig.genesisInterface`, `validateWiring` | `test_GenesisSelectorsReachOnlyTheirTargets` |

## Events

The directory's `FederatedContractListed` and `FederatedContractStatus` (artist registry) are
the logs-only record of every federated contract. A listing is the token's own when its
`FederationJoined` follows in the same transaction with the same facts (and its constructor's
`FederationTermsLocked`). Each template logs every state change: `ItemApproval`, `WorkOpened`
(the whole item and media list), `TokenMinted`, `PrimarySaleSettled`, `WorkReturned`,
`RecordChanged`, `Finalized`, `RoyaltyRateChanged`, `LocatorSet`, `OnChainComplete`,
`DefaultRendererSet`, `EditionsLinked`, `ContentStoreSet`, `FederationLeft`, `MinterSet`, the ERC-721/1155
transfers; the editions template `EditionCreated`, `EditionTermsLocked`, `EditionMinterBound`,
`EditionPrimaryMint`, `EditionSupplySealed`. The registry logs `TemplateSet` (with the deployer
and its creation code hash), `AdapterSet`, `Registered` (with the deployer); each deployer logs
`CreationCodeStored` once and `Deployed` (with the caller, salt and constructor arguments) for
every copy. Payout vaults are logged by the split ledger. Federated contracts earn no TDH.

## The nine template guarantees, as met

[Stream and auctions](stream-and-auctions.md#what-a-federated-template-must-guarantee) lists
what a federated template must guarantee for the English auction's refusal exit to stay fair.
The v1 templates meet each:

| # | Guarantee | How the v1 template meets it | Tested by |
| --- | --- | --- | --- |
| 1 | Gas: the whole settlement within the refusal gas less the auction's worst case | `settlePrimary` makes no external call and reads only its own storage; a sold settlement executes about 95,000 gas | `test_RealTemplate_SettlementFitsTheRefusalGasBudget` |
| 2 | `primarySale` answers NONE until the adapter settles | The token's state is IN_SALE from mint to `settlePrimary`; `primarySale` answers NONE for it | `test_FaultyTemplate_RefusedSaleCreditsTheBidAndTheWorkComesHome` |
| 3 | No third-party guards | Settlement calls nothing: no escrow, wallet or vault is touched | `test_RealTemplate_SettlementFitsTheRefusalGasBudget` |
| 4 | No buyer or recipient code | `settlePrimary`, `ownerOf` and `primaryTerms` call nothing; an unsold token moves into the template's custody with no receiver call | `test_Unbid_StaysInTheTemplatesCustodyAndRestarts` |
| 5 | No identity dependency for a sale | Settlement reads no identity state; even an unsold one names the template, not the artist, as creator | `test_SettlePrimary_OnlyTheMintingAdapterOnce` |
| 6 | Locked payees | The seller vault, the fee flag and the creator are written at mint; the fee terms are fixed at construction; the seller is a split-ledger vault address, never zero, the escrow or the auction | `test_Sold_TheNetworkGetsItsLockedTenPercentAndTheSellerTheRest` |
| 7 | An honest ledger | OpenZeppelin's ERC-721 `ownerOf` and `safeTransferFrom`, unmodified, starting from the constructor's storage only (FED-64: no hidden approval or pre-seeded token) | `test_FaultyTemplate_RefusedSaleCreditsTheBidAndTheWorkComesHome`, `test_Provenance_ACopyNotRecordedByTheApprovedDeployerNeverJoins` |
| 8 | One settlement, by its adapter | Only the minting adapter, once (`NotMintingAdapter`, `SaleAlreadySettled`); SOLD returns `holder` zero; UNBID and FROZEN_OUT return the template, which the adapter records as taken | `test_SettlePrimary_OnlyTheMintingAdapterOnce` |
| 9 | Fixed code | No proxy, no delegatecall, no immutables: the code hash the registry approved is the code that runs, deployed from the approved creation code | `test_Template_EveryCopyRunsTheCompiledRuntimeCode` |

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| A template version is found buggy | Its deployed copies keep the bug (code never changes) | GUARDIAN suspends at once (new works stop); revocation in 30 days ends its sales unsold; the artist leaves and redeploys a fixed version |
| A token whose settlement fails (a faulty version) | The bid is held until the refusal delay | `settleOrRefund` closes it with the bid credited; `reclaim` returns the work |
| The registry is replaced or disappears | Nothing listed is lost (entries are composed) | A new registry approves every template version (with its deployer) and admits the adapters **before** the artist registry's pointer moves, or running sales freeze out with refunds; with none, the artist leaves and admits its own minters |
| A registry lists a genuine token first, wrongly | The token can never confirm it, so never sells under it; it needs the artist's own consent signature for that token | The artist leaves and redeploys |
| A delisted contract leaves, or leaves while a delisting waits | LEFT_DELISTED: its running sales end unsold with refunds | None needed |
| A delisted pair's edition sale is running | It voids with full refunds | Relist, open a new sale |
| An edition sale voids while its best-effort seal is refused (a faulty token) | The edition stays bound to that adapter's void sale: no adapter reopens or binds it, and no minter mints it, ever | None needed: no copy can exist |
| A contract left while sales ran | They finish and pay the share they locked; no new sale starts on a shared adapter | The artist sells through minters it admits |

## Residual leakage (accepted)

Marketplaces that ignore ERC-2981; a 0% royalty rate (the artist's choice, no floor); self-bids
at the opening bid followed by an off-chain sale; side payments; works sold after an exit
through the artist's own minters (the exit is the way out of the bargain, by design); and
(governance risk) a replacement registry or adapter taking a different fee, behind the 30-day
swap and the guardian veto. None of these lets a listed contract sell through a network adapter
without paying the locked share.

## Parameters and limits

No number in a template is a policy number: the 32-media bound is the record's structural bound
(`Limits.MAX_MEDIA_FILES`), `UNCAPPED` (2^40 - 1) is a storage-width safety bound, the
100,000 denominator is the share unit. The fee share and recipient are each contract's own,
fixed at deployment. Gas rows and deployment costs (Prague, and Glamsterdam estimates with the
arithmetic) are in [ADR 0004's table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table)
and [ADR 0008](../adr/0008-federation.md).

## Differences from the ADRs

- ADR 0001 §16 "only the factory can add entries": there is no factory with power; a contract its
  version's ownerless deployer recorded joins itself, with its artist's consent.
- ADR 0005 decision 9: an unbid federated work stays in the template's custody and restarts.
- Study H's federated registry entries are not stored; they are composed on read.
- ADR 0007's genesis wiring list (`GovernanceConfig.isGenesisSelector`) also admits the
  federation's first configuration: the English auction's `setFederationRegistry` and the
  registry's `setAdapter` and `approveTemplate`, each scoped to targets declaring its interface
  (FED-70); every later change waits its class.

## References

[ADR 0008](../adr/0008-federation.md) · [ADR 0007](../adr/0007-permanence.md) ·
[Stream and auctions](stream-and-auctions.md) (AUC-28, AUC-45 to AUC-48, the nine template
guarantees) · [Editions and sales](editions-and-sales.md) ·
[Identity and recovery](identity-and-recovery.md) (the directory) ·
[`src/federated`](../../src/federated/README.md)
