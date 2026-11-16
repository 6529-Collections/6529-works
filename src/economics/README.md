# economics

Money routing for 6529 Works: the per-product economics new works lock at mint, the currency
allowlist, the permanent split ledger and its 66-byte CREATE2 wallets that artists and fixed
payees pull from, the escrow that catches refused payments, signed releases, batch claims, and
the governed vault for the network's own accounts. The rules are in
[Economics and payouts](../../docs/spec/economics-and-payouts.md) (`ECO-*`), including the wallet
address derivation, the payee-list rules and both escrow-recovery flows.

## Files

| File | What it is |
| --- | --- |
| `EconomicsResolver.sol` | Governed per-product economics for new works (fee share and recipient, royalty rate, default license), `newWorkTerms` and `resolveCurrency`; and the 6529 Network Museum (`museum`, `setMuseum`), where an unbid canonical work goes (ECO-37). |
| `AssetAllowlist.sol` | Replaceable (no permanent contract references it; withdrawals never read it). Governed currencies: status, increment floor, the English auction's opening bid (`setOpeningBid`, in the status word) and `statusClock` per asset, and a default currency per product, each compare-and-set on its own revision. |
| `SplitLedger.sol` | Permanent, permissionless, unowned. `walletFor` predicts and `createWallet` deploys a split wallet (a `SplitVault`) at its CREATE2 address; keeps every wallet's accounting; executes `release`, `releaseTo` and signed `releaseWithAuthorization` (EIP-712, per-account nonce bitmaps shared across wallets, `revokeNonce`). Fixed payees by account, artist-resolved payees by artist ID through the artist registry's `payoutAddress`. |
| `SplitVault.sol` | The wallet's 66 bytes of raw EVM code (documented byte by byte): holds ETH and ERC-20s, accepts plain ETH from anyone, moves funds only on its ledger's instruction. |
| `GovernedVault.sol` | The network fee recipient and the museum as contracts: receive ETH, ERC-20s, ERC-721s and ERC-1155s; forward only to a destination governance sets (FUNDS_SETTER, 14 days). |
| `RevenueEscrow.sol` | Credits a wallet whose payment failed; anyone flushes; governed `recover` with the consent rules; `consentToRecovery`; governed `sweepExcess` of what nobody is owed. |
| `ClaimRouter.sol` | Stateless batch claims through the ledger: up to 50 plain items (fixed payees) or 20 signed items. |
| `RevenuePayment.sol` | Internal library for payers: pay the wallet with a fixed gas allowance, else credit the escrow. |
| `TokenTransfer.sol`, `Splits.sol` | Internal libraries: exact-delta ERC-20 moves; payee-list validation, royalty payees and share maths. |
| [`interfaces/`](interfaces/) | This module's interfaces, `IArtistPayoutResolver` included. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Stream at mint; Editions at `createEdition` | Stream reads `economics` and derives the seller with `walletFor(payees, 0)`; Editions calls `newWorkTerms(PRODUCT_EDITIONS, payees)`. Either way the terms are locked into the work. | ECO-6, ECO-7 |
| Sale adapters | `defaultCurrency`, `isActive`, `statusClock` and `incrementFloor` on the allowlist (the English auction locks the currency at start and the increment floor at the first bid); `newWorkTerms(PRODUCT_EDITIONS, payees)` when an edition sale opens; `RevenuePayment` to the seller and fee recipient | ECO-26, ECO-34, AUC-15, EA-2, EA-12 |
| Anyone | `createWallet`, `release` for a fixed payee, `flush`, `claim`; a governed vault's `forward`, `releaseToDestination`, `consentToRecovery` | ECO-9 to ECO-15, ECO-27, ECO-29, ECO-30, ECO-41 |
| An artist's current payout address | `release`, `releaseTo`, or a signature submitted with `releaseWithAuthorization` / `claimSigned`; `revokeNonce` | ECO-16, ECO-17, ECO-20 to ECO-22 |
| A non-wallet account with escrow credits (the fee-recipient Safe) | `consentToRecovery(replacement)` | ECO-28 |
| Governance | resolver and allowlist setters, `deprecateAsset`, `recover`, `sweepExcess`, `GovernedVault.setDestination` | ECO-2 to ECO-5, ECO-32, ECO-33; [role matrix](../../docs/audit/roles.md#economicsresolver) |

Payment, release and recovery sequences are under
[Flows](../../docs/spec/economics-and-payouts.md#flows); events under
[Events and indexing](../../docs/integrators/events-and-indexing.md).

## Developer notes

- **Sale adapters never compute wallets.** The token supplies the seller and fee terms through
  `primaryTerms`; an adapter pays them with `RevenuePayment.payETH` or `payERC20`, which falls
  back to the escrow. A wallet need not be deployed: funds sent to its predicted address are
  split once anyone calls `createWallet`, which is why deployment stays off the 1/1 start path.
  It costs about 96K Prague gas (about 0.43M Glamsterdam), so deploy each seller and royalty
  wallet at its first sale: a deployed wallet never depends on deploying anything again
  (LIM-ECO-7). The edition auction's `open` does this for its seller and royalty wallets
  (EA-20).
- **Releases name the wallet by its configuration.** `release(payees, salt, asset, index)`: the
  ledger stores only `configOf` (for `isWallet` and the escrow) and derives the address from the
  list and salt, which callers read from `WalletCreated` or the work's terms.
- **Escrow recovery needs a deployed wallet on both sides.** `recover` compares
  `SplitLedger.configOf` of the blocked wallet and its replacement, so anyone first deploys the
  blocked wallet if it is not yet, and deploys the replacement (the same payees with another
  salt) with the permissionless `createWallet`; governance only executes `recover` (14 days).
  Recovery reaches escrow credits only, never a wallet's own balance.
- **Constant wallet init code, no compiler in the address.** The vault is raw bytecode with no
  payee data, so predicting an address hashes a few words and every address is a function of the
  documented bytes, not of a compiler version or metadata. Never add constructor arguments.
- **No rescue in wallets.** Every unit in a wallet is some payee's (cumulative entitlements,
  dust below the payee count); a mute fixed payee blocks only its own share. The escrow's
  `sweepExcess` is the one sweep, and it reaches only `balance - totalOwed` of the token address
  it names (a two-address token or a rebasing one is outside that bound, LIM-ECO-8).
- **Payee checks read no state.** `Splits.validate` refuses an artist ID of 2^160 or more and the
  ledger as a fixed payee; any check that read another contract could flip after a wallet's
  address was paid and leave it undeployable, so none is added there.
- **Governed vaults move NFTs by safe transfer** (a destination that cannot hold them refuses),
  and the escrow refuses a vault's recovery consent once its destination has changed (ECO-41).
- **Withdrawals never read the allowlist**, so a deprecated or never-admitted asset stays
  withdrawable (ECO-25); keep the allowlist out of the wallet and escrow.
- **Only a wallet release (and the escrow sweep and a governed vault's forward) accepts a
  no-return token.** The ledger counts an empty `transfer` return because the exact balance
  deltas prove the move (ECO-23). Keep every path that takes a sale currency in
  (payments, escrow deposits, adapter pulls) on the strict `transferExact` / `pullExact`.
- **Transaction cap.** [`GasCap.t.sol`](../../test/economics/GasCap.t.sol) measures the cold
  worst cases (a 64-payee wallet deployment and full atomic and continue-mode batches) against
  75% of the EIP-7825 cap (ECO-31); with every item carrying a 64-payee list the largest, a
  full atomic plain batch, is about 12.4M Prague gas. Rerun it after changing a batch bound or a per-item minimum; keeper guidance
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
LIM-ECO-7 and LIM-GAS-6; [invariants](../../docs/audit/invariants.md);
[buying, bidding and settling](../../docs/integrators/buying-bidding-settling.md).
