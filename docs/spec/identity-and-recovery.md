# Identity and recovery

Artists act through accounts. An account is a consolidated identity: one artist ID and any
number of wallets, all equal. The accounts module `Accounts` (today's artist registry) answers
who an artist is, which wallets act for it and where it is paid. It is a **replaceable module**
behind the permanent [`StreamDirectory6529`](../../src/core/StreamDirectory6529.sol) (slot
`ACCOUNTS`); the network can replace it after `moduleDelay` (7 days at launch). Tokens keep only an
artist ID.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| `Accounts` ([`IAccounts`](../../src/interfaces/core/IAccounts.sol), [`IArtistRegistry`](../../src/interfaces/IArtistRegistry.sol)) | module (`StreamDirectory6529.ACCOUNTS`) | Accounts, wallets, signatures and consent, own changes, replacements, contests, freezes, payout addresses. |
| [`ConsolidationAdapter`](../../src/identity/ConsolidationAdapter.sol) | module | Answers whether two wallets are consolidated (two-way delegation registrations). |
| [`StreamDirectory6529`](../../src/core/StreamDirectory6529.sol) | permanent | `payoutAddress(artistId)` forwards to the ACCOUNTS module. The split ledger asks it when it releases an artist's share. |

## How accounts work

- **Artist ID.** The `uint160` of the account's first root. Every address that has been a root
  maps to the ID forever (`artistIdOf`). An address that never registered is its own
  single-wallet account.
- **Wallets.** `isWallet(accountId, wallet)` is true for the root and for any wallet the
  consolidation source says is consolidated with it, read live. All wallets are equal: any of
  them signs, cancels or contests. If the source fails, only the root acts.
- **Signatures.** `requireSigned(accountId, digest, proof)` passes only for a wallet of the
  account that signed. `requireConsent(accountId, what, proof)` checks a consent good only for
  the contract that asks; it has no deadline or nonce, and holds until used or until the signing
  wallet leaves the account. Wallets may be contracts (ERC-1271) or EIP-7702 accounts.
- **Payout.** `payoutAddress(artistId)` is where split vaults pay the artist's share. It reads
  zero while the account is frozen or a pending change would move it; the money then stays in
  the vault. A payout that cannot pull is refused when set and again when the change takes
  effect: no contract of the network can call `release` for an artist, so none is accepted
  (the module's wiring, its AccessManager and consolidation source, the contracts listed
  at its deployment, the split ledger's vaults, every contract that declares a protocol
  interface and every contract the AccessManager governs). An account with no code, a smart
  account, a multi-signature wallet and an artist's own split contract outside the network
  are accepted. `isPayoutAllowed(address)` answers the check.
- **Replacing the module.** A new `Accounts` is deployed naming the module it replaces
  (`previous`). It answers every account it has not recorded from that module's record, so
  an account keeps its ID, root, wallets, payout address, freeze and pending change, and the
  address a moved account's ID was made from has no power. It never registers an address the
  replaced module knows. Only the module the directory names changes accounts: one that
  waits for activation and one that has been replaced change nothing. Its first change to an
  inherited account copies the record (`copyAccounts` copies a list), and from then on it
  alone answers for it. See
  [Replacing a module](../operations/replacing-modules.md#accounts-accounts-on-streamdirectory6529).
- **Which works are the artist's.** `isArtist(token, id, account)` reads
  `IStream(token).workOf(id).artistId`, for 6529 Stream and Independent Stream tokens alike.

### The consolidation adapter

`ConsolidationAdapter.isConsolidated(root, wallet)` is true while each of the two holds a live
registration of the other for all collections (delegation use case 999). There is no minimum
age. A read that fails counts as no registration. The delegation contract lets a wallet's
sub-delegate (use case 998) register delegations for it, so an artist who appoints a sub-delegate
gives it the means to add a wallet to the account.

## Change kinds

| Action | Who | Wait (compiled in this module) | Who stops it |
| --- | --- | --- | --- |
| Own change of root or payout | any wallet signs; anyone relays | 2 days | any wallet, or the network, at once |
| Replacement of the root | the network, with the new root's acceptance | 14 days' notice | the network at once; any wallet may contest during the notice |
| Contest of a replacement | any wallet, during the notice | runs only if the network upholds it within 90 days; otherwise it lapses | |
| Freeze | the network, at once | lasts 14 days per placement | the network ends it early |

A freeze stops every wallet, zeroes the payout and holds every pending change. **A freeze blocks
a contest**: no wallet acts while frozen, so a freeze placed with a replacement covers its whole
contest window. **A freeze can be placed again**: the network can end one and place another, or
place a new one when it ends. The network may uphold a contested replacement during a freeze;
the freeze then continues for the new root.

These timers are compiled into the accounts module, which the network can replace; they are not
promises of a permanent contract.

## Rules and invariants

| ID | Rule | Tests |
| --- | --- | --- |
| ID-1 | An artist ID is the `uint160` of its first root, created by the mint policy or, with the wallet's own signature, by the Independent Stream module. | `test_Register_*`, `test_RegisterIndependent_*` |
| ID-2 | A wallet acts for an account exactly when it is the root or consolidated with it; never while frozen or a replacement is pending. | `test_IsWallet_*`, `invariant_RequireSignedPassesExactlyForTheAccountsWallets` |
| ID-3 | `requireSigned` passes only for a wallet of the account that signed; `requireConsent` only for the asking contract. | `test_RequireSigned_*`, `test_RequireConsent_BindsTheCaller` |
| ID-4 | The root never depends on the consolidation source; a failing source is "no" for every other wallet. | `test_Accounts_RootNeverDependsOnTheSource` |
| ID-5 | An own change waits 2 days, is cancelled by any wallet or the network at once, and moves the root only to a wallet of the account. | `test_OwnChange_*`, `test_CancelOwnChange_ByTheNetwork` |
| ID-6 | A replacement is staged only by the network with the new root's acceptance, waits 14 days, and the network may withdraw it at once. | `test_Replacement_*`, `test_CancelReplacement_ByTheNetwork` |
| ID-7 | A wallet contests a replacement only during its notice; a contested replacement runs only if upheld within 90 days, otherwise it lapses. | `test_Contest_*` |
| ID-8 | A freeze lasts 14 days per placement, stops every wallet, zeroes the payout and holds pending changes. It blocks a contest, and the network can end it and place it again. An upheld contested replacement still executes during a freeze. | `test_Freeze_*`, `test_Freeze_AnUpheldContestedReplacementStillExecutes` |
| ID-9 | Reads of other contracts forward all gas; a shortfall reverts, never "no". | `test_GasRule_*` |
| ID-10 | A payout that cannot pull is refused when a change is staged, when it executes and at registration: the module's wiring, its AccessManager and consolidation source, the contracts listed at its deployment, the split ledger's vaults, every contract declaring a protocol interface (ERC-165) and every contract governed by the same AccessManager. Every contract of a deployment is refused; an account with no code, a smart account, a multi-signature wallet and a contract outside the network are accepted. `payoutAddress` is zero while frozen or while a pending change would move it. | `test_PayoutValidation_*`, `test_Payout_RefusesEveryContractOfTheDeployment`, `test_Payout_AcceptsAccountsThatCanPull`, `test_Payout_AGovernedContractDeployedWhileTheChangeWaitsIsCaughtAtExecution`, `test_GasRule_TheGovernedProbeNeverAnswersForGas` |
| ID-11 | `isArtist` is true only for a wallet of the work's lead account. | `test_IsArtist_AStreamWorkAnswersForEveryWalletOfTheLead`, `test_IsArtist_AnEditionAnswersThroughItsMaster`, `test_IsArtist_AFrozenAccountIsNo`, `test_IsArtist_AnythingElseIsNo` |
| ID-15 | The network swaps the consolidation source, compare-and-set, to a checked target. | `test_SetConsolidationSource_SwapsTheSourceWithItsPin` |
| ID-16 | A wallet can be any account `SignatureVerifier` verifies, including ERC-1271 and EIP-7702 accounts. | `test_ContractRoot_StagesByPreApproval`, `test_7702Account_PreApprovalAndECDSABothWork` |
| ID-17 | `StreamDirectory6529.payoutAddress` forwards to the ACCOUNTS module; a missing, reverting or gas-burning module reverts and never answers a default. | `testFuzz_PayoutAddress_ForwardsToTheAccountsModule`, `test_PayoutAddress_RevertsWithoutAModule`, `test_PayoutAddress_RevertsWhenTheModuleReverts`, `testFuzz_PayoutAddress_RevertsWhenTheModuleBurnsItsGas` |
| ID-42 | A module deployed with `previous` answers an account it has not recorded from the replaced module's record, read at each use: root, acting root (none while frozen or a replacement is pending), payout address, freeze and pending change, through any number of replacements. Consolidated wallets are its own source's answer, and a payout address it refuses by address is answered as none, without a call to that address. The address a moved account's ID was made from has no power. | `test_Successor_AnswersAnAccountItHasNotRecordedFromThePredecessor`, `test_Successor_AMovedAccountsFirstAddressHasNoWallet`, `test_Successor_AFreezeOrAPendingReplacementInThePredecessorStopsTheAccount`, `test_Successor_AnInheritedAccountUsesThisModulesConsolidationSource`, `test_Successor_ADifferentSourceHereDecidesTheWalletsOfAnInheritedAccount`, `test_Successor_APayoutThisModuleRefusesIsNotCarried`, `test_Successor_AnAllowedPayoutIsCarried`, `test_AccountsSuccessor_*`, `invariant_ASuccessorAnswersAsTheModuleItReplaces`, `test_ModuleSwap_ANewAccountsModuleKeepsEveryAccountAndFreeze` |
| ID-43 | A module never registers an address the module it replaces knows as a root, a former root or a reserved root, and takes no such address as a new root; an address no module of the chain knows is its own single-wallet account and registers with the ID its address gives. | `test_Successor_NeverRegistersAnAddressThePredecessorKnows`, `test_Successor_ANewRootMustBeFreeInThePredecessorToo`, `test_Successor_AnAddressNobodyKnowsIsItsOwnAccountAndRegistersHere`, `test_AccountsSuccessor_TheFirstAddressOfAMovedAccountCannotRegisterOrBePaid`, `test_Successor_TheFirstModuleReplacesNone` |
| ID-44 | The first change a module makes to an inherited account copies its record, freeze and pending change (`AccountInherited`), and `copyAccounts` does so for a list, for anyone; from then on the module answers for it from its own record, and a call that is refused copies nothing. A copy calls no address the account chose, so a payout contract cannot stop a copy, a freeze or a replacement. A change there is signed in that module's domain. A copied contest is resolved only by an outcome recorded for that module after the copy. What the module recorded comes first: a copy never moves an address it already maps, and leaves behind a pending change whose new root a change pending there reserves. | `test_Successor_AFreezeHereCopiesTheAccountAndThisModuleAnswersAlone`, `test_Successor_AnOwnChangeHereIsSignedInThisModulesDomain`, `test_Successor_APendingOwnChangeIsCopiedAndCancelledHere`, `test_Successor_APendingReplacementIsCopiedAndExecutedHere`, `test_Successor_APendingReplacementIsCopiedAndWithdrawnHere`, `test_Successor_AContestedReplacementNeedsAnOutcomeRecordedAfterTheCopy`, `test_Successor_ARefusedCallCopiesNothing`, `test_Successor_AWalletRevokesItsNonceHere`, `test_Successor_ACopyNeverRemapsAnAddressRecordedHere`, `test_Successor_ACopyLeavesBehindAChangeWhoseRootIsReservedHere`, `test_Successor_CopyAccountsCopiesAListForAnyone`, `test_Successor_APayoutContractCannotStopACopyOrAFreeze`, `test_Successor_CopiesEachAccountOnItsOwn`, `test_Successor_ACopyTakesTheWholeIdentityAndMapsRootAndIdAddress`, `test_Successor_ACopiedOwnChangeLeavesTheAccountActing`, `test_Successor_AnIdWiderThanAnAddressIsNeverCopied` |
| ID-45 | A replaced module that does not answer (a revert, no data, the wrong size) leaves the accounts only it holds with nobody acting and their payout zero, and nothing is registered or copied; an account the successor recorded acts, is paid and is frozen without reading it (naming a new root for one still needs its answer); a read that runs short of gas reverts; an address it claims for an account the successor recorded gains nothing. The replaced module must declare the accounts interface. | `test_Successor_APredecessorThatStopsAnsweringStopsOnlyItsOwnAccounts`, `test_Successor_AClaimByThePredecessorGivesNoPowerOverAnAccountRecordedHere`, `test_Successor_ThePredecessorMustBeAnAccountsModule`, `test_GasRule_AReadOfThePredecessorNeverAnswersForGas`, `test_GasRule_AnAccountRecordedHereNeverReadsThePredecessor` |
| ID-46 | Only the module the directory's ACCOUNTS slot names creates or changes an account: a module announced and not yet activated, and a module that has been replaced, refuse every such call (`NotModule`), for the network, for a wallet and for anyone, and copy nothing. What happens in the module in force during the wait is what the next one serves. | `test_Successor_WritesNothingBeforeItIsInForce`, `test_Successor_AFreezeAndAReplacementDuringTheWaitReachIt`, `test_Successor_AReplacedModuleWritesNothing`, `test_AccountsSuccessor_AFreezePlacedDuringTheWaitIsServedAndLiftedInTheNewModule`, `test_AccountsSuccessor_AChangeInTheOldModuleDuringTheWaitIsCarried` |

The Independent Stream directory rules (ID-12 to ID-14) are on the
[Independent Stream page](independent-stream.md).

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| A root key is stolen | The network freezes the account at once, then replaces the root | Any wallet can cancel the thief's own change meanwhile. |
| The consolidation source fails | Only roots act | The network replaces the source. |
| The accounts module is missing or fails | Vault releases to artists revert; the money stays in the vaults | The network installs a module in `StreamDirectory6529` (after `moduleDelay`). |
| A replaced accounts module stops answering its successor | The accounts only it holds have nobody acting and their payout held; no new artist registers; accounts the successor recorded are unaffected | The network installs another module (after `moduleDelay`). |
