# Invariants

This page lists every protocol invariant the test suite checks, for auditors who want to know
what is tested, under which campaign settings, and against which real or mocked contracts. It
covers the stateful invariant campaigns (an `invariant_*` function over a handler), the checks
the handlers make inside each action, and the most important properties that fuzz and unit
tests check instead. Each statement is taken from the assertion, not from the test's name. The
[Gaps](#gaps) section lists what no campaign covers yet.

> Pre-audit. See the [project status](../../README.md#status).

## Campaign settings

Every campaign runs with the settings in [`foundry.toml`](../../foundry.toml):

| Setting | Value | Source |
| --- | --- | --- |
| `[profile.default.invariant] runs` | 256 | `foundry.toml` |
| `[profile.default.invariant] depth` | 128 calls per run | `foundry.toml` |
| `[profile.default.invariant] fail_on_revert` | `true` | `foundry.toml` |
| `[profile.default.invariant] show_metrics` | `true` | `foundry.toml` |
| `[profile.default.fuzz] runs` | 256 | `foundry.toml` |
| Per-test overrides | none: no `/// forge-config:` comment exists under `test/` | `grep -rn "forge-config" test/` |

- **The rule.** Every contract that moves money gets stateful invariants of at least 256 runs
  of depth 128 ([AGENTS.md](../../AGENTS.md), [ADR 0001](../adr/0001-v1-scope.md#intended-behavior)).
- **`fail_on_revert` is on.** A handler action that reverts fails the campaign. Handlers are
  therefore written so that every action either succeeds or is skipped, and an action that
  must revert is checked inside the handler with `try`/`catch` or `vm.expectRevert`. That
  makes every assertion inside a handler part of the campaign: a wrong prediction reverts the
  handler and fails the run. This page lists those as **handler checks**.
- **Non-vacuity.** Several suites replay campaign-shaped sequences and assert that every path
  the invariants rely on really executes:
  `test_HandlerReachesEveryPath` (economics, Dutch, fixed price),
  `AuctionHandlerCoverage.test_EveryPathRuns`, `AuctionHaltsCoverage.test_HaltPathsRun` and
  `ArtistRegistryInvariantTest.test_HandlerReachesContestResolveAndLapse`.
- **After-campaign checks.** The two auction suites define `afterInvariant`, which drives every
  sale to an end after each run and checks that nothing is stuck.
- **Running them.** `forge test --match-contract Invariant` runs every campaign. The commands
  and the CI jobs are on [Build, test and budgets](build-and-test.md).

### Kinds used in the tables

| Kind | Meaning |
| --- | --- |
| stateful invariant | An `invariant_*` function, checked after every call of every run. |
| handler check | An assertion or expected revert inside a handler action; a failure fails the campaign through `fail_on_revert`. |
| after-campaign | An `afterInvariant` hook, checked at the end of every run. |
| fuzz | A `testFuzz_*` function (256 runs). |
| unit | A `test_*` function. |

## Stream and work records

[`test/stream/StreamInvariant.t.sol`](../../test/stream/StreamInvariant.t.sol), handler
[`StreamHandler`](../../test/stream/StreamHandler.sol). Real `Stream`, `WorkRecords` and
`SplitFactory`; the sale adapter (`MockSaleAdapter`), the economics resolver (`MockEconomics`)
and two renderers (`MockRenderer`) are mocks. 40 items in three collections.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-STR-1 | `totalMinted` equals the number of successful mints, `totalSupply` equals minted minus burned, and the balances of the adapter and every actor sum to `totalSupply`. | stateful invariant | `invariant_supplyIsMintedMinusBurned` | `mint`, `burn`, `deliver`, `transfer` |
| INV-STR-2 | Each mint receives ID `totalMinted + 1`, `totalMinted` never decreases, `ownerOf` of a burned ID reverts with `ERC721NonexistentToken`, and `work(totalMinted + 1)` reverts with `UnknownWork`. | stateful invariant | `invariant_idsMonotonicAndNeverReused` | `mint`, `burn` |
| INV-STR-3 | For every live token, the `royaltyInfo` receiver, `work().royaltyReceiver` and `work().seller` equal what the handler derived independently from the mint's payees and fee terms with the real split factory, the rate equals the last consented and governed rate, and `royaltyInfo(id, 1 ether)` pays `rate × 1 ether / 100,000`. | stateful invariant | `invariant_royaltyTermsLocked` | `mint` (random fee terms), `changeRoyalty` |
| INV-STR-4 | A royalty-rate change by governance alone, without the parties' consent, reverts; a replayed consent bundle never changes the work's state hash. | handler check (counted in `violations`, asserted by INV-STR-2 and INV-STR-3) | `forceRoyalty`, `replayRoyalty` | `forceRoyalty`, `replayRoyalty` |
| INV-STR-5 | Each collection's `minted` count equals the number of mints into it and never drops on a burn; each live work's collection and serial equal the model (1, 2, 3, ... in mint order per collection). | stateful invariant | `invariant_serialsPerCollection` | `mint`, `burn` |
| INV-STR-6 | `primarySaleSettled(id)` is true exactly for live tokens the minting adapter marked; `markPrimarySettled` by any other account reverts. | stateful invariant and handler check | `invariant_primarySaleSettledOnlyByMintingAdapter`, `forgeSettle` | `settle`, `forgeSettle` |
| INV-STR-7 | Once its primary sale is marked settled, a token cannot be burned by the minting adapter. | handler check (`violations`) | `burn` | `burn` |
| INV-STR-8 | A finalized work keeps its record file ID and renderer pin, `rendererOf` returns the pin, and `setRecord` or `finalize` on a finalized work reverts. | stateful invariant and handler check | `invariant_finalizedRecordsImmutable`, `attackFinalized` | `openRecord`, `setRecord`, `finalize`, `attackFinalized`, `swapRenderer`, `addLocator` |

## 6529 Editions

[`test/editions/Editions.invariant.t.sol`](../../test/editions/Editions.invariant.t.sol),
handler [`EditionsHandler`](../../test/editions/EditionsHandler.sol). Real `Editions`; Stream,
the package registry, economics, the artist registry, work records, the renderer and both
sale adapters (`EditionsAdapterMock`) are mocks. Three editions: a FIXED edition of 20 sold at
fixed price, an uncapped OPEN edition with a one-day Dutch window, and an OPEN edition of 30
with a 12-hour fixed-price window.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-ED-1 | Every mint attempt had the outcome the edition's terms predict: accepted only within the size, inside an OPEN window that starts at the first mint, through an adapter of the matching sale kind (`SaleKindMismatch` otherwise) and admitted as a minter (`NotAdmittedMinter` otherwise). No copy is minted at or after a window's end or beyond the size. | stateful invariant | `invariant_MintsFollowEditionTerms` | `buy`, `buyWithWrongAdapter`, `mintAsOutsider`, `warp` |
| INV-ED-2 | `edition(id).minted` equals every copy ever minted, never exceeds a nonzero size, and the holders' balances sum to minted minus burned. | stateful invariant | `invariant_SupplyAccounting` | `buy`, `burnFromCustody`, `transfer` |
| INV-ED-3 | An OPEN edition's `windowStart` is the time of its first mint and never moves; a FIXED edition's is zero. | stateful invariant | `invariant_WindowStartsOnce` | `buy`, `warp` |
| INV-ED-4 | The link never changes in either direction (`masterOf` returns Stream, the master ID and the content hash; `Stream.editionOf` returns Editions and the edition ID), and `royaltyInfo` returns the same receiver and amount, through repeated `createEdition` calls and secondary sales of the master. No handler action changes the rate. | stateful invariant | `invariant_LinkAndRoyaltyFixed` | `recreate`, `moveMaster` |

## Curation

[`test/curation/PackageRegistryInvariant.t.sol`](../../test/curation/PackageRegistryInvariant.t.sol),
handler `CurationHandler` in the same file. Real `PackageRegistry` and
`Eip712CurationVerifier`; the artist registry is `MockArtistRegistry`. Twenty items by three
artists: items 0 to 9 form package A, 6 to 15 package B (6 to 9 are in both), 16 to 19 are in
no package, items `i` and `i + 8` declare the same content hash, and a third root C starts
unregistered. The handler is an exact model: it predicts every call's outcome before making it.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-CUR-1 | No call the model forbids succeeds: a revoked or unregistered root, a foreign or wrong proof, a stale key, a spent or revoked move nonce, an expired move, used or released content, an unbound caller, or a second binding. | stateful invariant | `invariant_noUnexpectedSuccess` | all nine |
| INV-CUR-2 | Every call the model allows succeeds, so the model is exact. | stateful invariant | `invariant_noUnexpectedFailure` | all nine |
| INV-CUR-3 | Each item is consumed at most once, `isReleased` matches the model, and an item in no package is never consumed. | stateful invariant | `invariant_itemConsumedAtMostOnce` | `consume`, `release` |
| INV-CUR-4 | For each content hash, `consumedItemOf` and `editionClaimOf` equal the model's single live Stream item and edition claim. | stateful invariant | `invariant_contentRecordsMatch` | `consume`, `claimEdition`, `release` |
| INV-CUR-5 | The only reuse across products is the linked pair: an edition claims only a content hash Stream consumed, naming the item that consumed it, and claims never outnumber consumptions. | stateful invariant | `invariant_editionsReuseOnlyTheirMaster` | `claimEdition` |
| INV-CUR-6 | Every artist's move-nonce flags (31 per artist) and every root's status equal the model. | stateful invariant | `invariant_noncesAndStatuses` | `revokeMove`, `rotate`, `revokePackage`, `registerLate`, `acceptLate` |

The nine actions are `consume`, `claimEdition`, `release`, `revokeMove`, `rotate`,
`revokePackage`, `registerLate`, `acceptLate` and `rebind`. No dedicated invariant covers the
single use of a package's registration; the model's exactness (INV-CUR-1, INV-CUR-6) tests it.

## Economics

[`test/economics/invariant/EconomicsInvariant.t.sol`](../../test/economics/invariant/EconomicsInvariant.t.sol),
handler [`EconomicsHandler`](../../test/economics/invariant/EconomicsHandler.sol). Real
`SplitFactory`, `SplitWallet` (three payee configurations, each deployed at two salts so a
replacement exists), `ReleaseVerifier`, `RevenueEscrow`, `ClaimRouter` and OpenZeppelin
`AccessManager`; payments go through `RevenuePayment` in a `PaymentHarness`; the artist payout
resolver is `MockArtistResolver`. Assets: ETH, a USDC-style blocklist token, a fee-on-transfer
token whose fee is toggled, and a rebasing token whose index moves. The handler predicts each
outcome from its own ghost state, never from `releasable`, and records released amounts from
measured balance deltas.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-ECO-1 | Per wallet and asset, the per-payee releases sum to `totalReleased`, and (outside the rebasing token) `totalReleased` plus the balance equals everything the wallet received. | stateful invariant | `invariant_WalletConservesValue` | `release`, `releaseTo`, `releaseSigned`, `claimBatch`, `pay`, `receiveDirect`, `flush` |
| INV-ECO-2 | Each payee's `released` equals what its recipients measurably received, and never exceeds `floor(receipts × share / 100,000)` at the receipts the last release saw: the wallet's recorded mark for an ERC-20, the model's mark for ETH. | stateful invariant | `invariant_ReleasedWithinEntitlement` | release actions |
| INV-ECO-3 | Across all wallets, total released per asset equals what recipients measurably received, and (outside the rebasing token) the actors hold exactly that. | stateful invariant | `invariant_RecipientsReceivedEverythingReleased` | release actions |
| INV-ECO-4 | Each wallet's recorded receipts for an ERC-20 equal the model's high-water mark, so they never decrease, and (outside the rebasing token) never exceed live receipts. ETH records no mark, and live ETH receipts never fall below the model's mark. | stateful invariant | `invariant_ObservedNeverDecreases` | `rebaseTo`, `toggleFee`, release actions |
| INV-ECO-5 | Unreleasable dust in a wallet is at most the number of payees minus one, per asset (ETH, the blocklist token and the fee token). | stateful invariant | `invariant_DustIsBounded` | all |
| INV-ECO-6 | Every escrow credit equals the model, the credits sum to `totalOwed` per asset, and the escrow's balance is at least `totalOwed`. | stateful invariant | `invariant_EscrowIsSolventAndMatchesTheModel` | `pay`, `deposit`, `flush`, `recover`, `consentToggle` |
| INV-ECO-7 | The claim router never holds funds; the payer holds no ETH, no allowance to the escrow, and only the tokens of payments the model expected to revert. | stateful invariant | `invariant_IntermediariesHoldNothing` | `claimBatch`, `pay` |
| INV-ECO-8 | Every release, signed release, batch item, payment, deposit, flush and recovery reverts with exactly the error data the model predicts, or succeeds with exactly the predicted amount. | handler check | every action | all |
| INV-ECO-9 | A replayed signed release always fails: with `NonceAlreadyUsed`, or with `NotPayoutAddress` once the artist's payout changed. | handler check | `replaySigned` | `releaseSigned`, `revokeNonce`, `setArtistPayout` |
| INV-ECO-10 | Governed escrow recovery moves a split wallet's credit only to its equivalent replacement (same payees, another salt), and a non-wallet account's credit only to the replacement that account consented to; the recovery consumes the consent. | handler check | `recover`, `consentToggle` | `recover`, `consentToggle` |
| INV-ECO-11 | A claim batch pays each item exactly its predicted amount, and the recipients' balances rise by exactly the batch's total. | handler check | `claimBatch` | `claimBatch` |

## English auction

Two suites, each run once in ETH and once in an ERC-20 that blocks the seller wallet (so
ERC-20 seller payouts take the escrow route). In both, the network wallet refuses ETH, so ETH
fee payouts take the escrow route too. Real `EnglishAuction`, `AssetAllowlist`,
`RevenueEscrow` and `StatementLog`; the token is `MockMintTarget` (not Stream), and Permit2 is
`MockPermit2`.
- [`AuctionInvariant.t.sol`](../../test/sales/auction/invariant/AuctionInvariant.t.sol)
  (`AuctionInvariantEth`, `AuctionInvariantErc20`), handler
  [`AuctionHandler`](../../test/sales/auction/invariant/AuctionHandler.sol): starts and
  start-with-bids, bids by honest and hostile bidders (direct, EIP-2612 and relayed Permit2),
  dispute pauses, withdrawals, upheld cancellations, resumptions, settlements, claims, delivery
  claims, the start pause and governance changes.
- [`AuctionHaltsInvariant.t.sol`](../../test/sales/auction/invariant/AuctionHaltsInvariant.t.sol)
  (`AuctionHaltsInvariantEth`, `AuctionHaltsInvariantErc20`), handler
  [`AuctionHaltsHandler`](../../test/sales/auction/invariant/AuctionHaltsHandler.sol): the same,
  plus currency deprecation and re-admission (MARKET-2), a token that blocks the auction itself
  (MONEY-1 credits) and `claimFor`.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-AUC-1 | The auction's balance equals the live high bids (sales neither settled nor cancelled, with a bidder) plus every actor's claimable credit. In the halts suite the credits include the seller's and network's payout credits, and the balance is checked both `>=` and `==` that sum. | stateful invariant | `invariant_HeldEqualsLiveBidsPlusCredits`, `invariant_BalanceCoversOwed` | all |
| INV-AUC-2 | Every unit deposited as a bid is held by the auction, paid to the seller or network wallet, credited to one of them in the escrow, or claimed. | stateful invariant | `invariant_ValueIsConserved` (both suites) | all |
| INV-AUC-3 | Each sale has at most one outcome, a settlement or a cancellation. A cancelled sale's token is burned and it has no bidder; a settled sale holds its token only while a delivery is pending (and, in the base suite, is marked primary-settled); an open sale holds its token. | stateful invariant | `invariant_OneOutcomeAndExactCustody`, `invariant_ExactCustody` | `settle`, `cancel`, `claimDelivery` |
| INV-AUC-4 | Each sale keeps its locked currency, token and token ID and the increment floor its first bid locked (kept after a withdrawal). A live sale names the recipient of its live high bid, and `minimumBid` follows the locked terms: with no bidder, `max(openingBid, the withdrawn bid kept as reserve, 1)`; otherwise the bid plus `max(ceil(bid × share / 100,000), floor)`. | stateful invariant | `invariant_LockedTermsAndRecipients` | `bid`, `withdrawBid`, `govern` |
| INV-AUC-5 | Every sale, settled and cancelled ones included, keeps in storage the opening bid, increment share and anti-snipe window it locked at start, and the floor its first bid locked, whatever governance changed since. The test reads the storage directly and cross-checks the layout against the public view. | stateful invariant | `invariant_StoredTermsMatchWhatEachSaleLocked` | `govern` |
| INV-AUC-6 | After 30 days, settling every sale and claiming every delivery and credit leaves the auction with no funds and no token, and every deposit accounted for. | after-campaign | `AuctionInvariantBase.afterInvariant` | all |
| INV-AUC-7 | Settlement is eventually possible: once the token stops blocking the auction and the currency is re-admitted, every sale ends settled or cancelled, and the auction holds no funds and no token. | after-campaign | `AuctionHaltsInvariantBase.afterInvariant` | `drain` |
| INV-AUC-8 | A bid extends the end to at least `now + the locked window`. A settlement delivers the token to (or leaves it pending for) the recipient the high bid named, or the artist with no bid. A second dispute pause of the same sale reverts with `PauseExhausted`; a withdrawal leaves the sale paused; `resume` and `unpause` earlier than 48 hours (`Roles.STANDARD`) after the pause revert with `UnpauseTooEarly` (review finding GOV-5). | handler check | `bid`, `settle`, `pause`, `pauseAndWithdraw`, `resume`, `toggleStartPause` | as named |
| INV-AUC-9 | A sale that has not ended refuses `settle`. While its currency is deprecated, nothing settles for 30 days; then `settle` credits the standing bid back to its bidder and gives the work to its artist. A re-admission in the last window, or after the end, reopens the sale for the governed duration or the locked window, whichever is longer, and keeps the standing bid. | handler check | `AuctionHaltsHandler.settle`, `_freezeExit` | `settle`, `toggleCurrency` |

## Fixed-price and Dutch sales

Real `FixedPriceSale` and `DutchSale`; the edition (`MockEditionTarget`), the escrow
(`MockRevenueEscrow`), the asset allowlist (`MockAssetAllowlist`), the economics resolver and
Permit2 are mocks from [`SaleFixture`](../../test/helpers/SaleFixture.sol). The handlers make
valid purchases only (and, for fixed price, two attacks), while the seller wallet refuses ETH
or is blocked by the token at random, so payouts take the escrow route. The fee share is
25,000 of 100,000.

**Dutch:** [`DutchInvariant.t.sol`](../../test/sales/dutch/DutchInvariant.t.sol), handler
`DutchHandler` in the same file (edition size 40; ETH buyers overpay at random).

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-SAL-1 | The adapter's ETH balance equals the sum of buyers' claimable ETH credits. | stateful invariant | `invariant_CreditsAreFullyBacked` | `buyEth`, `claim` |
| INV-SAL-2 | The seller and network wallets' ETH plus their escrow credits equal the total charged; everything sent equals that plus the adapter's balance plus what was claimed; the network's part equals the sum of each purchase's fee. | stateful invariant | `invariant_EthIsConserved` | `buyEth`, `claim`, `setWallet` |
| INV-SAL-3 | The adapter holds no ERC-20 and credits none; the seller and network wallets' tokens plus their escrow credits equal the total charged, and the network's part equals the sum of fees. | stateful invariant | `invariant_TokenChargesAreExactAndNeverKept` | `buyToken`, `setWallet` |
| INV-SAL-4 | Copies minted never exceed the size and equal the model. | stateful invariant | `invariant_MintedWithinSupply` | `buyEth`, `buyToken` |
| INV-SAL-5 | The current price never rises between observations. | stateful invariant | `invariant_PriceNeverRises` | `warp` and purchases |

**Fixed price:** [`FixedPriceInvariant.t.sol`](../../test/sales/fixed/FixedPriceInvariant.t.sol),
handler `FixedPriceHandler` in the same file (edition size 16; a recipient-keyed priced
allowlist phase, a payer-keyed phase, a public phase with a cap of 3, and an ERC-20 sale with a
cap of 5 paid directly or by relayed Permit2).

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-SAL-6 | No purchase of one copy more than a leaf's remaining cap succeeds, and no wallet uses another wallet's leaf to mint to itself. | stateful invariant | `invariant_NoOverCapOrForeignLeafPurchaseSucceeds` | `attackOverCap`, `attackForeignLeaf` |
| INV-SAL-7 | The adapter holds no ETH; the ETH paid equals the seller and network wallets' balances plus their escrow credits; the escrow's ETH equals its `totalOwed`. | stateful invariant | `invariant_EthIsPaidOrEscrowedNeverKept` | ETH purchases, `setWallet` |
| INV-SAL-8 | The same for the ERC-20. | stateful invariant | `invariant_TokenIsPaidOrEscrowedNeverKept` | `buyToken`, `setWallet` |
| INV-SAL-9 | The network's ETH and token receipts, paid or escrowed, equal the sum of each purchase's `floor(total × 25,000 / 100,000)`. | stateful invariant | `invariant_FeesAreExact` | purchases |
| INV-SAL-10 | Copies minted never exceed the size, equal the model, and equal the holders' balances. | stateful invariant | `invariant_MintedWithinSupplyAndAccounted` | purchases |
| INV-SAL-11 | `purchased(token, id, phase, wallet)` never exceeds the wallet's leaf cap (phases 0 and 1), the public cap (3) or the ERC-20 sale's cap (5). | stateful invariant | `invariant_PerWalletCapsHold` | purchases |

## Identity and recovery

[`test/identity/ArtistRegistry.invariant.t.sol`](../../test/identity/ArtistRegistry.invariant.t.sol),
handler [`ArtistRegistryHandler`](../../test/identity/ArtistRegistryHandler.sol). Real
`ArtistRegistry` and `ConsolidationAdapter`; the delegation contract
(`DelegationManagementMock`), the split factory (`SplitFactoryWalletsMock`) and the statement
log (`DisputeOutcomeLogMock`) are mocks. One artist and four keys: the artist key, an
established consolidated wallet, a fresh key and a thief. Before every call the handler
predicts success or the exact error from the registry's state.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-ID-1 | The payout and `authorityOf` equal the model, which only a successful execution (`executeChange` or an upheld `resolveContested`) changes; `payoutAddress` is zero exactly while a pending change, whose contest (if any) has not lapsed after 365 days, would move the payout. | stateful invariant | `invariant_PayoutChangesOnlyThroughExecutedChanges` | `stageStandard`, `stageOverride`, `execute`, `resolve`, `expire`, `veto`, `cancel` |
| INV-ID-2 | IDENTITY-1: `activeAuthorityOf` is zero exactly while an override (kind above STANDARD) that would move the authority is pending and its contest, if any, has not lapsed; otherwise it equals the authority. | stateful invariant | `invariant_ActiveAuthorityIsRestrainedOnlyByAnAuthorityMovingOverride` | as INV-ID-1 |
| INV-ID-3 | The last-activity time and `changeNonce` equal the model: dormancy counts only the artist's own activity and executions (never overrides, vetoes or refreshes), and the nonce moves only with stagings and revocations. | stateful invariant | `invariant_ActivityAndNonceMatchTheModel` | `heartbeat`, `revokeNonce`, `refreshStanding`, stagings |
| INV-ID-4 | A pending change is well formed: `executableAt` is `stagedAt` plus 7 days (STANDARD) or 180 days (override); `previousAuthority` is the current authority; the evidence hash is zero exactly for STANDARD; the cancellers are those captured at staging, at most 16; the next authority and payout are nonzero; only overrides are contested, with `contestedAt` in `[stagedAt, executableAt)`; an uncontested change records no prior outcome. | stateful invariant | `invariant_PendingChangeIsWellFormed` | stagings, `cancel`, `toggleConsolidation` |
| INV-ID-5 | IDENTITY-2: `reservedFor(key)` is the artist ID exactly for the next authority of a pending change that moves the authority; every other key is unreserved. | stateful invariant | `invariant_OnlyThePendingNextAuthorityIsReserved` | stagings, `execute`, `veto` |
| INV-ID-6 | SIGS-3: `artistIdOf(key)` is the artist ID exactly for the keys that have been the artist's authority, and the model, which refuses any return to such a key, agrees. | stateful invariant | `invariant_PastAuthoritiesResolveToTheArtist` | stagings, `execute` |
| INV-ID-7 | The authority resolves to the artist; the standing snapshot holds at most 16 entries and no wallet twice. | stateful invariant | `invariant_AuthorityAndStandingAreConsistent` | `refreshStanding`, `toggleConsolidation` |
| INV-ID-8 | The guardian is veto-only: its `stageOverride` and `stageChange` revert. Used payloads and used override acceptances never stage again. `resolveContested` succeeds only for a live contest, citing the latest recorded outcome, which must differ from the outcome recorded before the contest, and (to uphold) after the 180-day notice; `expireContest` only 365 days after the contest. | handler check | `guardianRedirect`, `replayLast`, `replayAcceptance`, `resolve`, `expire` | as named |
| INV-ID-9 | A refresh removes an established wallet only after it has been missing for 30 days, removes a pending entry at once when its consolidation ends, marks missing exactly the wallets no longer consolidated (only established ones), records new entries with the source's `effectiveAt`, and records every consolidated key unless the snapshot is full. | handler check | `refreshStanding` | `refreshStanding`, `toggleConsolidation`, `warp` |

## Statements

[`test/records/StatementLog.invariant.t.sol`](../../test/records/StatementLog.invariant.t.sol),
handler [`StatementLogHandler`](../../test/records/StatementLogHandler.sol), which rebuilds
every subject's chain from the emitted events with
[`StatementModel`](../../test/records/StatementModel.sol). Real `StatementLog`; the artist
resolver, the ERC-721 and the ERC-1155 are mocks. The AccessManager is granted every role the
mocks know of, and must still never sign.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-DSP-1 | For every subject touched, the stored count and head equal the chain rebuilt from the emitted events. | stateful invariant | `invariant_CountAndHeadMatchEmittedEvents` | every append |
| INV-DSP-2 | A subject's `latestDisputeOutcome` equals the last DISPUTE_OUTCOME entry rebuilt from events, and is zero for a subject with none. | stateful invariant | `invariant_LatestDisputeOutcomeMatchesEvents` | `appendPlatform` |
| INV-DSP-3 | Every event is well formed, gapless and recomputable, and no replayed, tampered, expired or unauthorized append succeeds, including one by the admin, the curator, the platform or the log itself. | stateful invariant | `invariant_NoMalformedEventsReplaysOrUnauthorisedWrites` | `replay`, `tamperedRelay`, `expiredRelay`, `unauthorized` |
| INV-DSP-4 | ARTIST entries are signed by the artist (or its wallet) and OWNER entries by the owner, never by an admin, curator, platform or stranger; DISPUTE_OUTCOME appears only under PLATFORM and CURATION_EVIDENCE only under CURATOR; the AccessManager signs only GOVERNANCE_MANIFEST entries, as PLATFORM, about itself. | stateful invariant | `invariant_RolesAreSpokenOnlyByTheirHoldersAndReservedKindsStayReserved` | `reservedKindMisuse`, `governanceMisuse`, `appendGovernanceManifest` |
| INV-DSP-5 | Every ARTIST entry records the resolver that was active when it was written, across resolver swaps; no other role records one. | stateful invariant | `invariant_ArtistEntriesBindTheActiveResolver` | `swapResolver`, `appendArtist` |
| INV-DSP-6 | A relayed entry is followed by exactly one nonce event naming its entry, signer and nonce; a direct entry by none. | stateful invariant | `invariant_RelayedEntriesCarryTheirNonce` | `appendRelayed`, `appendRelayedByWallet` |
| INV-DSP-7 | A used or revoked nonce stays spent. | stateful invariant | `invariant_SpentNoncesStaySpent` | `revokeNonce`, relays |

## Entropy

[`test/entropy/VrfEntropyInvariant.t.sol`](../../test/entropy/VrfEntropyInvariant.t.sol),
handler `EntropyHandler` in the same file. Real `VrfEntropyModule`; the VRF coordinator
(`MockVrfCoordinator`) and the package registry (`MockPackageRegistry`) are mocks. Items 0 to
3 are the VRF items of one package; items 4 and 5 have seed policies NONE and ARTIST; items 6
and 7 are VRF revisions that carry the content of items 0 and 1.

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-ENT-1 | Every request, repeat and delivery had the predicted outcome: a request is accepted only for a VRF item of an approved package whose content is unconsumed; it issues a new request only when the content's draw is neither delivered nor pending (a repeat only after `retryDelay`); an item not yet linked joins a delivered or pending draw and returns zero; a delivery for any request ever issued never reverts. | stateful invariant | `invariant_EveryCallHadThePredictedOutcome` | `request`, `fulfill`, `setApproved`, `setConsumed` |
| INV-ENT-2 | At most one delivery fixes a content's seed, and `isDelivered` and `seedOf` agree with the model forever after. | stateful invariant | `invariant_AtMostOneSeedPerItemAndItNeverChanges` | `fulfill` |
| INV-ENT-3 | `requestOf(item)` is the last request its content's draw issued until the seed is delivered, then zero; an item never linked, or not VRF, never has one. | stateful invariant | `invariant_TheCurrentRequestIsTheLastIssued` | `request`, `fulfill` |
| INV-ENT-4 | Items that share a content hash read the same seed once both are linked and the draw is delivered. | stateful invariant | `invariant_ItemsThatShareContentReadOneSeed` | `request`, `fulfill` |

## Governance

[`test/governance/GovernanceInvariant.t.sol`](../../test/governance/GovernanceInvariant.t.sol),
handler `GovernanceHandler` in the same file. Real `GovernanceConfigurator` and
`WorksAccessManager`; the governed target is `GovernedTargetMock`, and a rogue stock
`AccessManager` exists for hostile operations. Admins schedule random hostile operations next
to benign guardian and admin rotations; a random vigilant guardian cancels every hostile
operation before time moves; the handler runs the configurator's full readback
(`configurator.verify`) at every warp. The handler also has guardians suspend
the fixed PLATFORM, CURATOR and STORAGE_OPERATOR keys (and try a role that is not
suspendable), admins schedule 30-day grants that lift those suspensions and that the guardians
let through, and admins try to cancel revocations another account scheduled (Rule 3).

| ID | Invariant | Kind | Test | Handler actions |
| --- | --- | --- | --- | --- |
| INV-GV-1 | Hostile operations never change the target (its authority, recipient, verifier, fee and admin calls) or give the attacker any role; nothing executes early or through a wrapper; no account cancels the operation that revokes its own role; no admin ever cancels a revocation another account scheduled (Rule 3); benign rotations and lifts always execute; the on-chain GUARDIAN, PAUSER and ADMIN membership of the rotating accounts equals the model; the hot admin keeps ADMIN; at least two guardians stay active. | stateful invariant | `invariant_GovernanceStaysContained` | `scheduleHostile`, `scheduleBenign`, `executeBenign`, `adminCancelAndReschedule`, `adminCancelsOthersRevocation`, `scheduleLift`, `tryExecute`, `tryDirect`, `trySelfRescue`, `warp` |
| INV-GV-2 | The configuration on chain reads back as the model's configuration after every warp: the fixed holders that are not suspended, plus the active rotators. | handler check | `warp` (`configurator.verify(modelConfig())`) | `warp` |
| INV-GV-3 | No role that is not suspendable is ever suspended, for any guardian, admin, keeper or attacker account; each fixed operational key's on-chain suspension equals the model (set by `suspend`, cleared by an executed 30-day lift); a suspended key fails `hasRole` and an unsuspended one passes; for the CURATOR key, `canCall` on the target answers immediate exactly when it is not suspended, with zero delay. | stateful invariant | `invariant_SuspensionsStayContained` | `guardianSuspends`, `scheduleLift`, `executeBenign`, `warp` |
| INV-GV-4 | A guardian's suspension of a fixed key that is not suspended succeeds, and its attempt on a role that is not suspendable (ADMIN on the hot admin, or another role on a guardian) never succeeds. | handler check | `guardianSuspends` (`fail_on_revert`; `nonSuspendableSuspended` checked by INV-GV-3) | `guardianSuspends` |

## Properties tested by fuzz and unit tests

These properties have no stateful campaign of their own, or are tested more directly by a
fuzz or unit test.

### Value conservation and money maths

| ID | Property | Kind | Test |
| --- | --- | --- | --- |
| PROP-ECO-1 | For 1 to 64 payees whose shares sum to 100,000, the entitlements never exceed what the wallet observed, and the unpaid dust is at most the payee count minus one. | fuzz | [`SplitMath.t.sol`](../../test/economics/SplitMath.t.sol) `testFuzz_EntitlementsNeverExceedObservedAndDustIsBounded` |
| PROP-ECO-2 | The entitlement equals a full-width `mulDiv(observed, share, 100,000)` for every `observed` up to `type(uint256).max`, and is monotonic in `observed`. | fuzz | `SplitMath.t.sol` `testFuzz_EntitlementMatchesMulDivOverTheFullRange`, `testFuzz_EntitlementIsMonotonic` |
| PROP-ECO-3 | When and in which order payees release does not change their totals; released plus balance equals everything received. | fuzz | `SplitMath.t.sol` `testFuzz_ReleaseTimingDoesNotChangeTotals` |
| PROP-ECO-4 | The factory accepts exactly the canonical payee lists. | fuzz | `SplitMath.t.sol` `testFuzz_ValidationAcceptsExactlyCanonicalLists` |
| PROP-ECO-5 | Escrow credits and flushes conserve value: credits sum to `totalOwed`, which equals the escrow's balance. | fuzz | [`RevenueEscrow.t.sol`](../../test/economics/RevenueEscrow.t.sol) `testFuzz_CreditsAndFlushesConserve` |
| PROP-ECO-6 | Every payment reaches the wallet or becomes the wallet's escrow credit. | fuzz | [`RevenuePayment.t.sol`](../../test/economics/RevenuePayment.t.sol) `testFuzz_PaymentsAlwaysReachTheWalletOrItsCredit` |
| PROP-ECO-7 | Signed partial releases never exceed the entitlement. | fuzz | [`ReleaseVerifier.t.sol`](../../test/economics/ReleaseVerifier.t.sol) `testFuzz_SignedPartialReleasesNeverExceedEntitlement` |
| PROP-ECO-8 | The royalty wallet's shares add up to 100,000. | fuzz | [`EconomicsResolver.t.sol`](../../test/economics/EconomicsResolver.t.sol) `testFuzz_RoyaltySplitSharesAddUp` |
| PROP-ECO-9 | A predicted wallet address equals the deployed one. | fuzz | [`SplitFactory.t.sol`](../../test/economics/SplitFactory.t.sol) `testFuzz_PredictionMatchesDeployment` |
| PROP-AUC-1 | A settlement splits the price exactly between seller and network; the fee is the `mulDiv` floor and the bid step the `mulDiv` ceiling; the increment is the larger of the share and the floor. | fuzz | [`EnglishAuction.t.sol`](../../test/sales/auction/EnglishAuction.t.sol) `testFuzz_Settle_SplitsExactly`, `testFuzz_Bid_IncrementIsMaxOfShareAndFloor`; [`EnglishAuctionFollowUp.t.sol`](../../test/sales/auction/EnglishAuctionFollowUp.t.sol) `testFuzz_FeeMatchesMulDivFloor`, `testFuzz_StepMatchesMulDivCeil` |
| PROP-SAL-1 | The Dutch price never rises over time, stays within its bounds and rounds toward the seller. | fuzz | [`DutchPricing.t.sol`](../../test/sales/dutch/DutchPricing.t.sol) `testFuzz_PriceNeverRisesOverTime`, `testFuzz_PriceStaysWithinItsBounds`, `testFuzz_LinearRoundsTowardTheSeller` |
| PROP-SAL-2 | A public phase's wallet cap is never exceeded. | fuzz | [`FixedPriceSale.t.sol`](../../test/sales/fixed/FixedPriceSale.t.sol) `testFuzz_PublicWalletCapIsNeverExceeded` |
| PROP-STR-1 | The royalty receiver is the factory's wallet, the amount matches `mulDiv`, and `royaltyInfo` never returns zero for lack of gas. | fuzz | [`Stream.t.sol`](../../test/stream/Stream.t.sol) `testFuzz_royaltyInfo_isTheFactoryWallet`, `testFuzz_royaltyInfo_matchesMulDiv`, `testFuzz_royaltyInfo_neverZeroForLackOfGas` |

### Single use, uniqueness and authorization

| ID | Property | Kind | Test |
| --- | --- | --- | --- |
| PROP-CUR-1 | An item consumes once; it stays single-use across packages that list it; uniqueness keys on the declared content hash; an item outside the package is refused. | unit | [`PackageRegistry.t.sol`](../../test/curation/PackageRegistry.t.sol) `test_consume_revertsDoubleConsume`, `test_consume_itemIsSingleUseAcrossPackages`, `test_consume_contentUniquenessKeysOnContentHash`, `test_consume_revertsItemNotInPackage` |
| PROP-CUR-2 | Merkle proofs verify, a foreign item is rejected, and revoking one move nonce leaves the others untouched. | fuzz | `PackageRegistry.t.sol` `testFuzz_merkle_proofs`, `testFuzz_merkle_foreignItemRejected`, `testFuzz_revokeMove_bitmapIsolation` |
| PROP-CUR-3 | Only active signers' attestations count, and arbitrary signature bytes are never approved. | fuzz | [`Eip712CurationVerifier.t.sol`](../../test/curation/Eip712CurationVerifier.t.sol) `testFuzz_isApproved_onlyActiveSignersCount`, `testFuzz_isApproved_neverRevertsOnGarbage` |
| PROP-ED-1 | An edition never mints beyond its size, and `createEdition` refuses a tampered item. | fuzz | [`Editions.t.sol`](../../test/editions/Editions.t.sol) `testFuzz_Mint_NeverExceedsSize`, `testFuzz_CreateEdition_RefusesTamperedItem` |
| PROP-ENT-1 | The first of many deliveries wins; only the coordinator delivers; an unissued request ID never delivers; non-VRF items and items outside an approved package are always refused. | fuzz | [`VrfEntropyFuzz.t.sol`](../../test/entropy/VrfEntropyFuzz.t.sol) `testFuzz_TheFirstDeliveryOfManyRequestsWins`, `testFuzz_OnlyTheCoordinatorMayFulfill`, `testFuzz_UnissuedRequestIdsNeverDeliver`, `testFuzz_NonVrfItemsAreAlwaysRefused`, `testFuzz_OnlyItemsOfAnApprovedPackageCanBeRequested` |
| PROP-GV-1 | Nobody cancels the operation that revokes their own role. | fuzz | [`GuardianCancel.t.sol`](../../test/governance/GuardianCancel.t.sol) `testFuzz_NobodyCancelsTheirOwnRevocation` |
| PROP-GV-2 | A raise-only parameter moves by at most 2× per step and never above its ceiling, for any sequence of raises. | fuzz | [`BoundedParameter.t.sol`](../../test/governance/BoundedParameter.t.sol) `testFuzz_RaiseMatchesSpecification`, `testFuzz_RaiseSequenceStaysBounded` |
| PROP-GV-3 | Only genesis selectors pass wiring validation. | fuzz | [`GenesisWiring.t.sol`](../../test/governance/GenesisWiring.t.sol) `testFuzz_OnlyGenesisSelectorsPassValidation` |
| PROP-GV-4 | For any role, any victim and any canceller among the guardians, the cold admin, a keeper and a key holder, another account's revocation is cancelled exactly when the canceller is a guardian and not the victim (Rules 2 and 3). | fuzz | [`GuardianCancel.t.sol`](../../test/governance/GuardianCancel.t.sol) `testFuzz_OnlyGuardiansCancelAnotherAccountsRevocation` |
| PROP-GV-5 | Every role ID from 0 to 13 (`Roles.COUNT`, one past the last role) other than PLATFORM, CURATOR and STORAGE_OPERATOR is refused by `suspend` (`RoleNotSuspendable`); `test_SuspendableRolesAreTheZeroDelayOperationalKeys` also checks `PUBLIC`. | fuzz | [`Suspension.t.sol`](../../test/governance/Suspension.t.sol) `testFuzz_OnlyOperationalRolesCanBeSuspended` |
| PROP-GV-6 | A suspension takes effect in the same block on `hasRole`, `canCall` and the target; the record and other roles stay; only guardians suspend; a pending holder can be suspended and never activates; only an ADMIN grant (guardian-vetoable) or a revocation, or the holder's renounce, lifts it; readback rejects a suspended holder. | unit | `Suspension.t.sol` `test_AGuardianSuspendsAKeyInTheSameBlock`, `test_OnlyGuardiansSuspend`, `test_APendingGrantCanBeSuspended`, `test_OnlyAnAdminGrantLiftsItAndAGuardianCanVetoThat`, `test_ARevocationClearsItAndTheKeyCanRenounce`, `test_ReadbackRejectsASuspendedHolder` |
| PROP-GV-7 | On the genesis deployment: a suspended PLATFORM key fails every PLATFORM path, manual checks included, while the creator's path stays open; a dishonest guardian's suspension lasts 60 days (still in force at day 59, lifted at day 60); the cold admin removes a hot admin and a guardian acting together in two 30-day rounds; demotions by grant stay cancellable by the demoted account. | unit | [`GovernanceRecovery.t.sol`](../../test/integration/GovernanceRecovery.t.sol) `test_GOV2_AGuardianSuspendsThePlatformKeyAtOnce`, `test_GOV2_ADishonestGuardiansSuspensionLastsAboutSixtyDays`, `test_GOV1_ColdAdminRemovesAHotAdminAndAGuardianActingTogether`, `test_GOV1_DemotionsByGrantStayCancellable` |
| PROP-ID-1 | A change never executes before its delay; the uphold window of a contested override is always open; the adapter's "established" answer matches a model. | fuzz | [`ArtistRegistry.t.sol`](../../test/identity/ArtistRegistry.t.sol) `testFuzz_ExecuteChange_RespectsTheDelay`; [`ContestedOverrides.t.sol`](../../test/identity/ContestedOverrides.t.sol) `testFuzz_L3_UpholdWindowAlwaysOpen`; [`ConsolidationAdapter.t.sol`](../../test/identity/ConsolidationAdapter.t.sol) `testFuzz_IsEstablished_MatchesModel` |
| PROP-DSP-1 | Any append sequence matches the model; relays round-trip and never replay; the nonce bitmap tracks exactly the spent nonces. | fuzz | [`StatementLog.t.sol`](../../test/records/StatementLog.t.sol) `testFuzz_SequenceMatchesModel`, `testFuzz_RelayRoundTripAndReplay`, `testFuzz_NonceBitmapTracksExactlyTheSpentNonces` |
| PROP-HASH-1 | The item hash binds the collection and the shares and does not depend on the chain. | fuzz | [`WorksHashing.t.sol`](../../test/interfaces/WorksHashing.t.sol) `testFuzz_itemHash_bindsCollection`, `testFuzz_itemHash_bindsShares`, `testFuzz_itemHash_independentOfChain` |

### Content and rendering

| ID | Property | Kind | Test |
| --- | --- | --- | --- |
| PROP-CNT-1 | Stored files round-trip, and ranged reads match a reference. | fuzz | [`ContentStore.t.sol`](../../test/content/ContentStore.t.sol) `testFuzz_RoundTrip`, `testFuzz_Read_MatchesReference` |
| PROP-CNT-2 | The base64 attestation agrees with an oracle on arbitrary bytes and on one injected byte. | fuzz | [`Base64Attest.t.sol`](../../test/content/Base64Attest.t.sol) `testFuzz_ArbitraryBytesMatchTheOracle`, `testFuzz_Attest_OneInjectedByteMatchesTheOracle` |
| PROP-RND-1 | The JSON scanner agrees with `serde_json`; every accepted record yields JSON every parser reads; escaping is correct for any valid text and its output is inert. | fuzz | [`JsonScan.t.sol`](../../test/content/renderer/JsonScan.t.sol) `testFuzz_AgreesWithSerdeJson`; [`RendererReview.t.sol`](../../test/content/renderer/RendererReview.t.sol) `testFuzz_M4_AcceptedRecordsGiveJsonEveryParserReads`; [`Renderer.t.sol`](../../test/content/renderer/Renderer.t.sol) `testFuzz_Escaping_AnyValidText`; [`JsonEscape.t.sol`](../../test/libraries/JsonEscape.t.sol) `testFuzz_EscapedOutputIsInert` |

### Gas, state growth and the transaction cap

The figures behind these rows are in
[ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table); the rules are on
[Build, test and budgets](build-and-test.md#gas-and-state-growth-rules).

| ID | Property | Kind | Test |
| --- | --- | --- | --- |
| PROP-GAS-1 | A steady-state ETH `start` and `startWithBid`, for one and two parties, a VRF work and an edition master, cost at most 350K Prague gas (`START_BUDGET` in [`IntegrationBase.sol`](../../test/integration/IntegrationBase.sol)). | unit | [`GasReport.t.sol`](../../test/integration/GasReport.t.sol) `test_Gas_Start_SteadyState`, `test_Gas_StartWithBid_SteadyState`, `test_Gas_Start_TwoPartyWork`, `test_Gas_StartWithBid_TwoPartyWork`, `test_Gas_Start_VrfWork`, `test_Gas_Start_EditionMaster` |
| PROP-GAS-2 | Every measured operation creates exactly its stated number of new storage slots and new accounts; a steady-state `start` writes at most 6 new slots and `startWithBid` at most 7 (`START_MAX_SLOTS`, `START_WITH_BID_MAX_SLOTS`). | unit | every `test_Gas_*` in `GasReport.t.sol` |
| PROP-GAS-3 | Every other measured operation stays under its Prague test ceiling or regression ceiling. | unit | every `test_Gas_*` in `GasReport.t.sol` |
| PROP-GAS-4 | The harness's cold-account correction is exact: a `start` measured from a fully cold state equals the corrected figure measured after every account was warmed; nothing is added for accounts already cold; storage the harness does not cool is refused. | unit | [`GasHarness.t.sol`](../../test/integration/GasHarness.t.sol) `test_TheColdAccountCorrectionIsExact`, `test_NothingIsAddedForAccountsAlreadyCold`, `test_RequireCooledRefusesStorageItDoesNotCool` |
| PROP-GAS-5 | The state-growth counter counts a slot once, ignores overwrites, zero-to-zero, reverted writes, out-of-gas and `INVALID` frames and transient storage, and counts `CREATE` and ETH sent to a fresh account or an empty precompile as new accounts. | unit | [`StateGrowth.t.sol`](../../test/helpers/StateGrowth.t.sol) (24 tests) |
| PROP-GAS-6 | `tokenURI` costs at most 8M Prague gas (`TOKEN_URI_BUDGET`) with every record, media and locator cap filled at once, on the real stack, for Stream and for Editions' `uri`; a `tokenURI` creates no state. | unit | [`TokenUriBudget.t.sol`](../../test/integration/TokenUriBudget.t.sol) `test_Budget_*`; `GasReport.t.sol` `test_Gas_TokenURIBySize`; [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol) `RendererGasTest`, `RendererGasBudgetTest` |
| PROP-GAS-7 | Worst-case bounded inputs fit the EIP-7825 cap of 16,777,216 gas in Prague gas, intrinsic and calldata included: claim batches and the largest split wallet; mint, `openRecord`, relicense with 16 consents, the longest locator, the preferred-locator scan and `syncOnChain`; `consume` and `registerPackage`; `createEdition`; `openSale` and purchases; settlement with every fallback; `stageChange`, `stageOverride` and `refreshStanding` (under half the cap); manifest registration and attestation at `MAX_CHUNKS`; genesis `configure`. | unit | [`GasCap.t.sol`](../../test/economics/GasCap.t.sol), [`StreamTxCap.t.sol`](../../test/stream/StreamTxCap.t.sol), [`PackageRegistryGas.t.sol`](../../test/curation/PackageRegistryGas.t.sol), `Editions.t.sol` `test_Gas_CreateEditionWorstCaseFitsTxCap`, [`FixedPriceGasCap.t.sol`](../../test/sales/fixed/FixedPriceGasCap.t.sol), [`DutchGasCap.t.sol`](../../test/sales/dutch/DutchGasCap.t.sol), [`EnglishAuctionGas.t.sol`](../../test/sales/auction/EnglishAuctionGas.t.sol) `test_SettleGas_FitsTheTransactionCap`, [`EnglishAuctionHostile.t.sol`](../../test/sales/auction/EnglishAuctionHostile.t.sol) `test_SettleWorstCaseFitsTheFusakaCap`, [`ArtistRegistryReview.t.sol`](../../test/identity/ArtistRegistryReview.t.sol) `test_WorstCase_*`, `ContentStore.t.sol` `test_RegisterManifest_AtMaxChunksFitsTheTransactionGasCap`, `Base64Attest.t.sol` `test_Attest_AtMaxChunksEveryCallFitsTheTransactionGasCap`, [`Genesis.t.sol`](../../test/integration/Genesis.t.sol) `test_GenesisConfigureFitsTheTransactionCap`, [`GenesisConfig.t.sol`](../../test/governance/GenesisConfig.t.sol) `test_MaximumWiringFitsTheTransactionGasCap` |
| PROP-GAS-8 | The VRF callback creates no storage slot and, repriced as ADR 0004 models Glamsterdam, uses at most half of `MIN_CALLBACK_GAS` (100,000). | unit | [`VrfEntropyModule.t.sol`](../../test/entropy/VrfEntropyModule.t.sol) `test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam` |

## Gaps

What no stateful campaign covers yet. Stateful suites on the real, wired stack are being added
in [PR #62](https://github.com/6529-Collections/6529-works/pull/62). Coverage, mutation testing
and Halmos proofs are being added in
[PR #58](https://github.com/6529-Collections/6529-works/pull/58).

**Money-moving contracts.**
- **`ClaimRouter` and `RevenueEscrow` do have campaign coverage**, in the economics campaign:
  `claimBatch` (plain and signed), `deposit`, `pay`, `flush`, `recover` and
  `consentToRecovery`, with INV-ECO-6, INV-ECO-7, INV-ECO-10 and INV-ECO-11. The auction
  suites also run against the real `RevenueEscrow`. The fixed-price and Dutch campaigns do not:
  they use `MockRevenueEscrow`, so INV-SAL-2, INV-SAL-3, INV-SAL-7 and INV-SAL-8 check the
  mock's bookkeeping on the escrow side.
- **`AssetAllowlist`** has no invariants of its own. It runs as a real dependency only in the
  auction halts campaign (deprecation and re-admission); the fixed-price and Dutch campaigns
  use `MockAssetAllowlist`.
- **`EconomicsResolver`** has no campaign. Its terms are mocked in the Stream, Editions and sale
  campaigns.
- **The fixed-price and Dutch campaigns** make valid purchases only, plus two attacks (over-cap
  and foreign leaf). They do not pause the adapter, deprecate a currency or close and reopen
  sales, so the halt clock (`scheduleDelay`) and the overlapping-halts behavior are covered
  only by unit tests ([`SalesFollowUpRegression.t.sol`](../../test/adv/SalesFollowUpRegression.t.sol),
  [`Market1Regression.t.sol`](../../test/adv/Market1Regression.t.sol)).

**Other contracts.**
- **`WorkRecords`** is covered only through the Stream campaign: finalize immutability, the
  royalty-rate consent path and locator adds. `relicense`, `repinRenderer`, `syncOnChain` and
  the preferred-location settings are not driven by any campaign.
- **`ContentStore`, `DependencyRegistry` and `Renderer`** have fuzz and unit tests only
  (PROP-CNT-1, PROP-CNT-2, PROP-RND-1).
- **`Eip712CurationVerifier`** runs as a real dependency in the curation campaign, but the
  campaign never disables, re-enables or swaps a signer.
- **`ConsolidationAdapter`** runs as a real dependency in the identity campaign over a mock
  delegation contract; its own model is a fuzz test (PROP-ID-1).
- **Suspension in the governance campaign** covers the fixed keys on a mock target only, checks
  `canCall` for the CURATOR key alone, and lifts by grant only. The manual PLATFORM and CURATOR
  paths (sale adapters, `WorkRecords.addLocator`, relayed statements), lifts by revocation and
  renounce, and the dishonest-guardian timeline are unit and integration tests (PROP-GV-6,
  PROP-GV-7).
- **Deployment and readback guards** (`DeployGuards`, `Verify.s.sol`: Safe topology, canonical
  dependencies, the VRF subscription, epoch mode, pending operations) have unit tests only, in
  [`DeployScript.t.sol`](../../test/deploy/DeployScript.t.sol).

**Mocks at the boundaries.** No campaign drives the fully wired system. Each campaign mocks
its neighbors: the Stream campaign mocks the sale adapter and economics; the auction campaigns
mint into `MockMintTarget`; the Editions campaign mocks Stream and the adapters; the fixed-price
and Dutch campaigns mock the edition, escrow, allowlist and resolver; the entropy campaign mocks
the registry and the coordinator; the governance campaign governs a mock target. Properties
that span contracts (for example, that a `start` consumes, mints and takes custody atomically,
or that a real Editions mint through a real `FixedPriceSale` conserves value) are covered by
the scenario tests in [`test/integration/`](../../test/integration/README.md), not by a
campaign.

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
