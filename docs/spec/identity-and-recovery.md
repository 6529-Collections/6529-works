# Identity and recovery

Artists act through accounts. An account is a consolidated identity: one artist ID and any
number of wallets, all equal. The accounts module `Accounts` (today's artist registry) answers
who an artist is, which wallets act for it and where it is paid. It is a **replaceable module**
behind the permanent [`Directory`](../../src/core/Directory.sol) (slot `ACCOUNTS`); the network
can replace it after `moduleDelay` (7 days at launch). Tokens keep only an artist ID.

> Pre-audit. See the [project status](../../README.md#status).

## Contracts

| Contract | Kind | What it does |
| --- | --- | --- |
| `Accounts` ([`IAccounts`](../../src/interfaces/core/IAccounts.sol), [`IArtistRegistry`](../../src/interfaces/IArtistRegistry.sol)) | module (`Directory.ACCOUNTS`) | Accounts, wallets, signatures and consent, own changes, replacements, contests, freezes, payout addresses. |
| [`ConsolidationAdapter`](../../src/identity/ConsolidationAdapter.sol) | module | Answers whether two wallets are consolidated (two-way delegation registrations). |
| [`Directory`](../../src/core/Directory.sol) | permanent | `payoutAddress(artistId)` forwards to the ACCOUNTS module. The split ledger asks it when it releases an artist's share. |

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
  the vault. A payout that cannot pull is refused when set.
- **Which works are the artist's.** `isArtist(token, id, account)` reads
  `IStream(token).workOf(id).artistId`, for 6529 Stream and federated tokens alike.

### The consolidation adapter

`ConsolidationAdapter.isConsolidated(root, wallet)` is true while each of the two holds a live
registration of the other for all collections (delegation use case 999). There is no minimum
age. A read that fails counts as no registration.

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
| ID-1 | An artist ID is the `uint160` of its first root, created by the mint policy or, with the wallet's own signature, by the federation module. | `test_Register_*`, `test_RegisterFederated_*` |
| ID-2 | A wallet acts for an account exactly when it is the root or consolidated with it; never while frozen or a replacement is pending. | `test_IsWallet_*`, `invariant_RequireSignedPassesExactlyForTheAccountsWallets` |
| ID-3 | `requireSigned` passes only for a wallet of the account that signed; `requireConsent` only for the asking contract. | `test_RequireSigned_*`, `test_RequireConsent_BindsTheCaller` |
| ID-4 | The root never depends on the consolidation source; a failing source is "no" for every other wallet. | `test_Accounts_RootNeverDependsOnTheSource` |
| ID-5 | An own change waits 2 days, is cancelled by any wallet or the network at once, and moves the root only to a wallet of the account. | `test_OwnChange_*`, `test_CancelOwnChange_ByTheNetwork` |
| ID-6 | A replacement is staged only by the network with the new root's acceptance, waits 14 days, and the network may withdraw it at once. | `test_Replacement_*`, `test_CancelReplacement_ByTheNetwork` |
| ID-7 | A wallet contests a replacement only during its notice; a contested replacement runs only if upheld within 90 days, otherwise it lapses. | `test_Contest_*` |
| ID-8 | A freeze lasts 14 days per placement, stops every wallet, zeroes the payout and holds pending changes. It blocks a contest, and the network can end it and place it again. An upheld contested replacement still executes during a freeze. | `test_Freeze_*`, `test_Freeze_AnUpheldContestedReplacementStillExecutes` |
| ID-9 | Reads of other contracts forward all gas; a shortfall reverts, never "no". | `test_GasRule_*` |
| ID-10 | A payout that cannot pull is refused; `payoutAddress` is zero while frozen or while a pending change would move it. | `test_PayoutValidation_*` |
| ID-11 | `isArtist` is true only for a wallet of the work's lead account. | |
| ID-15 | The network swaps the consolidation source, compare-and-set, to a checked target. | `test_SetConsolidationSource_SwapsTheSourceWithItsPin` |
| ID-16 | A wallet can be any account `SignatureVerifier` verifies, including ERC-1271 and EIP-7702 accounts. | `test_ContractRoot_StagesByPreApproval`, `test_7702Account_PreApprovalAndECDSABothWork` |
| ID-17 | `Directory.payoutAddress` forwards to the ACCOUNTS module; a missing, reverting or gas-burning module reverts and never answers a default. | |

The federation directory rules (ID-12 to ID-14) are on the [federation page](federation.md).

## Failure modes and recovery

| Failure | Effect | Recovery |
| --- | --- | --- |
| A root key is stolen | The network freezes the account at once, then replaces the root | Any wallet can cancel the thief's own change meanwhile. |
| The consolidation source fails | Only roots act | The network replaces the source. |
| The accounts module is missing or fails | Vault releases to artists revert; the money stays in the vaults | The network installs a module in `Directory` (after `moduleDelay`). |
