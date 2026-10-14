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
| `MintSaleBase.sol` | What both adapters share: targets (listed, or active in the federation registry), `LockedTerms` at open, one open sale per `(token, id)`, payment collection, minting per purchase, payouts with the escrow fallback, pull credits, the emergency pause, ERC-165. |
| `FixedPriceSale.sol` | `IFixedPriceSale`: allowlist phases, per-wallet caps and prices, artist approval of discounts. |
| `DutchSale.sol` | `IDutchSale`: a descending price from the token's `DutchParams`. |
| `DutchPricing.sol` | The price curve (internal library, ported from PR #744's `StreamDutchPricing`). |

Permit2 is called through the shared
[`ISignatureTransfer`](../interfaces/external/ISignatureTransfer.sol).

### Opening a sale

The lead artist (the terms' `creator`) or the PLATFORM role opens a sale. The
adapter reads the token's `primaryTerms(id, "")` and fails closed unless:
- the token is a target;
- the sale kind matches the adapter;
- a priced sale names its currency (`CURRENCY_DEFAULT` is only for zero-price
  gifts);
- the economics resolver accepts the currency (`resolveCurrency`), returning
  exactly the currency the token named unless it named `CURRENCY_DEFAULT`
  (`CurrencyMismatch`);
- a seller is set, a fee recipient is set unless the fee share is zero, and the
  fee share is at most 100,000.

The terms are then locked as `LockedTerms`:
- `CURRENCY_DEFAULT` is resolved once, through `resolveCurrency`. A listed
  token uses the 6529 Editions product; a registry token uses the 6529 Stream
  Federated product.
- A later change to a product default affects only sales opened afterwards.

Only one sale per `(token, id)` may be open at a time, and closing it frees the
token. Closing a sale that is already closed reverts with `SaleAlreadyClosed`.
Anyone may close a fixed-price sale whose phases have all ended. Price and
supply always come from the token, which enforces size, window and the admitted
minters on every mint.

**Targets.** Governance lists tokens (`setTarget`). From v1.1 a token is also a
target while the federation registry reports it active (`isTarget`). Such a
token:
- must run the code its registry entry records;
- pays the network fee share of its entry to the economics resolver's
  federated fee recipient (`networkFeeRecipient`), ignoring its own fee terms;
- stops selling as soon as the registry delists it. Every purchase re-checks
  `isActive`.

The resolver is fixed at construction. It must support `IEconomicsResolver`
through ERC-165, and EIP-7702 delegated accounts are rejected. Its asset
allowlist is read once, and it must:
- have code;
- not be EIP-7702 delegated;
- support `IAssetAllowlist`, if it answers ERC-165 at all.

The economics lane's `AssetAllowlist` implements no ERC-165, so it passes on
the first two checks; it is trusted as the resolver's own dependency.

The registry is installed by compare-and-set (`setFederationRegistry`).
Installation:
- requires ERC-165 support for `IFederationRegistry`;
- rejects EIP-7702 delegated accounts;
- pins the code hash. A registry whose code later differs is ignored.

**Currency halts.** Every purchase requires its locked currency to be active
on the allowlist, so deprecating an asset halts running sales in it as an
emergency tightening. Claims are never blocked.

**Halts stop the clock.** A pause of the adapter, or a deprecation of a sale's
currency, stops the sale's schedule as well as its purchases. Each sale records,
when it opens, how long the adapter has been paused and its currency deprecated
so far; the growth since is the sale's `scheduleDelay(saleId)`. Fixed-price
phase windows and the Dutch curve run that much later than configured, so a halt
never uses up an allowlist phase or lets the Dutch price fall: trading resumes
where it stopped. A pause during a deprecation counts twice, which only moves the
schedule later. The adapter's own pause time is `pausedTotal` plus the running
pause; the currency's is the allowlist's `statusClock`. Anyone may close a
fixed-price sale once its moved phases have all ended.

**Emergency pause.** `pause` (PAUSER, immediate) makes `openSale` and
`purchase` revert with `SalePaused` on an adapter, and `unpause` (UNPAUSER)
resumes them. `closeSale` and `claim` always work. As on the auction, pausing a
paused adapter reverts with `SalePaused`, and unpausing one that is not paused
reverts with `NotPaused`. An unpause is refused with `UnpauseTooEarly` until 48
hours (`Roles.STANDARD`) after the pause: AccessManager counts the UNPAUSER delay
from scheduling, so an unpause scheduled before the pause could otherwise undo it
in the same block. The adapter counts the delay from the pause, so the guardians
always have that window to cancel it. The auction's `unpause` and its per-auction
`resume` follow the same rule.

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
the sale opens. Tooling must emit at most one leaf per account and phase:
otherwise a relayer could choose among a wallet's leaves.

**Recipient binding (the fix for PR #744's High finding).** `account` is the
wallet that receives the tokens, or the payer in a payer-keyed phase. The payer
is always authenticated: it is `msg.sender` for direct and EIP-2612 payments,
and the Permit2 signer for intents. Nobody can therefore use another wallet's
leaf to mint to themselves. Anyone may still *pay* for an allowlisted
recipient: the tokens go to that recipient and count against its cap. That is
how gifts are pushed, and it means a third party can spend a recipient's
allowance by buying it for them.

**Caps** count per `(token, id, phase index, keyed wallet)` across sales, read
with `purchased(token, id, phase, account)`. Public phases share counts by
phase index too. Reopening a token with the same tree never resets them; a
deliberately fresh drop uses new phase indices. That means padding: the new
sale keeps placeholder phases (for example, already-ended windows) at the old
indices and puts the new phases after them, within `Limits.MAX_PHASES` (16)
per sale. Placeholders count toward `SaleStarted.startTime`, the earliest phase
start. An allowlist phase enforces the
leaf's cap, and the phase's `walletCap` too when it is nonzero. A public phase
enforces `walletCap` per recipient.

**Discounts need the artist** (integrator decision 4). A leaf price below the
package price is accepted only in an approved sale. A sale is approved when:
- the creator opens it; or
- the PLATFORM role opens it with the creator's EIP-712 signature over
  `PhaseConfiguration(token, id, currency, packagePrice, Phase[] phases, nonce,
  deadline)`.

The phases are typed (`Phase(start, end, root, walletCap, payerKeyed,
leafPriced)`), so wallets show every window, cap and flag. The currency and
package price are the sale's resolved terms, so an approval never carries over
to another currency or price.

The nonce is single-use and revocable (`revokeConsentNonce`), and contract
creators sign through ERC-1271. `phaseConfigurationDigest` returns the digest
to sign. Leaf prices at or above the package price need no approval, except in a
zero-price sale: there every priced leaf needs the artist's approval
(`PricedLeavesNeedApproval`), because only the approval binds the currency a
default-currency gift resolves to.

**Gifts** are zero-price sales: a package price of zero, or an approved leaf
price of zero. A gift pays no network fee, by design.

### Payments

| Method | Payer | What happens |
| --- | --- | --- |
| `DIRECT` | `msg.sender` | ETH as `msg.value`, or a pull of an approved ERC-20. |
| `PERMIT` | `msg.sender` | An EIP-2612 permit for `amount` (the 65-byte `r \|\| s \|\| v`; any other length reverts with `InvalidPayment`), then a pull. A permit someone already submitted is tolerated: the pull uses the allowance it granted. |
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

The fixed-price, Dutch and auction adapters share these rules and their errors: a
claim to the zero address reverts with `InvalidRecipient`, an ETH claim the recipient
refuses with `ClaimFailed` (the credit is kept), and a token that misreports the
payer's balance around a Permit2 transfer with `TokenBalanceMismatch`.

Fixed price charges exactly `quantity × unit price`, and `Payment.amount` must
equal it. In a Dutch sale, `Payment.amount` is the most the buyer will pay. An
ERC-20 payment is charged exactly the current price, and ETH above the charge
is credited to the payer and claimed with `claim`.

### Payouts

Each purchase mints to the recipient, then pays the network fee
(`floor(total × feeShare / 100,000)`) and the seller (the rest). A zero amount is
not paid at all, so terms with a zero fee share need no fee recipient. The seller is
the work's predicted split wallet, which may not be deployed yet. An ETH payout
forwards 100,000 gas. A wallet that refuses, or a token that blocks it (as USDC
can), is paid through the revenue escrow instead, so no recipient can block a
sale. Nothing is kept: a fixed-price adapter holds no funds between
transactions, and a Dutch adapter holds exactly its outstanding ETH credits.

### Events for indexers

A recipient's ERC-1155 hook runs inside `purchase`, and a creator's hook may
close the sale there. So a purchase's `SaleSettled` can follow its sale's
`SaleClosed`. Treat `SaleClosed` as "no new purchases", not as the last event
of a sale. A Dutch `SaleStarted.endTime` is when the curve reaches its resting
price; the sale itself continues until closed or sold out.

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
- A pause or a currency deprecation moves the whole curve later by its length
  (`scheduleDelay`), so the price resumes where it stopped.
- `maxUnitPrice` protects a buyer whose transaction lands earlier than expected.

### Governance

| Selector | Role |
| --- | --- |
| `setTarget`, `setFederationRegistry` | SUCCESSOR_SETTER (30 days) |
| `openSale`, `closeSale` | PLATFORM (the creator needs no role; anyone closes an ended fixed-price sale) |
| `pause` | PAUSER (immediate) |
| `unpause` | UNPAUSER |
| `revokeConsentNonce` | the creator itself |

The PLATFORM check uses the AccessManager's `canCall` for the selector, and
needs an immediate (zero-delay) grant. The creator who may close a sale is read
from the token at close time (the artist's active authority), so after a
recovery the old key loses that power, and while a recovery override is pending
nobody but PLATFORM can close it. Nothing here is payable except `purchase`.

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
