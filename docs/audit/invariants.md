# Invariants

For auditors: every invariant the stateful campaigns, their handlers, and fuzz and unit tests
check, and which contracts each campaign runs for real. Each statement comes from the
assertion, not the test's name; [Gaps](#gaps) lists what no campaign covers.

> Pre-audit. See the [project status](../../README.md#status).

**The plain core.** [ADR 0010](../adr/0010-plain-permanent-core.md) replaced `Stream`, `Editions`,
`WorkRecords` and the federated templates with a small permanent core. Its invariants come first,
under [The permanent core](#the-permanent-core). Campaigns of the modules that were rewritten
(the English auction, the edition auction on the whole stack, the records modules, federated
sales) are being ported: until then their rows name the test they had, as placeholders, and
`tools/check_rules.py` reports them.

## The permanent core

Invariant campaigns at 256 runs, depth 128, `fail_on_revert`.

**Stream** ([`StreamCoreInvariant.t.sol`](../../test/core/invariant/StreamCoreInvariant.t.sol),
handler [`StreamCoreHandler`](../../test/core/invariant/StreamCoreHandler.sol)): the real
`Stream`, three stand-in minters and a TERMS stand-in; six content hashes, three collectors.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CORE-1 | At most one live token per content hash. | `invariant_OneLiveTokenPerContent` | mint, burn, transfer |
| INV-CORE-2 | A token's outcome leaves `NONE` once and never changes after. | `invariant_OutcomeIsRecordedOnce` | record a sale, burn, rescue |
| INV-CORE-3 | Token IDs follow `totalMinted` and are never reused; `totalSupply == totalMinted - totalBurned`; owners and balances match the model. | `invariant_IdsAndSupply`, `invariant_OwnersMatchTheModel` | mint, burn, transfer |
| INV-CORE-4 | No call by any module or minter changes the owner of a token whose outcome is `SOLD`, and a sold token is never burned; every refused call the handler predicts is refused. | `invariant_SoldTokensStayLive`, `invariant_NoRefusedCallSucceeded` | every action |
| INV-CORE-5 | `itemHash`, `artistId`, `collectionId`, `serial`, `kind`, `seedPolicy` and `seed` never change after mint. | `invariant_FactsNeverChange` | every action |
| INV-CORE-6 | A locked royalty rate never changes. | `invariant_LockedRateNeverChanges` | set royalty, lock |

The same campaign runs on a federated 1/1 token
([`FederatedStreamInvariant.t.sol`](../../test/federated/invariant/FederatedStreamInvariant.t.sol)),
whose minters are the federation module's answer, with one more check:
`invariant_HasMintedMatchesTheModel`.

**Editions** ([`EditionsInvariant.t.sol`](../../test/core/EditionsInvariant.t.sol), handler
[`EditionsHandler`](../../test/core/EditionsHandler.sol)): the real `Editions` and `Stream`.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CORE-8 | `minted <= maxSupply` always; a sealed `maxSupply` never changes. | `invariant_MintedNeverPassesTheMaximum`, `invariant_ASealedMaximumNeverChanges` | create, mint, seal |
| INV-CORE-9 | `minter` changes only by `rebind`, only with nothing minted and unsealed, once the `rebindDelay` in force has passed since the minter's removal. | `invariant_TheMinterChangesOnlyByItsRules` | rebind, remove minter, warp |
| INV-CORE-10 | The sum of balances plus burned copies equals `minted`. | `invariant_BalancesPlusBurnedEqualMinted` | mint, burn, transfer |

**WorkFacts** ([`WorkFactsInvariant.t.sol`](../../test/core/WorkFactsInvariant.t.sol)): the real
`WorkFacts` with the records fixture.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CORE-11 | Media never change after open; `recordFileId` never changes after `finalized`; `finalized`, `licenseLocked`, `repinLocked` and `onChainComplete` never go back to false; a CC0 work stays CC0; `renderer` changes only by finalize or `repin`, never past the lock. | `invariant_TheFactsHold` | open, set record, set license, finalize, repin, lock |

**Placeholders for campaigns being ported** (each becomes a row when its test exists):

- INV-CORE-7: Stream's state is rebuilt exactly from its logs (log replay).
- INV-CORE-14: only the network changes `moduleDelay`, `rescueDelay`, `rebindDelay` and
  `unclaimedPeriod`; each change emits the old and new values; an action is refused before the
  period in force has elapsed; zero is allowed; an addition already announced keeps its time.
- INV-CORE-15: expiry or forfeit never takes money that has waited less than the unclaimed period
  in force, and never money that arrived after a mark or after a credit aged (ledger, escrow and
  both auctions, one `AgedCredits` rule in the auctions).
- INV-CORE-16: in every seam position (minter, TERMS, RENDERER, RECORDS, accounts, federation
  gate), a module that lies, reverts, burns all its gas or re-enters moves no token, changes no
  fact and moves no balance; `ownerOf` and transfers still work.

## Campaign settings

Every campaign runs with `[profile.default.invariant]` in [`foundry.toml`](../../foundry.toml):
`runs = 256`, `depth = 128` calls per run, `fail_on_revert = true`, `show_metrics = true`.
Fuzz tests run 256 times (`[profile.default.fuzz] runs`). Two `/// forge-config:` comments under
`test/` change fuzz runs: `testFuzz_Clear_MatchesTheBruteForceOverUnits` runs 10,000 times, and
`testFuzz_Settlement_EqualsTheLibraryClearing` 10,000 under the `deep` profile; none changes
an invariant campaign's runs or depth. Three campaigns check their invariant after every
fourth call (`check_interval = 4`; every call in the `deep` profile): the content store, the
Stream lifecycle and the edition auction, whose checks read many contracts; each of their
actions still checks its own effects.

- **The rule.** Every contract that moves money gets stateful invariants of at least 256 runs
  of depth 128 ([AGENTS.md](../../AGENTS.md), [ADR 0001](../adr/0001-v1-scope.md#intended-behavior)).
- **`fail_on_revert`.** Every handler action succeeds or is skipped, and an expected revert is
  asserted inside the handler (`try`/`catch` or `vm.expectRevert`), so a wrong prediction fails
  the campaign.
- **Kinds.** A campaign row is a stateful invariant (an `invariant_*` function, checked after
  every call of every run) unless its Test cell says **handler check** (an assertion inside a
  handler action, failing the campaign through `fail_on_revert`) or **after-campaign** (an
  `afterInvariant` hook, checked at the end of every run).
- **Non-vacuity.** Every campaign has a handler self-test: the economics campaign's
  `test_HandlerReachesEveryPath`, and elsewhere `test_EveryActionRuns` or
  `test_HandlerPathsReachState`, built on [`HandlerReach`](../../test/helpers/HandlerReach.sol):
  it calls every targeted handler action with mixed-width arguments and reads each call's state
  diff, and fails unless every action changed a contract under test, was refused by one, or
  moved the clock, as its expectation names; it then checks every invariant on the state the
  drive left.
- **Traceability.** Every row's Test cell must name a function that exists under `test/`;
  [`tools/check_rules.py`](../../tools/check_rules.py) checks it in CI.
- **Running them.** `forge test --match-contract Invariant`; commands and CI jobs are in the
  [testing guide](../testing/README.md).

## Work records modules

The RECORDS module `WorkRules`, the mint policy and the delivery contracts. Their campaigns are
being ported to the plain core; until then each invariant is listed as a placeholder.

### Work powers

The earlier campaign is being ported to the plain core.

Placeholders for campaigns being ported (each becomes a row when its test exists):

- INV-STR-12: A work's renounced mask only gains bits: it equals the OR of every applied renunciation and keeps every bit it held at the previous check.
- INV-STR-13: No renounced power's function succeeds again, every call the rules allow succeeds, and the rate and license are the ones the handler applied.
- INV-STR-14: A work's royalty rate stays at most 100,000 and never moves once its royalty power is renounced.

### The mint policy

The earlier campaign is being ported to the plain core.

Placeholders for campaigns being ported (each becomes a row when its test exists):

- INV-STR-15: MP-1 ([AUC-38](../spec/stream-and-auctions.md#rules-and-invariants)): whatever the mint policy answers, no existing token's views change, and each stays held by the adapter that minted it.
- INV-STR-16: No content mints twice ([AUC-44](../spec/stream-and-auctions.md#rules-and-invariants)): whatever the mint policy answers, Stream's content record (`consumedItemOf`) names the item of the one token that minted each content hash, and no second mint of a content hash succeeds.

### Work records under replaced delivery contracts and stores

The earlier campaign is being ported to the plain core.

Placeholders for campaigns being ported (each becomes a row when its test exists):

- INV-STR-17: A complete, finalized work's `tokenURI` never changes.
- INV-STR-18: A complete work's facts (record, media, license, rate, powers, pin, completeness and each file's store) never change.

### Delivery contracts

The earlier campaign is being ported to the plain core.

Placeholders for campaigns being ported (each becomes a row when its test exists):

- INV-WD-4: Every action has the predicted outcome: strangers, the artist after finalize, duplicate and malformed URIs, a full quota, a dead or missing index, an unknown collection, a stale compare-and-set value and a stranger's replacement are refused; all else succeeds.
- INV-WD-1: In every real delivery contract ever installed, each file's locators are exactly those appended, in order, at most 16; the artist added at most 8 and only before finalize, the platform at most 8 before finalize and at most the artist's unused slots more after; counts, artist mask and dead mask match the model; a dead mark never clears ([WS-19, WS-20](../spec/works-and-storage.md#rules-and-invariants)).
- INV-WD-2: Every real delivery contract ever installed resolves each file's preferred locator in WS-21's order: the live file index, the collection kind, the global kind, the first live locator, the implicit ONCHAIN copy of a synced work, else none; a dead locator is never served ([WS-21, WS-22](../spec/works-and-storage.md#rules-and-invariants)).
- INV-WD-3: `WorkRecords.delivery` is the contract installed last, each installed contract names its predecessor, and `preferredLocator` serves the current contract's answer only when well formed: a real successor's own resolution, a hostile one's well-formed answer, else the work's own (ONCHAIN when synced, else none) ([WS-39, WS-40](../spec/works-and-storage.md#rules-and-invariants)).

## The governed vault

[`GovernedVaultInvariant.t.sol`](../../test/economics/GovernedVaultInvariant.t.sol), handler
`GovernedVaultHandler` in the same file. The real network fee vault (`GovernedVault`, the
`SplitLedger`'s network and a fixed 25% payee of a royalty wallet), with ETH, a plain ERC-20, a
no-return token, a blocklist token, a fee-on-transfer token, ERC-721 works and ERC-1155 copies;
destinations include a contract that refuses ETH when closed and `ReenteringDestination`, which
on every ETH payment tries to make itself the destination and to pull the rest.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ECO-15 | The vault holds what reached it less what it forwarded; every account that could receive anything holds exactly what it received while it was the destination, through `forward` or `releaseToDestination`; every work and copy is with the vault or the destination it was forwarded to ([ECO-41](../spec/economics-and-payouts.md#rules-and-invariants)). | `invariant_HoldingsLeaveOnlyToTheDestination` | `fund`, `forward`, `forwardWork`, `forwardCopies`, `pushShare`, `releaseToDestination` |
| INV-ECO-16 | The destination is the one the network last set with the current revision, never zero or the vault; the revision counts the changes; stale and future revisions, a stranger, and the re-entering destination never change it (ECO-41). | `invariant_DestinationIsCompareAndSetByTheNetwork` | `setDestination`, `forward` |
| INV-ECO-17 | Every forward and destination change has the predicted outcome (nothing to forward, more than held, a refusing or blocked party, a token delivering less than sent, a destination that cannot hold works, a stale revision, a stranger are refused), with exactly the predicted amount. | `invariant_EveryCallHadThePredictedOutcome` | all |

## Curation signers

[`CurationSignerInvariant.t.sol`](../../test/curation/CurationSignerInvariant.t.sol), handler
`CurationSignerHandler` in the same file. Real `PackageRegistry`, `Eip712CurationVerifier` and
`WorksAccessManager` (its grant counter matters: a revoke and re-grant in one block must not
revive an epoch); three signer keys, 24 roots. Signers sign at their current epoch, also while
disabled or without the role; anyone submits (some tampered); the network disables, re-enables,
swaps keys, kills approvals and revokes roots; a stranger tries the network's actions.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CUR-7 | A root registers only from an approval made at the signer's current epoch while active; none signed before a disable, a revocation or a swap, or while disabled or without the role, ever registers; each epoch value is new at every disable, enable, revocation and grant. | `invariant_RegistrationsFollowTheSignersEpoch` | `sign`, `register`, `disable`, `enable`, `swap` |
| INV-CUR-8 | The registry's view of every root is the model's: unregistered, live with its signer, or revoked (a killed signer's root reads as revoked from the kill on). | `invariant_RootsMatchTheModel` | `register`, `kill`, `revokeRoot` |
| INV-CUR-9 | The verifier's view of each signer (disabled, active, epoch) is the model's. | `invariant_SignersMatchTheModel` | `disable`, `enable`, `swap` |

## Curation

[`PackageRegistryInvariant.t.sol`](../../test/curation/PackageRegistryInvariant.t.sol),
handler `CurationHandler` in the same file. Real `PackageRegistry` and
`Eip712CurationVerifier`; mock `MockArtistRegistry`. Twenty items by three artists: 0 to 9 in
package A, 6 to 15 in package B, 16 to 19 in none; items `i` and `i + 8` share a content hash;
a third root C starts unregistered; Stream's content record ([AUC-44](../spec/stream-and-auctions.md#rules-and-invariants)) is
`StreamContentMock`, which the registry's `consumedItemOf`, `releasedTo` and `isReleased` answer
from. The handler is an exact model of eight actions: `consume` (a mint through the mock),
`release`, `revokeMove`, `rotate`, `revokePackage`, `registerLate`, `acceptLate` and `rebind`.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CUR-1 | No call the model forbids succeeds (revoked or unregistered root, foreign or wrong proof, stale key, spent or revoked move nonce, expired move, used or released content, unbound caller, second binding). | `invariant_noUnexpectedSuccess` | all nine |
| INV-CUR-2 | Every call the model allows succeeds, so the model is exact. | `invariant_noUnexpectedFailure` | all eight |
| INV-CUR-3 | Each item is consumed at most once, never if it is in no package, and `isReleased` matches the model. | `invariant_itemConsumedAtMostOnce` | `consume`, `release` |
| INV-CUR-4 | Per content hash, `consumedItemOf` equals the model's single live Stream item. | `invariant_contentRecordsMatch` | `consume`, `release` |
| INV-CUR-6 | Every artist's 31 move-nonce flags and every root's status equal the model. | `invariant_noncesAndStatuses` | `revokeMove`, `rotate`, `revokePackage`, `registerLate`, `acceptLate` |

No dedicated invariant covers the single use of a package's registration; the model's
exactness (INV-CUR-1, INV-CUR-6) tests it.

## Economics

[`EconomicsInvariant.t.sol`](../../test/economics/invariant/EconomicsInvariant.t.sol), handler
[`EconomicsHandler`](../../test/economics/invariant/EconomicsHandler.sol). Real `SplitLedger`
and its 66-byte `SplitVault` wallets (three payee sets, each at two salts so a replacement exists;
the ledger also verifies signed releases),
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
| INV-ECO-6 | Every escrow credit equals the model, credits sum to `totalOwed` per asset, and the escrow's balance is at least `totalOwed`. | `invariant_EscrowIsSolventAndMatchesTheModel` | `pay`, `deposit`, `flush`, `recover`, `consentToggle`, `expire` |
| INV-ECO-7 | The claim router holds nothing, and the payer holds no ETH, no allowance to the escrow, and only the tokens of payments the model expected to revert. | `invariant_IntermediariesHoldNothing` | `claimBatch`, `pay` |
| INV-ECO-8 | Every release, signed release, batch item, payment, deposit, flush and recovery reverts with exactly the predicted error data or moves exactly the predicted amount. | handler check: every action (`release`, `releaseTo`, `releaseSigned`, `claimBatch`, `pay`, `deposit`, `flush`, `recover`) | all |
| INV-ECO-9 | A replayed signed release fails with `NonceAlreadyUsed`, or with `NotPayoutAddress` once the artist's payout changed. | handler check: `replaySigned` | `releaseSigned`, `revokeNonce`, `setArtistPayout` |
| INV-ECO-10 | Governed recovery moves a split wallet's credit only to its equivalent replacement (same payees, another salt), another account's only to the replacement that account consented to, consuming the consent, and the network's own credits without consent. | handler check: `recover`, `consentToggle` | as named |
| INV-ECO-11 | A claim batch pays each item its predicted amount, and the recipients' balances rise by exactly the batch total. | handler check: `claimBatch` | as named |
| INV-ECO-12 | Per wallet and asset, what was released plus what is still releasable equals what the wallet received (the ledger's accounting matches the vault's balances). | `invariant_ReleasedPlusReleasableMatchesReceived` | release actions, `pay`, `receiveDirect` |
| INV-ECO-13 | The escrow's excess over `totalOwed` is exactly what `sweepExcess` may move, and for every asset the handler uses (ETH and single-address, non-rebasing tokens) a sweep never reduces a credit's backing ([ECO-40](../spec/economics-and-payouts.md#rules-and-invariants); two-address and rebasing tokens: LIM-ECO-8). | `invariant_EscrowExcessIsExactlyTheUnowed` | `pay`, `deposit`, `flush`, `recover`, `sweep` |
| INV-ECO-14 | A running mark never exceeds what the payee was entitled to when marked; a forfeit pays the network at most the marked level less what the payee released, and only 180 days after the mark; every release from a wallet naming the network fee vault also pays the vault its due share, or leaves it due when the vault's token refuses. | `invariant_MarksWithinEntitlement`; handler check: `mark`, `forfeit`, `expire` | `mark`, `forfeit`, `expire`, `warp`, release actions |

## English auction

[`AuctionInvariant.t.sol`](../../test/sales/auction/invariant/AuctionInvariant.t.sol), handler
`AuctionHandler` in the same file. The real `EnglishAuction` on the real `Stream` and `Directory`
(`AuctionFixture`), with the real split ledger, escrow, asset allowlist and economics resolver;
a stand-in mint policy, federation policy, federated token and statement log. The handler
starts curated and federated sales with and without a bid, bids, moves the clock, settles,
refuses settlement, restarts, claims, expires credits, pauses for a dispute, withdraws,
cancels and changes the unclaimed period, and keeps a model of every credit's money with the
time each part arrived.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-AUC-1 | The auction's ETH balance equals its standing high bids plus every account's credits. | `invariant_BalanceIsStandingBidsPlusCredits` | all |
| INV-AUC-14 | `expireCredit` never sends the network money that has waited less than the unclaimed period in force when the expiry is attempted, whatever credits arrived meanwhile and whatever the period was set to. | `invariant_NeverTakesMoneyYoungerThanThePeriod` | `expire`, `setPeriod`, `bid`, `cancel`, `withdraw` |

Placeholders for the rest of the earlier campaign (each becomes a row when its test exists):

- INV-AUC-2: Every unit deposited as a bid is held by the auction, paid to the seller or network wallet, credited to one of them in the escrow, or claimed.
- INV-AUC-3: Each sale has at most one outcome and exact custody: a cancelled sale's token is burned, with no bidder; a settled sale holds its token only while delivery is pending (base suite: marked primary-settled); an open sale holds it.
- INV-AUC-4: Each sale keeps its locked currency, token, token ID and first-bid increment floor (even after a withdrawal), a live sale names its high bid's recipient, and `minimumBid` is `max(openingBid, the withdrawn bid kept as reserve, 1)` with no bidder, else the bid plus `max(ceil(bid × share / 100,000), floor)`.
- INV-AUC-5: Every sale, ended or not, keeps in storage the opening bid, increment share and anti-snipe window locked at start and its first bid's floor, whatever governance changed (read from storage, layout cross-checked against the view).
- INV-AUC-6: After 30 days, settling every sale and claiming every delivery and credit leaves no funds and no token, with every deposit accounted for.
- INV-AUC-7: Once the token stops blocking, every sale ends settled or cancelled, leaving no funds and no token.
- INV-AUC-8: A bid extends the end to at least `now + the locked window`; settlement delivers the token (or leaves it pending) to the high bid's recipient, or the museum if none; a second dispute pause reverts (`PauseExhausted`); a withdrawal leaves the sale paused; the network's `resume` lands at any moment of the pause.
- INV-AUC-9: An unended sale refuses `settle`; settlement after the end delivers or leaves a pending delivery.
- INV-AUC-10: With hostile tokens, the auction's balance equals the actors' credits plus the live high bids, and every deposited bid is held, claimed, or paid to the seller, the network or the escrow for them.
- INV-AUC-11: The network receives exactly the fee on every sold sale (the listed terms, or for a federated sale the registry's share locked at start), paid to the recipient current at settlement, and nothing on a refused, rescued or unsold one.
- INV-AUC-12: From any state the campaign reaches, once 2 days have passed after each sale's end, `settleOrRefund` brings every unsettled federated sale to SETTLED whatever its token does, and `settle` the stand-in's, leaving no standing bid, with INV-AUC-10, INV-AUC-11 and INV-AUC-13 still holding.
- INV-AUC-13: A bidder holds a sale's work, by the token's own ledger, only if that sale is SETTLED with it as the winning bidder, so it paid, and the network's fee on it is counted in INV-AUC-11.

## Edition sales

The edition auction runs on mocks in the unit suites; its campaign on the whole stack is below.

## The edition auction on the whole stack

The campaign that ran the edition auction on the deployed stack is being ported to
`script/DeployCore.sol`. Placeholders (each becomes a row when its test exists):

- INV-EA-1: No unsold or extra copies: an edition's minted supply equals the units its claims minted, never exceeds the clearing count `k`, and equals `k` once every winning bid is claimed; the units every bid wins sum to `k`.
- INV-EA-2: ETH conservation: the adapter's balance is what bidders paid in minus refunds, revenue and credits paid out, and equals exactly what it owes: every unclaimed bid's escrow, less its won units at the clearing price once settled, plus the credits.
- INV-EA-3: Clearing optimality and the breadth rule: before settlement the live count, price and best revenue equal the per-unit reference's (so the count is the largest within the margin of `R*`); at settlement the stored result equals it too, and its revenue is within the margin of `R*`.
- INV-EA-4: The cap: the count never exceeds a nonzero creator cap.
- INV-EA-5: FIFO at the cut step: every claim mints exactly the reference's fill in arrival order of the units the clearing step sells, the marginal bid partly, and `bidOutcome` agrees with the claim; the departure order the handler sorts equals `settlementOrder` (a fresh settler's order), and a sweep completes.
- INV-EA-6: The view equals settlement: the last live `clearing` before settling is the stored result, and the stored result never changes afterwards.
- INV-EA-7: The clocks: `endTimes` reads the 1/1's end live, `closeAt` is that end plus 15 minutes, `endTime = max(closeAt, softEnd)` never before `closeAt` and never past the backstop, the soft end is the handler's model (a bid or raise in the window, none while the 1/1 is paused), and bidding is open exactly when the rules say.
- INV-EA-8: No settlement before the end, before the 1/1 settles, or before the edition exists when copies sold; a cancelled 1/1's sale refuses a bid once the adapter reads the cancellation (LIM-EA-16 has the rest) and settles VOID; `abandon` from 21 days after the close creates the edition when the master settled, else voids.
- INV-EA-9: A void sale refunds every bid in full and mints nothing.
- INV-EA-10: Firm bids and single claims: a withdrawal at any time (also during a 1/1 dispute pause), a stranger's raise, a payment one wei off, a second open, a second claim, all revert.
- INV-EA-11: Beside the 1/1: a 1/1 bid in its anti-snipe window extends the 1/1 and never moves the edition end earlier; an unbid 1/1 settles to the museum.
- INV-EA-12: Per-settler sweeps and completability: a settler's call moves only its own progress (`sweepOf`); an order that skips a departure is accepted but never finishes its sender's sweep; a reordered one reverts with `InvalidSettlementOrder`; after any of these, a keeper settling from its own address completes settlement within a bounded number of calls, and a later call by another settler returns true and changes nothing.
- INV-EA-13: No claim while SETTLING: while a sale's scan or sweep is unfinished, its bidder's claim and a pushed claim both revert with `InvalidAuctionState`. A book wider than one call's scan (24 words) settles over calls: the first stores scan progress and no result; an early call may advance the scan before the edition exists, and the call that would finish it waits for the edition.

## Identity and recovery

[`Accounts.invariant.t.sol`](../../test/identity/Accounts.invariant.t.sol), handler
`AccountsHandler` in the same file. Real `Accounts` and `ConsolidationAdapter` with the
identity fixture's mocks. The handler stages own changes and replacements, freezes and
unfreezes, consolidates and unconsolidates wallets, and signs with the account's wallets and with
outsiders.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ID-1 | `requireSigned` passes exactly for the account's wallets (the root, or a wallet the source says is consolidated with it), never for an outsider and never while the account is frozen ([ID-2, ID-3](../spec/identity-and-recovery.md#rules-and-invariants)). | `invariant_RequireSignedPassesExactlyForTheAccountsWallets` | as named in the handler |

The earlier identity campaign (INV-ID-2 to INV-ID-13: the restraint flag, activity and nonces,
reservations, past authorities, the standing snapshot, timers, the federation directory with
LEFT, and the source acting only for dormant artists) left with that machinery in the second
permanence pass; the contest, replacement and freeze rules are unit-tested in
`ArtistRegistry.t.sol` (`test_Contest_*`) and the
directory in `FederationDirectory.t.sol`.

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
| INV-ENT-1 | A request succeeds only for a VRF item of an approved package with unconsumed content, issues a new request only if the content's draw is neither delivered nor pending (a repeat only after the content's backoff wait, `retryDelay * 2^repeats` capped at 30 days, the count restarting after a coordinator swap), else links the item to that draw and returns zero; a delivery for any request the current coordinator issued never reverts, and one from another coordinator always does. | `invariant_EveryCallHadThePredictedOutcome` | `request`, `fulfill`, `setApproved`, `setConsumed`, `swap` |
| INV-ENT-2 | At most one delivery fixes a content's seed, and `isDelivered` and `seedOf` match the model forever after. | `invariant_AtMostOneSeedPerItemAndItNeverChanges` | `fulfill` |
| INV-ENT-3 | `requestOf(item)` is the last request its content's draw issued until delivery, then zero, and an unlinked or non-VRF item never has one. | `invariant_TheCurrentRequestIsTheLastIssued` | `request`, `fulfill` |
| INV-ENT-4 | Items that share a content hash read one seed once both are linked and the draw is delivered. | `invariant_ItemsThatShareContentReadOneSeed` | `request`, `fulfill` |
| INV-ENT-5 | A content's draw never has more requests to one coordinator in one tenure than the tenure's first plus every repeat made at its earliest backoff moment since then. | `invariant_TheBackoffBoundsTheRequestsOfAContent` | `request`, `swap` |

## Governance

[`GovernanceInvariant.t.sol`](../../test/governance/GovernanceInvariant.t.sol), handler
`GovernanceHandler` in the same file. Real `GovernanceConfigurator` and `WorksAccessManager`;
mock `GovernedTargetMock`. Random actors, the network among them, hand the network over, accept,
try to grant themselves network roles, grant and revoke an operational key, brake and run
operations, and renounce roles; refused calls are caught.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-GV-1 | Exactly one address holds the network roles (`ADMIN`, `NETWORK`, `PARAMETER_SETTER`, `FUNDS_SETTER`, `SUCCESSOR_SETTER`); it is `network()`, it carries each class's delay, and the configurator holds none ([GV-14](../spec/governance.md#rules-and-invariants)). | `invariant_ExactlyOneAddressHoldsTheNetworkRoles` | `transfer`, `accept`, `grantNetworkRole`, `grantOperational`, `brakeAndRun`, `renounce` |

## Content store

[`ContentStoreInvariant.t.sol`](../../test/content/ContentStoreInvariant.t.sol): the test
contract is its own handler. Real `ContentStore`; seven chunks (two full, three tails, one that
fits only last) and seven files over them, written again and in any order, registered again,
with another MIME type over the same chunks, over chunks that break the layout rule, and
malformed; reads over random ranges. One function asserts the invariants after every fourth
call (`check_interval = 4`; every call in the `deep` profile); every action checks its own
outcome at once.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CNT-1 | A chunk's pointer is set by its first write and never changes, and its code is exactly the chunk. | `invariant_contentStore` | `writeChunk` |
| INV-CNT-2 | A file's ID is the hash of its whole manifest, and its declared length, chunk list, encoding, MIME type and SHA-256 never change. | `invariant_contentStore` | `registerManifest`, `registerMalformed` |
| INV-CNT-3 | A file is complete exactly when every chunk it names is stored with the length the layout rule gives it, and `missingChunks` lists exactly the others, in order. | `invariant_contentStore` | `writeChunk`, `registerManifest` |
| INV-CNT-4 | A read returns exactly the bytes written over any range whose chunks are all stored with their layout lengths, and a range that touches a missing or mis-sized chunk never reads. | handler check: `readBack` (`violations`, asserted by `invariant_contentStore`) | `readBack` |

Non-vacuity: `ContentStoreInvariantTest.test_EveryActionRuns`.

## Federated sales

The earlier campaign is being ported to the plain core.

Placeholders for campaigns being ported (each becomes a row when its test exists):

- INV-FSA-1: The auction's ETH balance equals every bidder's claimable credit plus the high bid of every unsettled sale.
- INV-FSA-2: The network fee recipient receives exactly its locked share on every sold federated sale, and nothing otherwise.
- INV-FSA-3: A person holds a federated work only if its sale is SOLD, and then it is the bidder who paid.
- INV-FSA-4: Federation never touches 6529 Stream (its supply and the curated token's owner) or a curated artist's identity.
- INV-FSA-5: Every sale ends: after each is refused, the auction owes only credits, and INV-FSA-1 and INV-FSA-2 still hold.

Non-vacuity: `FederationInvariantTest.test_HandlerPathsReachState`.

## Invariants removed or changed

The behaviour these checked was removed or changed by the owner's decisions of 16 November 2026
(ADR 0009) and by the plain core (ADR 0010); the IDs are not reused.

| ID | What it checked | Now |
| --- | --- | --- |
| INV-ID-1 (old) to INV-ID-13 | The single authority, the restraint flag, activity and dormancy, reservations, the standing snapshot, governed timers, the directory's LEFT state, and a source acting only for dormant artists | Removed; INV-ID-1 now checks the consolidated account ([Identity and recovery](#identity-and-recovery)) |
| INV-GV-2 to INV-GV-8; PROP-GV-1, PROP-GV-4 to PROP-GV-7 | Guardian cancel rules, suspensions, escalation, dead-admin recovery, seat caps | Removed with guardians, seats, suspension and recovery; INV-GV-1 and PROP-GV-8 check the single network |
| INV-STR-9 to INV-STR-11 | Stream's interned terms and their hashed positions; only the minting adapter marks a sale settled | Removed: one plain struct per token ([ADR 0010](../adr/0010-plain-permanent-core.md)); the settlement rule is INV-CORE-2 |
| INV-STR-14 (old) | A royalty rate never rises | Changed: a rate stays within 100,000 and is fixed once renounced |
| INV-EA-10 (old) | Withdrawals of bids placed before a 1/1 dispute pause | Changed: no edition bid is ever withdrawn |
| INV-EA-7 (old) | A per-sale close offset | Changed: every sale closes 15 minutes after its 1/1 |
| INV-STR-1 to INV-STR-8 | Stream and work records on the old `Stream` and `WorkRecords` | Replaced by INV-CORE-1 to INV-CORE-6 and INV-CORE-11 ([ADR 0010](../adr/0010-plain-permanent-core.md)) |
| INV-ED-1 to INV-ED-6 | The old `Editions` contract | Replaced by INV-CORE-8 to INV-CORE-10 |
| INV-FED-1 to INV-FED-6 | The old federated templates | The federated tokens run the core code: INV-CORE-1 to INV-CORE-10 |

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
| PROP-ECO-6 | Every payment reaches the wallet or becomes its escrow credit. | [`RevenuePayment.t.sol`](../../test/economics/RevenuePayment.t.sol) `test_PayETHGoesStraightToTheWallet`, `test_PayETHFallsBackToEscrowWhenRefused`, `test_CallerCannotStarveETHPaymentIntoEscrow` |
| PROP-ECO-7 | Signed partial releases never exceed the entitlement. | [`ReleaseVerifier.t.sol`](../../test/economics/ReleaseVerifier.t.sol) `testFuzz_SignedPartialReleasesNeverExceedEntitlement` |
| PROP-ECO-8 | The royalty wallet's shares add up to 100,000. | [`EconomicsResolver.t.sol`](../../test/economics/EconomicsResolver.t.sol) `testFuzz_RoyaltySplitSharesAddUp` |
| PROP-ECO-9 | A predicted wallet address equals the deployed one. | [`SplitFactory.t.sol`](../../test/economics/SplitFactory.t.sol) `testFuzz_PredictionMatchesDeployment` |
| PROP-AUC-1 | A settlement splits the price exactly between seller and network, with the fee the `mulDiv` floor, the bid step the `mulDiv` ceiling, and the increment the larger of the share and the floor. | [`EnglishAuction.t.sol`](../../test/sales/auction/EnglishAuction.t.sol) |
| PROP-EA-1 | On random books of bids and raises, capped and uncapped, under four margins, the edition auction's live clearing, every bid's outcome and the settlement order equal a brute-force per-unit reference, and settling and claiming every bid mints exactly the count and leaves the adapter empty; other settlers' skipped, partial and reversed sweeps never block the keeper or change an outcome. | |
| PROP-EA-2 | The step ladder rises strictly and nests for every allowed steps-per-decade and base price. | [`StepLadder.t.sol`](../../test/interfaces/StepLadder.t.sol) `testFuzz_DecadesAndSteps`, `test_EveryLadderRisesAndNests` |
| PROP-STR-1 | The royalty receiver is the factory's wallet, the amount matches `mulDiv`, and `royaltyInfo` never returns zero for lack of gas. | `Stream.t.sol` |

### Single use, uniqueness and authorization

| ID | Property | Test |
| --- | --- | --- |
| PROP-CUR-1 | An item consumes once, even across packages that list it, uniqueness keys on the declared content hash, and an item outside the package is refused. | [`PackageRegistry.t.sol`](../../test/curation/PackageRegistry.t.sol) `test_consume_revertsDoubleConsume`, `test_consume_itemIsSingleUseAcrossPackages`, `test_consume_contentUniquenessKeysOnContentHash`, `test_consume_revertsItemNotInPackage` |
| PROP-CUR-2 | Merkle proofs verify, a foreign item is rejected, and revoking one move nonce leaves the others untouched. | `PackageRegistry.t.sol` `testFuzz_merkle_proofs`, `testFuzz_merkle_foreignItemRejected`, `testFuzz_revokeMove_bitmapIsolation` |
| PROP-CUR-3 | Only active signers' attestations count, and arbitrary signature bytes are never approved. | [`Eip712CurationVerifier.t.sol`](../../test/curation/Eip712CurationVerifier.t.sol) `testFuzz_isApproved_onlyActiveSignersCount`, `testFuzz_isApproved_neverRevertsOnGarbage` |
| PROP-ED-1 | An edition never mints beyond its creator's cap, and `createEdition` refuses a tampered item. | `Editions.t.sol` |
| PROP-ENT-1 | The first of many deliveries wins, only the coordinator delivers, an unissued request ID never delivers, and non-VRF items and items outside an approved package are always refused. | [`VrfEntropyFuzz.t.sol`](../../test/entropy/VrfEntropyFuzz.t.sol) `testFuzz_TheFirstDeliveryOfManyRequestsWins`, `testFuzz_OnlyTheCoordinatorMayFulfill`, `testFuzz_UnissuedRequestIdsNeverDeliver`, `testFuzz_NonVrfItemsAreAlwaysRefused`, `testFuzz_OnlyItemsOfAnApprovedPackageCanBeRequested` |
| PROP-GV-8 | Only the network holds a network role, for any account and network role. | [`NetworkAndBrake.t.sol`](../../test/governance/NetworkAndBrake.t.sol) `testFuzz_OnlyTheNetworkHoldsTheNetworkRoles` |
| PROP-GV-2 | A raise-only parameter moves by at most 2× per step and never above its ceiling, for any sequence of raises. | [`BoundedParameter.t.sol`](../../test/governance/BoundedParameter.t.sol) `testFuzz_RaiseMatchesSpecification`, `testFuzz_RaiseSequenceStaysBounded` |
| PROP-GV-3 | Only genesis selectors pass wiring validation. | |
| PROP-ID-1 | The value rules hold for any input: a royalty rate up to 100,000 rises or falls with agreement; a fee share only ever falls; a federated share in force never exceeds the deployed share; every release path pays the network its share; a mark never takes money that arrived after it; every edition sale closes 15 minutes after its 1/1. | ; `Stream.t.sol` ; ; [`NetworkShare.t.sol`](../../test/economics/NetworkShare.t.sol) `testFuzz_EveryReleasePathPaysTheNetwork`, `testFuzz_AMarkNeverTakesLaterMoney`; [`UniformEditionAuctionWindow.t.sol`](../../test/sales/edition/UniformEditionAuctionWindow.t.sol) `testFuzz_Window_TheCloseIsTheOneOfOneEndPlusFifteenMinutes` |
| PROP-DSP-1 | Any append sequence matches the model, relays round-trip and never replay, and the nonce bitmap tracks exactly the spent nonces. | [`StatementLog.t.sol`](../../test/records/StatementLog.t.sol) `testFuzz_SequenceMatchesModel`, `testFuzz_RelayRoundTripAndReplay`, `testFuzz_NonceBitmapTracksExactlyTheSpentNonces` |
| PROP-HASH-1 | The item hash binds the collection and the shares and does not depend on the chain. | [`WorksHashing.t.sol`](../../test/interfaces/WorksHashing.t.sol) `testFuzz_itemHash_bindsCollection`, `testFuzz_itemHash_bindsShares`, `testFuzz_itemHash_independentOfChain` |
| PROP-STR-2 | Retired: Stream holds no dependencies and no artist registry. | none |
| PROP-STR-3 | `tokenURI` never falls back to another renderer: a finalized work uses its pin, an unfinalized one the RENDERER module, and a fault or shortfall reverts ([AUC-42](../spec/stream-and-auctions.md#rules-and-invariants)). | |
| PROP-ECO-10 | A governed vault forwards what it holds only to its destination, which only a compare-and-set FUNDS_SETTER action changes ([ECO-41](../spec/economics-and-payouts.md#rules-and-invariants)). | [`GovernedVault.t.sol`](../../test/economics/GovernedVault.t.sol) `test_AnyoneForwardsETHToTheDestinationOnly`, `test_SetDestinationIsCompareAndSet`, `test_SetDestinationIsGovernedInTheFundsClass` |

### Content and rendering

| ID | Property | Test |
| --- | --- | --- |
| PROP-CNT-1 | Stored files round-trip, and ranged reads match a reference. | [`ContentStore.t.sol`](../../test/content/ContentStore.t.sol) `testFuzz_RoundTrip`, `testFuzz_Read_MatchesReference` |
| PROP-CNT-2 | The base64 attestation agrees with an oracle on arbitrary bytes and on one injected byte. | [`Base64Attest.t.sol`](../../test/content/Base64Attest.t.sol) `testFuzz_ArbitraryBytesMatchTheOracle`, `testFuzz_Attest_OneInjectedByteMatchesTheOracle` |
| PROP-RND-1 | The JSON scanner agrees with `serde_json`, every accepted record yields JSON every parser reads, and escaping is correct for any valid text, with inert output. | [`JsonScan.t.sol`](../../test/content/renderer/JsonScan.t.sol) `testFuzz_AgreesWithSerdeJson`; [`RendererRecords.t.sol`](../../test/content/renderer/RendererRecords.t.sol) `testFuzz_Record_AcceptedRecordsGiveJsonEveryParserReads`; [`Renderer.t.sol`](../../test/content/renderer/Renderer.t.sol) `testFuzz_Escaping_AnyValidText`; [`JsonEscape.t.sol`](../../test/libraries/JsonEscape.t.sol) `testFuzz_EscapedOutputIsInert` |

### Gas, state growth and the transaction cap

Figures: [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table). Rules: the
[testing guide](../testing/README.md).

| ID | Property | Test |
| --- | --- | --- |
| PROP-GAS-1 | Every start row, with and without a bid (one and two parties, a VRF work, an edition master, an artist's first work), costs at most 370,000 Prague gas (`START_BUDGET` in `CoreIntegrationBase.sol`); a start with a bid of a VRF work, which also writes the seed, at most 395,000 (`VRF_START_BUDGET`). | |
| PROP-GAS-2 | Every measured operation creates exactly its stated number of new storage slots and accounts; every start row writes at most 8 new slots, with or without a bid (`START_MAX_SLOTS`); a start with a bid of a VRF work at most 9 (`VRF_START_MAX_SLOTS`). | every `test_Gas_*` in |
| PROP-GAS-3 | Every other measured operation stays under its Prague test ceiling or regression ceiling. | every `test_Gas_*` in |
| PROP-GAS-4 | The harness's cold-account correction is exact (a `start` from a fully cold state equals the corrected figure after warming every account), adds nothing for accounts already cold, and refuses storage it does not cool. | |
| PROP-GAS-5 | The state-growth counter counts a slot once, ignores overwrites, zero-to-zero, reverted writes, out-of-gas and `INVALID` frames and transient storage, and counts `CREATE` and ETH sent to a fresh account or an empty precompile as new accounts. | [`StateGrowth.t.sol`](../../test/helpers/StateGrowth.t.sol) (24 tests, among them `test_OneNewSlot`, `test_ZeroToZeroIsNotNew`, `test_WriteInARevertedCallIsNotNew`, `test_WriteInAFrameThatRanOutOfGasIsNotNew`, `test_WriteInAFrameThatHitInvalidIsNotNew`, `test_TransientStorageIsNeverASlot`, `test_CreateIsANewAccountWithItsSlots`, `test_EthToAnEmptyPrecompileIsANewAccount`) |
| PROP-GAS-6 | With every record, media and locator cap filled on the real stack, Stream's `tokenURI` and Editions' `uri` cost at most 8M Prague gas (`TOKEN_URI_BUDGET`) and create no state. | `test_Budget_*`; ; [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol) `RendererGasTest`, `RendererGasBudgetTest` |
| PROP-GAS-7 | Worst-case bounded inputs fit the EIP-7825 cap of 16,777,216 gas in Prague gas, intrinsic and calldata included: claim batches and the largest payee list; mint, `openRecord`, relicense with 16 consents, the longest locator, the preferred-locator scan and `syncOnChain`; `consume` and `registerPackage`; `createEdition`; every `settle` call of the edition auction's worst cases (every step of the widest ladder used, the cap binding at step 0, the longest departure sweep); settlement with every fallback; manifest registration and attestation at `MAX_CHUNKS`; genesis `configure`. | [`GasCap.t.sol`](../../test/economics/GasCap.t.sol), [`PackageRegistryGas.t.sol`](../../test/curation/PackageRegistryGas.t.sol), `Editions.t.sol` [`EnglishAuctionHostile.t.sol`](../../test/sales/auction/EnglishAuctionHostile.t.sol) `ContentStore.t.sol` `test_RegisterManifest_OneCallOf512FitsTheTransactionGasCap`, `Base64Attest.t.sol` `test_Attest_AtMaxChunksEveryCallFitsTheTransactionGasCap` |
| PROP-GAS-8 | The VRF callback creates no storage slot and, repriced as ADR 0004 models Glamsterdam, uses at most half of `MIN_CALLBACK_GAS` (100,000). | [`VrfEntropyModule.t.sol`](../../test/entropy/VrfEntropyModule.t.sol) `test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam` |

## Gaps

What no stateful campaign covers today, after the plain-core integration. Coverage, mutation
testing and Halmos proofs are in [Testing](../testing/README.md).

- **The campaigns being ported.** The English auction, the edition auction on the whole stack,
  the records modules (`WorkRules`, `WorkDelivery`), federated sales, log replay and the
  settings and money rules of the core (INV-CORE-7, INV-CORE-14 to INV-CORE-16) have no campaign
  on the new code yet; their rows above name the tests they had.
- **The fully wired system.** The core campaigns run the real permanent contracts with stand-in
  modules; scenario tests on the deployed stack (`script/DeployCore.sol`) are being ported to
  [`test/integration/`](../../test/integration/README.md).
- **Execution-delay changes of a curation signer** (inactive but keeping its epoch) are unit
  tests only.
- **`DependencyRegistry` and `Renderer`**: fuzz and unit tests only (PROP-RND-1). The content
  store has its campaign (INV-CNT-1 to INV-CNT-4).
- **`ConsolidationAdapter`** runs only over a mock delegation contract.
- **Deployment and readback** (`DeployCore`, `VerifyCore`): unit tests only, in
  `test/deploy/`.

## Differences from the ADRs

See the [register](../spec/README.md#differences-from-the-adrs).

## References

- Code: [`foundry.toml`](../../foundry.toml), [`src/`](../../src/)
- ADRs: [ADR 0001](../adr/0001-v1-scope.md#test-plan), [ADR 0002](../adr/0002-access-manager-hardening.md#test-plan),
  [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#consequences)
- Tests: every file linked above; [`test/integration/README.md`](../../test/integration/README.md)
- Related pages: the [testing guide](../testing/README.md),
  [Known limitations and accepted risks](known-limitations.md), [trust assumptions](trust-assumptions.md),
  [Scope](scope.md), the [spec](../spec/README.md)
