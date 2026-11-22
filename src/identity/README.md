# identity

The accounts module and its consolidation adapter: who an artist or collaborator is (a 6529
consolidated account: a root wallet and every wallet consolidated with it, all equal), where the
account's money goes, how the account changes its root, payout or profile (2 days), and how the
network replaces a root (14 days' notice, contestable) or freezes an account at once (14 days).
The module is replaceable: the permanent [`Directory`](../core/Directory.sol) names the current
one in its `ACCOUNTS` slot ([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)). The rules
are in [Identity and recovery](../../docs/spec/identity-and-recovery.md) (`ID-*`).

## Files

| File | What it is |
| --- | --- |
| `Accounts.sol` | The accounts module: [`IArtistRegistry`](../interfaces/IArtistRegistry.sol), which is also [`IAccounts`](../interfaces/core/IAccounts.sol) (who may act for an account), the statement log's [`IArtistRoleResolver`](../interfaces/IArtistRoleResolver.sol) (`isArtist`) and [`IArtistPayoutResolver`](../economics/interfaces/IArtistPayoutResolver.sol) (`payoutAddress`, which split vaults reach through `Directory.payoutAddress`). Replaceable. |
| `ConsolidationAdapter.sol` | `IConsolidationSource` (declared in `IArtistRegistry.sol`) over the 6529 delegation contract: `isConsolidated(root, wallet)`, a live two-way all-collections use-case-999 consolidation, no minimum age. |

## Entry points

| Caller | Calls |
| --- | --- |
| Any contract checking an account (federated tokens, the federation module, the mint policy, the rules modules) | `isWallet`, `requireSigned`, `requireConsent`, `consentDigest`, `frozenUntil` |
| The package registry | `register` on an account's first package acceptance |
| The federation module (the directory's `FEDERATION` slot) | `registerFederated`, with the wallet's own signature |
| Anyone, relaying a wallet's signature | `stageChange`; `executeChange` once due; `expireContest` once lapsed |
| A wallet of the account | `cancelChange` (cancel an own change, contest a replacement, never while frozen); `revokeNonce` |
| The network | `freeze`, `unfreeze`, `cancelReplacement`, `cancelOwnChange`, `stageReplacement`, `resolveContested`, `setConsolidationSource`, `setPackageRegistry` |
| The statement log; the directory; sale contracts | `isArtist`; `payoutAddress`; `activeAuthorityOf` |

The module is deployed with its contracts (`Accounts.Wiring`: directory, 6529 Stream, 6529 Stream
Editions, split ledger, statement log, first package registry) as constructor arguments; there is
no bind step. The four `bind*` functions remain only so older tooling compiles, and always revert.

## Freeze and contest

- **A freeze blocks a contest of a replacement.** Nobody can contest while the account is
  frozen, so a freeze placed together with a replacement leaves no moment to contest it: a
  contest binds only a network that does not also freeze the account.
- **A freeze can be placed again.** `freeze` is refused while a freeze runs; once it ended, or
  the network lifted it with `unfreeze`, the network may freeze the account again at once, for
  another 14 days.
- While frozen the account has no acting wallet, its payout reads zero (vaults hold its money)
  and no pending change executes, except the network's own `resolveContested`.

## Developer notes

- **`isArtist`** resolves the lead artist of any token that answers `IStream.workOf` (6529 Stream
  and every federated token), or of an edition through `IEditions.stream()` and the same ID. A
  token that answers neither, or answers malformed data, is "false".
- **Payout refusals.** A payout may not be this module, the directory, 6529 Stream or Editions,
  the split ledger or one of its vaults, the statement log, the package registry, or any
  contract declaring (ERC-165) the interface of a network contract that cannot pull money.
- **The live read.** A non-root wallet costs one call to the consolidation source, forwarding
  all gas (`BoundedCall.tryReadWordAll`): a shortfall reverts, anything else but `true` is "no".
- **Compiled waits.** `OWN_CHANGE_DELAY` 2 days, `REPLACEMENT_NOTICE` 14 days, `CONTEST_LAPSE`
  90 days, `FREEZE_PERIOD` 14 days. The module is replaceable, so these are its current rules,
  not promises of the permanent contracts.
- **`federatedListing`** forwards the federation module's `entry`, for the entropy module.
- **Tests:** `test/identity/` (run with `FOUNDRY_TEST=test/identity` until the rest of the tree
  compiles again at integration).

## See also

[ADR 0010](../../docs/adr/0010-plain-permanent-core.md);
[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery);
[known limitations](../../docs/audit/known-limitations.md#identity-and-recovery);
[trust assumptions](../../docs/audit/trust-assumptions.md).
