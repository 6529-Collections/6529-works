# Economics and payouts

Who is paid, and how: the network's share of primary sales and royalties, the split vaults that
divide money among payees, signed and batched releases, and the escrow that holds a payment a
wallet could not receive. Money already owed is held by permanent code: the split ledger, its
vaults and the escrow. The policies that decide new terms are replaceable modules.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| [`SplitLedger`](../../src/economics/SplitLedger.sol) | permanent, unowned | Deploys split vaults, tracks each payee's entitlement, releases, signed releases, marks and forfeits. Its payout resolver is `Directory`. |
| [`SplitVault`](../../src/economics/SplitVault.sol) | permanent (one per payee list) | 66 bytes: accepts ETH from anyone and moves funds only on its ledger's instruction. |
| [`RevenueEscrow`](../../src/economics/RevenueEscrow.sol) | permanent | Holds credits for refused payments; anyone flushes a credit to its wallet; `locked()` says whether it is mid-call. |
| [`Directory`](../../src/core/Directory.sol) | permanent | Answers artists' payout addresses (from the accounts module) and holds `unclaimedPeriod`. |
| [`GovernedVault`](../../src/economics/GovernedVault.sol) | permanent | The network fee recipient and the museum as contracts: move what they hold only to a destination the network sets. |
| `StreamTerms` ([`ITerms`](../../src/interfaces/core/ITerms.sol)) | module (TERMS) | Sets a token's royalty receiver and rate, locks the rate, lowers the network's fee share. |
| [`EconomicsResolver`](../../src/economics/EconomicsResolver.sol) | module | Per-product fee recipient, fee share, royalty rate, default license, the museum. |
| [`AssetAllowlist`](../../src/economics/AssetAllowlist.sol) | module | ETH's opening bid and increment floor for the auction. |
| [`ClaimRouter`](../../src/economics/ClaimRouter.sol) | module | Stateless batch claims across vaults. |

## Launch terms

Rates and shares are out of 100,000, so the 6.529% royalty is exactly 6,529.

| Product | Network fee share at launch | Royalty rate |
| --- | --- | --- |
| 6529 Stream | 25,000 (25%) | 6,529 |
| 6529 Stream Editions | 25,000 (25%) | 6,529 |
| Federated | 10,000 (10%), recorded per token at listing, only lowered | 6,529 |

These are values of the replaceable resolver; a change applies to new works only.

## Flows

- **A primary sale.** The sale contract pays the seller (the split vault of the item's payees)
  and the network's share. A refused payout goes to the escrow, credited to that wallet.
- **Royalties.** Each token stores its royalty receiver and rate. The receiver at mint is the
  vault of `Splits.royaltyPayees(seller, feeRecipient, feeShare)` (salt zero), or the seller at a
  zero share. Marketplaces pay that vault directly.
### Payee lists, wallets and the split ledger

A payee list is canonical: 1 to 64 entries, sorted by `(artistId, account)`, shares summing to
100,000. Its vault's address is a CREATE2 prediction over the ledger, the list and a salt;
anyone deploys it with `createWallet`, and money sent before deployment is split once it exists.

### An artist's signed pull through the claim router

An artist's payout address may sign a `ReleaseAuthorization` that anyone submits, alone or in a
`ClaimRouter` batch; it works once per nonce, only for the vault, chain and ledger it names.

### Wallet payments and the escrow

A payer pays a vault directly, else through the escrow as a credit under that vault; a caller
cannot starve a payment into the escrow.

### Releases

- **Release.** Anyone releases a fixed payee to its own account. An artist-resolved payee is
  released only by the artist's current payout address (asked from `Directory`, which asks the
  accounts module), directly or by signature. If the accounts module is missing or fails, the
  release reverts and the money stays in the vault.
- **Lowering the network's share.** The TERMS module may lower a work's fee share, never raise
  it. It checks that the stated seller, fee recipient and current share give the stored
  receiver, deploys the new vault, then names it on the token and its edition.

## Unclaimed money

`Directory.unclaimedPeriod` is the network's setting (180 days at launch), changed at once, zero
allowed, with old and new in `UnclaimedPeriodSet`. The ledger and the escrow **read it when the
action is attempted**, so a change applies to marks and credits already running. What changes is
only when; the amounts are never more than the money that has itself waited.

- **Split vault share.** Anyone may mark a payee's releasable share. Once the unclaimed period
  in force has passed since the mark, anyone may send the network what of the marked level is
  still unreleased. Money that arrived after the mark is never taken.
- **Escrow credit.** Credits to an account are grouped in windows. A credit with no open
  window opens one; the window takes every credit for one unclaimed period from its first
  credit, and all of it is due one period after its last credit. Money expires only after it
  has itself waited the period, and a window's due time can be at most two periods after its
  first deposit. Anyone may deposit into an open window; that can move the window's due time
  later within that bound and never earlier. A deposit made once an amount has waited the
  period never joins that amount's window, so it cannot move the time that amount is due.
- If reading the period fails, the forfeit or expiry reverts and the money stays.

## Compiled limits

| Limit | Value |
| --- | --- |
| Payees per vault | 1 to 64 |
| Vault code | 66 bytes |
| Batch sizes (claim router) | 50 plain, 20 signed |

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| ECO-1 | Rates and shares are out of 100,000; the launch royalty 6,529 is exactly 6.529%. | `test_RoyaltyRateIsExact`, `test_LaunchDefaults` |
| ECO-2 | A product's fee share is below 100,000, its royalty rate at most 100,000, and a nonzero share names a nonzero recipient. | `test_ConstructorEmitsAndValidates`, `test_SetFeeTermsIsCompareAndSet` |
| ECO-3 | The fee recipient is never the resolver, its dependencies or a recognised protocol contract. | |
| ECO-4 | Every governed economics setter is compare-and-set on its own revision. | `test_SetRoyaltyRateIsCompareAndSetOnItsOwnRevision` |
| ECO-5 | Setters are restricted to their roles and non-payable. | `test_RolesAndDelaysThroughAccessManager`, `check_everyGovernedWrite_needsItsRole` |
| ECO-6 | Economics changes apply to new works only. | `test_ChangesApplyToNewWorksOnly` |
| ECO-7 | The royalty receiver is the salt-zero vault of `Splits.royaltyPayees`, or the seller at a zero share; the policy, the terms module and the resolver derive the same address. | `test_RoyaltyReceiverMatchesTheSharedDerivation`, `test_ZeroFeeShareOmitsTheFeePayee` |
| ECO-8 | A payee list is canonical: 1 to 64 entries, sorted, shares summing to 100,000. | `test_RejectsUnsortedAndDuplicatePayees`, `testFuzz_ValidationAcceptsExactlyCanonicalLists` |
| ECO-9 | A vault's address is the documented CREATE2 derivation; the deployed vault is always at the prediction. | `test_AddressIsTheDocumentedCreate2Derivation`, `testFuzz_PredictionMatchesDeployment` |
| ECO-10 | `createWallet` is permissionless, writes one word and logs the whole list. | `test_AnyoneCreatesAWalletForAnyCanonicalList` |
| ECO-11 | Funds sent to a predicted address before deployment are split once the vault exists. | `test_FundsSentBeforeDeploymentAreSplitAfterwards` |
| ECO-12 | The ledger pins no code hash of its resolver; the resolver must have code at deployment. | `test_CreateWalletIgnoresTheResolversCodeHash` |
| ECO-13 | A payee's releases never exceed its entitlement; dust stays below the payee count. | `invariant_ReleasedWithinEntitlement`, `invariant_DustIsBounded` |
| ECO-14 | A vault conserves value. | `invariant_WalletConservesValue` |
| ECO-15 | Anyone releases a fixed payee, only to its own account; a mute payee blocks only its own share. | `test_AnyoneMayReleaseAFixedPayeeButOnlyToItsAccount`, `test_MutePayeeBlocksOnlyItsOwnShare` |
| ECO-16 | Only an artist's current payout address releases an artist-resolved payee. | `test_ArtistPayeeIsPullOnly`, `test_ArtistPayeeFollowsResolverAtReleaseTime` |
| ECO-17 | `releaseTo` is callable only by the payee's current payout address; no release pays zero, the vault or the ledger. | `test_ReleaseToRequiresTheCurrentPayoutAddress` |
| ECO-18 | While the payout is unresolved, only the artist-resolved payees stop. | `test_UnresolvedOrFailingResolverBlocksOnlyTheArtistPayee` |
| ECO-19 | A split vault and protocol contracts that cannot pull never become a payout address. | `test_NestedWalletCannotBeAnArtistPayoutAddress` |
| ECO-20 | A signed release works once per nonce, only in the vault, chain and ledger it names, before its deadline. | `test_ReplayAndRevokedNoncesRevert`, `test_ExpiredAuthorizationReverts` |
| ECO-21 | Replay protection is keyed on the nonce; one revocation covers every vault. | `test_ReplayIsKeyedOnTheNonceNotTheSignatureBytes`, `test_OneRevocationCoversEveryWallet` |
| ECO-22 | A failed signed release keeps its nonce. | `test_FailedPaymentRollsBackNonce` |
| ECO-23 | Every ERC-20 move in the ledger and escrow changes both balances by exactly the amount. | `test_FeeOnTransfer_EscrowDepositReverts`, `test_NoReturn_ReleasePaysEachPayeeInFull` |
| ECO-24 | An ERC-20 whose balance shrinks below the recorded mark freezes that asset's releases without loss. | `test_ShrinkingBalanceFailsClosedUntilRecovered` |
| ECO-25 | Withdrawals never read the allowlist. | `test_NeverAdmittedAssetsStayWithdrawable` |
| ECO-26 | A payment reaches the vault or a credit under it, never anywhere else. | `test_PayETHGoesStraightToTheWallet`, `test_PayETHFallsBackToEscrowWhenRefused`, `test_CallerCannotStarveETHPaymentIntoEscrow` |
| ECO-27 | The escrow is solvent per asset; a flush pays only the credited wallet. | `invariant_EscrowIsSolventAndMatchesTheModel`, `check_flush_paysOnlyTheCreditedWallet` |
| ECO-28 | `recover` moves a vault's credit only to an equivalent vault, and the network's own credit anywhere but zero, the escrow or itself. | `test_RecoverMovesCreditsToAnEquivalentReplacement`, `test_TheNetworkCannotMoveAnotherAccountsCredit` |
| ECO-29 | The claim router keeps no funds and cannot redirect a release. | `invariant_IntermediariesHoldNothing` |
| ECO-30 | Batches are bounded. | `test_BatchesUpToMaxClaimsAndRejectsMore` |
| ECO-31 | The worst-case batches and the 64-payee vault deployment fit the transaction gas cap. | `test_WorstCaseAtomicClaimBatchFitsTheCap`, `test_MaximumWalletDeploymentFitsTheCap` |
| ECO-32 | Retired: the auction is ETH only; no asset admission. | |
| ECO-33 | Retired: no asset deprecation or readmission. | |
| ECO-34 | Retired: no default currency. | |
| ECO-35 | A CC0 default license names the CC0 text the resolver was deployed with. | `test_ACc0DefaultLicenseNamesThePinnedText` |
| ECO-36 | Retired: no ERC-20 settlement payouts. | |
| ECO-37 | The museum is set at deployment, never zero or a protocol contract; changed by the network compare-and-set. | `test_Museum_SetAtDeployment`, `test_SetMuseum_IsCompareAndSet` |
| ECO-38 | ETH is always active: no function deprecates it, and no other asset can be admitted. | `test_NoOtherAssetCanBeAdmitted` |
| ECO-39 | A split vault is the 66-byte code and obeys only its ledger. | `test_RuntimeIsTheDocumentedSixtySixBytes`, `check_vault_obeysOnlyItsLedger` |
| ECO-40 | `sweepExcess` moves only what nobody is owed. | `test_SweepExcess_TakesOnlyWhatNobodyIsOwed`, `invariant_EscrowExcessIsExactlyTheUnowed` |
| ECO-41 | A governed vault moves what it holds only to its destination, which only the network changes. | `test_AnyoneForwardsETHToTheDestinationOnly`, `invariant_HoldingsLeaveOnlyToTheDestination` |
| ECO-42 | No compiled gas number in the ledger; a shortfall reverts, never a refusal. | `test_GasRule_ThePushToTheNetworkIsNeverSkippedForGas` |
| ECO-43 | Every release from a vault that names the network fee vault also pays the fee vault its due share. | `test_ReleaseFromARoyaltyWalletAlsoPaysTheFeeVault`, `testFuzz_EveryReleasePathPaysTheNetwork` |
| ECO-44 | Anyone may mark a payee's share; once the unclaimed period in force has passed since the mark, anyone may send the network what of the marked level is still unreleased, never money that arrived later. | `test_AShareClaimedInTimeIsNotForfeited`, `testFuzz_AMarkNeverTakesLaterMoney`, `test_ARunningMarkCannotBeRestarted` |
| ECO-45 | Only the aged part of an escrow credit expires, once the unclaimed period in force has passed since it aged; a later deposit never shortens a clock, and moves a window's due time at most to two periods after the window's first deposit; never the network's own credit. | `test_ExpireRefusals`, `test_AStrangersDepositMovesAWindowsDueTimeByLessThanOnePeriod`, `testFuzz_ExpiryGuaranteesUnderAnyInterleaving`, `test_Credits_EscrowAStreamOfCreditsCannotHoldAWindowOpen` |
| ECO-46 | `unclaimedPeriod` is the network's setting in `Directory` (180 days at launch), changed at once, zero allowed; the ledger and escrow read it when the action is attempted. | `test_UnclaimedPeriod_OneEightyDaysAtDeploymentOnlyTheNetworkSetsIt` |
| ECO-47 | The escrow's `locked()` is true exactly while it is inside a guarded call. | |

## Events

Ledger: `WalletCreated`, releases, marks and forfeits. Escrow: credits, flushes, expiries.
`Directory`: `UnclaimedPeriodSet`. TERMS: `RoyaltySet` on the token, `FeeShareLowered`.
Signatures on the [events page](../integrators/events-and-indexing.md).

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| A payout wallet refuses ETH | Credited in the escrow | Anyone flushes it to the wallet. |
| An artist's account is frozen or changing | The artist's share waits in the vault | It releases once the account is settled. |
| The accounts module is missing or fails | Artist releases revert; money stays | The network installs a module in `Directory`. |
| A payee never claims | The share waits | After the unclaimed period in force, from a mark, anyone may send it to the network. |
