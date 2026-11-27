# Invariants

For auditors: every invariant the stateful campaigns, their handlers, and fuzz and unit tests
check, and which contracts each campaign runs for real. Each statement comes from the
assertion, not the test's name; [Gaps](#gaps) lists what no campaign covers.

> Pre-audit. See the [project status](../../README.md#status).

**The plain core.** [ADR 0010](../adr/0010-plain-permanent-core.md) replaced `Stream6529`,
`StreamEditions6529`, `WorkRecords` and the Independent Stream templates with a small permanent
core. Its invariants come first, under [The permanent core](#the-permanent-core). Some invariants
that campaigns checked on the earlier contracts have no stateful campaign on the current ones.
Each is listed under its area as "no stateful campaign", outside the tables, with what does
cover it; [Gaps](#gaps) has the summary.

## The permanent core

Invariant campaigns at 256 runs, depth 128, `fail_on_revert`.

**Stream** ([`StreamCoreInvariant.t.sol`](../../test/core/invariant/StreamCoreInvariant.t.sol),
handler [`StreamCoreHandler`](../../test/core/invariant/StreamCoreHandler.sol)): the real
`Stream6529`, three stand-in minters and a TERMS stand-in; six content hashes, three collectors.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CORE-1 | At most one live token per content hash. | `invariant_OneLiveTokenPerContent` | mint, burn, transfer |
| INV-CORE-2 | A token's outcome leaves `NONE` once and never changes after. | `invariant_OutcomeIsRecordedOnce` | record a sale, burn, rescue |
| INV-CORE-3 | Token IDs follow `totalMinted` and are never reused; `totalSupply == totalMinted - totalBurned`; owners and balances match the model. | `invariant_IdsAndSupply`, `invariant_OwnersMatchTheModel` | mint, burn, transfer |
| INV-CORE-4 | No call by any module or minter changes the owner of a token whose outcome is `SOLD`, and a sold token is never burned; every refused call the handler predicts is refused. | `invariant_SoldTokensStayLive`, `invariant_NoRefusedCallSucceeded` | every action |
| INV-CORE-5 | `itemHash`, `artistId`, `collectionId`, `serial`, `kind`, `seedPolicy` and `seed` never change after mint. | `invariant_FactsNeverChange` | every action |
| INV-CORE-6 | A locked royalty rate never changes. | `invariant_LockedRateNeverChanges` | set royalty, lock |

The same campaign runs on an Independent Stream 1/1 token
([`IndependentStreamInvariant.t.sol`](../../test/independent/invariant/IndependentStreamInvariant.t.sol)),
whose minters are the Independent Stream module's answer, with one more check:
`invariant_HasMintedMatchesTheModel`.

**Editions** ([`EditionsInvariant.t.sol`](../../test/core/EditionsInvariant.t.sol), handler
[`EditionsHandler`](../../test/core/EditionsHandler.sol)): the real `StreamEditions6529` and
`Stream6529`.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CORE-8 | `minted <= maxSupply` always; a sealed `maxSupply` never changes. | `invariant_MintedNeverPassesTheMaximum`, `invariant_ASealedMaximumNeverChanges` | create, mint, seal |
| INV-CORE-9 | `minter` changes only by `rebind`, only with nothing minted and unsealed, once the `rebindDelay` in force has passed since the minter's removal. | `invariant_TheMinterChangesOnlyByItsRules` | rebind, remove minter, warp |
| INV-CORE-10 | The sum of balances plus burned copies equals `minted`. | `invariant_BalancesPlusBurnedEqualMinted` | mint, burn, transfer |

**WorkFacts** ([`WorkFactsInvariant.t.sol`](../../test/core/WorkFactsInvariant.t.sol)): the real
`StreamWorkFacts6529` with the records fixture.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-CORE-11 | Media never change after open; `recordFileId` never changes after `finalized`; `finalized`, `licenseLocked`, `repinLocked` and `onChainComplete` never go back to false; a CC0 work stays CC0; `renderer` changes only by finalize or `repin`, never past the lock. | `invariant_TheFactsHold` | open, set record, set license, finalize, repin, lock |

Non-vacuity of the Independent Stream campaign:
`IndependentStreamInvariantTest.test_HandlerReachesEveryState`.

**No stateful campaign** checks these as stated (each becomes a row when its test exists):

- INV-CORE-7: Stream's state is rebuilt exactly from its logs (log replay). The replay tests in
  [`test/replay/`](../../test/replay) run scripted scenarios on the deployed stack, not random
  call sequences.
- INV-CORE-14: only the network changes `moduleDelay`, `rescueDelay`, `rebindDelay` and
  `unclaimedPeriod`; each change emits the old and new values; an action is refused before the
  period in force has elapsed; zero is allowed; an addition already announced keeps its time.
  Campaigns check the waits while the settings change (INV-CORE-9, INV-LIF-6, INV-LIF-9,
  INV-LIF-14, INV-LIF-15, INV-AUC-14); who may change a setting and the events are unit and fuzz
  tests ([`StreamSettings.t.sol`](../../test/core/StreamSettings.t.sol)).
- INV-CORE-15: expiry or forfeit never takes money that has waited less than the unclaimed period
  in force, and never money that arrived after a mark or after a credit aged (ledger, escrow and
  both auctions, one `AgedCredits` rule in the auctions). Campaigns check it in the English
  auction (INV-AUC-14, INV-LIF-9) and for the ledger's marks (INV-ECO-14), whose handler also
  predicts every escrow expiry; credit expiry in the edition auction has unit tests only.
- INV-CORE-16: in every seam position (minter, TERMS, RENDERER, RECORDS, accounts, Independent
  Stream gate), a module that lies, reverts, burns all its gas or re-enters moves no token, changes
  no fact and moves no balance; `ownerOf` and transfers still work. Unit tests only
  (`test/core/*Hostile*.t.sol`, `WorkRulesHostile.t.sol`, `IndependentHostile.t.sol`); the
  lifecycle campaign's hostile party is a bidder and recipient, not a module.

## The deployed stack

Two campaigns run 6529 Stream on the whole stack as `script/DeployCore.sol` deploys it with the
committed genesis ([`test/integration/invariant/`](../../test/integration/README.md#invariant-suites));
the third, the edition auction's, is [below](#the-edition-auction-on-the-whole-stack). Each
action predicts its outcome from the rules and records any disagreement, which the invariant
function reports.

**A work's lifecycle**
([`StreamLifecycleInvariant.t.sol`](../../test/integration/invariant/StreamLifecycleInvariant.t.sol),
handler [`StreamLifecycleHandler`](../../test/integration/invariant/StreamLifecycleHandler.sol)):
the real token, package registry, `StreamWorkFacts6529` with `WorkRules`, delivery contract,
English auction and accounts module; three artists with six works each, three bidders, and a
contract that reverts, burns its gas or re-enters when it is paid or handed a work.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-LIF-1 | Every live token has one owner, a known holder, and is in the auction's custody exactly while its sale is unsettled or its delivery pending; a burned token has no owner and its sale is cancelled. | `invariant_streamLifecycle` | `start`, `settle`, `resolveDispute`, `transfer`, `claimDelivery` |
| INV-LIF-2 | Token IDs are assigned once, in order, one per item; supply is minted minus burned. | `invariant_streamLifecycle` | `start`, `resolveDispute` |
| INV-LIF-3 | The facts fixed at mint never change, and the outcome is `NONE` until the sale records it, then `SOLD` or `UNSOLD` for good. | `invariant_streamLifecycle` | every action |
| INV-LIF-4 | A content hash is held by at most one live work; a burned work holds it until it is released; a released item is barred, and only the release's beneficiary mints the content again. | `invariant_streamLifecycle` | `start`, `resolveDispute`, `releaseContent` |
| INV-LIF-5 | A record's media never change; its record file is the opened one or the artist's last `setRecord` and never changes after finalize; a finalized work keeps its pinned renderer and code hash; a CC0 work stays CC0 with the pinned text; locators only append, within each side's quota. | `invariant_streamLifecycle`; handler check: `addLocator` | `openRecord`, `setRecord`, `finalize`, `relicense`, `addLocator` |
| INV-LIF-6 | The RENDERER module is the one the network last activated; a pending module keeps the time it was given whatever the module delay becomes; a finalized work is drawn by its pinned renderer, an unfinalized one by the module. | `invariant_streamLifecycle` | `swapRenderer`, `finalize` |
| INV-LIF-7 | An account has no active authority exactly while it is frozen or being replaced, and nothing its keys try as the artist goes through. | `invariant_streamLifecycle`; handler check: `restrainedAct` | `stageRecovery`, `endRecovery`, `freezeAccount`, `restrainedAct` |
| INV-LIF-8 | The auction's ETH balance is what was paid in less what was paid out, and equals the live high bids plus the credits. | `invariant_streamLifecycle` | `bid`, `hostileBid`, `settle`, `claimCredit`, `hostileClaim`, `expireCredit` |
| INV-LIF-9 | A credit is everything credited and not claimed or expired, and its expiry is due one unclaimed period, as it stands, after its waiting money started to wait; an expiry sends exactly that money to the network's fee recipient and never money younger than the period. | `invariant_streamLifecycle`; handler check: `expireCredit` | `expireCredit`, `setUnclaimedPeriod`, `claimCredit` |
| INV-LIF-10 | A work settled without a bid is held by the museum, whatever its artist's standing, and the museum holds nothing else. | `invariant_streamLifecycle` | `settle` |

Non-vacuity: `StreamLifecycleInvariantTest.test_EveryActionRuns`.

**Work and minter states**
([`StreamStatesInvariant.t.sol`](../../test/integration/invariant/StreamStatesInvariant.t.sol);
the test contract is its own handler): works minted through the English auction and through a
second minter the network adds; both minters removed and added again; the module and rescue
delays changed; works reported, burned, transferred and rescued. One function checks all five.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-LIF-11 | A work's state changes only along the table: never minted to in sale; in sale to out of custody, cancelled, sold, unsold or rescued; out of custody back to in sale; the rest are final. | `invariant_streamStatesFollowTheTables` | every action |
| INV-LIF-12 | A recorded outcome never changes. | `invariant_streamStatesFollowTheTables` | every action |
| INV-LIF-13 | A minter's state changes only along the table: never added to pending or active; pending to active or removed; active to removed; removed to pending or active; a change that would change nothing is refused. | `invariant_streamStatesFollowTheTables` | add and remove a minter |
| INV-LIF-14 | An added minter is active from the time it was given when added, whatever the module delay becomes. | `invariant_streamStatesFollowTheTables` | add a minter, change the module delay, warp |
| INV-LIF-15 | A report, burn or rescue goes through exactly when the rules allow it: a minter, active or removed, that holds a token with no outcome reports once or burns; the network rescues only a token a removed minter holds unsold, once the rescue delay, as it stands, has passed since the removal. | `invariant_streamStatesFollowTheTables` | `rescue`, report, burn, change the rescue delay |

Non-vacuity: `StreamStatesInvariantTest.test_EveryTransitionIsReached`.

## Campaign settings

Every campaign runs with `[profile.default.invariant]` in [`foundry.toml`](../../foundry.toml):
`runs = 256`, `depth = 128` calls per run, `fail_on_revert = true`, `show_metrics = true`.
Fuzz tests run 256 times (`[profile.default.fuzz] runs`). Two `/// forge-config:` comments under
`test/` change fuzz runs: `testFuzz_Clear_MatchesTheBruteForceOverUnits` runs 10,000 times, and
`testFuzz_Settlement_EqualsTheLibraryClearing` 10,000 under the `deep` profile. The four Forge
runners of the Medusa harnesses ([below](#the-second-fuzzers-harnesses-under-forge)) run 64
times at depth 64 (256 at depth 128 under `deep`); no other comment changes an invariant
campaign's runs or depth. Three campaigns check their invariant after every
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

The RECORDS module `WorkRules`, the mint policy and the delivery contracts. The lifecycle
campaign runs all three on the deployed stack (INV-LIF-4 to INV-LIF-6). The invariants below are
those of the campaigns on the earlier contracts; no stateful campaign checks them as stated,
and each becomes a row when its test exists.

### Work powers

No stateful campaign; unit and fuzz tests in `test/records/WorkRules*.t.sol`.

- INV-STR-12: A work's renounced mask only gains bits: it equals the OR of every applied renunciation and keeps every bit it held at the previous check.
- INV-STR-13: No renounced power's function succeeds again, every call the rules allow succeeds, and the rate and license are the ones the handler applied.
- INV-STR-14: A work's royalty rate stays at most 100,000 and never moves once its royalty power is renounced.

### The mint policy

No stateful campaign runs a mint policy that answers arbitrarily. With the real package
registry as the policy, INV-LIF-4 checks one live work per content hash, and INV-CUR-4 the
registry's content record.

- INV-STR-15: MP-1 ([AUC-38](../spec/stream-and-auctions.md#rules-and-invariants)): whatever the mint policy answers, no existing token's views change, and each stays held by the adapter that minted it.
- INV-STR-16: No content mints twice ([AUC-44](../spec/stream-and-auctions.md#rules-and-invariants)): whatever the mint policy answers, Stream's content record (`consumedItemOf`) names the item of the one token that minted each content hash, and no second mint of a content hash succeeds.

### Work records under replaced delivery contracts and stores

No stateful campaign replaces a delivery contract or a store. INV-CORE-11, INV-LIF-5 and
INV-LIF-6 check that a work's facts and pinned renderer hold while the RENDERER module is
swapped; no campaign compares `tokenURI` output.

- INV-STR-17: A complete, finalized work's `tokenURI` never changes.
- INV-STR-18: A complete work's facts (record, media, license, rate, powers, pin, completeness and each file's store) never change.

### Delivery contracts

INV-LIF-5 checks that locators only append, within the quotas, on one delivery contract. No
stateful campaign marks a locator dead, reads the preferred locator or installs a successor.

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
`AuctionHandler` in the same file. The real `EnglishAuction` on the real `Stream6529` and
`StreamDirectory6529` (`AuctionFixture`), with the real split ledger, escrow, asset allowlist and
economics resolver; a stand-in mint policy, Independent Stream policy, Independent Stream token and
statement log. The handler starts curated and Independent Stream sales with and without a bid, bids,
moves the clock, settles, refuses settlement, restarts, claims, expires credits, pauses for a
dispute, withdraws, cancels and changes the unclaimed period, and keeps a model of every credit's
money with the time each part arrived.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-AUC-1 | The auction's ETH balance equals its standing high bids plus every account's credits. | `invariant_BalanceIsStandingBidsPlusCredits` | all |
| INV-AUC-14 | `expireCredit` never sends the network money that has waited less than the unclaimed period in force when the expiry is attempted, whatever credits arrived meanwhile and whatever the period was set to. | `invariant_NeverTakesMoneyYoungerThanThePeriod` | `expire`, `setPeriod`, `bid`, `cancel`, `withdraw` |

The rest of the earlier campaign has no stateful campaign as stated (each becomes a row when
its test exists). On the deployed stack the lifecycle and state campaigns check a sale's custody
and single outcome (INV-AUC-3: INV-LIF-1, INV-LIF-3, INV-LIF-11, INV-LIF-12), the museum
(INV-LIF-10) and, inside the handler, that a second dispute pause is refused; the money's path
to the seller and the network, the minimum bid, liquidation and Independent Stream sales on a
hostile token are unit and integration tests only.

- INV-AUC-2: Every unit deposited as a bid is held by the auction, paid to the seller or network wallet, credited to one of them in the escrow, or claimed.
- INV-AUC-3: Each sale has at most one outcome and exact custody: a cancelled sale's token is burned, with no bidder; a settled sale holds its token only while delivery is pending (base suite: marked primary-settled); an open sale holds it.
- INV-AUC-4: Each sale keeps its token and token ID (even after a withdrawal), a live sale names its high bid's recipient, and `minimumBid` is `max(openingBid, the withdrawn bid kept as reserve, 1)` with no bidder, else the bid plus `max(ceil(bid × share / 100,000), floor)`.
- INV-AUC-5: Every sale, ended or not, keeps in storage the seller and fee share written at its start, whatever governance changed (read from storage, layout cross-checked against the view); the opening bid, increment share, increment floor and anti-snipe window are not stored per sale and are read when a bid is placed (AUC-15).
- INV-AUC-6: After 30 days, settling every sale and claiming every delivery and credit leaves no funds and no token, with every deposit accounted for.
- INV-AUC-7: Once the token stops blocking, every sale ends settled or cancelled, leaving no funds and no token.
- INV-AUC-8: A bid extends the end to at least `now` plus the governed window in force at that bid; settlement delivers the token (or leaves it pending) to the high bid's recipient, or the museum if none; a second dispute pause reverts (`PauseExhausted`); a withdrawal leaves the sale paused; the network's `resume` lands at any moment of the pause.
- INV-AUC-9: An unended sale refuses `settle`; settlement after the end delivers or leaves a pending delivery.
- INV-AUC-10: With hostile tokens, the auction's balance equals the actors' credits plus the live high bids, and every deposited bid is held, claimed, or paid to the seller, the network or the escrow for them.
- INV-AUC-11: The network receives exactly the fee on every sold sale (the listed terms, or for an
  Independent Stream sale the registry's share locked at start), paid to the recipient current at
  settlement, and nothing on a refused, rescued or unsold one.
- INV-AUC-12: From any state the campaign reaches, once 2 days have passed after each sale's end,
  `settleOrRefund` brings every unsettled Independent Stream sale to SETTLED whatever its token
  does, and `settle` the stand-in's, leaving no standing bid, with INV-AUC-10, INV-AUC-11 and
  INV-AUC-13 still holding.
- INV-AUC-13: A bidder holds a sale's work, by the token's own ledger, only if that sale is SETTLED with it as the winning bidder, so it paid, and the network's fee on it is counted in INV-AUC-11.

## Edition sales

The edition auction runs on mocks in the unit suites; its campaign on the deployed stack is below.

## The edition auction on the whole stack

[`EditionAuctionInvariant.t.sol`](../../test/integration/invariant/EditionAuctionInvariant.t.sol),
handler [`EditionAuctionHandler`](../../test/integration/invariant/EditionAuctionHandler.sol).
The stack `script/DeployCore.sol` deploys with the committed genesis: the real
`StreamEditions6529`, the uniform-price edition auction and its lens, each sale beside its
master's 1/1 in the real English auction. Six masters by one artist with creator caps of none,
none, 4, none, 6 and 2; five edition bidders, two 1/1 collectors, two keepers and a settler
that submits bad orders. Clearing is compared with the per-unit brute-force reference
[`UniformClearingReference`](../../test/helpers/UniformClearingReference.sol). One function
asserts the state after every fourth call (`check_interval = 4`; every call in the `deep`
profile); a handler check fails the campaign through the same function.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-EA-1 | No unsold or extra copies: an edition's minted supply equals the units its claims minted, never exceeds the clearing count `k`, and equals `k` once every winning bid is claimed; the units every bid wins sum to `k`; the edition is sealed at `k` by the clearing, at zero when the sale is void, and holds the creator's cap until then. | `invariant_editionAuction` | `open`, `settle`, `claim` |
| INV-EA-2 | ETH conservation: the auction's balance is what bidders paid in minus refunds, revenue and credits paid out, and equals exactly what it owes: every unclaimed bid's escrow, less its won units at the clearing price once settled, plus the credits. | `invariant_editionAuction` | all |
| INV-EA-3 | Clearing optimality and the breadth rule: before settlement the live count, price and best revenue equal the per-unit reference's; at settlement the stored count and price equal it too, and the revenue is within the margin of the best revenue. | `invariant_editionAuction`; handler check: `settle` | `bid`, `raise`, `settle` |
| INV-EA-4 | The cap: the count never exceeds a nonzero creator cap. | `invariant_editionAuction`; handler check: `settle` | `bid`, `fifoHole`, `settle` |
| INV-EA-5 | FIFO at the cut step: every claim mints exactly the reference's fill in arrival order of the units the clearing step sells, the marginal bid partly, and `bidOutcome` agrees with the claim; `settlementOrder` equals the departure order the handler sorts, and the sweep completes. | handler check: `claim`, `settle`; `invariant_editionAuction` | `fifoHole`, `raise`, `settle`, `claim` |
| INV-EA-6 | The view equals settlement: the last live `clearing` before settling is the stored result, and the stored result never changes afterwards. | handler check: `settle`; `invariant_editionAuction` | `settle` |
| INV-EA-7 | The clocks: `endTimes` reads the 1/1's end live, `closeAt` is that end plus 15 minutes, `endTime = max(closeAt, softEnd)` never before `closeAt` and never past the backstop, the soft end is the handler's model (a bid or raise in the window, none while the 1/1 is paused), and bidding is open exactly when the rules say. | `invariant_editionAuction` | `bid`, `raise`, `bidOneOfOne`, `disputePause`, `warp` |
| INV-EA-8 | No settlement before the end or before the 1/1 settles; a cancelled 1/1's sale refuses a bid once the auction reads the cancellation (LIM-EA-16 has the rest) and settles VOID; `abandon` goes through exactly from 21 days after the close for a sale that paid nothing whose 1/1 was cancelled. | handler check: `settle`, `abandon` | `settle`, `abandon`, `resolveDispute` |
| INV-EA-9 | A void sale refunds every bid in full, mints nothing and seals its edition at zero. | `invariant_editionAuction`; handler check: `claim` | `resolveDispute`, `settle`, `abandon`, `claim` |
| INV-EA-10 | Firm bids and single claims: a withdrawal at any time (also during a 1/1 dispute pause), a stranger's raise, a payment one wei off, a late or second open and a second claim are all refused. | handler check: `withdraw`, `raise`, `bid`, `open`, `claim` | as named |
| INV-EA-11 | Beside the 1/1: a 1/1 bid in its anti-snipe window extends the 1/1 and never moves the edition end earlier; an unbid 1/1 settles to the museum. | handler check: `bidOneOfOne`, `settleOneOfOne` | as named |
| INV-EA-12 | Per-settler sweeps and completability: a settler's call moves only its own progress (`sweepOf`); an order that skips a departure is accepted but never finishes its sender's sweep; a reordered one reverts with `InvalidSettlementOrder`; after any of these, a keeper settling from its own address completes settlement, and a later call by another settler returns true. | handler check: `settle` | `fifoHole`, `raise`, `settle` |
| INV-EA-13 | No claim while SETTLING: while a sale's scan or sweep is unfinished, its bidder's claim and a pushed claim both revert with `InvalidAuctionState`. A book wider than one call's scan (24 words) settles over calls: the first stores scan progress and no result, and does not seal the edition. | handler check: `settle` | `wideBook`, `settle` |

Non-vacuity: `EditionAuctionInvariantTest.test_EveryActionRuns`.

Not in this campaign, and unit and integration tests only: an edition sale whose 1/1 is offered
again (EA-17), `abandon` for a 1/1 that gives no usable answer, and the expiry of an unclaimed
credit.

## Identity and recovery

[`Accounts.invariant.t.sol`](../../test/identity/Accounts.invariant.t.sol), handler
`AccountsHandler` in the same file. Real `Accounts` and `ConsolidationAdapter` with the
identity fixture's mocks. The handler stages own changes and replacements, freezes and
unfreezes, consolidates and unconsolidates wallets, and signs with the account's wallets and with
outsiders.

| ID | Invariant | Test | Handler actions |
| --- | --- | --- | --- |
| INV-ID-1 | `requireSigned` passes exactly for the account's wallets (the root, or a wallet the source says is consolidated with it), never for an outsider and never while the account is frozen ([ID-2, ID-3](../spec/identity-and-recovery.md#rules-and-invariants)). | `invariant_RequireSignedPassesExactlyForTheAccountsWallets` | as named in the handler |
| INV-ID-14 | A module that replaces another, and has not recorded the account, answers for it as the replaced module does: the same wallets pass `requireSigned`, the same root, acting root, payout address and freeze, and every address that is or was a root names the account in both ([ID-42](../spec/identity-and-recovery.md#rules-and-invariants)). | `invariant_ASuccessorAnswersAsTheModuleItReplaces` | the same handler, driving the replaced module |

The earlier identity campaign (INV-ID-2 to INV-ID-13: the restraint flag, activity and nonces,
reservations, past authorities, the standing snapshot, timers, the Independent Stream directory with
LEFT, and the source acting only for dormant artists) left with that machinery in the second
permanence pass; the contest, replacement and freeze rules are unit-tested in
`ArtistRegistry.t.sol` (`test_Contest_*`) and the
directory in `IndependentStreamDirectory.t.sol`.

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

## Independent Stream sales

An Independent Stream pair's tokens run the core campaigns
([The permanent core](#the-permanent-core)). The English auction campaign starts Independent
Stream sales on a stand-in token, so INV-AUC-1 covers the balance of INV-FSA-1. No stateful
campaign checks the others (each becomes a row when its test exists); integration tests cover
a pair's sales on the deployed stack
([`IndependentPair.t.sol`](../../test/integration/IndependentPair.t.sol),
[`IndependentEditionSale.t.sol`](../../test/integration/IndependentEditionSale.t.sol)).

- INV-FSA-1: The auction's ETH balance equals every bidder's claimable credit plus the high bid of every unsettled sale.
- INV-FSA-2: The network fee recipient receives exactly its locked share on every sold Independent
  Stream sale, and nothing otherwise.
- INV-FSA-3: A person holds an Independent Stream work only if its sale is SOLD, and then it is the
  bidder who paid.
- INV-FSA-4: Independent Stream never touches 6529 Stream (its supply and the curated token's owner)
  or a curated artist's identity.
- INV-FSA-5: Every sale ends: after each is refused, the auction owes only credits, and INV-FSA-1 and INV-FSA-2 still hold.

## The second fuzzer's harnesses under Forge

The four Medusa harnesses in [`test/medusa/`](../../test/medusa) share no code with the handlers
above and keep their own model of the rules ([Testing](../testing/README.md#second-fuzzer-medusa)).
Forge runs each as a campaign too: `invariant_MedusaPropertiesHold` in `LedgerMedusaTest`,
`StreamCoreMedusaTest`, `WorkFactsMedusaTest` and `LogMedusaTest` asserts every `property_*`
function of its harness, at 64 runs of depth 64. They carry no ID of their own here; the
properties restate INV-ECO, INV-CORE and INV-DSP rows against a second model. Non-vacuity:
`test_HarnessActionsReachState` in each.

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
| INV-STR-1 to INV-STR-8 | Stream and work records on the old `Stream6529` and `WorkRecords` | Replaced by INV-CORE-1 to INV-CORE-6 and INV-CORE-11 ([ADR 0010](../adr/0010-plain-permanent-core.md)) |
| INV-ED-1 to INV-ED-6 | The old `StreamEditions6529` contract | Replaced by INV-CORE-8 to INV-CORE-10 |
| INV-IND-1 to INV-IND-6 | The old Independent Stream templates | The Independent Stream tokens run the core code: INV-CORE-1 to INV-CORE-10 |

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
| PROP-AUC-1 | A settlement splits the price exactly between seller and network: the seller's part is its share rounded down and the fee is the remainder (the exact fee rounded up, by less than 1 wei). The bid step is the `mulDiv` ceiling, and the increment the larger of the share and the floor. | [`EnglishAuction.t.sol`](../../test/sales/auction/EnglishAuction.t.sol) `testFuzz_Settle_TheSellersPartRoundsDown`, `testFuzz_Bid_IncrementRule` |
| PROP-EA-1 | On random books of bids and raises, capped and uncapped, under four margins, the edition auction's live clearing, every bid's outcome and the settlement order equal a brute-force per-unit reference, and settling and claiming every bid mints exactly the count and leaves the adapter empty; other settlers' skipped, partial and reversed sweeps never block the keeper or change an outcome. | [`EditionAuctionDifferential.t.sol`](../../test/integration/EditionAuctionDifferential.t.sol) `testFuzz_Clearing_EqualsTheBruteForceReference`, `test_Differential_ReachesARationedSweepWithDepartures` |
| PROP-EA-2 | The step ladder rises strictly and nests for every allowed steps-per-decade and base price. | [`StepLadder.t.sol`](../../test/interfaces/StepLadder.t.sol) `testFuzz_DecadesAndSteps`, `test_EveryLadderRisesAndNests` |
| PROP-STR-1 | The royalty receiver is the factory's wallet, the amount matches `mulDiv`, and `royaltyInfo` never returns zero for lack of gas. | [`StreamCorePolicyPorted.t.sol`](../../test/integration/StreamCorePolicyPorted.t.sol) `test_Mint_LogsTheFactsThePackageAndTheEconomicsDerive`; [`Editions.t.sol`](../../test/core/Editions.t.sol) `testFuzz_RoyaltyInfo_ExactForAnyPrice`; [`RoyaltyInfoGas.t.sol`](../../test/integration/RoyaltyInfoGas.t.sol) `test_RoyaltyInfo_FitsItsGasBudgetCold`, `test_RoyaltyInfo_RevertsWithTooLittleGasAndNeverAnswersZero` |

### Single use, uniqueness and authorization

| ID | Property | Test |
| --- | --- | --- |
| PROP-CUR-1 | An item consumes once, even across packages that list it, uniqueness keys on the declared content hash, and an item outside the package is refused. | [`PackageRegistry.t.sol`](../../test/curation/PackageRegistry.t.sol) `test_consume_revertsDoubleConsume`, `test_consume_itemIsSingleUseAcrossPackages`, `test_consume_contentUniquenessKeysOnContentHash`, `test_consume_revertsItemNotInPackage` |
| PROP-CUR-2 | Merkle proofs verify, a foreign item is rejected, and revoking one move nonce leaves the others untouched. | `PackageRegistry.t.sol` `testFuzz_merkle_proofs`, `testFuzz_merkle_foreignItemRejected`, `testFuzz_revokeMove_bitmapIsolation` |
| PROP-CUR-3 | Only active signers' attestations count, and arbitrary signature bytes are never approved. | [`Eip712CurationVerifier.t.sol`](../../test/curation/Eip712CurationVerifier.t.sol) `testFuzz_isApproved_onlyActiveSignersCount`, `testFuzz_isApproved_neverRevertsOnGarbage` |
| PROP-ED-1 | An edition never mints beyond its creator's cap, and the edition auction's `open` refuses a tampered item. | [`Editions.t.sol`](../../test/core/Editions.t.sol) `testFuzz_Mint_NeverPassesTheMaximum`; [`UniformEditionAuction.t.sol`](../../test/sales/edition/UniformEditionAuction.t.sol) `test_Open_ChecksTheItem`; [`EditionAuction.t.sol`](../../test/integration/EditionAuction.t.sol) `test_EditionAuction_OpenChecksTheMaster` |
| PROP-ENT-1 | The first of many deliveries wins, only the coordinator delivers, an unissued request ID never delivers, and non-VRF items and items outside an approved package are always refused. | [`VrfEntropyFuzz.t.sol`](../../test/entropy/VrfEntropyFuzz.t.sol) `testFuzz_TheFirstDeliveryOfManyRequestsWins`, `testFuzz_OnlyTheCoordinatorMayFulfill`, `testFuzz_UnissuedRequestIdsNeverDeliver`, `testFuzz_NonVrfItemsAreAlwaysRefused`, `testFuzz_OnlyItemsOfAnApprovedPackageCanBeRequested` |
| PROP-GV-8 | Only the network holds a network role, for any account and network role. | [`NetworkAndBrake.t.sol`](../../test/governance/NetworkAndBrake.t.sol) `testFuzz_OnlyTheNetworkHoldsTheNetworkRoles` |
| PROP-GV-2 | A raise-only parameter moves by at most 2× per step and never above its ceiling, for any sequence of raises. | [`BoundedParameter.t.sol`](../../test/governance/BoundedParameter.t.sol) `testFuzz_RaiseMatchesSpecification`, `testFuzz_RaiseSequenceStaysBounded` |
| PROP-GV-3 | Only genesis selectors pass wiring validation. | [`GenesisWiringPorted.t.sol`](../../test/governance/GenesisWiringPorted.t.sol) `testFuzz_OnlyGenesisSelectorsPassValidation`, `test_GenesisSelectorsAreExactlyTheAllowList` |
| PROP-ID-1 | The value rules hold for any input: a royalty rate up to 100,000 rises or falls with agreement; a fee share only ever falls; an Independent Stream share in force never exceeds the deployed share; every release path pays the network its share; a mark never takes money that arrived after it; every edition sale closes 15 minutes after its 1/1. | ; `Stream.t.sol` ; ; [`NetworkShare.t.sol`](../../test/economics/NetworkShare.t.sol) `testFuzz_EveryReleasePathPaysTheNetwork`, `testFuzz_AMarkNeverTakesLaterMoney`; [`UniformEditionAuctionWindow.t.sol`](../../test/sales/edition/UniformEditionAuctionWindow.t.sol) `testFuzz_Window_TheCloseIsTheOneOfOneEndPlusFifteenMinutes` |
| PROP-DSP-1 | Any append sequence matches the model, relays round-trip and never replay, and the nonce bitmap tracks exactly the spent nonces. | [`StatementLog.t.sol`](../../test/records/StatementLog.t.sol) `testFuzz_SequenceMatchesModel`, `testFuzz_RelayRoundTripAndReplay`, `testFuzz_NonceBitmapTracksExactlyTheSpentNonces` |
| PROP-HASH-1 | The item hash binds the collection and the shares and does not depend on the chain. | [`WorksHashing.t.sol`](../../test/interfaces/WorksHashing.t.sol) `testFuzz_itemHash_bindsCollection`, `testFuzz_itemHash_bindsShares`, `testFuzz_itemHash_independentOfChain` |
| PROP-STR-2 | Retired: Stream holds no dependencies and no artist registry. | none |
| PROP-STR-3 | `tokenURI` never falls back to another renderer: a finalized work uses its pin, an unfinalized one the RENDERER module, and a fault or shortfall reverts ([AUC-42](../spec/stream-and-auctions.md#rules-and-invariants)). | [`Stream.t.sol`](../../test/core/Stream.t.sol) `test_RendererOf_PinnedThenModuleThenNone`; [`StreamCorePolicyPorted.t.sol`](../../test/integration/StreamCorePolicyPorted.t.sol) `test_RendererOf_AFailingReadFailsClosed`, `test_RendererOf_ShortGasNeverServesAnotherRenderer`; [`StreamHostile.t.sol`](../../test/core/StreamHostile.t.sol) `test_Hostile_AsRenderer` |
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
| PROP-GAS-1 | Every steady-state start row, with and without a bid (one and two parties, a VRF work, an edition master, an artist's first work, the first work in a new collection), costs at most 370,000 Prague gas (`START_BUDGET` in `CoreIntegrationBase.sol`); a start with a bid of a VRF work, which also writes the seed, at most 395,000 (`VRF_START_BUDGET`). The deployment's first start ever, the auction's first bid and `SaleStarter.start` have regression ceilings of their own (`FIRST_START_CEILING`, `FIRST_BID_CEILING`, `STARTER_CEILING` in `GasReport.t.sol`). | [`GasReport.t.sol`](../../test/integration/GasReport.t.sol) `test_Gas_Start_SteadyState`, `test_Gas_StartWithBid_TwoPartyWork`, `test_Gas_Start_VrfWork`, `test_Gas_StartWithBid_VrfWork`, `test_Gas_Start_EditionMaster`, `test_Gas_StartWithBid_ArtistsFirstWork_TwoParty_Vrf_MaxParams`, `test_Gas_Start_FirstWorkInANewCollection`, `test_Gas_Start_FirstWorkEver`, `test_Gas_StartWithBid_FirstBid`, `test_Gas_SaleStarter_Start` |
| PROP-GAS-2 | Every measured operation creates exactly its stated number of new storage slots and accounts; every start row writes at most 8 new slots, with or without a bid (`START_MAX_SLOTS`); a start with a bid of a VRF work at most 9 (`VRF_START_MAX_SLOTS`). | every `test_Gas_*` in |
| PROP-GAS-3 | Every other measured operation stays under its Prague test ceiling or regression ceiling. | every `test_Gas_*` in |
| PROP-GAS-4 | The harness's cold-account correction is exact (a `start` from a fully cold state equals the corrected figure after warming every account), adds nothing for accounts already cold, and refuses storage it does not cool. | [`GasHarness.t.sol`](../../test/integration/GasHarness.t.sol) `test_GasHarness_TheColdAccountCorrectionIsExact`, `test_GasHarness_NothingIsAddedForAccountsAlreadyCold`, `test_GasHarness_RequireCooledRefusesStorageItDoesNotCool` |
| PROP-GAS-5 | The state-growth counter counts a slot once, ignores overwrites, zero-to-zero, reverted writes, out-of-gas and `INVALID` frames and transient storage, and counts `CREATE` and ETH sent to a fresh account or an empty precompile as new accounts. | [`StateGrowth.t.sol`](../../test/helpers/StateGrowth.t.sol) (24 tests, among them `test_OneNewSlot`, `test_ZeroToZeroIsNotNew`, `test_WriteInARevertedCallIsNotNew`, `test_WriteInAFrameThatRanOutOfGasIsNotNew`, `test_WriteInAFrameThatHitInvalidIsNotNew`, `test_TransientStorageIsNeverASlot`, `test_CreateIsANewAccountWithItsSlots`, `test_EthToAnEmptyPrecompileIsANewAccount`) |
| PROP-GAS-6 | With every record, media and locator cap filled on the real stack, Stream's `tokenURI` and Editions' `uri` cost at most 8M Prague gas (`TOKEN_URI_BUDGET`) and create no state. | `test_Budget_*`; ; [`RendererGas.t.sol`](../../test/content/renderer/RendererGas.t.sol) `RendererGasTest`, `RendererGasBudgetTest` |
| PROP-GAS-7 | Worst-case bounded inputs fit the EIP-7825 cap of 16,777,216 gas in Prague gas, intrinsic and calldata included: claim batches and the largest payee list; mint, `openRecord`, relicense with 16 consents, the longest locator, the preferred-locator scan and `syncOnChain`; `consume` and `registerPackage`; `createEdition`; every `settle` call of the edition auction's worst cases (every step of the widest ladder used, the cap binding at step 0, the longest departure sweep); settlement with every fallback; manifest registration and attestation at `MAX_CHUNKS`; genesis `configure`. | [`GasCap.t.sol`](../../test/economics/GasCap.t.sol), [`PackageRegistryGas.t.sol`](../../test/curation/PackageRegistryGas.t.sol), `Editions.t.sol` [`EnglishAuctionHostile.t.sol`](../../test/sales/auction/EnglishAuctionHostile.t.sol) `ContentStore.t.sol` `test_RegisterManifest_OneCallOf512FitsTheTransactionGasCap`, `Base64Attest.t.sol` `test_Attest_AtMaxChunksEveryCallFitsTheTransactionGasCap` |
| PROP-GAS-8 | The VRF callback creates no storage slot and, repriced as ADR 0004 models Glamsterdam, uses at most half of `MIN_CALLBACK_GAS` (100,000). | [`VrfEntropyModule.t.sol`](../../test/entropy/VrfEntropyModule.t.sol) `test_Callback_UsesUnderHalfTheFloorUnderGlamsterdam` |

## Gaps

What no stateful campaign covers today. Coverage, mutation testing and Halmos proofs are in
[Testing](../testing/README.md).

- **Invariants of the earlier campaigns.** Listed under their areas as "no stateful campaign":
  the core's log replay, settings and hostile modules (INV-CORE-7, INV-CORE-14 to INV-CORE-16;
  campaigns cover INV-CORE-14 and INV-CORE-15 in part); the work powers, an arbitrary mint
  policy, and replaced delivery contracts and stores (INV-STR-12 to INV-STR-18, INV-WD-1 to
  INV-WD-4); the English auction beyond its balance, its credits' age and what the
  deployed-stack campaigns check (INV-AUC-2 to INV-AUC-13); Independent Stream sales (INV-FSA-2
  to INV-FSA-5).
- **Edition sales outside the curated stack.** The edition campaign runs the curated pair. An
  Independent Stream pair's edition auction, a sale whose 1/1 is offered again and the expiry
  of an edition credit have unit and integration tests only.
- **Money past the auctions.** No campaign on the deployed stack follows a settlement's
  proceeds through the split vaults and the escrow; the economics campaign (INV-ECO-1 to
  INV-ECO-14) runs the ledger, vaults and escrow with a payment harness in place of the sales.
- **Stand-ins in the core campaigns.** The Stream, Editions and WorkFacts campaigns run the
  real permanent contracts with stand-in modules; the deployed-stack campaigns run the genesis
  modules, with a stand-in second minter and renderer, and never a hostile module.
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
