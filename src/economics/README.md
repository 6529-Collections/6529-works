# economics

Money routing for 6529 Works: the per-product economics new works lock at mint, the currency
allowlist, CREATE2 split wallets that artists and fixed payees pull from, the escrow that catches
refused payments, signed releases and batch claims. The rules are in
[Economics and payouts](../../docs/spec/economics-and-payouts.md) (`ECO-*`), including the wallet
address derivation, the payee-list rules and both escrow-recovery flows.

## Files

| File | What it is |
| --- | --- |
| `EconomicsResolver.sol` | Governed per-product economics for new works (fee share and recipient, royalty rate, default license), `newWorkTerms` and `resolveCurrency`; and the 6529 Network Museum (`museum`, `setMuseum`), where an unbid canonical work goes (ECO-37). |
| `AssetAllowlist.sol` | Governed currencies: status, increment floor and `statusClock` per asset, and a default currency per product, each compare-and-set on its own revision. |
| `SplitFactory.sol` | Permissionless, unowned factory: `walletFor` predicts and `createWallet` deploys a `SplitWallet` at its CREATE2 address; pins the resolver and release verifier by code hash. |
| `SplitWallet.sol` | Immutable pull-payment wallet for ETH and any ERC-20: fixed payees by account, artist-resolved payees by artist ID through the artist registry's `payoutAddress`. |
| `ReleaseVerifier.sol` | The singleton for signed releases: EIP-712 authorizations, per-account nonce bitmaps shared across wallets, `revokeNonce`. |
| `RevenueEscrow.sol` | Credits a wallet whose payment failed; anyone flushes; governed `recover` with the consent rules; `consentToRecovery`. |
| `ClaimRouter.sol` | Stateless batch claims: up to 50 plain items (fixed payees) or 20 signed items. |
| `RevenuePayment.sol` | Internal library for payers: pay the wallet with a fixed gas allowance, else credit the escrow. |
| `TokenTransfer.sol`, `Splits.sol` | Internal libraries: exact-delta ERC-20 moves; payee-list validation, royalty payees and share maths. |
| [`interfaces/`](interfaces/) | This module's interfaces, `IArtistPayoutResolver` included. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Stream at mint; Editions at `createEdition` | Stream reads `economics` and derives the seller with `walletFor(payees, 0)`; Editions calls `newWorkTerms(PRODUCT_EDITIONS, payees)`. Either way the terms are locked into the work. | ECO-6, ECO-7 |
| Sale adapters | `defaultCurrency`, `isActive`, `statusClock` and `incrementFloor` on the allowlist (the English auction locks the currency at start and the increment floor at the first bid); `newWorkTerms(PRODUCT_EDITIONS, payees)` when an edition sale opens; `RevenuePayment` to the seller and fee recipient | ECO-26, ECO-34, AUC-15, EA-2, EA-12 |
| Anyone | `createWallet`, `release` for a fixed payee, `flush`, `claim` | ECO-9 to ECO-15, ECO-27, ECO-29, ECO-30 |
| An artist's current payout address | `release`, `releaseTo`, or a signature submitted with `releaseWithAuthorization` / `claimSigned`; `revokeNonce` | ECO-16, ECO-17, ECO-20 to ECO-22 |
| A non-wallet account with escrow credits (the fee-recipient Safe) | `consentToRecovery(replacement)` | ECO-28 |
| Governance | resolver and allowlist setters, `deprecateAsset`, `recover` | ECO-2 to ECO-5, ECO-32, ECO-33; [role matrix](../../docs/audit/roles.md#economicsresolver) |

Payment, release and recovery sequences are under
[Flows](../../docs/spec/economics-and-payouts.md#flows); events under
[Events and indexing](../../docs/integrators/events-and-indexing.md).

## Developer notes

- **Sale adapters never compute wallets.** The token supplies the seller and fee terms through
  `primaryTerms`; an adapter pays them with `RevenuePayment.payETH` or `payERC20`, which falls
  back to the escrow. A wallet need not be deployed: funds sent to its predicted address are
  split once anyone calls `createWallet`, which is why deployment stays off the start path.
- **Escrow recovery needs a deployed wallet on both sides.** `recover` compares
  `SplitFactory.configOf` of the blocked wallet and its replacement, so anyone first deploys the
  blocked wallet if it is not yet, and deploys the replacement (the same payees with another
  salt) with the permissionless `createWallet`; governance only executes `recover` (14 days).
  Recovery reaches escrow credits only, never a wallet's own balance.
- **Constant wallet init code.** A wallet reads its payee list back from the factory
  (`pendingPayees`, transient during `createWallet`), so predicting an address hashes a few
  words; never move the list into constructor arguments.
- **Withdrawals never read the allowlist**, so a deprecated or never-admitted asset stays
  withdrawable (ECO-25); keep the allowlist out of the wallet and escrow.
- **Transaction cap.** [`GasCap.t.sol`](../../test/economics/GasCap.t.sol) measures the cold
  worst cases (a 64-payee wallet deployment and full atomic and continue-mode batches) against
  75% of the EIP-7825 cap (ECO-31); the largest, a full continue-mode signed batch, is about
  10.8M Prague gas. Rerun it after changing a batch bound or a per-item minimum; keeper guidance
  is LIM-GAS-6.
- **Bytecode:** wide margins; figures in the
  [audit scope](../../docs/audit/scope.md#economics). Per-operation gas is in
  [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table).
- **Tests:** `forge test --match-path 'test/economics/**'` (unit, hostile tokens, split maths,
  gas caps, invariants); Halmos proofs of `Splits` in `test/symbolic/`
  ([Testing](../../docs/testing/README.md)); end to end,
  [`EscrowRecovery.t.sol`](../../test/integration/EscrowRecovery.t.sol).

## Not in v1

The settlement recorder of ADR 0001 §7 (single-use settlement keys); each adapter's own state
prevents a second settlement (LIM-ECO-5).

## See also

[ADR 0001 §7](../../docs/adr/0001-v1-scope.md#7-economics) (with §5 currencies and §11 the
artist-resolved payout), [ADR 0003, economics](../../docs/adr/0003-build-time-decisions.md#economics-amends-adr-0001-7);
[known limitations](../../docs/audit/known-limitations.md#economics-and-payouts) LIM-ECO-1 to
LIM-ECO-5 and LIM-GAS-6; [invariants](../../docs/audit/invariants.md);
[buying, bidding and settling](../../docs/integrators/buying-bidding-settling.md).
