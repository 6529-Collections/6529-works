# Buying, bidding, settling and claiming

For marketplace and wallet engineers, relayers and keepers: how to start, bid on and settle a
6529 Stream auction, bid on 6529 Stream Editions copies in the edition auction, claim what is
owed, and read royalties. Rules are in [Stream and auctions](../spec/stream-and-auctions.md#rules-and-invariants) (`AUC-n`),
[Editions and sales](../spec/editions-and-sales.md#rules-and-invariants) (`ED-n`, `EA-n`) and
[Economics and payouts](../spec/economics-and-payouts.md#rules-and-invariants) (`ECO-n`); event
signatures in [Events and indexing](events-and-indexing.md); addresses in [Addresses](addresses.md).

> Pre-audit. See the [project status](../../README.md#status).

Sepolia r4 ([Addresses](addresses.md#sepolia-r4)) runs `main` at `1e7022b`: the 1/1 auction,
the uniform edition auction and the claims as this page describes them, with 1-hour 1/1
auctions (a testnet setting). The superseded r3 runs `v1.0.0-rc.1`, with the edition terms
and the fixed-price and Dutch edition adapters that ADR 0005 replaced. The superseded r2 predates the October 2026 review fixes: it
has no `claimFor`, ERC-20 payout frame, `scheduleDelay`, currency freeze,
`SHORTFALL_REVERT_CEILING` or identity restraint
([Addresses](addresses.md#sepolia-r2-superseded)). Sepolia gas figures here are r2's; r3's
and r4's (with every edition-auction step) are in
[the flows file](../../deployments/11155111/flows.md#r4-the-rc2-candidate-1-november-2026).

## Before you start

### Contracts you call

| Contract | Interface | You call it to |
| --- | --- | --- |
| `EnglishAuction` | [IEnglishAuction](../../src/interfaces/IEnglishAuction.sol) | start, bid, withdraw, settle, claim |
| `UniformEditionAuction` | [IUniformEditionAuction](../../src/interfaces/IUniformEditionAuction.sol) | open an edition's sale, bid, raise, withdraw during a 1/1 dispute, settle, claim |
| `Stream` | [IStream](../../src/interfaces/IStream.sol), [IMintTarget](../../src/interfaces/IMintTarget.sol) | preview a start, read works, `royaltyInfo` |
| `Editions` | [IEditions](../../src/interfaces/IEditions.sol) | read editions, `royaltyInfo` |
| `PackageRegistry` | [IPackageRegistry](../../src/interfaces/IPackageRegistry.sol) | check approvals, acceptances and move nonces; relay acceptances; get the move digest |
| `VrfEntropyModule` | [IEntropyModule](../../src/interfaces/IEntropyModule.sol) | request a VRF seed |
| `AssetAllowlist` | [IAssetAllowlist](../../src/economics/interfaces/IAssetAllowlist.sol) | read a currency's status and increment floor |
| `RevenueEscrow` | [IRevenueEscrow](../../src/economics/interfaces/IRevenueEscrow.sol) | flush refused payouts |
| `SplitWallet`, `SplitFactory` | [ISplitWallet](../../src/economics/interfaces/ISplitWallet.sol), [ISplitFactory](../../src/economics/interfaces/ISplitFactory.sol) | deploy a wallet, release a share |
| `ReleaseVerifier` | [IReleaseVerifier](../../src/economics/interfaces/IReleaseVerifier.sol) | build and revoke signed releases |
| `ClaimRouter` | [IClaimRouter](../../src/economics/interfaces/IClaimRouter.sol) | batch releases |

The sale adapters share [`ISaleAdapter`](../../src/interfaces/ISaleAdapter.sol): `SaleStarted`,
`SaleSettled`, `Credited`, `Claimed`, `claim`, `claimable`, `paused` and the shared errors.

### Conventions

- **Currencies.** `CURRENCY_ETH` is `address(0)`. `CURRENCY_DEFAULT` is
  `address(type(uint160).max)`; in a package it means "the product's default currency when the sale
  starts" ([EconomicsTypes.sol](../../src/interfaces/types/EconomicsTypes.sol)). Every sale locks
  its resolved currency when it starts or opens (AUC-15). Edition auctions take ETH only (EA-4).
- **Shares and rates** are out of 100,000 (`Splits.DENOMINATOR`, ECO-1): 6.529% is 6,529.
- **Errors** are custom errors. A nested contract's error (Stream, the package registry, the
  allowlist, Permit2, a token) bubbles up unchanged: decode against every ABI on the path
  ([ABIs and interface IDs](abis-and-interface-ids.md)).
- **Simulate first.** Run every write with `eth_call`, and take the gas limit from
  `eth_estimateGas` on the target chain ([Prague gas and Glamsterdam gas](#prague-gas-and-glamsterdam-gas)).

### The `Payment` struct

Every English-auction bid carries one `Payment`
([SaleTypes.sol](../../src/interfaces/types/SaleTypes.sol)):

| Field | Type | Meaning |
| --- | --- | --- |
| `method` | `PaymentMethod` | `DIRECT` (0), `PERMIT` (1) or `PERMIT2` (2) |
| `payer` | `address` | The bidder or buyer of record. Refunds and credits go to it. For `DIRECT` and `PERMIT` it must be `msg.sender`; for `PERMIT2` it is the signer, and anyone may submit. |
| `amount` | `uint256` | The exact bid |
| `deadline` | `uint256` | The permit's deadline (`PERMIT`, `PERMIT2`); ignored for `DIRECT` |
| `nonce` | `uint256` | The Permit2 nonce; zero otherwise |
| `signature` | `bytes` | `PERMIT`: exactly 65 bytes, `r \|\| s \|\| v`. `PERMIT2`: the Permit2 signature. `DIRECT`: empty |

The auction collects it in `_collect`
([EnglishAuction.sol](../../src/sales/EnglishAuction.sol)):

- **ETH** takes `DIRECT` only, with `payer == msg.sender` and `msg.value == amount`; anything else
  reverts with `InvalidPayment()`.
- **An ERC-20** takes `msg.value == 0`. For `DIRECT`, the payer approved the adapter beforehand.
  For `PERMIT`, an EIP-2612 permit of `amount` to the adapter; a permit that fails (say,
  submitted first by someone else) is ignored, and the pull uses whatever allowance exists. For
  `PERMIT2`, the payer approved the canonical Permit2 once and signs a witness transfer (below).
- An expired `PERMIT` or `PERMIT2` deadline reverts with `PaymentExpired(deadline)`, even where an
  allowance would cover the pull.

**Which ERC-20s work** ([TokenTransfer.sol](../../src/economics/TokenTransfer.sol)):

- **Balance deltas, on every path.** A fee-on-transfer or rebasing token reverts with
  `TokenBalanceMismatch(asset)`.
- **Return values, except under `PERMIT2`.** Every other movement also requires exactly one
  `true` word back (`TokenCallFailed(asset, selector)`;
  `test_NoReturnAndFalseReturningTokensFailClosed` in
  [EnglishAuctionHostile.t.sol](../../test/sales/auction/EnglishAuctionHostile.t.sol)). Around a
  `PERMIT2` pull the adapter checks only balances, and Permit2 accepts a token that returns
  nothing (`test_Bid_APermit2PullMustMoveBothBalancesByExactlyTheAmount` in
  [EnglishAuctionHostile.t.sol](../../test/sales/auction/EnglishAuctionHostile.t.sol)).
- **Governance is the guard.** A currency is usable only once `AssetAllowlist.admitAsset`
  (FUNDS_SETTER, 14 days) admits it, and governance admits standard ERC-20s only; the admission
  probe is not a behavior check (ECO-32).

### Signing a Permit2 payment

A `PERMIT2` payment is a Permit2 `permitWitnessTransferFrom`, signed in Permit2's own EIP-712
domain. The witness binds the action, so a relayer can submit it and cannot change it
(AUC-19).

- The signed type is `PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,`
  followed by the action's witness type string.
- `permitted` is `(currency, payment.amount)`, `spender` is the adapter, and `nonce` and `deadline`
  are `payment.nonce` and `payment.deadline`.
- The witness is `keccak256(abi.encode(WITNESS_TYPEHASH, field1, field2, ...))`, with the fields
  below in order. The type strings and typehashes are in
  [ABIs and interface IDs](abis-and-interface-ids.md#permit2-witnesses).

| Action | Witness typehash | Witness fields |
| --- | --- | --- |
| `bid` | `BID_WITNESS` | `saleId`, the recipient **resolved** (the payer when zero), `payment.amount`, `payment.deadline` |
| `startWithBid` | `START_BID_WITNESS` | `token`, `keccak256(mintData)`, the recipient **resolved**, `payment.amount`, `payment.deadline` |

When the auction's `permit2()` is zero, a `PERMIT2` payment reverts with `InvalidPayment()`.

## Starting an auction

Starting is permissionless: one transaction mints the work into the auction's custody and starts
its clock. Whoever submits it pays the gas; the network is not obliged to
([ADR 0001 §5](../adr/0001-v1-scope.md#5-sales-and-auctions)).

```solidity
function start(address token, bytes calldata mintData) external returns (uint256 saleId);

function startWithBid(
    address token,
    bytes calldata mintData,
    address recipient,
    Payment calldata payment
) external payable returns (uint256 saleId);

function saleIdOf(address token, uint256 tokenId) external pure returns (uint256);
```

- `token` is the 6529 Stream address; `mintData` is `abi.encode(StreamMintRequest)` (below).
- The sale ID is `uint256(keccak256(abi.encode(token, tokenId)))`. Take it from the return value or
  from `SaleStarted`; the token ID is assigned at mint.
- `startWithBid` also places the first bid, with the bid's payer as the bidder of record; a
  relayer can submit it with a `PERMIT2` bid.

### Building the `StreamMintRequest`

[PackageTypes.sol](../../src/interfaces/types/PackageTypes.sol) defines the request:

| Field | Type | Where it comes from |
| --- | --- | --- |
| `packageRoot` | `bytes32` | The approved package root, from the published package document |
| `item` | `PackageItem` | The item, exactly as published in the package document |
| `proof` | `bytes32[]` | The Merkle proof that places the item's leaf under the root, at most 32 nodes (`Limits.MAX_PROOF_DEPTH`) |
| `move.nonce` | `uint256` | The lead artist's move nonce |
| `move.deadline` | `uint64` | When the move signature expires |
| `move.signature` | `bytes` | The lead artist's `MoveToStream` signature |

The item hash, leaf and tree are OpenZeppelin's `StandardMerkleTree` over
`[PACKAGE_ITEM_DOMAIN, item]` ([Curation](../spec/curation.md#identifiers-and-hashes)), so the
package tooling's proofs verify directly.

**Check before you submit:**

1. `PackageRegistry.packageOf(root)` returns `APPROVED`.
2. `PackageRegistry.consumedItemOf(item.contentHash)` is zero.
3. `PackageRegistry.acceptedAs(root, party.account)` is nonzero for every `item.parties[i]`.
4. `Stream.collection(item.collectionId)` does not revert.
5. The move is unexpired and `PackageRegistry.isMoveNonceUsed(artistId, nonce)` is false.
6. For a VRF item, `IEntropyModule.isDeliveredContent(item.contentHash)` is true (the check
   `Stream.mint` makes; `isDelivered(itemHash)` answers the same for an item `requestSeed` linked).
7. The currency is usable ([The currency](#the-currency)).
8. `Stream.primaryTerms(0, mintData).creator` is nonzero, so the lead artist is not
   [restrained](../glossary.md#restraint). This preview does not check the proof, acceptances or
   move.
9. `EnglishAuction.paused()` is false.

### The move signature

The lead artist signs the [move](../glossary.md#move) off-chain, in the package registry's EIP-712
domain (name `6529 Works Package Registry`, version `1`, the chain ID, the registry's address), over
`MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)`
(`Typehashes.MOVE_TO_STREAM`). `PackageRegistry.moveDigest(packageRoot, itemHash, nonce, deadline)`
returns the digest to sign.

- **Signer.** The active authority of the lead artist's ID
  (`IArtistRegistry.activeAuthorityOf(artistId)`), where the artist ID is
  `PackageRegistry.acceptedAs(root, item.parties[0].account)`.
- **Signature forms.** 65-byte ECDSA, 64-byte ERC-2098, ERC-1271 (at most 4,096 bytes) and
  EIP-7702 accounts ([SignatureVerifier.sol](../../src/libraries/SignatureVerifier.sol)).
- **Nonce.** Any unused `uint256`, single use per artist ID. Use them in order from 0: the first
  255 share an existing storage word, which keeps the start within its gas budget. The artist
  revokes an unused one with `revokeMove(artistId, nonce)`. A move signed by a rotated-away
  authority stays void.

### Encoding `mintData`

Encode the request as one tuple. Stream reads it in place and reverts with
`IMintTarget.InvalidMintRequest()` unless the first word is `0x20` (`_request` in
[Stream.sol](../../src/stream/Stream.sol)). In Solidity, as the Sepolia driver
[Flows.s.sol](../../script/sepolia/Flows.s.sol) does:

```solidity
bytes memory mintData = abi.encode(
    StreamMintRequest(packageRoot, item, proof, MoveAuthorization(nonce, deadline, signature))
);
```

Off-chain, encode a single parameter of this type (for example with ethers'
`AbiCoder.encode([REQUEST], [request])`):

```text
tuple(
  bytes32 packageRoot,
  tuple(
    uint8 kind, uint256 collectionId, bytes32 contentHash, bytes32 mediaHash, bytes32 recordFileId,
    tuple(address account, uint8 role)[] parties,
    tuple(uint256 artistId, address account, uint32 share)[] payees,
    tuple(string spdxId, bytes32 textFileId) license,
    uint8 seedPolicy, bytes32 seed,
    tuple(bytes32 saleKind, address currency, bytes params) sale,
    tuple(uint8 format, uint64 size, uint64 window, uint256 price, address currency, bytes32 saleKind, bytes params) edition
  ) item,
  bytes32[] proof,
  tuple(uint256 nonce, uint64 deadline, bytes signature) move
)
```

Do not encode the four members as four separate parameters: that drops the leading offset word.

### VRF works

A work whose item has `seedPolicy == VRF` starts only after its seed is delivered (AUC-4):

1. Anyone calls `requestSeed(item, packageRoot, proof)` on the entropy module.
2. Wait for `SeedDelivered(contentHash, requestId, seed)`; on Sepolia it arrived five blocks after
   the request ([flows §6](../../deployments/11155111/flows.md#6-vrf)).
3. Check `isDeliveredContent(item.contentHash)`, then start.

If no seed arrives, anyone may request again once `retryDelay()` has passed (at least 3 days,
`VrfEntropyModule.MIN_RETRY_DELAY`); earlier calls revert with `RequestPending(itemHash, retryAt)`.

### The currency

The currency locks at start (AUC-15). `CURRENCY_DEFAULT` resolves to
`AssetAllowlist.defaultCurrency(PRODUCT_STREAM)`, ETH at launch; an explicit currency must be
active. An unusable currency reverts with `CurrencyNotConfigured(product)` or
`AssetNotActive(asset)`. Read the locked currency from `SaleStarted.currency` or
`auction(saleId).currency`, never from the current default.

```mermaid
sequenceDiagram
    participant Artist as Lead artist
    participant Starter as Starter, anyone
    participant Entropy as VrfEntropyModule
    participant Auction as EnglishAuction
    participant Stream
    participant Registry as PackageRegistry
    Artist->>Starter: MoveToStream signature, off-chain
    opt VRF work
        Starter->>Entropy: requestSeed(item, packageRoot, proof)
        Entropy-->>Starter: SeedDelivered, a few blocks later
    end
    Starter->>Auction: start(stream, mintData)
    Auction->>Stream: mint(auction, 0, 1, mintData)
    Stream->>Registry: consume(packageRoot, item, proof, move)
    Registry-->>Stream: itemHash, artistId
    Note over Stream: checks the VRF seed, assigns the token ID and serial
    Stream-->>Auction: tokenId, PrimaryTerms
    Note over Auction: locks currency, opening bid, increment share, window
    Auction-->>Starter: saleId, SaleStarted
```

**Events.** `ItemConsumed` ([PackageRegistry](events-and-indexing.md#packageregistry)), the mint's
`Transfer` and `WorkMinted` ([Stream](events-and-indexing.md#stream)), and `SaleStarted`, whose
`price` is the locked opening bid and `endTime` the initial end, plus `BidPlaced` for
`startWithBid` ([EnglishAuction](events-and-indexing.md#englishauction)).

### Errors

Errors come from `EnglishAuction` (`SalePaused`, `TargetNotAllowed`, `InvalidSaleTerms`), `Stream`
(`InvalidMintRequest`, the item-rule errors below, `SeedNotDelivered`), `AssetAllowlist`
(currency), `PackageRegistry`, or the shared `SignatureVerifier` and `Dependency` errors.

| Error | Cause | What to do |
| --- | --- | --- |
| `SalePaused()` | The emergency pause stops starts only (AUC-13). | Wait: an unpause comes at least 48 hours after the pause. |
| `TargetNotAllowed(token)` | `token` is not a served token contract. | Use the Stream address. |
| `InvalidMintRequest()`, `InvalidItemSale()`, `InvalidLeadArtist()`, `UnknownCollection(collectionId)`, `InvalidSeedPolicy()`, `InvalidLicenseId()`, `InvalidWorkTerms()`, `TermsCapacityExceeded()` | Malformed `mintData`, a missing collection, or item terms Stream refuses (AUC-2). | Fix the request. |
| `PackageNotApproved(packageRoot)`, `ContentUsed(product, contentHash, claimedBy)`, `ContentReserved(contentHash, beneficiary)` | The root is unknown or revoked; the item already started, or its content is claimed by or reserved for another item. | Nothing to start. |
| `ItemNotInPackage(packageRoot, itemHash)` | The proof does not place the item, or has more than 32 nodes. | Rebuild the proof. |
| `PartyNotAccepted(packageRoot, account)` | A party has not accepted the root. | Relay its signed acceptance with `acceptPackage(packageRoot, acceptance, signature)`. |
| `InvalidItem(itemHash)` | Parties, payees, seed or edition fields are inconsistent. | Report it to curation. |
| `SignatureExpired(deadline)`, `InvalidSignature(signer)` | The move expired, was signed by another key, or the lead artist is restrained. | Get a fresh move, or wait for the override's outcome. |
| `MoveNonceUsed(artistId, nonce)` | The nonce was spent or revoked. | Ask for a move with a new nonce. |
| `SeedNotDelivered(itemHash)` | A VRF work's seed has not arrived. | Request the seed and wait. |
| `AssetNotActive(asset)`, `CurrencyNotConfigured(product)` | The item's currency, or the product default, is not usable. | Wait for governance. |
| `InvalidSaleTerms(token, id)` | The token returned unusable terms (AUC-14). | Report it. |

`startWithBid` can also revert with any bidding error below.

### Gas

A steady-state `start`'s Prague gas and new slots are in the
[ADR 0004 table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table) (AUC-32), with the
costlier first-time cases (an artist's first start, with and without a bid, which on a
collision of its terms' position writes one slot more; LIM-GAS-10) and the ERC-20 Permit2
`startWithBid`.

## Bidding

```solidity
function bid(uint256 saleId, address recipient, Payment calldata payment) external payable;
function minimumBid(uint256 saleId) external view returns (uint256);
function auction(uint256 saleId) external view returns (Auction memory);
```

`recipient` receives the token if the bid wins; zero means the payer. It cannot be the auction
itself (`InvalidRecipient(recipient)`).

- **The amount.** The bid is `payment.amount` exactly; there is no "bid up to" form. Read
  `minimumBid(saleId)` just before you submit (the rule is AUC-16). Live parameters are in
  `config()` and `AssetAllowlist.incrementFloor(currency)`; launch defaults are in the
  [script README](../../script/README.md#environment-reference). A bid above `type(uint96).max`
  reverts with OpenZeppelin's `SafeCastOverflowedUintDowncast`.
- **[Anti-snipe](../glossary.md#anti-snipe).** A bid in the last `extensionWindow` moves the end
  (AUC-17); `BidPlaced.endTime` carries the end after the bid. A bid at or after the end reverts
  with `InvalidAuctionState(saleId, ENDED)` (`test_Bid_AntiSnipeExtends` in
  [EnglishAuction.t.sol](../../test/sales/auction/EnglishAuction.t.sol)).
- **Outbid [credits](../glossary.md#credit).** An outbid bid, even by the same bidder, is credited
  to its payer, never pushed (AUC-18), and claimed with `claim(currency, to)`.

### Paying

Pay as in [The `Payment` struct](#the-payment-struct). With `PERMIT2`, anyone may submit the
bidder's signed bid:

```mermaid
sequenceDiagram
    participant Bidder as Bidder, the payer
    participant Relayer
    participant Auction as EnglishAuction
    participant Permit2
    Bidder->>Bidder: sign PermitWitnessTransferFrom with the Bid witness
    Bidder->>Relayer: Payment with method PERMIT2
    Relayer->>Auction: bid(saleId, recipient, payment)
    Note over Auction: checks minimumBid, credits the previous bidder, may extend the clock
    Note over Auction: emits BidPlaced, then collects the payment
    Auction->>Permit2: permitWitnessTransferFrom
    Permit2-->>Auction: amount moved from the payer
    Note over Auction: checks both balance deltas, or reverts the whole bid
```

### Withdrawing, and when bids stop

```solidity
function withdrawBid(uint256 saleId) external;
```

Only the high bidder (the payer) may withdraw, and only while the auction is paused for a dispute
or its locked currency is deprecated and the sale has not settled (MARKET-2). The bid is credited
back (`BidWithdrawn`), and its amount stays as a reserve the next bid must reach.

| Halt | Bids revert with | Rule |
| --- | --- | --- |
| [Dispute pause](../glossary.md#dispute-pause) by a guardian, at most 7 days | `InvalidAuctionState(saleId, PAUSED)` | AUC-26, AUC-27 |
| The locked currency is deprecated | `AssetNotActive(currency)` | AUC-25 |
| Emergency `pause()` on the auction | Nothing: it stops only `start` and `startWithBid` | AUC-13 |

A resumed auction emits `AuctionResumed(saleId, endTime)`; an upheld dispute's cancel emits
`AuctionCancelled`, credits the high bid back and burns the token.

### Errors

| Error | Cause | What to do |
| --- | --- | --- |
| `UnknownSale(saleId)` | No such sale. | Check the sale ID. |
| `InvalidAuctionState(saleId, state)` | The auction is paused, ended, settled or cancelled. | Read `auction(saleId).state`. |
| `BidTooLow(required, offered)` | Below `minimumBid`. | Re-read and re-sign. |
| `InvalidPayment()` | Method, amount, `msg.value` or payer mismatch; a `PERMIT` signature that is not 65 bytes; Permit2 disabled. | Fix the payment. |
| `PaymentExpired(deadline)` | The permit deadline passed. | Sign again. |
| `InvalidRecipient(recipient)` | The recipient is the auction. | Name another recipient. |
| `AssetNotActive(currency)` | The locked currency is deprecated (the auction is frozen). | Wait; a standing bidder may withdraw. |
| `TargetNotAllowed(token)` | A federated token's registry entry was delisted (v1.1). | None. |
| `TokenBalanceMismatch(asset)`, `TokenCallFailed(asset, selector)` | A non-standard token, a balance below the amount, or a missing allowance. | Fund and approve, or use another currency. |

### Events and gas

`BidPlaced`, and the auction's `Credited` for the previous bidder when the bid outbids
([EnglishAuction](events-and-indexing.md#englishauction)). A bid that outbids is a row of the
[ADR 0004 table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table).

## Settling

```solidity
function settle(uint256 saleId) external;
function claimDelivery(uint256 saleId, address to) external;
function claimFor(address account, address currency) external returns (uint256 amount);
function pendingDelivery(uint256 saleId) external view returns (address);
```

Settlement is permissionless once `auction(saleId).state == ENDED` (derived from the clock; no
transaction ends an auction), and never depends on the winner accepting the token (AUC-21).

```mermaid
stateDiagram-v2
    [*] --> Active : start or startWithBid
    Active --> Active : bid, may extend the clock
    Active --> Paused : dispute pause by GUARDIAN
    Paused --> Active : resume, or 7 days pass
    Paused --> Cancelled : cancel after an upheld dispute
    Active --> Ended : the clock runs out
    Ended --> Active : settle after a late currency re-admission
    Ended --> Settled : settle
    Settled --> [*]
    Cancelled --> [*]
```

```mermaid
sequenceDiagram
    participant Keeper
    participant Auction as EnglishAuction
    participant Seller as Seller wallet
    participant Fee as Fee recipient
    participant Escrow as RevenueEscrow
    participant Stream
    Keeper->>Auction: settle(saleId)
    Auction->>Stream: settlePrimary(tokenId, SOLD, bidder, currency, price)
    Stream-->>Auction: seller and fee terms (Stream records the sale)
    Auction->>Seller: price minus fee
    Auction->>Fee: fee
    alt a wallet or the token refuses
        Auction->>Escrow: credit for that wallet
    end
    Auction->>Stream: safeTransferFrom to the recipient, 300,000 gas
    alt delivery fails
        Note over Auction: DeliveryPending, the token stays in custody
    end
    Auction-->>Keeper: SaleSettled
```

The fee is `floor(price × feeShare / 100,000)`. The [seller wallet](../glossary.md#seller-wallet)
is a predicted split-wallet address and may not be deployed yet.

### Gas the caller must forward

`settle` refuses to run unless it can give each external call its allowance, plus EIP-150's
1/63, plus a reserve, so a starved call cannot force the escrow or pending route (AUC-22):

| Call | Allowance | Reserve | Revert when short |
| --- | ---: | ---: | --- |
| ETH payout to each wallet | 100,000 (`PAYOUT_GAS`) | 40,000 (`ETH_CALL_RESERVE`) | `PaymentInsufficientGas(100000)` |
| ERC-20 payout frame, per payout | 1,000,000 (`_ERC20_PAYOUT_GAS`), of which the token's `transfer` gets 300,000 (`ERC20_TRANSFER_GAS`) | 50,000 (`DELIVERY_RESERVE`) | `PaymentInsufficientGas(1000000)` |
| Delivery (`safeTransferFrom`) | 300,000 (`DELIVERY_GAS`) | 50,000 (`DELIVERY_RESERVE`) | `DeliveryInsufficientGas()` |

So an ERC-20 `settle` needs a gas limit of about 1.11M although it uses about 140K, and an ETH
`settle` about 460K ([ADR 0004, Security impact](../adr/0004-gas-budgets-under-glamsterdam.md#security-impact);
`test_Settle_SettlerGasLimitVersusGasUsed` in
[EnglishAuction.t.sol](../../test/sales/auction/EnglishAuction.t.sol)).
`eth_estimateGas` returns these; never reuse the gas a past settlement used. The first payout to
a new seller wallet creates its account, at the settler's cost.

### Outcomes and what to do

| Outcome | How you see it | What to do |
| --- | --- | --- |
| Delivered | `Transfer` to the recipient, `SaleSettled` | Nothing. |
| Delivery failed (rejected, or the hook needed more than 300,000 gas) | `DeliveryPending(saleId, recipient)`; `pendingDelivery(saleId)` nonzero | The recipient or the winning bidder calls `claimDelivery(saleId, to)`, `to` neither zero nor the auction. An unsold 6529 Stream work is never pending: Stream moves it to the museum itself (owner decision 17). With no bids on any other token (federated, or listed later), the artist's authority may claim too (AUC-33). |
| A payout refused by the wallet (ETH: reverted or needed over 100,000 gas) or by the token | The escrow's `Credited` | Anyone calls `RevenueEscrow.flush(wallet, asset)`, for a token once it allows it. |
| An ERC-20 payout that failed even through the escrow (MONEY-1, AUC-23) | The auction's `Credited(wallet, token, saleId, amount)` | Anyone calls `claimFor(wallet, token)`; the funds only go to `wallet`. |
| No bid (D140, AUC-24, owner decision 17) | The auction reports UNBID to the token (`settlePrimary`); 6529 Stream moves the work from the auction's custody to the 6529 Network Museum, `IEconomicsResolver.museum()` read then, even while the artist is [restrained](../glossary.md#restraint), and emits `PrimarySaleSettled` with the outcome. `SaleSettled` has `buyer == address(0)`, `price == 0` and the museum as recipient. Any other token's work (federated, or listed later by governance) goes to the creator the token reports. | Nothing. Its edition sale still sells and settles, by anyone's `settle` call after its close ([EA-11](../spec/editions-and-sales.md#rules-and-invariants)). |
| No bid on another token's work while its artist is restrained (IDENTITY-1, AUC-24) | Reverts with `InvalidRecipient(address(0))`: the creator from `IMintTarget.primaryTerms(tokenId, "")` is zero | Retry once the recovery override executes, is vetoed or voided, or lapses. |
| Locked currency deprecated under 30 days | Reverts with `AssetNotActive(currency)` | Wait; the high bidder may `withdrawBid`. |
| Locked currency deprecated 30 days | The high bid is credited back; the auction reports FROZEN_OUT and 6529 Stream moves the work to the museum; any other token's goes to its artist | The bidder claims its credit. |
| Currency re-admitted in the last window or after the end | `AuctionResumed(saleId, endTime)`, no `SaleSettled` | Bid again; settle after the new end. |
| Paused for a dispute | Reverts with `InvalidAuctionState(saleId, PAUSED)` | Wait for the resume, the cancel, or 7 days. |

A sale settles normally during a restraint, with a bid to its winner and without one to the
museum (`test_AuctionWithABidRunningAtStagingSettlesNormally` and
`test_NoBidAuctionRunningAtStagingGoesToTheMuseumAtOnce` in
[RecoveryRestraint.t.sol](../../test/integration/RecoveryRestraint.t.sol)). For the currency freeze
(MARKET-2, AUC-25), read when the deprecation began from `AssetAllowlist.statusClock(currency)`,
which returns `(status, since, inactiveTotal)`, on the auction's `allowlist()`; re-admission comes
no earlier than 14 days after it (ECO-33).

### Keeper checklist

1. Track ends from `SaleStarted.endTime`, every `BidPlaced.endTime`, `AuctionPaused` and
   `AuctionResumed`.
2. At `ENDED`, simulate `settle(saleId)`. A revert with `AssetNotActive`,
   `InvalidRecipient(address(0))` or `InvalidAuctionState(..., PAUSED)` means the sale is waiting:
   retry later.
3. Send with the limit from `eth_estimateGas`.
4. In the receipt, `SaleSettled` means settled; `AuctionResumed` alone means reopened. Follow up
   `DeliveryPending` and both kinds of `Credited` ([Claiming](#claiming)).

### Settlement errors

Besides the reverts in the two tables above:

| Error | Cause |
| --- | --- |
| `UnknownSale(saleId)`, `InvalidAuctionState(saleId, state)` | No such sale, or not `ENDED`. |
| `NoPendingDelivery(saleId)` | `claimDelivery` with nothing pending, or by a caller that may not claim. |
| `InvalidRecipient(to)` | `claimDelivery` to zero or to the auction. |
| `IRevenueEscrow.InvalidAsset(address(0))` | `claimFor` on an ETH credit, which only its bidder claims. |

## Bidding in an edition auction

Copies of a 6529 Stream Editions edition are sold only by the edition auction,
`UniformEditionAuction`, which runs beside the master's 1/1 English auction and closes after it.
Anyone bids a quantity at a price step; at the close the clearing picks how many copies sell and
the one price every winner pays; winners claim their copies and everyone claims the rest of their
escrow. The rules, the clearing and a worked example are in
[Editions and sales](../spec/editions-and-sales.md#the-clearing) (`EA-n`).

An edition's copies are minted only by an adapter governance admitted on 6529 Stream Editions
whose sale kind the edition's terms name
([Editions and sales](../spec/editions-and-sales.md#mint-copies), ED-5). For any edition:

- An edition's ID is its master's Stream token ID. `Editions.edition(editionId)` gives the terms
  (the creator's cap `maxCount`, the currency, sale kind and params), the copies minted so far
  and the bound adapter (`minter`).
- An edition is bound to one adapter, the only one that may mint it (ED-5): the one whose sale
  opened it (`bindMinter`, possibly before the edition exists), or else the first to mint it.
  `EditionMinterBound` names it ([Editions](events-and-indexing.md#editions)).
- `EditionUnavailable(editionId)` from a mint means the creator's cap is reached (ED-6).

The fixed-price and Dutch adapters of `v1.0.0-rc.1` were removed by ADR 0005.

### Finding the sale

- The sale ID is `saleIdOf(editions, editionId)`, `uint256(keccak256(abi.encode(editions,
  editionId)))`, where the edition ID is the master's 6529 Stream token ID. `auction(saleId)`
  reverts with `UnknownAuction` until someone opens it.
- `auction(saleId)` returns the locked terms (`terms`: base price, steps per decade, step count,
  margin, close offset, soft-close window, maximum extension), the creator's cap (`maxCount`, zero for
  none), the seller and fee terms, the status and the book's extent.
- `endTimes(saleId)` returns every clock, read live: the 1/1's end and state, `closeAt` (the 1/1's
  end plus the offset), `softEnd`, `endTime`, the backstop, and `biddingOpen` and
  `withdrawalsOpen`. Show `endTime` as the close; it moves with the 1/1's anti-snipe and with
  late edition bids.

### Opening

```solidity
function open(address token, uint256 id, bytes calldata data) external returns (uint256 saleId);
```

Anyone may open the sale from the 1/1's start until the edition close; the keeper batches it with
the 1/1's `start`. `data` is `abi.encode(item)`, the master's package item exactly as approved:
its hash must equal the item hash Stream stored (`IStream.coreOf`), so no proof is needed. A sale
nobody opens before the close never sells copies by this adapter (LIM-EA-11).

`open` binds the edition to the adapter (`Editions.bindMinter`, `EditionMinterBound`) before it
records the sale: a second adapter of the same kind cannot open it (`MinterMismatch`), and only
the bound adapter ever mints it, even after governance removes it. If the edition does not exist
yet, the binding records the sale's `PRODUCT_EDITIONS` economics in Editions; if it does, the
sale pays the economics it recorded. A sale once opened, voided ones included, is never opened
again (`AuctionExists`).

### The ladder

Bids name a step, not a price. `stepPrice(saleId, step)` and `ladder(saleId)` return the prices
under the sale's locked terms (under `config()` before it opens). The prices are exact wei
amounts from a fixed table, so clients can also compute them, and must match the golden vectors
in [`test/fixtures/edition-auction/`](../../test/fixtures/edition-auction/) (the reference model
is [`tools/edition_auction_ref.py`](../../tools/edition_auction_ref.py)). Snap a typed price to a
step.

### Bidding and raising

```solidity
function bid(uint256 saleId, uint256 step, uint256 quantity) external payable returns (uint256 bidId);
function raise(uint256 saleId, uint256 bidId, uint256 newStep) external payable;
```

- **Pay exactly.** `msg.value` must be `quantity × stepPrice(saleId, step)` for a bid and
  `quantity × (stepPrice(newStep) − stepPrice(step))` for a raise (`IncorrectPayment`).
- **Bids are firm.** A bid can be raised but never lowered, and not withdrawn except while the
  1/1 is paused for a dispute, and then only if it was placed or last raised before the pause's minute (`withdrawBid`,
  below). More copies means another bid. Tell the
  bidder before they sign.
- **The bid ID** runs from 1 in each sale. `bidOf(saleId, bidId)` returns the bidder, step,
  quantity and queue position.
- **Timing.** Bids are accepted while `endTimes(saleId).biddingOpen`. A bid or raise less than
  `softWindow` before `endTime` extends it to `softWindow` after the bid, up to the backstop.
  While the 1/1 is paused for a dispute, bids are accepted at any time and move no clock.
- **A cap.** When the creator capped the edition, the step where the cap binds fills in arrival
  order, and a raise rejoins at the back of its new step.

### What to show before and after a bid

Every figure comes from the views, so no two clients disagree:

| View | Returns | Show it as |
| --- | --- | --- |
| `clearing(saleId)` | The result if the sale closed now: count, step, price, revenue, network fee, best revenue, whether the cut step is rationed | "Right now: 80 editions at 0.0511 ETH each" |
| `bidOutcome(saleId, bidId)` | Copies won, price, escrow, refund, units ahead in the queue; final once settled | "In: 3 at 0.0511 (0.0828 ETH comes back)", "Partly in: 2 of 5" |
| `quote(saleId, step, quantity)` | What a new bid would win, and how many existing units it would push out or pull in. It prices a new bid: for a raise it counts the bid at its old step and its new one, so compute a raise's effect client-side | "→ 81 at 0.0464 · you'd be in · 0 pushed out" |
| `lowestWinningStep(saleId, quantity)` | The lowest step at which a new bid would win at least one unit (not necessarily all `quantity`) | "A bid of 1 gets in from 0.0464" |
| `stepTotals(saleId)` | Live units per step from the lowest used step | The demand ladder |

The lowest winning step can sit below the current price, because of the breadth margin: such a
bid lowers everyone's price. Say so. Both views enforce the sale-wide live-unit limit below
2^32, but neither enforces a capped sale's per-step position capacity (live plus departed units)
or the bid-ID limit, which `bid` enforces.

### Withdrawing during a dispute

```solidity
function withdrawBid(uint256 saleId, uint256 bidId, address to) external;
```

Only while the 1/1 is paused for a dispute (`endTimes(saleId).withdrawalsOpen`), and only
for a bid placed or last raised in a minute, counted from the sale's open, that ended before the
pause began (`WithdrawalsClosed` otherwise; ADR 0005 §12): it sends the whole escrow to `to`. A
bid placed or raised during the pause, in its minute, or in the withdrawal's own block stays
until the outcome. `canWithdraw(saleId, bidId)` answers for one bid. If the dispute is upheld
and the 1/1 cancelled, the sale is void and every remaining bid is refunded in full at its
claim.

### Settling

```solidity
function settle(uint256 saleId, uint256[] calldata order) external returns (bool settled);
// IUniformEditionAuctionLens, answered by the adapter's address too:
function settlementOrderFor(uint256 saleId, address settler) external view returns (uint256[] memory);
function sweepOf(uint256 saleId, address settler)
    external view returns (uint256 swept, uint256 nextPosition, uint256 cutoff);
```

Permissionless once the end has passed and the 1/1 is settled, or at any time once the 1/1 is
cancelled, which voids the sale (`SettlementNotReady` otherwise). When copies sold, the edition
must exist first: call `Editions.createEdition` (permissionless once the master's sale settled;
`EditionNotCreated` otherwise).

Settlement runs in calls of bounded gas, each of which advances it, so no book is too large to
settle. A call scans at most 24 words of the book (eight steps each); the call that finishes the
scan pays the revenue; when a cap binds inside a step that lost bids to raises or withdrawals,
that call and the next ones sweep up to 16, then 96, of its departures. `settle` returns true once
the sale is SETTLED (or VOID) and claims open, false while there is more to do; on a settled sale
it returns true and changes nothing.

**Each settler sweeps on its own.** The sweep's progress belongs to `msg.sender`: pass
`settlementOrderFor(saleId, you)`, the rest of your own sweep in position order (empty unless a
cap binds inside such a step), and call `settle(saleId, order)` from the same address until it
returns true. The first settler to sweep every departure settles the sale. A reordered order
reverts (`InvalidSettlementOrder`); an order that skips a departure is accepted but can never
finish your sweep, and changes nobody else's: settle from another address. `sweepOf(saleId,
you)` shows your progress, and `DeparturesSwept` reports it, so interleaved settlers' events can
show `swept` going down.

**Never settle through a shared public relayer** such as Multicall3: every caller of the relayer
is one `msg.sender`, so they share one sweep, which one caller's wrong order strands for all of
them. Settle directly, or through a contract of your own.

Keeper checklist ([runbook](../../script/README.md#the-edition-auction-keeper)): open the edition
sale with the 1/1's `start`; after the 1/1 settles, call `createEdition`, then, once `endTime`
has passed, `settle(saleId, settlementOrderFor(saleId, keeper))` from the keeper's own address
until it returns true; push claims with `claimBidFor` for bidders who do not claim.

### Claiming copies and refunds

```solidity
function claimBid(uint256 saleId, uint256 bidId, address to) external returns (uint256 unitsWon, uint256 refund);
function claimBidFor(uint256 saleId, uint256 bidId) external returns (uint256 unitsWon, uint256 refund);
```

- `claimBid` is the bidder's: it mints the copies won to `to` and sends the refund,
  `escrow − unitsWon × price`, to `to`. A loser's refund is its whole escrow.
- `claimBidFor` is anyone's: the copies go to the bidder and the refund is credited to its
  `claimable` ETH, which it takes with `claim(address(0), to)` ([below](#credits-on-a-sale-adapter)).
- **The recipient must accept ERC-1155.** A recipient whose hook rejects the copies reverts the
  claim; claim to another address.
- Copies exist only once claimed: the edition's supply reaches the clearing count when every
  winning bid is claimed.

### Events

`AuctionOpened`, `BidPlaced`, `BidRaised`, `BidWithdrawn`, `AuctionCleared`, `DeparturesSwept`,
`AuctionSettled`, `AuctionVoided` and `BidClaimed`, with `ISaleAdapter`'s `SaleStarted`,
`SaleSettled` (one per sale: the count as the quantity, a zero buyer), `Credited` and `Claimed`,
and Editions' `TransferSingle` per claim
([UniformEditionAuction](events-and-indexing.md#uniformeditionauction),
[Editions](events-and-indexing.md#editions)).

### Errors

| Error | Cause |
| --- | --- |
| `UnknownAuction(saleId)`, `AuctionExists(saleId)` | No sale with this ID; or a second `open`. |
| `NoOneOfOneAuction(master, id)` | The 1/1 auction does not exist, or was cancelled. |
| `BiddingClosed(saleId, endTime)` | The end passed, or the 1/1 was cancelled (seen by a bid within `softWindow` of the close; earlier bids are refunded at the void); for `open`, the edition close passed. |
| `InvalidStep(step)`, `InvalidQuantity(quantity)` | A step past the ladder or a raise that does not move up; a zero quantity, units past 2^32 − 1, or a bid ID past 2^32 − 1. |
| `IncorrectPayment(expected, paid)` | `msg.value` is not exactly the escrow or the top-up. |
| `UnknownBid(saleId, bidId)`, `NotBidder(caller)` | No live bid with this ID; the caller is not its bidder. |
| `WithdrawalsClosed(saleId)` | A withdrawal outside a 1/1 dispute pause, or of a bid placed or last raised during it (or in its minute). |
| `SettlementNotReady(saleId)`, `EditionNotCreated(token, id)` | Too early to settle; create the edition first. |
| `InvalidSettlementOrder(index)` | The order is out of range or not in increasing position. |
| `InvalidAuctionState(saleId, status)` | The sale is not in a state that allows the call, such as a claim before settlement. |
| `SalePaused()`, `TargetNotAllowed(token)`, `InvalidSaleTerms(token, id)` | `open` while paused, for a token not served, or with terms that are not this kind's. |
| `InvalidRecipient(to)`, `NothingToClaim(account, currency)` | `withdrawBid`, `claimBid` or `claim` to zero, or `claimBid` to the adapter; `claim` with no credit. |
| `ClaimFailed(to)` | `to` refused the ETH; the bid stays claimable. |

### Gas

The budgets for `bid`, `claimBid` and `settle` are in
[ADR 0005 §5](../adr/0005-stream-editions-auction.md#5-gas-budgets-adr-0004), and the measured
Prague gas and new slots in the [ADR 0004 table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table).
A losing bidder pays for its bid and its refund claim.

## Claiming

Refunds are never pushed; every amount owed has a pull function:

| What is owed | Where | Who calls | Function |
| --- | --- | --- | --- |
| An outbid, withdrawn or refunded bid | `EnglishAuction` | The bidder (payer) | `claim(currency, to)` |
| An edition bid's copies and refund | `UniformEditionAuction` | The bidder; anyone with `claimBidFor` | `claimBid(saleId, bidId, to)`, `claimBidFor(saleId, bidId)` |
| A refund `claimBidFor` credited | `UniformEditionAuction` | The bidder | `claim(address(0), to)` |
| An ERC-20 auction payout that failed (MONEY-1) | `EnglishAuction` | Anyone, for the wallet | `claimFor(wallet, token)` |
| A token whose delivery failed | `EnglishAuction` | The recipient or the winning bidder; with no bids on a token other than 6529 Stream, also its artist | `claimDelivery(saleId, to)` |
| A payout a wallet or token refused | `RevenueEscrow` | Anyone | `flush(wallet, asset)` |
| A payee's share of sales or royalties | the `SplitWallet` | Depends on the payee (below) | `release`, `releaseTo`, `releaseWithAuthorization` |

### Credits on a sale adapter

```solidity
function claimable(address account, address currency) external view returns (uint256);
function claim(address currency, address to) external returns (uint256 amount);
```

`claim` sends all of the caller's credits in `currency` to `to` and emits `Claimed`. It reverts with
`InvalidRecipient(address(0))` for a zero `to`, `NothingToClaim(account, currency)` for no credit,
and `ClaimFailed(to)` when `to` refuses ETH, keeping the credit. On Sepolia, a bidder's `claim` of
an outbid credit used 32,580 gas ([flows §2](../../deployments/11155111/flows.md#2-the-curated-stream-sale)).

### The escrow

```solidity
function owed(address wallet, address asset) external view returns (uint256);
function flush(address wallet, address asset) external returns (uint256 amount);
```

Anyone may flush; the funds only go to `wallet` (ECO-27). `flush` reverts with
`NothingOwed(wallet, asset)` when nothing is owed, and with `ETHTransferFailed(wallet, amount)` when
the wallet refuses ETH again. A credit for a wallet a token has blocked moves to an equivalent
replacement only by a governed `recover` (ECO-28,
[recovery flows](../spec/economics-and-payouts.md#escrow-recovery-for-a-blocked-split-wallet)).

### Split wallets

Sale proceeds go to the [seller wallet](../glossary.md#seller-wallet) (`seller` in
`Stream.work(tokenId)` or `Editions.edition(editionId)`; for a work,
`SplitFactory.walletFor(item.payees, bytes32(0))`), royalties to the
[royalty wallet](../glossary.md#royalty-wallet) (`royaltyReceiver` in the same records). Both are
predicted CREATE2 addresses (ECO-9).

- **Deploy before you release.** Funds sent to a predicted address wait there (ECO-11). Anyone
  deploys the wallet with `SplitFactory.createWallet(payees, salt)`, with the payees and salt (zero)
  the address was predicted from. Its cost is in the
  [ADR 0004 table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table): mostly code, which
  Glamsterdam reprices.
- **Releasable amount.** `releasable(asset, index)`; ETH is `address(0)` (ECO-13).

| Function | Who may call | Pays to |
| --- | --- | --- |
| `release(asset, index)` | Anyone, for a [fixed payee](../glossary.md#fixed-payee); only the current payout address, for an [artist-resolved payee](../glossary.md#artist-resolved-payee) | The payee's account or payout address |
| `releaseTo(asset, index, recipient)` | Only the payee's current payout address | `recipient` |
| `releaseWithAuthorization(authorization, signature)` | Anyone, with the payee's signature | The signed `recipient` |

A royalty wallet's two payees (the seller wallet and the fee recipient) are fixed, so anyone may
push royalties on to them; a seller wallet's artist-resolved payees are pull-only (ECO-15, ECO-16).

The errors (`NotPayoutAddress`, `NothingToRelease`, `PayoutUnresolved` and others) are declared
in [ISplitWallet.sol](../../src/economics/interfaces/ISplitWallet.sol).

### Signed releases

A payee signs an EIP-712 authorization in the release verifier's domain (name
`6529 Works Release Verifier`, version `1`, the chain ID, the verifier's address), with the type
string exactly as in `ReleaseVerifier.RELEASE_TYPEHASH`
([ReleaseVerifier.sol](../../src/economics/ReleaseVerifier.sol)):

```text
ReleaseAuthorization(address wallet,address asset,uint256 payee,address account,address recipient,uint256 amount,uint256 nonce,uint256 deadline)
```

- `account` is the signer and must be the payee's payout address when the release runs (ECO-20).
- `amount` is released exactly; `type(uint256).max` releases everything due. Prefer it for a fixed
  payee: anyone may push that payee's balance first, and an exact-amount release then reverts
  without spending its nonce (ECO-22).
- Nonces are any `uint256`, single use per account across every wallet (ECO-21). Revoke one with
  `revokeNonce(nonce)`; check one with `nonceUsed(account, nonce)`. `releaseDigest(authorization)`
  returns the digest to sign.
- Moving the payout address away does not revoke its signatures: if the payout returns to that key,
  its unexpired authorizations work again. Sign short deadlines or revoke.

### The claim router (keepers)

```solidity
function claim(IClaimRouter.Claim[] calldata claims, bool continueOnFailure)
    external returns (uint256[] memory amounts);
function claimSigned(IClaimRouter.SignedClaim[] calldata claims, bool continueOnFailure)
    external returns (uint256[] memory amounts);
```

The router is stateless: it calls `release` for each `Claim(wallet, asset, payee)` and
`releaseWithAuthorization` for each `SignedClaim(authorization, signature)`, and never holds or
redirects funds (ECO-29). Plain items pay fixed payees only; a plain item for an artist-resolved
payee fails. A batch holds at most 50 plain items (`MAX_CLAIMS`) or 20 signed ones
(`MAX_SIGNED_CLAIMS`), and more revert with `TooManyClaims(count)`
([ClaimRouter.sol](../../src/economics/ClaimRouter.sol), ECO-30).

- **Atomic mode** (`continueOnFailure == false`): any failed item reverts the batch with
  `ClaimCallFailed(index, wallet, size, reason)`.
- **Continue mode**: a failed item emits `ClaimFailed(wallet, asset, payee, index, size, reason)`,
  releases 0, and the batch goes on. The batch reverts with `ClaimInsufficientGas(index, available)`
  when an item's even share of the gas left is below `MIN_ITEM_GAS` (`MIN_SIGNED_ITEM_GAS`), or when
  an item offered less than `SHORTFALL_REVERT_CEILING` runs dry, so gas estimation raises the limit
  instead of silently skipping it.

Keeper guidance ([LIM-GAS-6](../audit/known-limitations.md#gas-and-glamsterdam)):
- Estimate every batch; a full batch of first releases may not fit one transaction, and then
  reverts whole, so split it.
- A party to an item (a gas-burning co-payee, a signed release's recipient, a token issuer) can
  make it look short of gas after you estimated. Simulate privately, isolate contract payees and
  unfamiliar tokens, and drop an item whose revert names its index.
- An artist's first signed release through the router is a row of the
  [ADR 0004 table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table).

## Royalties for marketplaces

Both tokens implement ERC-2981 and report it through `supportsInterface(0x2a55205a)`:

```solidity
function royaltyInfo(uint256 tokenId, uint256 salePrice)
    external view returns (address receiver, uint256 royaltyAmount);
```

| | 6529 Stream | 6529 Stream Editions |
| --- | --- | --- |
| Receiver | Derived on each call: the seller wallet at a zero fee share, otherwise the royalty split wallet (AUC-7, ECO-7) | Stored when the edition was created (ED-7) |
| Amount | `floor(salePrice × rate / 100,000)`, without overflow for any price | `Math.mulDiv(salePrice, rate, 100,000)`, rounded down |
| Rate | Set at mint from the product default, 6,529 (6.529%) at launch ([launch terms](../spec/economics-and-payouts.md#products-and-launch-terms)) | Starts at the master's current rate and follows its re-rates |
| Unknown token | `UnknownWork(tokenId)` | `UnknownEdition(editionId)` |
| Rate change event | `RoyaltyRateChanged` ([Stream](events-and-indexing.md#stream)) | `RoyaltyRateChanged` and `MetadataUpdate` ([Editions](events-and-indexing.md#editions)) |

- **Gas.** Stream's `royaltyInfo` makes one view call to the split factory; its gas as a whole
  call is in the [ADR 0004 table](../adr/0004-gas-budgets-under-glamsterdam.md#the-table).
  Short of gas it reverts, never returning a zero royalty; supply comfortably more.
- **Advisory.** Stream and Editions transfer as plain ERC-721 and ERC-1155 tokens and do not enforce
  payment ([ADR 0001 §16](../adr/0001-v1-scope.md#16-6529-stream-federated)).
- **A predicted receiver.** The royalty wallet may not be deployed yet: ETH sent to it creates the
  account once, and splits once anyone deploys the wallet.

## Prague gas and Glamsterdam gas

Every Prague figure here is [Prague gas](../glossary.md#prague-gas), what Foundry measures
([ADR 0004 decision 1](../adr/0004-gas-budgets-under-glamsterdam.md#decision)). Sepolia has run
Glamsterdam, which reprices state creation, since 6 October 2026
([ADR 0004, Problem](../adr/0004-gas-budgets-under-glamsterdam.md#problem)).

- **Rule of thumb on Sepolia's parameters:** Prague gas, plus about 89,000 per new slot, plus about
  184,000 per new account ([ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md#the-table),
  after the table). Reads are not repriced.
- **Estimate on the target chain** with `eth_estimateGas`, never from the Prague figures or a
  Foundry simulation: Foundry 1.7.1 has no Amsterdam EVM (ADR 0004).
- **Mainnet may differ.** Its Glamsterdam parameters are not final (ADR 0004 decision 3).

## References

- **Code.** [src/sales](../../src/sales/) and [src/economics](../../src/economics/), with their
  [sales](../../src/sales/README.md) and [economics](../../src/economics/README.md) READMEs; the
  interfaces are linked under [Contracts you call](#contracts-you-call).
- **ADRs.** [ADR 0001 §5](../adr/0001-v1-scope.md#5-sales-and-auctions) (sales and auctions),
  [§7](../adr/0001-v1-scope.md#7-economics) (economics),
  [ADR 0004](../adr/0004-gas-budgets-under-glamsterdam.md) (gas budgets under Glamsterdam),
  [ADR 0005](../adr/0005-stream-editions-auction.md) (the edition auction).
- **Tests.** Linked where cited; Prague gas rows from
  [GasReport.t.sol](../../test/integration/GasReport.t.sol).
- **Measurements.** [Sepolia flows](../../deployments/11155111/flows.md).
- **Related pages.** [Stream and auctions](../spec/stream-and-auctions.md),
  [Editions and sales](../spec/editions-and-sales.md),
  [Economics and payouts](../spec/economics-and-payouts.md),
  [Identity and recovery](../spec/identity-and-recovery.md),
  [Events and indexing](events-and-indexing.md), [ABIs and interface IDs](abis-and-interface-ids.md),
  [Addresses](addresses.md).
