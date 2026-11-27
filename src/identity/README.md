# identity

The accounts module and its consolidation adapter: who an artist or collaborator is (a 6529
consolidated account: a root wallet and every wallet consolidated with it, all equal), where the
account's money goes, how the account changes its root, payout or profile (2 days), and how the
network replaces a root (14 days' notice, contestable) or freezes an account at once (14 days).
The module is replaceable: the permanent [`StreamDirectory6529`](../core/StreamDirectory6529.sol)
names the current one in its `ACCOUNTS` slot
([ADR 0010](../../docs/adr/0010-plain-permanent-core.md)). The rules are in
[Identity and recovery](../../docs/spec/identity-and-recovery.md) (`ID-*`).

## Files

| File | What it is |
| --- | --- |
| `Accounts.sol` | The accounts module: [`IArtistRegistry`](../interfaces/IArtistRegistry.sol), which is also [`IAccounts`](../interfaces/core/IAccounts.sol) (who may act for an account), the statement log's [`IArtistRoleResolver`](../interfaces/IArtistRoleResolver.sol) (`isArtist`) and [`IArtistPayoutResolver`](../economics/interfaces/IArtistPayoutResolver.sol) (`payoutAddress`, which split vaults reach through `StreamDirectory6529.payoutAddress`). Replaceable. |
| `ConsolidationAdapter.sol` | `IConsolidationSource` (declared in `IArtistRegistry.sol`) over the 6529 delegation contract: `isConsolidated(root, wallet)`, a live two-way all-collections use-case-999 consolidation, no minimum age. |

## Entry points

| Caller | Calls |
| --- | --- |
| Any contract checking an account (Independent Stream tokens, the Independent Stream module, the mint policy, the rules modules) | `isWallet`, `requireSigned`, `requireConsent`, `consentDigest`, `frozenUntil` |
| The package registry | `register` on an account's first package acceptance |
| The Independent Stream module (the directory's `INDEPENDENT_STREAM` slot) | `registerIndependent`, with the wallet's own signature |
| Anyone, relaying a wallet's signature | `stageChange`; `executeChange` once due; `expireContest` once lapsed |
| A wallet of the account | `cancelChange` (cancel an own change, contest a replacement, never while frozen); `revokeNonce` |
| The network | `freeze`, `unfreeze`, `cancelReplacement`, `cancelOwnChange`, `stageReplacement`, `resolveContested`, `setConsolidationSource`, `setPackageRegistry` |
| The statement log; the directory; sale contracts | `isArtist`; `payoutAddress`; `activeAuthorityOf` |

The module is deployed with its contracts (`Accounts.Wiring`: directory, 6529 Stream, 6529 Stream
Editions, split ledger, statement log, first package registry) as constructor arguments; there is
no bind step.

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
  and every Independent Stream token), or of an edition through `IEditions.stream()` and the same
  ID. A token that answers neither, or answers malformed data, is "false".
- **Payout refusals.** A payout may not be this module, the directory, 6529 Stream or Editions,
  the split ledger or one of its vaults, the statement log, the package registry, the
  AccessManager, the consolidation source, a contract listed at deployment (`notPayouts`: the
  deployment's contracts no rule recognises), any contract declaring (ERC-165) a protocol
  interface (`ProtocolContracts`, plus a module host, the directory, the record contract, a
  mint policy and an Independent Stream gate), or any contract whose `authority()` is this
  module's AccessManager. Checked at staging, at execution and at registration;
  `isPayoutAllowed(address)` answers it. An account with no code and a contract that is
  none of the above are accepted.
- **Replacing the module.** `previous` names the module this one replaces (zero for the
  first). An account not recorded here is answered from that module's record (`artistIdOf`,
  `activeAuthorityOf`, `authorityOf`, `payoutAddress`, `frozenUntil`, `artist`,
  `pendingChange`, `reservedFor`), each read forwarding all gas; consolidation is this
  module's own source's answer. `register` refuses an address that module knows. The first
  function here that changes an inherited account copies its record, freeze and pending
  change (`AccountInherited`); `changeNonce` counts from zero here. A replaced module that
  does not answer stops only the accounts it still holds
  ([Replacing a module](../../docs/operations/replacing-modules.md)).
- **The live read.** A non-root wallet costs one call to the consolidation source, forwarding
  all gas (`BoundedCall.tryReadWordAll`): a shortfall reverts, anything else but `true` is "no".
- **Compiled waits.** `OWN_CHANGE_DELAY` 2 days, `REPLACEMENT_NOTICE` 14 days, `CONTEST_LAPSE`
  90 days, `FREEZE_PERIOD` 14 days. The module is replaceable, so these are its current rules,
  not promises of the permanent contracts.
- **Tests:** `test/identity/` (run with `FOUNDRY_TEST=test/identity` until the rest of the tree
  compiles again at integration).

## See also

[ADR 0010](../../docs/adr/0010-plain-permanent-core.md);
[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery);
[known limitations](../../docs/audit/known-limitations.md#identity-and-recovery);
[trust assumptions](../../docs/audit/trust-assumptions.md).
