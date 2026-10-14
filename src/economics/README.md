# economics

Money routing for 6529 Works, governed by
[ADR 0001 §7 (economics)](../../docs/adr/0001-v1-scope.md#7-economics), with the
payment-currency rules in [§5](../../docs/adr/0001-v1-scope.md#5-sales-and-auctions)
and the artist-resolved payout recipient in
[§11](../../docs/adr/0001-v1-scope.md#11-artist-identity-and-recovery).
Rates use a 100,000 denominator, so the 6.529% royalty is exact (6,529).

| Contract | Role |
| --- | --- |
| `SplitFactory` | Permissionless, unowned. Deploys `SplitWallet`s at CREATE2 addresses that commit to the resolver, the verifier, the canonical payee list and a salt. Pins the resolver and verifier at installation (code present, not EIP-7702 delegated, code hash recorded). Records each wallet's payee configuration hash. |
| `SplitWallet` | Immutable pull-payment wallet for ETH (`address(0)`) and any ERC-20. Payee `i` may release `floor(observed × share / 100,000) − released`, where `observed` is the balance plus everything released. Fixed payees name an account. Artist-resolved payees name an `artistId` and are paid at the resolver's current address. |
| `ReleaseVerifier` | The singleton for signed releases (EIP-712, ERC-1271, EIP-7702 through the shared `SignatureVerifier`). An authorization binds wallet, asset, payee, account, recipient, amount, nonce and deadline; the domain binds the chain. Nonces are unordered, single use, per account across all wallets, and revocable. |
| `AssetAllowlist` | Governed currency allowlist: a status per asset (`Active`, `Deprecated`), a per-currency increment floor and a default currency per product. ETH is admitted at deployment. Admission is compare-and-set on status and floor. |
| `RevenueEscrow` | Credits a wallet when a payment to it fails. Anyone flushes a credit to its wallet. Governed `recover` moves a credit only to an equivalent replacement wallet. |
| `EconomicsResolver` | Implements `IEconomicsResolver`: governed per-product economics for new works (Stream and Editions 75/25, Federated 90/10, royalty 6.529%), the network fee recipient, the default license (CC0), `newWorkTerms` (predicted seller and royalty wallets) and `resolveCurrency` through the allowlist. Changes apply to new works only: works lock their terms at mint. |
| `RevenuePayment` | Internal library for payers: pay the wallet, else credit the escrow. |
| `ClaimRouter` | Stateless batch claims: up to 50 plain items (fixed payees) or 20 signed items (any payee). |
| `TokenTransfer`, `Splits` | Internal libraries: strict ERC-20 moves with exact balance deltas; payee-list rules and share maths. |

## Who can release

- **Fixed payees are push.** Anyone may call `release`; the funds can only go
  to the payee's own account.
- **Artist-resolved payees are pull-only.** Only the current payout address may
  release: by calling `release` or `releaseTo` itself, or by a signature that
  anyone submits through `releaseWithAuthorization` (smart accounts sign with
  ERC-1271). Nobody can push an accrued balance to a lost key before recovery
  redirects it.
- **A split wallet cannot be an artist's payout address**, because it cannot
  pull. An artist who wants revenue to flow into another split should name that
  wallet as a fixed payee instead. More generally, a payout address must be an
  account that can call `release` itself, never a protocol contract. The artist
  registry refuses the claim router, the escrow, the sale adapters, 6529 Stream
  and 6529 Editions (each declares its interface through ERC-165,
  `src/libraries/ProtocolContracts.sol`) and every deployed split wallet, at
  registration, staging and execution. A split wallet's predicted address has no
  code before deployment, so it cannot be told apart from an empty account: the
  re-check at execution catches a wallet deployed while the change waits, and
  tools should check `walletFor` off-chain.
- **Rotating a payout address does not revoke its signatures.** A key the
  payout moved away from cannot release, but if the payout returns to it
  (A, then B, then A), its unexpired authorizations work again. Revoke
  outstanding nonces with `ReleaseVerifier.revokeNonce`, or sign short
  deadlines.
- **Push can pre-empt a fixed payee's signed release.** Anyone may push a fixed
  payee's whole balance to its own account first; a signed release of an exact
  amount then reverts without consuming its nonce, and the funds are already in
  the payee's account. Sign `type(uint256).max` to take whatever is due.
- `ClaimRouter.claim` handles fixed payees only. A plain item for an artist
  payee fails, and continue mode skips it. Artists batch through
  `claimSigned`, with one signature per wallet.

## For sale adapters

- Resolve the split to a payee list in canonical order: fixed payees first
  (`artistId == 0`, ascending by account), then artist-resolved payees
  (`account == 0`, ascending by `artistId`), shares summing to 100,000.
- Pay `factory.walletFor(payees, bytes32(0))` with `RevenuePayment.payETH` or
  `RevenuePayment.payERC20`. The wallet need not be deployed yet: funds sent to
  the address are split once anyone calls `createWallet`. Deployment costs
  about 1.26M gas for two payees, so keep it off the auction-start path.
- Read `AssetAllowlist.defaultCurrency(product)` and `incrementFloor(asset)` when
  a sale starts, and lock both for that sale.

## Escrow recovery

If a token blocks a wallet (as USDC can), payments to it land in the escrow
and cannot flush. Governance deploys an equivalent replacement: the same payee
list with another salt. It then calls `recover(wallet, replacement, asset)` to
move the credit, after which anyone flushes it to the replacement.

- `recover` deviates from ADR 0001 §7's consent wording; consent is trivially
  satisfied because payees are identical. Recorded in ADR 0003.
- A credit the replacement already holds is added to, never overwritten.
- The original wallet must be deployed first; anyone can deploy it.
- Recovery reaches only escrow credits. The blocked wallet's own balance stays
  stuck until the token unblocks it.

## Batch claims and gas

Continue mode reverts unless every item can be offered its minimum gas: 200,000
per plain item and 450,000 per signed item. This stops gas estimation settling
on a limit at which every item silently runs dry. An item that needs more than
its minimum can still fail at the estimated limit; submit it with more gas, or
in atomic mode.

Every loop is bounded so each transaction fits the EIP-7825 cap of 16,777,216
gas. `test/economics/GasCap.t.sol` measures the cold worst cases, including
intrinsic and calldata gas:

| Case | Gas |
| --- | --- |
| 64-payee wallet deployment | 4.3M |
| Full atomic plain batch | 6.3M |
| Full atomic signed batch (4 KiB ERC-1271 signatures) | 8.7M |
| Full continue-mode plain batch at its estimated gas | 10.3M |
| Full continue-mode signed batch at its estimated gas | 10.8M |

## Governance

Delay classes follow
[ADR 0002](../../docs/adr/0002-access-manager-hardening.md); the `recover` row is
recorded in ADR 0003. Every allowlist setter is compare-and-set on a per-asset
(or per-product) revision that every change bumps:

| Selector | Role (`src/governance/Roles.sol`) | Class |
| --- | --- | --- |
| `AssetAllowlist.admitAsset` | `Roles.FUNDS_SETTER` | Funds and recipients (14 days) |
| `AssetAllowlist.setDefaultCurrency` | `Roles.FUNDS_SETTER` | Funds and recipients (14 days) |
| `AssetAllowlist.setIncrementFloor` | `Roles.PARAMETER_SETTER` | Standard (48 hours) |
| `AssetAllowlist.deprecateAsset` | `Roles.GUARDIAN` | Immediate (tightening) |
| `RevenueEscrow.recover` | `Roles.FUNDS_SETTER` | Funds and recipients (14 days) |
| `EconomicsResolver.setFeeTerms` | `Roles.FUNDS_SETTER` | Funds and recipients (14 days) |
| `EconomicsResolver.setRoyaltyRate` | `Roles.PARAMETER_SETTER` | Standard (48 hours) |
| `EconomicsResolver.setDefaultLicense` | `Roles.PARAMETER_SETTER` | Standard (48 hours) |

Withdrawals never read the allowlist: a deprecated or never-admitted asset
stays withdrawable from wallets and the escrow (fixes RC1 Medium M-3).
Deprecation is reversible only through a compare-and-set re-admission.

## New work terms

`EconomicsResolver.newWorkTerms(product, payees)` predicts, without deploying:
- `seller`: `walletFor(payees, 0)`, the artist portion's wallet;
- `royaltyReceiver`: `walletFor(Splits.royaltyPayees(seller, feeRecipient, feeShare), 0)`,
  which pays `100,000 - feeShare` to the seller wallet and `feeShare` to the
  network. It is the seller wallet itself when the fee share is zero.

Deploy either wallet later with exactly those payee lists. Funds sent to the
predicted addresses before deployment are split once they exist.

## Not here yet

The settlement recorder (single-use settlement keys) is not part of this
module yet.
