# identity

The artist registry and its consolidation adapter: who an artist or collaborator is (a 6529
consolidated account: a root wallet and every wallet consolidated with it, all equal), where the
account's money goes, how the account changes its root, payout or profile (2 days), how the
network replaces a root (14 days' notice, contestable) or freezes an account at once (14 days),
and the permanent directory of federated contracts. The rules are in
[Identity and recovery](../../docs/spec/identity-and-recovery.md) (`ID-*`).

## Files

| File | What it is |
| --- | --- |
| `ArtistRegistry.sol` | [`IArtistRegistry`](../interfaces/IArtistRegistry.sol), which is also [`IAccounts`](../interfaces/IAccounts.sol) (who may act for an account; every consumer asks it), the statement log's [`IArtistRoleResolver`](../interfaces/IArtistRoleResolver.sol) (`isArtist`) and the split wallets' [`IArtistPayoutResolver`](../economics/interfaces/IArtistPayoutResolver.sol) (`payoutAddress`). |
| `ConsolidationAdapter.sol` | `IConsolidationSource` (declared in `IArtistRegistry.sol`) over the 6529 delegation contract: `isConsolidated(root, wallet)`, a live two-way all-collections use-case-999 consolidation, no minimum age. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Any contract checking an account | `isWallet`, `requireSigned`, `requireConsent`, `consentDigest`, `frozenUntil`, `isFederationDelisted`, `federatedFeeShare` | ID-2 to ID-4 |
| The bound package registry | `register` on an account's first package acceptance | ID-1 |
| The bound federation registry | `registerFederated` (with the wallet's own signature); `listFederatedContract` (with a wallet's consent); `setFederatedStatus` | ID-1, ID-12 |
| Anyone, relaying a wallet's signature | `stageChange`; `executeChange` once due; `expireContest` once lapsed | ID-5, ID-7 |
| A wallet of the account | `cancelChange` (cancel an own change, contest a replacement); `revokeNonce` | ID-5, ID-7 |
| The network | `freeze`, `unfreeze`, `cancelReplacement` (no delay); `stageReplacement`, `resolveContested`, `setFederationDelisted`, `lowerFederatedFeeShare` (24 hours); `setConsolidationSource`, `setPackageRegistry`, `setFederationRegistry` (7 days) | ID-6 to ID-8, ID-13 to ID-15 |
| The statement log; split wallets; sale creators | `isArtist`; `payoutAddress`; `activeAuthorityOf` | ID-10, ID-11 |

Genesis wires `bindPackageRegistry`, `bindStream`, `bindSplitFactory`, `bindStatementLog` and
`bindFederationRegistry`.

## Developer notes

- **The registry is permanent.** Split wallets and Stream pin it, so it is never redeployed;
  the consolidation source and the federation registry are swapped inside it.
- **Storage.** `_artists[id]`: slot 0 holds the root, the end of a freeze, the replacing flag
  and the federation delisting flag, so `isWallet` for the root reads one word; then the payout
  with the nonce, and the profile. `_pending` (one change), `artistIdOf` for every past and
  present root, `reservedFor` for a staged new root, `_acceptanceUsed` for replacement
  acceptances, `_listings[token]` (artist ID, status and fee share in one slot).
- **The live read.** A non-root wallet costs one call to the consolidation source, forwarding
  all gas (`BoundedCall.tryReadWordAll`): a shortfall reverts, anything else but `true` is "no".
- **Fixed values.** `OWN_CHANGE_DELAY` 2 days, `REPLACEMENT_NOTICE` 14 days, `CONTEST_LAPSE` 90
  days, `FREEZE_PERIOD` 14 days: compiled constants, each the guarantee.
- **Delegation contract.** A constructor argument of the adapter: mainnet's 6529 delegation
  contract, and on Sepolia the official deployment with identical runtime bytecode.
- **Tests:** `forge test --match-path 'test/identity/**'`. End to end:
  [`IdentityRecovery.t.sol`](../../test/integration/IdentityRecovery.t.sol).

## See also

[ADR 0001 §11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery);
[known limitations](../../docs/audit/known-limitations.md#identity-and-recovery);
[trust assumptions](../../docs/audit/trust-assumptions.md).
