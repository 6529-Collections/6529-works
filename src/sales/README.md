# sales

Shared sale adapters written against a minimal mint interface rather than
against Stream: the English auction (Stream's only primary sale; anti-snipe
clock, pull refunds, escrow fallback, pending claim when NFT delivery fails,
dispute pause), fixed price with allowlist phases and ERC-20 permits, and Dutch
pricing. Each sale locks its currency (ETH or an allowlisted standard ERC-20)
when it starts, and new sale types arrive as new adapters through a timelocked
minter-role grant. Governed by
[ADR 0001 §5](../../docs/adr/0001-v1-scope.md#5-sales-and-auctions), with
§6 (edition sales), §12 (dispute pause) and §16 (federated use).

## Fixed price and Dutch

| File | Role |
| --- | --- |
| `MintSaleBase.sol` | What both adapters share: targets (listed, or active in the federation registry), `LockedTerms` at open, one open sale per `(token, id)`, payment collection, minting per purchase, payouts with the escrow fallback, pull credits, ERC-165. |
| `FixedPriceSale.sol` | `IFixedPriceSale`: allowlist phases, per-wallet caps and prices, artist approval of discounts. |
| `DutchSale.sol` | `IDutchSale`: a descending price from the token's `DutchParams`. |
| `DutchPricing.sol` | The price curve (internal library, ported from PR #744's `StreamDutchPricing`). |
| `ISignatureTransfer.sol` | The one Permit2 entry point the adapters call. |

### Opening a sale

The lead artist (the terms' `creator`) or the PLATFORM role opens a sale. The
adapter reads the token's `primaryTerms(id, "")` and fails closed unless:
- the token is a target;
- the sale kind matches the adapter;
- the currency is active on the asset allowlist;
- a seller and a fee recipient are set and the fee share is at most 100,000.

The terms are then locked as `LockedTerms`:
- `CURRENCY_DEFAULT` is resolved once, through
  `AssetAllowlist.defaultCurrency`. A listed token uses the 6529 Editions
  product; a registry token uses the 6529 Stream Federated product.
- A later change to a product default affects only sales opened afterwards.

Only one sale per `(token, id)` may be open at a time, and closing it frees the
token. Closing a sale that is already closed reverts with `SaleAlreadyClosed`. Price and supply always come from the token, which enforces size,
window and the admitted adapters on every mint.

**Targets.** Governance lists tokens (`setTarget`). From v1.1 a token is also a
target while the federation registry reports it active (`isTarget`). For such
a token, the network fee share comes from its registry entry, and the fee
recipient from the economics resolver's 6529 Stream Federated economics. The
token's own fee terms are ignored. The resolver is fixed at construction and
must support `IEconomicsResolver` through ERC-165; EIP-7702 delegated accounts
are rejected.

The registry is installed by compare-and-set (`setFederationRegistry`).
Installation:
- requires ERC-165 support for `IFederationRegistry`;
- rejects EIP-7702 delegated accounts;
- pins the code hash. A registry whose code later differs is ignored.

**Currency halts.** Every purchase requires its locked currency to be active
on the allowlist, so deprecating an asset halts running sales in it as an
emergency tightening. Claims are never blocked.

### Allowlists

Each fixed-price phase has a time window `[start, end)`, an optional Merkle
root, a per-wallet cap and an optional per-wallet price. A leaf is

```
keccak256(bytes.concat(keccak256(abi.encode(
    keccak256("6529WORKS_ALLOWLIST_LEAF_V1"), chainid, adapter, token, id,
    phase, account, cap, price))))
```

over OpenZeppelin sorted-pair trees (`StandardMerkleTree` compatible), with
proofs of at most 32 nodes. `allowlistLeaf(token, id, …)` computes it before
the sale opens.

**Recipient binding (the fix for PR #744's High finding).** `account` is the
wallet that receives the tokens, or the payer in a payer-keyed phase. The payer
is always authenticated: it is `msg.sender` for direct and EIP-2612 payments,
and the Permit2 signer for intents. Nobody can therefore use another wallet's
leaf to mint to themselves. Anyone may still *pay* for an allowlisted
recipient: the tokens go to that recipient and count against its cap. That is
how gifts are pushed, and it means a third party can spend a recipient's
allowance by buying it for them.

**Caps** count per `(token, id, phase index, keyed wallet)` across sales
(`purchasedOf`). Reopening a token with the same tree never resets them; a
deliberately fresh drop uses new phase indices. An allowlist phase enforces the
leaf's cap, and the phase's `walletCap` too when it is nonzero. A public phase
enforces `walletCap` per recipient.

**Discounts need the artist** (integrator decision 4). A leaf price below the
package price is accepted only in an approved sale. A sale is approved when:
- the creator opens it; or
- the PLATFORM role opens it with the creator's EIP-712
  `PhaseConfiguration(token, id, phasesHash, nonce, deadline)` signature, where
  `phasesHash = keccak256(abi.encode(phases))`.

The nonce is single-use and revocable (`revokeConsentNonce`), and contract
creators sign through ERC-1271. `phaseConfigurationDigest` returns the digest
to sign. Leaf prices at or above the package price need no approval.

**Gifts** are zero-price sales: a package price of zero, or an approved leaf
price of zero.

### Payments

| Method | Payer | What happens |
| --- | --- | --- |
| `DIRECT` | `msg.sender` | ETH as `msg.value`, or a pull of an approved ERC-20. |
| `PERMIT` | `msg.sender` | An EIP-2612 permit for `amount`, then a pull. A permit someone already submitted is tolerated: the pull uses the allowance it granted. |
| `PERMIT2` | the signer | `permitWitnessTransferFrom`; the witness binds the purchase, so a relayer can submit it. |

The Permit2 witnesses are `Typehashes.PURCHASE_WITNESS` (fixed price: sale,
phase, recipient, quantity, the exact amount, deadline) and
`Typehashes.DUTCH_PURCHASE_WITNESS` (sale, recipient, quantity,
`maxUnitPrice`, deadline).

Permit2 binds the token, the maximum amount, the spender (the adapter), the
nonce and the deadline; the witness binds everything else. The adapter checks
the deadline itself and checks both balance deltas after Permit2, because
Permit2 does not. Every ERC-20 movement is exact, so fee-on-transfer, rebasing,
no-return and false-returning tokens revert. Replay protection is the token's
or Permit2's nonce, never signature bytes.

Fixed price charges exactly `quantity × unit price`, and `Payment.amount` must
equal it. In a Dutch sale, `Payment.amount` is the most the buyer will pay. An
ERC-20 payment is charged exactly the current price, and ETH above the charge
is credited to the payer and claimed with `claim`.

### Payouts

Each purchase mints to the recipient, then pays the network fee
(`floor(total × feeShare / 100,000)`) and the seller (the rest). The seller is
the work's predicted split wallet, which may not be deployed yet. An ETH payout
forwards 100,000 gas. A wallet that refuses, or a token that blocks it (as USDC
can), is paid through the revenue escrow instead, so no recipient can block a
sale. Nothing is kept: a fixed-price adapter holds no funds between
transactions, and a Dutch adapter holds exactly its outstanding ETH credits.

### Dutch clearing semantics

There is no clearing price.
- Each purchase pays the unit price of the block it lands in.
- Copies already sold are never repriced, and there is no rebate when the price
  later falls.
- The price falls from the package price to `restingPrice` over `duration`
  seconds: linearly, or in equal drops every `stepSeconds`, which must divide
  the duration.
- The reduction is rounded down, so the price never falls below the exact
  curve.
- After the curve, the price rests at `restingPrice` until the supply or window
  runs out or the sale is closed.
- `maxUnitPrice` protects a buyer whose transaction lands earlier than expected.

### Governance

| Selector | Role |
| --- | --- |
| `setTarget`, `setFederationRegistry` | SUCCESSOR_SETTER (30 days) |
| `openSale`, `closeSale` | PLATFORM (the creator needs no role) |
| `revokeConsentNonce` | the creator itself |

The PLATFORM check uses the AccessManager's `canCall` for the selector, and
needs an immediate (zero-delay) grant. The creator who may close a sale is read
from the token at close time, so after a recovery the old key loses that
power. Nothing here is payable except `purchase`.

### Gas

Measured cold in `test/sales/*/…GasCap.t.sol`, including intrinsic and calldata
gas. The cap is EIP-7825's 16,777,216.

| Transaction | Gas |
| --- | --- |
| `openSale` with 16 phases and a 4 KiB ERC-1271 consent | about 1.50M |
| Fixed-price purchase: Permit2, 32-node proof, two escrowed token payouts | about 0.45M |
| Fixed-price purchase: ETH, 32-node proof, two gas-burning wallets | about 0.48M |
| Dutch purchase: ETH credit, two gas-burning wallets | about 0.45M |
| Dutch purchase: Permit2, two escrowed token payouts | about 0.40M |

These figures use a mock edition, so the real 6529 Editions mint adds its own
cost.
