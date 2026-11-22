# economics

Money routing for 6529 Works: the per-product economics new works lock at mint, the currency
allowlist, the permanent split ledger and its 66-byte CREATE2 wallets that artists and fixed
payees pull from, the escrow that catches refused payments, signed releases, batch claims, and
the governed vault for the network's own accounts. The rules are in
[Economics and payouts](../../docs/spec/economics-and-payouts.md) (`ECO-*`).

## Files

| File | What it is |
| --- | --- |
| `EconomicsResolver.sol` | Governed per-product economics for new works (fee share and recipient, royalty rate, default license), and `newWorkTerms`; and the 6529 Network Museum (`museum`, `setMuseum`), where an unbid canonical work goes (ECO-37). |
| `AssetAllowlist.sol` | Replaceable (no permanent contract references it; withdrawals never read it). ETH only: the English auction's opening bid (`setOpeningBid`) and increment floor (`setIncrementFloor`), read when a bid is placed, each compare-and-set on ETH's revision. No other asset can be admitted and ETH is always active. |
| `SplitLedger.sol` | Permanent, permissionless, unowned. `walletFor` predicts and `createWallet` deploys a split wallet (a `SplitVault`) at its CREATE2 address; keeps every wallet's accounting; executes `release`, `releaseTo` and signed `releaseWithAuthorization` (EIP-712, per-account nonce bitmaps shared across wallets, `revokeNonce`). Fixed payees by account, artist-resolved payees by artist ID through the artist registry's `payoutAddress`. Every release also pays the network fee vault (`network`, a constructor argument) its due share when it is a payee (ECO-43); `mark` and, once the unclaimed period has passed (`Directory.unclaimedPeriod`, a network setting, 180 days at launch, read when the forfeit is attempted), `forfeit` send an unclaimed share to the network (ECO-44). A payee who cannot release (a frozen or unresolved artist account) can still be marked and forfeited. |
| `SplitVault.sol` | The wallet's 66 bytes of raw EVM code (documented byte by byte): holds ETH and ERC-20s, accepts plain ETH from anyone, moves funds only on its ledger's instruction. |
| `GovernedVault.sol` | The network fee recipient and the museum as contracts: receive ETH, ERC-20s, ERC-721s and ERC-1155s; forward only to a destination the network sets (3 days for the fee vault, 7 days for the museum's). Deployed before the ledger, which names the fee vault. |
| `RevenueEscrow.sol` | Credits a wallet whose payment failed; anyone flushes; governed `recover` (identical wallets; the network's own credits without consent; anyone else's with its `consentToRecovery`); `expire` to the network of credits whose window's last credit has waited the unclaimed period (`Directory.unclaimedPeriod`, 180 days at launch), so each waits from one period to under two (ECO-45); the period is read at every deposit, recovery and expiry, and an amount already counted as aged stays aged; `locked()` for callers that must not run inside it; governed `sweepExcess` of what nobody is owed. |
| `ClaimRouter.sol` | Stateless batch claims through the ledger: up to 50 plain items (fixed payees) or 20 signed items. |
| `RevenuePayment.sol` | Internal library for payers: pay the wallet with a fixed gas allowance, else credit the escrow. |
| `TokenTransfer.sol`, `Splits.sol` | Internal libraries: exact-delta ERC-20 moves; payee-list validation, royalty payees and share maths. |
| [`interfaces/`](interfaces/) | This module's interfaces, `IArtistPayoutResolver` included. |

## Entry points

| Caller | Calls | Rules |
| --- | --- | --- |
| Stream at mint; Editions at `createEdition` | Stream reads `economics` and derives the seller with `walletFor(payees, 0)`; Editions calls `newWorkTerms(PRODUCT_EDITIONS, payees)`. Either way the terms are locked into the work. | ECO-6, ECO-7 |
| Sale adapters | `openingBid(ETH)` and `incrementFloor(ETH)` on the allowlist (the English auction reads both when a bid is placed); `newWorkTerms(PRODUCT_STREAM, payees)` in the package registry at a start; `newWorkTerms(PRODUCT_EDITIONS, payees)` when an edition sale opens; `museum()` and `networkFeeRecipient(product)` at settlement; `RevenuePayment` to the seller and fee recipient | ECO-26, ECO-34, AUC-15, EA-2, EA-12 |
| Anyone | `createWallet`, `release` for a fixed payee, `mark`, `forfeit`, `flush`, `expire`, `claim`; a governed vault's `forward`, `releaseToDestination` | ECO-9 to ECO-15, ECO-27, ECO-29, ECO-30, ECO-41, ECO-43 to ECO-45 |
| An artist's current payout address | `release`, `releaseTo`, or a signature submitted with `releaseWithAuthorization` / `claimSigned`; `revokeNonce` | ECO-16, ECO-17, ECO-20 to ECO-22 |
| A non-wallet account with escrow credits that is not the network's | `consentToRecovery(replacement)` | ECO-28 |
| Governance | resolver and allowlist setters, `recover`, `sweepExcess`, `GovernedVault.setDestination` | ECO-2 to ECO-5, ECO-32, ECO-33; [role matrix](../../docs/audit/roles.md#economicsresolver) |

Payment, release and recovery sequences are under
[Flows](../../docs/spec/economics-and-payouts.md#flows); events under
[Events and indexing](../../docs/integrators/events-and-indexing.md).

## Developer notes

- **Sale adapters never compute wallets.** They pay the token's `primaryTerms` through
  `RevenuePayment` (escrow fallback); a wallet is paid before it is deployed (EA-20, LIM-ECO-7).
- **Wallets are named by configuration.** The ledger stores only `configOf` and derives each
  address from payees and salt; `recover` compares `configOf`, so both wallets must be deployed.
- **Constant wallet init code.** Every address is a function of the documented vault bytes, not
  of a compiler. Never add constructor arguments.
- **Payee checks read no state.** A `Splits.validate` check that read another contract could
  flip after a wallet's address was paid and leave it undeployable.
- **Keep the allowlist out of the wallet and escrow** (ECO-25).
- **Deployment order.** The fee vault (`GovernedVault`) first, then the ledger with it as
  `network`; the ledger checks only that it has code, so the deploy script must pass the right
  vault.
- **The network push looks up a sorted list.** `_payNetwork` binary-searches the canonical payee
  list; it runs only after the main release succeeded, which proves the list is the wallet's.
- **Token strictness.** Only a wallet release, the escrow sweep and a governed vault's forward
  accept a no-return token (ECO-23); every path that takes a sale currency in stays on
  `transferExact` / `pullExact`.
- **The vault copies a callee's whole return;** the ledger copies one word (`SplitVault`
  NatSpec). Its bytes are pinned by `test_Golden_InitCodeHashAndRuntime`.
- **Transaction cap.** Rerun [`GasCap.t.sol`](../../test/economics/GasCap.t.sol) after changing a
  batch bound, a per-item minimum or the continue-mode signature bound (ECO-31, LIM-GAS-6).
- **Bytecode:** [audit scope](../../docs/audit/scope.md#the-permanent-core); gas:
  [ADR 0004](../../docs/adr/0004-gas-budgets-under-glamsterdam.md#the-table).
- **Tests:** `forge test --match-path 'test/economics/**'`; Halmos proofs of `Splits` in
  `test/symbolic/` ([Testing](../../docs/testing/README.md)); end to end,
  `EscrowRecovery.t.sol`.

## See also

[ADR 0001 §7](../../docs/adr/0001-v1-scope.md#7-economics) (with §5 currencies and §11 the
artist-resolved payout), [ADR 0003, economics](../../docs/adr/0003-build-time-decisions.md#economics-amends-adr-0001-7);
[known limitations](../../docs/audit/known-limitations.md#economics-and-payouts) LIM-ECO-1 to
LIM-ECO-8 (LIM-ECO-5: no settlement recorder in v1) and LIM-GAS-6;
[invariants](../../docs/audit/invariants.md);
[buying, bidding and settling](../../docs/integrators/buying-bidding-settling.md).
