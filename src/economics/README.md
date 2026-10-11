# economics

Money routing for 6529 Works, governed by
[ADR 0001 §7 (economics)](../../docs/adr/0001-v1-scope.md#7-economics), with the
payment-currency rules in [§5](../../docs/adr/0001-v1-scope.md#5-sales-and-auctions)
and the artist-resolved payout recipient in
[§11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery).
Rates use a 100,000 denominator, so the 6.529% royalty is exact (6,529).

| Contract | Role |
| --- | --- |
| `SplitFactory` | Permissionless, unowned. Deploys `SplitWallet`s at CREATE2 addresses that commit to the resolver and the canonical payee list. `walletFor(payees)` gives the address before deployment. |
| `SplitWallet` | Immutable pull-payment wallet for ETH (`address(0)`) and any ERC-20. Payee `i` may release `floor(observed × share / 100,000) − released`, where `observed` is balance plus everything released. Fixed payees name an account; artist-resolved payees name an `artistId` paid at the resolver's current address. |
| `ReleaseAuthorization` | EIP-712 signed releases (inherited by `SplitWallet`): binds asset, payee, account, recipient, amount, nonce and deadline; the domain binds chain and wallet. Unordered single-use nonces, revocable. |
| `AssetAllowlist` | Governed currency allowlist: status per asset (`Active`, `Deprecated`), a per-currency increment floor, a default currency per product. ETH is admitted at deployment. |
| `RevenueEscrow` | Credits a wallet when a payment to it fails; anyone flushes, only to the captured wallet. No recovery route. |
| `RevenuePayment` | Internal library for payers: pay the wallet, else credit the escrow. |
| `ClaimRouter` | Stateless batch claims of up to 50 items; each item calls `release`, which pays only the payee. Continue mode needs at least 200,000 gas per item. |
| `TokenTransfer`, `Splits` | Internal libraries: strict ERC-20 moves with exact balance deltas; payee-list rules and share maths. |

## For sale adapters

- Resolve the split to a payee list in canonical order: fixed payees first
  (`artistId == 0`, ascending by account), then artist-resolved payees
  (`account == 0`, ascending by `artistId`), shares summing to 100,000.
- Pay `factory.walletFor(payees)` with `RevenuePayment.payETH` or
  `RevenuePayment.payERC20`. The wallet need not be deployed yet: funds sent to
  the address are split once anyone calls `createWallet`. Deployment costs
  about 1.6M gas for two payees, so keep it off the auction-start path.
- Read `AssetAllowlist.defaultCurrency(product)` and `incrementFloor(asset)` when
  a sale starts, and lock both for that sale.

## Gas bounds

Every loop is bounded so each transaction fits the EIP-7825 cap of 16,777,216
gas (`test/economics/GasCap.t.sol` measures the worst cases, cold): a 64-payee
wallet deployment is about 4.7M, a full atomic claim batch about 6.4M, and a
full continue-mode batch at its minimum gas about 10.8M.

## Governance (proposed; the governance lane owns the final mapping)

Only `AssetAllowlist` is governed, through AccessManager `restricted` (delay
classes in [ADR 0001 §13](../../docs/adr/0001-v1-scope.md#13-governance)):

| Selector | Proposed class |
| --- | --- |
| `admitAsset` | Standard (48 hours) |
| `setDefaultCurrency` | Standard (48 hours) |
| `setIncrementFloor` | Standard (48 hours) |
| `deprecateAsset` | Tightening (immediate) |

Withdrawals never read the allowlist: a deprecated or never-admitted asset
stays withdrawable from wallets and the escrow (fixes RC1 Medium M-3).

## Not here yet

Royalty and revenue resolvers with scoped assignments, and the settlement
recorder (single-use settlement keys), are not part of this module yet.
