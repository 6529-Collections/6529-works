# Invariants

For auditors: every invariant the stateful campaigns, their handlers, and fuzz and unit tests
check, and which contracts each campaign runs for real. Each statement comes from the
assertion, not the test's name; [Gaps](#gaps) lists what no campaign covers.

> Pre-audit. See the [project status](../../README.md#status).

## Campaign settings

Every campaign runs with `[profile.default.invariant]` in [`foundry.toml`](../../foundry.toml):
`runs = 256`, `depth = 128` calls per run, `fail_on_revert = true`, `show_metrics = true`.
Fuzz tests run 256 times (`[profile.default.fuzz] runs`). No `/// forge-config:` comment under
`test/` overrides either.

- **The rule.** Every contract that moves money gets stateful invariants of at least 256 runs
  of depth 128 ([AGENTS.md](../../AGENTS.md), [ADR 0001](../adr/0001-v1-scope.md#intended-behavior)).
- **`fail_on_revert`.** Every handler action succeeds or is skipped, and an expected revert is
  asserted inside the handler (`try`/`catch` or `vm.expectRevert`), so a wrong prediction fails
  the campaign.
- **Kinds.** A campaign row is a stateful invariant (an `invariant_*` function, checked after
  every call of every run) unless its Test cell says **handler check** (an assertion inside a
  handler action, failing the campaign through `fail_on_revert`) or **after-campaign** (an
  `afterInvariant` hook, checked at the end of every run).
- **Non-vacuity.** `test_HandlerReachesEveryPath` (economics, Dutch, fixed price),
  `AuctionHandlerCoverage.test_EveryPathRuns`, `AuctionHaltsCoverage.test_HaltPathsRun` and
  `ArtistRegistryInvariantTest.test_HandlerReachesContestResolveAndLapse` replay
  campaign-shaped sequences and assert that every path the invariants rely on executes.
- **Running them.** `forge test --match-contract Invariant`; commands and CI jobs are on
  [Build, test and budgets](build-and-test.md).

## Stream and work records

[`StreamInvariant.t.sol`](../../test/stream/StreamInvariant.t.sol), handler
[`StreamHandler`](../../test/stream/StreamHandler.sol). Real `Stream`, `WorkRecords` and
`SplitFactory`; mocks `MockSaleAdapter`, `MockEconomics` and two `MockRenderer`s. 40 items in
three collections.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-STR-1 | `totalMinted` counts successful mints, `totalSupply` is minted minus burned, and the adapter's and actors' balances sum to `totalSupply`. | `invariant_supplyIsMintedMinusBurned` | `mint`, `burn`, `deliver`, `transfer` |
| INV-STR-2 | Each mint gets ID `totalMinted + 1` and `totalMinted` never decreases, while a burned ID's `ownerOf` reverts (`ERC721NonexistentToken`), as does `work(totalMinted + 1)` (`UnknownWork`). | `invariant_idsMonotonicAndNeverReused` | `mint`, `burn` |
| INV-STR-3 | Each live token's `royaltyInfo` receiver, `work().royaltyReceiver` and `work().seller` match the handler's own derivation (mint payees, fee terms, real split factory) at the last consented, governed rate, and `royaltyInfo(id, 1 ether)` pays `rate × 1 ether / 100,000`. | `invariant_royaltyTermsLocked` | `mint` (random fee terms), `changeRoyalty` |
| INV-STR-4 | Governance alone cannot change a royalty rate, and a replayed consent bundle never changes the work's state hash. | handler check: `forceRoyalty`, `replayRoyalty` (`violations`, asserted by INV-STR-2 and INV-STR-3) | as named |
| INV-STR-5 | Each collection's `minted` equals its mints and never drops on a burn, and each live work's collection and serial match the model (1, 2, 3, ... per collection). | `invariant_serialsPerCollection` | `mint`, `burn` |
| INV-STR-6 | `primarySaleSettled(id)` is true exactly for the live tokens the minting adapter marked, and `markPrimarySettled` from anyone else reverts. | `invariant_primarySaleSettledOnlyByMintingAdapter`; handler check: `forgeSettle` | `settle`, `forgeSettle` |
| INV-STR-7 | The minting adapter cannot burn a token whose primary sale is marked settled. | handler check: `burn` (`violations`) | as named |
| INV-STR-8 | A finalized work keeps its record file ID and renderer pin (returned by `rendererOf`), and `setRecord` and `finalize` on it revert. | `invariant_finalizedRecordsImmutable`; handler check: `attackFinalized` | `finalize`, `setRecord`, `attackFinalized`, `swapRenderer`, `addLocator` |

## 6529 Editions

[`Editions.invariant.t.sol`](../../test/editions/Editions.invariant.t.sol), handler
[`EditionsHandler`](../../test/editions/EditionsHandler.sol). Real `Editions`; Stream, the package
registry, economics, the artist registry, work records, the renderer and both sale adapters
(`EditionsAdapterMock`) are mocks. Editions: FIXED of 20 at fixed
price; uncapped OPEN with a one-day Dutch window; OPEN of 30 with a 12-hour fixed-price window.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ED-1 | A mint succeeds only within the size, before the end of an OPEN window that starts at the first mint, from an admitted minter (else `NotAdmittedMinter`) of the matching sale kind (else `SaleKindMismatch`). | `invariant_MintsFollowEditionTerms` | `buy`, `buyWithWrongAdapter`, `mintAsOutsider`, `warp` |
| INV-ED-2 | `edition(id).minted` counts every copy ever minted and never exceeds a nonzero size, and balances sum to minted minus burned. | `invariant_SupplyAccounting` | `buy`, `burnFromCustody`, `transfer` |
| INV-ED-3 | An OPEN edition's `windowStart` is its first mint's time and never moves; a FIXED edition's is zero. | `invariant_WindowStartsOnce` | `buy`, `warp` |
| INV-ED-4 | Through repeated `createEdition` calls and resales of the master, neither the link (`masterOf`: Stream, master ID, content hash; `Stream.editionOf`: Editions, edition ID) nor `royaltyInfo`'s receiver and amount change. | `invariant_LinkAndRoyaltyFixed` | `recreate`, `moveMaster` |

## Curation

[`PackageRegistryInvariant.t.sol`](../../test/curation/PackageRegistryInvariant.t.sol),
handler `CurationHandler` in the same file. Real `PackageRegistry` and
`Eip712CurationVerifier`; mock `MockArtistRegistry`. Twenty items by three artists: 0 to 9 in
package A, 6 to 15 in package B, 16 to 19 in none; items `i` and `i + 8` share a content hash;
a third root C starts unregistered. The handler is an exact model of nine actions: `consume`,
`claimEdition`, `release`, `revokeMove`, `rotate`, `revokePackage`, `registerLate`,
`acceptLate` and `rebind`.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CUR-1 | No call the model forbids succeeds (revoked or unregistered root, foreign or wrong proof, stale key, spent or revoked move nonce, expired move, used or released content, unbound caller, second binding). | `invariant_noUnexpectedSuccess` | all nine |
| INV-CUR-2 | Every call the model allows succeeds, so the model is exact. | `invariant_noUnexpectedFailure` | all nine |
| INV-CUR-3 | Each item is consumed at most once, never if it is in no package, and `isReleased` matches the model. | `invariant_itemConsumedAtMostOnce` | `consume`, `release` |
| INV-CUR-4 | Per content hash, `consumedItemOf` and `editionClaimOf` equal the model's single live Stream item and edition claim. | `invariant_contentRecordsMatch` | `consume`, `claimEdition`, `release` |
| INV-CUR-5 | An edition claims only a content hash Stream consumed, naming the consuming item, and claims never outnumber consumptions, so the linked pair is the only reuse across products. | `invariant_editionsReuseOnlyTheirMaster` | `claimEdition` |
| INV-CUR-6 | Every artist's 31 move-nonce flags and every root's status equal the model. | `invariant_noncesAndStatuses` | `revokeMove`, `rotate`, `revokePackage`, `registerLate`, `acceptLate` |

No dedicated invariant covers the single use of a package's registration; the model's
exactness (INV-CUR-1, INV-CUR-6) tests it.

## Economics

[`EconomicsInvariant.t.sol`](../../test/economics/invariant/EconomicsInvariant.t.sol), handler
[`EconomicsHandler`](../../test/economics/invariant/EconomicsHandler.sol). Real `SplitFactory`,
`SplitWallet` (three payee sets, each at two salts so a replacement exists), `ReleaseVerifier`,
`RevenueEscrow`, `ClaimRouter`, OpenZeppelin `AccessManager`, and `RevenuePayment` in a
`PaymentHarness`; mock `MockArtistResolver`. Assets: ETH, a USDC-style blocklist token, a
fee-on-transfer token and a rebasing token. The handler predicts outcomes from its own ghost
state, never `releasable`, and measures releases by balance deltas.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ECO-1 | Per wallet and asset, payee releases sum to `totalReleased`, and (except for the rebasing token) `totalReleased` plus the balance equals everything received. | `invariant_WalletConservesValue` | `release`, `releaseTo`, `releaseSigned`, `claimBatch`, `pay`, `receiveDirect`, `flush` |
| INV-ECO-2 | Each payee's `released` equals what its recipients measurably received, at most `floor(receipts × share / 100,000)` at its last release's receipts (the wallet's mark for an ERC-20, the model's for ETH). | `invariant_ReleasedWithinEntitlement` | release actions |
| INV-ECO-3 | Per asset, total released across wallets equals what recipients measurably received, and (except for the rebasing token) the actors hold exactly that. | `invariant_RecipientsReceivedEverythingReleased` | release actions |
| INV-ECO-4 | Recorded ERC-20 receipts equal the model's high-water mark (never decreasing and, except for the rebasing token, never above live receipts); ETH records no mark, and live ETH receipts never fall below the model's. | `invariant_ObservedNeverDecreases` | `rebaseTo`, `toggleFee`, release actions |
| INV-ECO-5 | Unreleasable dust per wallet and asset (ETH, the blocklist and fee tokens) is at most the payee count minus one. | `invariant_DustIsBounded` | all |
| INV-ECO-6 | Every escrow credit equals the model, credits sum to `totalOwed` per asset, and the escrow's balance is at least `totalOwed`. | `invariant_EscrowIsSolventAndMatchesTheModel` | `pay`, `deposit`, `flush`, `recover`, `consentToggle` |
| INV-ECO-7 | The claim router holds nothing, and the payer holds no ETH, no allowance to the escrow, and only the tokens of payments the model expected to revert. | `invariant_IntermediariesHoldNothing` | `claimBatch`, `pay` |
| INV-ECO-8 | Every release, signed release, batch item, payment, deposit, flush and recovery reverts with exactly the predicted error data or moves exactly the predicted amount. | handler check: every action | all |
| INV-ECO-9 | A replayed signed release fails with `NonceAlreadyUsed`, or with `NotPayoutAddress` once the artist's payout changed. | handler check: `replaySigned` | `releaseSigned`, `revokeNonce`, `setArtistPayout` |
| INV-ECO-10 | Governed recovery moves a split wallet's credit only to its equivalent replacement (same payees, another salt) and another account's only to the replacement that account consented to, consuming the consent. | handler check: `recover`, `consentToggle` | as named |
| INV-ECO-11 | A claim batch pays each item its predicted amount, and the recipients' balances rise by exactly the batch total. | handler check: `claimBatch` | as named |

## English auction

Two suites, each run in ETH and in an ERC-20 that blocks the seller wallet (so ERC-20 seller
payouts go to the escrow); the network wallet refuses ETH, so ETH fee payouts do too. Real `EnglishAuction`, `AssetAllowlist`,
`RevenueEscrow` and `StatementLog`; mocks `MockMintTarget` (not Stream) and `MockPermit2`. Each
suite's `afterInvariant` drives every sale to an end after each run.

- [`AuctionInvariant.t.sol`](../../test/sales/auction/invariant/AuctionInvariant.t.sol)
  (`AuctionInvariantEth`, `AuctionInvariantErc20`), handler
  [`AuctionHandler`](../../test/sales/auction/invariant/AuctionHandler.sol): starts with and
  without bids, honest and hostile bids (direct, EIP-2612, relayed Permit2), dispute pauses,
  withdrawals, upheld cancellations, resumptions, settlements, claims, delivery claims, the
  start pause and governance changes.
- [`AuctionHaltsInvariant.t.sol`](../../test/sales/auction/invariant/AuctionHaltsInvariant.t.sol)
  (`AuctionHaltsInvariantEth`, `AuctionHaltsInvariantErc20`), handler
  [`AuctionHaltsHandler`](../../test/sales/auction/invariant/AuctionHaltsHandler.sol): the same,
  plus currency deprecation and re-admission (MARKET-2), a token that blocks the auction
  (MONEY-1 credits) and `claimFor`.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-AUC-1 | The auction's balance equals the high bids of live sales (neither settled nor cancelled) plus every actor's claimable credit (in the halts suite including the seller's and network's payout credits, checked both `>=` and `==`). | `invariant_HeldEqualsLiveBidsPlusCredits`, `invariant_BalanceCoversOwed` | all |
| INV-AUC-2 | Every unit deposited as a bid is held by the auction, paid to the seller or network wallet, credited to one of them in the escrow, or claimed. | `invariant_ValueIsConserved` (both suites) | all |
| INV-AUC-3 | Each sale has at most one outcome and exact custody: a cancelled sale's token is burned, with no bidder; a settled sale holds its token only while delivery is pending (base suite: marked primary-settled); an open sale holds it. | `invariant_OneOutcomeAndExactCustody`, `invariant_ExactCustody` | `settle`, `cancel`, `claimDelivery` |
| INV-AUC-4 | Each sale keeps its locked currency, token, token ID and first-bid increment floor (even after a withdrawal), a live sale names its high bid's recipient, and `minimumBid` is `max(openingBid, the withdrawn bid kept as reserve, 1)` with no bidder, else the bid plus `max(ceil(bid × share / 100,000), floor)`. | `invariant_LockedTermsAndRecipients` | `bid`, `withdrawBid`, `govern` |
| INV-AUC-5 | Every sale, ended or not, keeps in storage the opening bid, increment share and anti-snipe window locked at start and its first bid's floor, whatever governance changed (read from storage, layout cross-checked against the view). | `invariant_StoredTermsMatchWhatEachSaleLocked` | `govern` |
| INV-AUC-6 | After 30 days, settling every sale and claiming every delivery and credit leaves no funds and no token, with every deposit accounted for. | after-campaign: `AuctionInvariantBase.afterInvariant` | all |
| INV-AUC-7 | Once the token stops blocking and the currency is re-admitted, every sale ends settled or cancelled, leaving no funds and no token. | after-campaign: `AuctionHaltsInvariantBase.afterInvariant` | `drain` |
| INV-AUC-8 | A bid extends the end to at least `now + the locked window`; settlement delivers the token (or leaves it pending) to the high bid's recipient, or the artist if none; a second dispute pause reverts (`PauseExhausted`); a withdrawal leaves the sale paused; `resume` or `unpause` within 48 hours (`Roles.STANDARD`) of the pause reverts (`UnpauseTooEarly`, review finding GOV-5). | handler check: `bid`, `settle`, `pause`, `pauseAndWithdraw`, `resume`, `toggleStartPause` | as named |
| INV-AUC-9 | An unended sale refuses `settle`; a deprecated currency blocks settlement for 30 days, then `settle` credits the standing bid back to its bidder and gives the work to its artist; re-admission in the last window or after the end reopens the sale for the longer of the governed duration and the locked window, keeping the bid. | handler check: `AuctionHaltsHandler.settle`, `_freezeExit` | `settle`, `toggleCurrency` |

## Fixed-price and Dutch sales

Real `FixedPriceSale` and `DutchSale`; mocks from [`SaleFixture`](../../test/helpers/SaleFixture.sol)
for the edition (`MockEditionTarget`), escrow (`MockRevenueEscrow`), allowlist
(`MockAssetAllowlist`), economics resolver and Permit2. The handlers make only valid purchases
(plus two attacks for fixed price) while the seller wallet randomly refuses ETH or is blocked
by the token, so payouts reach the escrow. The fee share is 25,000 of 100,000.

**Dutch:** [`DutchInvariant.t.sol`](../../test/sales/dutch/DutchInvariant.t.sol), handler
`DutchHandler` in the same file (edition size 40; ETH buyers overpay at random).

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-SAL-1 | The adapter's ETH balance equals the buyers' claimable ETH credits. | `invariant_CreditsAreFullyBacked` | `buyEth`, `claim` |
| INV-SAL-2 | Seller and network ETH plus escrow credits equal the total charged, all ETH sent equals that plus the adapter's balance and claims, and the network's part equals the summed fees. | `invariant_EthIsConserved` | `buyEth`, `claim`, `setWallet` |
| INV-SAL-3 | The adapter holds and credits no ERC-20, seller and network tokens plus escrow credits equal the total charged, and the network's part equals the summed fees. | `invariant_TokenChargesAreExactAndNeverKept` | `buyToken`, `setWallet` |
| INV-SAL-4 | Copies minted equal the model and never exceed the size. | `invariant_MintedWithinSupply` | `buyEth`, `buyToken` |
| INV-SAL-5 | The current price never rises between observations. | `invariant_PriceNeverRises` | `warp` and purchases |

**Fixed price:** [`FixedPriceInvariant.t.sol`](../../test/sales/fixed/FixedPriceInvariant.t.sol),
handler `FixedPriceHandler` in the same file (edition size 16; a recipient-keyed priced
allowlist phase, a payer-keyed phase, a public phase capped at 3, and an ERC-20 sale capped at
5, paid directly or by relayed Permit2).

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-SAL-6 | No purchase beyond a leaf's remaining cap succeeds, and no wallet mints to itself with another wallet's leaf. | `invariant_NoOverCapOrForeignLeafPurchaseSucceeds` | `attackOverCap`, `attackForeignLeaf` |
| INV-SAL-7 | The adapter holds no ETH, ETH paid equals seller and network balances plus escrow credits, and the escrow's ETH equals its `totalOwed`. | `invariant_EthIsPaidOrEscrowedNeverKept` | ETH purchases, `setWallet` |
| INV-SAL-8 | INV-SAL-7 holds for the ERC-20. | `invariant_TokenIsPaidOrEscrowedNeverKept` | `buyToken`, `setWallet` |
| INV-SAL-9 | The network's ETH and token receipts, paid or escrowed, equal the sum of each purchase's `floor(total × 25,000 / 100,000)`. | `invariant_FeesAreExact` | purchases |
| INV-SAL-10 | Copies minted equal the model and the holders' balances and never exceed the size. | `invariant_MintedWithinSupplyAndAccounted` | purchases |
| INV-SAL-11 | `purchased(token, id, phase, wallet)` stays within the leaf cap (phases 0 and 1), the public cap (3) or the ERC-20 sale's cap (5). | `invariant_PerWalletCapsHold` | purchases |

### Stream's interned terms

[`StreamTermsInvariant.t.sol`](../../test/stream/StreamTermsInvariant.t.sol), handler
`TermsHandler` in the same file. Real `Stream` and `SplitFactory`; mocks as above, two admitted
adapters and two fee recipients. The handler mints under 36 terms that share six 23-bit
positions (real collisions, found offline), re-rates tokens toward colliding rates, and squats
empty positions with foreign words so that terms must overflow.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-STR-9 | Every token's terms ID names exactly the terms it locked, at their hashed position or through the overflow index, and every view of the last token touched (`work`, `artistOf`, `royaltyInfo`, `primaryTerms`) returns those terms. | `invariant_EveryViewMatchesTheLockedTerms` | `mint`, `reRate`, `squat`, `settle` |
| INV-STR-10 | Terms and terms IDs map one-to-one: the same terms always get the same ID, and an ID never names two terms. | handler check: `mint`, `reRate` | as named |
| INV-STR-11 | Only the minting adapter can mark a token settled. | handler check: `settle` | as named |

## Identity and recovery

[`ArtistRegistry.invariant.t.sol`](../../test/identity/ArtistRegistry.invariant.t.sol),
handler [`ArtistRegistryHandler`](../../test/identity/ArtistRegistryHandler.sol). Real
`ArtistRegistry` and `ConsolidationAdapter`; mocks `DelegationManagementMock`,
`SplitFactoryWalletsMock` and `DisputeOutcomeLogMock`. One artist and four keys: the artist
key, an established consolidated wallet, a fresh key and a thief. The handler predicts success
or the exact error before every call.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ID-1 | The payout and `authorityOf` equal the model and change only by a successful `executeChange` or upheld `resolveContested`; `payoutAddress` is zero exactly while a pending change would move the payout and its contest, if any, has not lapsed (365 days). | `invariant_PayoutChangesOnlyThroughExecutedChanges` | `stageStandard`, `stageOverride`, `execute`, `resolve`, `expire`, `veto`, `cancel` |
| INV-ID-2 | IDENTITY-1: `activeAuthorityOf` is zero exactly while a pending override (kind above STANDARD) would move the authority and its contest, if any, has not lapsed, and otherwise equals the authority. | `invariant_ActiveAuthorityIsRestrainedOnlyByAnAuthorityMovingOverride` | as INV-ID-1 |
| INV-ID-3 | The last-activity time and `changeNonce` equal the model: dormancy counts only the artist's own activity and executions (not overrides, vetoes or refreshes), and the nonce moves only on stagings and revocations. | `invariant_ActivityAndNonceMatchTheModel` | `heartbeat`, `revokeNonce`, `refreshStanding`, stagings |
| INV-ID-4 | A pending change is well formed: `executableAt` is `stagedAt` plus 7 days (STANDARD) or 180 days (override), `previousAuthority` is current, the evidence hash is zero exactly for STANDARD, the cancellers are those captured at staging (at most 16), the next authority and payout are nonzero, only overrides are contested (`contestedAt` in `[stagedAt, executableAt)`), and uncontested changes record no prior outcome. | `invariant_PendingChangeIsWellFormed` | stagings, `cancel`, `toggleConsolidation` |
| INV-ID-5 | IDENTITY-2: `reservedFor(key)` is the artist ID for exactly the next authority of a pending authority-moving change. | `invariant_OnlyThePendingNextAuthorityIsReserved` | stagings, `execute`, `veto` |
| INV-ID-6 | SIGS-3: `artistIdOf(key)` is the artist ID for exactly the keys that have been the artist's authority, as in the model, which refuses any return to such a key. | `invariant_PastAuthoritiesResolveToTheArtist` | stagings, `execute` |
| INV-ID-7 | The authority resolves to the artist, and the standing snapshot holds at most 16 entries and no wallet twice. | `invariant_AuthorityAndStandingAreConsistent` | `refreshStanding`, `toggleConsolidation` |
| INV-ID-8 | The guardian's `stageOverride` and `stageChange` revert, used payloads and override acceptances never restage, `resolveContested` succeeds only for a live contest citing a latest outcome that differs from the pre-contest one (to uphold, after the 180-day notice), and `expireContest` only 365 days after the contest. | handler check: `guardianRedirect`, `replayLast`, `replayAcceptance`, `resolve`, `expire` | as named |
| INV-ID-9 | A refresh drops an established wallet only after 30 days missing and a pending one once its consolidation ends, marks missing exactly the established wallets no longer consolidated, stamps new entries with the source's `effectiveAt`, and records every consolidated key unless the snapshot is full. | handler check: `refreshStanding` | `refreshStanding`, `toggleConsolidation`, `warp` |
| INV-ID-10 | The `restrained` flag in the authority's storage word is set exactly while the pending change is an override that moves the authority, lapsed or not. | `invariant_RestrainedFlagMatchesThePendingChange` | as INV-ID-1 |

## Statements

[`StatementLog.invariant.t.sol`](../../test/records/StatementLog.invariant.t.sol), handler
[`StatementLogHandler`](../../test/records/StatementLogHandler.sol), which rebuilds each
subject's chain from the emitted events with [`StatementModel`](../../test/records/StatementModel.sol).
Real `StatementLog`; mock artist resolver, ERC-721 and ERC-1155. The AccessManager holds every
role the mocks know and must still never sign.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-DSP-1 | Every touched subject's stored count and head equal the chain rebuilt from the events. | `invariant_CountAndHeadMatchEmittedEvents` | every append |
| INV-DSP-2 | `latestDisputeOutcome` equals the subject's last DISPUTE_OUTCOME entry rebuilt from events, or zero if none. | `invariant_LatestDisputeOutcomeMatchesEvents` | `appendPlatform` |
| INV-DSP-3 | Every event is well formed, gapless and recomputable, and no replayed, tampered, expired or unauthorized append succeeds, even by the admin, curator, platform or log itself. | `invariant_NoMalformedEventsReplaysOrUnauthorisedWrites` | `replay`, `tamperedRelay`, `expiredRelay`, `unauthorized` |
| INV-DSP-4 | Only the artist (or its wallet) signs ARTIST entries and only the owner OWNER entries; DISPUTE_OUTCOME appears only under PLATFORM and CURATION_EVIDENCE only under CURATOR; the AccessManager signs only GOVERNANCE_MANIFEST entries about itself, as PLATFORM. | `invariant_RolesAreSpokenOnlyByTheirHoldersAndReservedKindsStayReserved` | `reservedKindMisuse`, `governanceMisuse`, `appendGovernanceManifest` |
| INV-DSP-5 | Every ARTIST entry, and no other, records the resolver active when it was written, across resolver swaps. | `invariant_ArtistEntriesBindTheActiveResolver` | `swapResolver`, `appendArtist` |
| INV-DSP-6 | A relayed entry is followed by exactly one nonce event naming its entry, signer and nonce, and a direct entry by none. | `invariant_RelayedEntriesCarryTheirNonce` | `appendRelayed`, `appendRelayedByWallet` |
| INV-DSP-7 | A used or revoked nonce stays spent. | `invariant_SpentNoncesStaySpent` | `revokeNonce`, relays |

## Entropy

[`VrfEntropyInvariant.t.sol`](../../test/entropy/VrfEntropyInvariant.t.sol), handler
`EntropyHandler` in the same file. Real `VrfEntropyModule`; mocks `MockVrfCoordinator` and
`MockPackageRegistry`. Items 0 to 3 are one package's VRF items, items 4 and 5 have seed
policies NONE and ARTIST, and items 6 and 7 are VRF revisions carrying the content of items 0
and 1.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ENT-1 | A request succeeds only for a VRF item of an approved package with unconsumed content, issues a new request only if the content's draw is neither delivered nor pending (a repeat only after `retryDelay`), else links the item to that draw and returns zero; a delivery for any issued request never reverts. | `invariant_EveryCallHadThePredictedOutcome` | `request`, `fulfill`, `setApproved`, `setConsumed` |
| INV-ENT-2 | At most one delivery fixes a content's seed, and `isDelivered` and `seedOf` match the model forever after. | `invariant_AtMostOneSeedPerItemAndItNeverChanges` | `fulfill` |
| INV-ENT-3 | `requestOf(item)` is the last request its content's draw issued until delivery, then zero, and an unlinked or non-VRF item never has one. | `invariant_TheCurrentRequestIsTheLastIssued` | `request`, `fulfill` |
| INV-ENT-4 | Items that share a content hash read one seed once both are linked and the draw is delivered. | `invariant_ItemsThatShareContentReadOneSeed` | `request`, `fulfill` |

## Governance

[`GovernanceInvariant.t.sol`](../../test/governance/GovernanceInvariant.t.sol), handler
`GovernanceHandler` in the same file. Real `GovernanceConfigurator` and `WorksAccessManager`;
mock `GovernedTargetMock`, plus a rogue stock `AccessManager` for hostile operations. Admins
schedule hostile operations next to benign guardian and admin rotations, a vigilant guardian
cancels each hostile one before time moves, and every warp runs `configurator.verify`.
Guardians suspend the fixed PLATFORM, CURATOR and STORAGE_OPERATOR keys (and try a
non-suspendable role), admins schedule 30-day grants that lift them, and admins try to cancel
revocations another account scheduled (Rule 3).

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-GV-1 | Hostile operations never change the target (authority, recipient, verifier, fee, admin calls) or grant the attacker a role; nothing executes early or through a wrapper; no account cancels its own role's revocation, and no admin another account's (Rule 3); benign rotations and lifts always execute; rotators' GUARDIAN, PAUSER and ADMIN membership equals the model; the hot admin keeps ADMIN; at least two guardians stay active. | `invariant_GovernanceStaysContained` | all except `guardianSuspends` |
| INV-GV-2 | After every warp the on-chain configuration reads back as the model's: the unsuspended fixed holders plus the active rotators. | handler check: `warp` (`configurator.verify(modelConfig())`) | as named |
| INV-GV-3 | No non-suspendable role is ever suspended; each fixed key's suspension equals the model (set by `suspend`, cleared by an executed 30-day lift); a suspended key fails `hasRole`, an unsuspended one passes; the CURATOR key's `canCall` on the target is immediate, with zero delay, exactly when unsuspended. | `invariant_SuspensionsStayContained` | `guardianSuspends`, `scheduleLift`, `executeBenign`, `warp` |
| INV-GV-4 | A guardian's suspension of an unsuspended fixed key succeeds; its attempt on a non-suspendable role (ADMIN on the hot admin, another role on a guardian) never does. | handler check: `guardianSuspends` (`fail_on_revert`; `nonSuspendableSuspended` checked by INV-GV-3) | as named |

## Properties tested by fuzz and unit tests

Properties with no campaign of their own, or tested more directly outside one: by fuzz tests
(`testFuzz_*`, 256 runs) or unit tests (`test_*`).

### Value conservation and money maths

| ID | Property | Test |
| --- | --- | --- |
| PROP-ECO-1 | For 1 to 64 payees whose shares sum to 100,000, entitlements never exceed what the wallet observed and unpaid dust is at most the payee count minus one. | [`SplitMath.t.sol`](../../test/economics/SplitMath.t.sol) `testFuzz_EntitlementsNeverExceedObservedAndDustIsBounded` |
| PROP-ECO-2 | The entitlement equals a full-width `mulDiv(observed, share, 100,000)` for every `observed` up to `type(uint256).max` and is monotonic in `observed`. | `SplitMath.t.sol` `testFuzz_EntitlementMatchesMulDivOverTheFullRange`, `testFuzz_EntitlementIsMonotonic` |
| PROP-ECO-3 | Release timing and order do not change payees' totals, and released plus balance equals everything received. | `SplitMath.t.sol` `testFuzz_ReleaseTimingDoesNotChangeTotals` |
| PROP-ECO-4 | The factory accepts exactly the canonical payee lists. | `SplitMath.t.sol` `testFuzz_ValidationAcceptsExactlyCanonicalLists` |
| PROP-ECO-5 | Escrow credits and flushes conserve value: credits sum to `totalOwed`, which equals the escrow's balance. | [`RevenueEscrow.t.sol`](../../test/economics/RevenueEscrow.t.sol) `testFuzz_CreditsAndFlushesConserve` |
| PROP-ECO-6 | Every payment reaches the wallet or becomes its escrow credit. | [`RevenuePayment.t.sol`](../../test/economics/RevenuePayment.t.sol) `testFuzz_PaymentsAlwaysReachTheWalletOrItsCredit` |
| PROP-ECO-7 | Signed partial releases never exceed the entitlement. | [`ReleaseVerifier.t.sol`](../../test/economics/ReleaseVerifier.t.sol) `testFuzz_SignedPartialReleasesNeverExceedEntitlement` |
| PROP-ECO-8 | The royalty wallet's shares add up to 100,000. | [`EconomicsResolver.t.sol`](../../test/economics/EconomicsResolver.t.sol) `testFuzz_RoyaltySplitSharesAddUp` |
| PROP-ECO-9 | A predicted wallet address equals the deployed one. | [`SplitFactory.t.sol`](../../test/economics/SplitFactory.t.sol) `testFuzz_PredictionMatchesDeployment` |
| PROP-AUC-1 | A settlement splits the price exactly between seller and network, with the fee the `mulDiv` floor, the bid step the `mulDiv` ceiling, and the increment the larger of the share and the floor. | [`EnglishAuction.t.sol`](../../test/sales/auction/EnglishAuction.t.sol) `testFuzz_Settle_SplitsExactly`, `testFuzz_Bid_IncrementIsMaxOfShareAndFloor`; [`EnglishAuctionFollowUp.t.sol`](../../test/sales/auction/EnglishAuctionFollowUp.t.sol) `testFuzz_FeeMatchesMulDivFloor`, `testFuzz_StepMatchesMulDivCeil` |
| PROP-SAL-1 | The Dutch price never rises over time, stays within its bounds and rounds toward the seller. | [`DutchPricing.t.sol`](../../test/sales/dutch/DutchPricing.t.sol) `testFuzz_PriceNeverRisesOverTime`, `testFuzz_PriceStaysWithinItsBounds`, `testFuzz_LinearRoundsTowardTheSeller` |
| PROP-SAL-2 | A public phase's wallet cap is never exceeded. | [`FixedPriceSale.t.sol`](../../test/sales/fixed/FixedPriceSale.t.sol) `testFuzz_PublicWalletCapIsNeverExceeded` |
| PROP-STR-1 | The royalty receiver is the factory's wallet, the amount matches `mulDiv`, and `royaltyInfo` never returns zero for lack of gas. | [`Stream.t.sol`](../../test/stream/Stream.t.sol) `testFuzz_royaltyInfo_isTheFactoryWallet`, `testFuzz_royaltyInfo_matchesMulDiv`, `testFuzz_royaltyInfo_neverZeroForLackOfGas` |

### Single use, uniqueness and authorization

| ID | Property | Test |
| --- | --- | --- |
| PROP-CUR-1 | An item consumes once, even across packages that list it, uniqueness keys on the declared content hash, and an item outside the package is refused. | [`PackageRegistry.t.sol`](../../test/curation/PackageRegistry.t.sol) `test_consume_revertsDoubleConsume`, `test_consume_itemIsSingleUseAcrossPackages`, `test_consume_contentUniquenessKeysOnContentHash`, `test_consume_revertsItemNotInPackage` |
| PROP-CUR-2 | Merkle proofs verify, a foreign item is rejected, and revoking one move nonce leaves the others untouched. | `PackageRegistry.t.sol` `testFuzz_merkle_proofs`, `testFuzz_merkle_foreignItemRejected`, `testFuzz_revokeMove_bitmapIsolation` |
| PROP-CUR-3 | Only active signers' attestations count, and arbitrary signature bytes are never approved. | [`Eip712CurationVerifier.t.sol`](../../test/curation/Eip712CurationVerifier.t.sol) `testFuzz_isApproved_onlyActiveSignersCount`, `testFuzz_isApproved_neverRevertsOnGarbage` |
| PROP-ED-1 | An edition never mints beyond its size, and `createEdition` refuses a tampered item. | [`Editions.t.sol`](../../test/editions/Editions.t.sol) `testFuzz_Mint_NeverExceedsSize`, `testFuzz_CreateEdition_RefusesTamperedItem` |
| PROP-ENT-1 | The first of many deliveries wins, only the coordinator delivers, an unissued request ID never delivers, and non-VRF items and items outside an approved package are always refused. | [`VrfEntropyFuzz.t.sol`](../../test/entropy/VrfEntropyFuzz.t.sol) `testFuzz_TheFirstDeliveryOfManyRequestsWins`, `testFuzz_OnlyTheCoordinatorMayFulfill`, `testFuzz_UnissuedRequestIdsNeverDeliver`, `testFuzz_NonVrfItemsAreAlwaysRefused`, `testFuzz_OnlyItemsOfAnApprovedPackageCanBeRequested` |
| PROP-GV-1 | Nobody cancels the operation that revokes their own role. | [`GuardianCancel.t.sol`](../../test/governance/GuardianCancel.t.sol) `testFuzz_NobodyCancelsTheirOwnRevocation` |
| PROP-GV-2 | A raise-only parameter moves by at most 2× per step and never above its ceiling, for any sequence of raises. | [`BoundedParameter.t.sol`](../../test/governance/BoundedParameter.t.sol) `testFuzz_RaiseMatchesSpecification`, `testFuzz_RaiseSequenceStaysBounded` |
| PROP-GV-3 | Only genesis selectors pass wiring validation. | [`GenesisWiring.t.sol`](../../test/governance/GenesisWiring.t.sol) `testFuzz_OnlyGenesisSelectorsPassValidation` |
| PROP-GV-4 | For any role, victim and canceller (guardians, cold admin, keeper, key holder), another account's revocation is cancelled exactly when the canceller is a guardian and not the victim (Rules 2 and 3). | [`GuardianCancel.t.sol`](../../test/governance/GuardianCancel.t.sol) `testFuzz_OnlyGuardiansCancelAnotherAccountsRevocation` |
| PROP-GV-5 | `suspend` refuses with `RoleNotSuspendable` every role ID from 0 to 13 (`Roles.COUNT`, one past the last role) except PLATFORM, CURATOR and STORAGE_OPERATOR (`test_SuspendableRolesAreTheZeroDelayOperationalKeys` also checks `PUBLIC`). | [`Suspension.t.sol`](../../test/governance/Suspension.t.sol) `testFuzz_OnlyOperationalRolesCanBeSuspended` |
| PROP-GV-6 | A suspension takes effect in the same block on `hasRole`, `canCall` and the target, keeping the record and other roles; only guardians suspend; a suspended pending holder never activates; only an ADMIN grant (guardian-vetoable), a revocation or the holder's renounce lifts it; readback rejects a suspended holder. | `Suspension.t.sol` `test_AGuardianSuspendsAKeyInTheSameBlock`, `test_OnlyGuardiansSuspend`, `test_APendingGrantCanBeSuspended`, `test_OnlyAnAdminGrantLiftsItAndAGuardianCanVetoThat`, `test_ARevocationClearsItAndTheKeyCanRenounce`, `test_ReadbackRejectsASuspendedHolder` |
| PROP-GV-7 | On the genesis deployment, a suspended PLATFORM key fails every PLATFORM path (manual checks included) while the creator's stays open, a dishonest guardian's suspension lasts 60 days (in force at day 59, lifted at 60), the cold admin removes a hot admin and a guardian acting together in two 30-day rounds, and demotions by grant stay cancellable by the demoted account. | [`GovernanceRecovery.t.sol`](../../test/integration/GovernanceRecovery.t.sol) `test_GOV2_AGuardianSuspendsThePlatformKeyAtOnce`, `test_GOV2_ADishonestGuardiansSuspensionLastsAboutSixtyDays`, `test_GOV1_ColdAdminRemovesAHotAdminAndAGuardianActingTogether`, `test_GOV1_DemotionsByGrantStayCancellable` |
| PROP-ID-1 | A change never executes before its delay, a contested override's uphold window is always open, and the adapter's "established" answer matches a model. | [`ArtistRegistry.t.sol`](../../test/identity/ArtistRegistry.t.sol) `testFuzz_ExecuteChange_RespectsTheDelay`; [`ContestedOverrides.t.sol`](../../test/identity/ContestedOverrides.t.sol) `testFuzz_L3_UpholdWindowAlwaysOpen`; [`ConsolidationAdapter.t.sol`](../../test/identity/ConsolidationAdapter.t.sol) `testFuzz_IsEstablished_MatchesModel` |
| PROP-DSP-1 | Any append sequence matches the model, relays round-trip and never replay, and the nonce bitmap tracks exactly the spent nonces. | [`StatementLog.t.sol`](../../test/records/StatementLog.t.sol) `testFuzz_SequenceMatchesModel`, `testFuzz_RelayRoundTripAndReplay`, `testFuzz_NonceBitmapTracksExactlyTheSpentNonces` |
| PROP-HASH-1 | The item hash binds the collection and the shares and does not depend on the chain. | [`WorksHashing.t.sol`](../../test/interfaces/WorksHashing.t.sol) `testFuzz_itemHash_bindsCollection`, `testFuzz_itemHash_bindsShares`, `testFuzz_itemHash_independentOfChain` |

### Content and rendering

| ID | Property | Test |
| --- | --- | --- |
| PROP-CNT-1 | Stored files round-trip, and ranged reads match a reference. | [`ContentStore.t.sol`](../../test/content/ContentStore.t.sol) `testFuzz_RoundTrip`, `testFuzz_Read_MatchesReference` |
| PROP-CNT-2 | The base64 attestation agrees with an oracle on arbitrary bytes and on one injected byte. | [`Base64Attest.t.sol`](../../test/content/Base64Attest.t.sol) `testFuzz_ArbitraryBytesMatchTheOracle`, `testFuzz_Attest_OneInjectedByteMatchesTheOracle` |
| PROP-RND-1 | The JSON scanner agrees with `serde_json`, every accepted record yields JSON every parser reads, and escaping is correct for any valid text, with inert output. | [`JsonScan.t.sol`](../../test/content/renderer/JsonScan.t.sol) `testFuzz_AgreesWithSerdeJson`; [`RendererReview.t.sol`](../../test/content/renderer/RendererReview.t.sol) `testFuzz_M4_AcceptedRecordsGiveJsonEveryParserReads`; [`Renderer.t.sol`](../../test/content/renderer/Renderer.t.sol) `testFuzz_Escaping_AnyValidText`; [`JsonEscape.t.sol`](../../test/libraries/JsonEscape.t.sol) `testFuzz_EscapedOutputIsInert` |

### Gas, state growth and the transaction cap

Figures: [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table). Rules:
[Build, test and budgets](build-and-test.md#gas-and-state-growth-rules).

| ID | Property | Test |
| --- | --- | --- |
| PROP-GAS-1 | A steady-state ETH `start` and `startWithBid`, for one and two parties, a VRF work and an edition master, cost at most 350K Prague gas (`START_BUDGET` in [`IntegrationBase.sol`](../../test/integration/IntegrationBase.sol)). | [`GasReport.t.sol`](../../test/integration/GasReport.t.sol) `test_Gas_Start_SteadyState`, `test_Gas_StartWithBid_SteadyState`, `test_Gas_Start_TwoPartyWork`, `test_Gas_StartWithBid_TwoPartyWork`, `test_Gas_Start_VrfWork`, `test_Gas_Start_EditionMaster` |
| PROP-GAS-2 | Every measured operation creates exactly its stated number of new storage slots and accounts, at most 6 slots for a steady-state `start` and 7 for `startWithBid` (`START_MAX_SLOTS`, `START_WITH_BID_MAX_SLOTS`), the same for an artist's first start; on a collision of its terms' hashed position, a first start writes one slot more (LIM-GAS-10). | every `test_Gas_*` in `GasReport.t.sol`; [`StreamTermsGrind.t.sol`](../../test/stream/StreamTermsGrind.t.sol) `test_GroundCollisionAddsOneSlotToTheFirstStart` |
| PROP-GAS-3 | Every other measured operation stays under its Prague test ceiling or regression ceiling. | every `test_Gas_*` in `GasReport.t.sol` |
| PROP-GAS-4 | The harness's cold-account correction is exact (a `start` from a fully cold state equals the corrected figure after warming every account), adds nothing for accounts already cold, and refuses storage it does not cool. | [`GasHarness.t.sol`](../../test/integration/GasHarness.t.sol) `test_TheColdAccountCorrectionIsExact`, `test_NothingIsAddedForAccountsAlreadyCold`, `test_RequireCooledRefusesStorageItDoesNotCool` |
| PROP-GAS-5 | The state-growth counter counts a slot once, ignores overwrites, zero-to-zero, reverted writes, out-of-gas and `INVALID` frames and transient storage, and counts `CREATE` and ETH sent to a fresh account or an empty precompile as new accounts. | [`StateGrowth.t.sol`](../../test/helpers/StateGrowth.t.sol) (24 tests) |
| PROP-GAS-6 | With every record, media and locator cap filled on the real stack, Stream's `tokenURI` and Editions' `uri` cost at most 8M Prague gas (`TOKEN_URI_BUDGET`) and create no state. | [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol) `test_Budget_*`; `GasReport.t.sol` `test_Gas_TokenURIBySize`; [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol) `RendererGasTest`, `RendererGasBudgetTest` |
| PROP-GAS-7 | Worst-case bounded inputs fit the EIP-7825 cap of 16,777,216 gas in Prague gas, intrinsic and calldata included: claim batches and the largest split wallet; mint, `openRecord`, relicense with 16 consents, the longest locator, the preferred-locator scan and `syncOnChain`; `consume` and `registerPackage`; `createEdition`; `openSale` and purchases; settlement with every fallback; `stageChange`, `stageOverride` and `refreshStanding` (under half the cap); manifest registration and attestation at `MAX_CHUNKS`; genesis `configure`. | [`GasCap.t.sol`](../../test/economics/GasCap.t.sol), [`StreamTxCap.t.sol`](../../test/stream/StreamTxCap.t.sol), [`PackageRegistryGas.t.sol`](../../test/curation/PackageRegistryGas.t.sol), `Editions.t.sol` `test_Gas_CreateEditionWorstCaseFitsTxCap`, [`FixedPriceGasCap.t.sol`](../../test/sales/fixed/FixedPriceGasCap.t.sol), [`DutchGasCap.t.sol`](../../test/sales/dutch/DutchGasCap.t.sol), [`EnglishAuctionGas.t.sol`](../../test/sales/auction/EnglishAuctionGas.t.sol) `test_SettleGas_FitsTheTransactionCap`, [`EnglishAuctionHostile.t.sol`](../../test/sales/auction/EnglishAuctionHostile.t.sol) `test_SettleWorstCaseFitsTheFusakaCap`, [`ArtistRegistryReview.t.sol`](../../test/identity/ArtistRegistryReview.t.sol) `test_WorstCase_*`, `ContentStore.t.sol` `test_RegisterManifest_AtMaxChunksFitsTheTransactionGasCap`, `Base64Attest.t.sol` `test_Attest_AtMaxChunksEveryCallFitsTheTransactionGasCap`, [`Genesis.t.sol`](../../test/integration/Genesis.t.sol) `test_GenesisConfigureFitsTheTransactionCap`, [`GenesisConfig.t.sol`](../../test/governance/GenesisConfig.t.sol) `test_MaximumWiringFitsTheTransactionGasCap` |
| PROP-GAS-8 | The VRF callback creates no storage slot and, repriced as ADR 0004 models Glamsterdam, uses at most half of `MIN_CALLBACK_GAS` (100,000). | [`VrfEntropyModule.t.sol`](../../test/entropy/VrfEntropyModule.t.sol) `test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam` |

## Gaps

What no stateful campaign covers yet. Suites on the real, wired stack are being added in
[PR #62](https://github.com/6529-Collections/6529-works/pull/62); coverage, mutation testing
and Halmos proofs are in [Testing](../testing/README.md).

- **The real escrow under fixed-price and Dutch sales.** Those campaigns use
  `MockRevenueEscrow`, so INV-SAL-2, INV-SAL-3, INV-SAL-7 and INV-SAL-8 check the mock's side
  (the real `ClaimRouter` and `RevenueEscrow` run in the economics and auction campaigns).
- **`AssetAllowlist`** runs for real only in the auction halts campaign; **`EconomicsResolver`**
  is always mocked.
- **Sale halts.** The fixed-price and Dutch campaigns never pause, deprecate a currency or
  reopen a sale; the halt clock (`scheduleDelay`) and overlapping halts have unit tests only
  ([`SalesFollowUpRegression.t.sol`](../../test/adv/SalesFollowUpRegression.t.sol),
  [`Market1Regression.t.sol`](../../test/adv/Market1Regression.t.sol)).
- **`WorkRecords`** runs only inside the Stream campaign, which never drives `relicense`,
  `repinRenderer`, `syncOnChain` or the preferred-location settings.
- **`ContentStore`, `DependencyRegistry` and `Renderer`**: fuzz and unit tests only
  (PROP-CNT-1, PROP-CNT-2, PROP-RND-1).
- **Curation signer changes**: the campaign never disables, re-enables or swaps an
  `Eip712CurationVerifier` signer.
- **`ConsolidationAdapter`** runs only over a mock delegation contract; its model is a fuzz
  test (PROP-ID-1).
- **Suspension** is campaigned on a mock target, with `canCall` for CURATOR only and lifts by
  grant only; the manual PLATFORM and CURATOR paths, lifts by revocation or renounce, and the
  dishonest-guardian timeline are unit and integration tests (PROP-GV-6, PROP-GV-7).
- **Deployment and readback guards** (`DeployGuards`, `Verify.s.sol`): unit tests only, in
  [`DeployScript.t.sol`](../../test/deploy/DeployScript.t.sol).
- **The fully wired system.** Every campaign mocks its neighbors; properties that span
  contracts (an atomic `start`, value conservation through a real Editions mint) are covered
  by the scenario tests in
  [`test/integration/`](../../test/integration/README.md).

## Differences from the ADRs

See the [register](../spec/README.md#differences-from-the-adrs).

## References

- Code: [`foundry.toml`](../../foundry.toml), [`src/`](../../src/)
- ADRs: [ADR 0001](../adr/0001-v1-scope.md#test-plan), [ADR 0002](../adr/0002-access-manager-hardening.md#test-plan),
  [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#consequences)
- Tests: every file linked above; [`test/integration/README.md`](../../test/integration/README.md)
- Related pages: [Build, test and budgets](build-and-test.md),
  [Known limitations and accepted risks](known-limitations.md), [Threat model](threat-model.md),
  [Scope](scope.md), the [spec](../spec/README.md)
