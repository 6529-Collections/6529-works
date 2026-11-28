# Buying, bidding, settling and claiming

For marketplace and wallet engineers, relayers and keepers: how to start, bid on and settle a
6529 Stream auction, bid on edition copies, claim what is owed, and read royalties. Sales are in
ETH only. Rules are in [Stream and auctions](../spec/stream-and-auctions.md#rules-and-invariants)
(`AUC-n`), [Editions and sales](../spec/editions-and-sales.md#rules-and-invariants) (`ED-n`,
`EA-n`) and [Economics and payouts](../spec/economics-and-payouts.md#rules-and-invariants)
(`ECO-n`); events in [Events and indexing](events-and-indexing.md).

> Pre-audit. See the [project status](../../README.md#status).

The sale contracts are replaceable modules. Their exact function signatures and errors are in
the exported ABIs ([`abi/`](../../abi)); this page describes the flow, which the restructuring
keeps.

## Contracts you call

| Contract | You call it to |
| --- | --- |
| `EnglishAuction` | start, bid, settle, claim credits, claim a pending delivery |
| `UniformEditionAuction` | open an edition's sale, bid, raise, settle, abandon, claim |
| `SaleStarter` | start a 1/1 with its payout vaults and record in one transaction (the network's keeper uses it) |
| `Stream6529` ([`IStream`](../../src/interfaces/core/IStream.sol)) | read works (`workOf`, `ownerOf`), `royaltyInfo`, check minters (`isMinter`) |
| `StreamEditions6529` ([`IEditions`](../../src/interfaces/core/IEditions.sol)) | read editions (`editionOf`), `royaltyInfo` |
| `PackageRegistry` ([`IMintPolicy`](../../src/interfaces/core/IMintPolicy.sol)) | check approvals, acceptances and move nonces; `preview` a start; get the move digest |
| `VrfEntropyModule` | request a VRF seed |
| `RevenueEscrow` | flush refused payouts |
| `SplitLedger`, `ClaimRouter` | release split-vault shares, singly or in batches |

Simulate every write with `eth_call` and take the gas limit from `eth_estimateGas`.

## Starting an auction

Starting is permissionless. One transaction asks the mint policy, mints the work into the
auction's custody and starts the clock:

```solidity
function start(address token, bytes calldata mintData) external returns (uint256 saleId);
function startWithBid(address token, bytes calldata mintData, address recipient)
    external payable returns (uint256 saleId);
function saleIdOf(address token, uint256 tokenId) external pure returns (uint256);
```

- `mintData` is the request the mint policy reads: the approved package root, the item exactly
  as published, its Merkle proof (at most 32 nodes), and the lead artist's move signature
  (nonce, deadline, `abi.encodePacked(wallet, signature)`).
- The sale ID is `uint256(keccak256(abi.encode(token, tokenId)))`.
- `startWithBid` also places the first bid; `msg.value` is the bid.

**Check before you submit:** the root is `APPROVED`; every party accepted the root; the move is
unexpired and its nonce unused; no live token holds the content (`Stream6529.tokenOfContent`), or
the content was released for this artist; for a VRF item, the seed is delivered; the lead
artist's account is not frozen or changing; the auction is not paused. `PackageRegistry.preview`
answers the mint facts and terms a start would get.

**The move signature.** Any wallet of the lead artist's account signs, in the package registry's
EIP-712 domain, `MoveToStream(bytes32 packageRoot,bytes32 itemHash,uint256 nonce,uint64 deadline)`;
`PackageRegistry.moveDigest` returns the digest. Use nonces in order from 0. Any wallet of the
account revokes an unused nonce.

## Bidding

- The first bid is at least the opening bid (0.05 ETH at launch). Each later bid adds at least
  the larger of 5% of the high bid and 0.001 ETH. Read `minimumBid(saleId)`.
- A bid in the last 15 minutes moves the end to 15 minutes after the bid.
- An outbid bid is credited to its payer. Claim it with `claim`. Credits are never pushed.
- During a dispute pause bids are refused; the high bid stays.

## Settling

Anyone settles after the end. With a bid, the work goes to the winner (or waits as a pending
delivery the winner claims with `claimDelivery`), and the seller and the network are paid; a
refused payment goes to the escrow. With no bid, a 6529 Stream work goes to the museum; an
unsold Independent Stream work stays in the auction and can be started again. Forward the gas
`eth_estimateGas` reports: a settler that starves the delivery or payouts is refused.

### Gas the caller must forward

Take the limit from `eth_estimateGas`; the auction refuses a settler that does not forward the
delivery gas (300,000) and the payout gas (100,000 per wallet).

An Independent Stream token that refuses to settle can be closed with `settleOrRefund(saleId)` from
2 days after the end: the bid is credited back.

**Keeper checklist:** settle every ended sale; flush escrow credits to their wallets; deploy
vaults before they are named (the policy does this at start); expire only credits that have
waited the unclaimed period in force.

## Edition auctions

- **Open** (anyone) from the 1/1's start until its close; the keeper batches it with the start.
  Opening creates the edition.
- **Bid** on a step of the price ladder with a quantity; pay exactly `quantity × stepPrice`.
  `quote` and `lowestWinningStep` say what a new bid would win. **Raise** moves a whole bid up for
  the difference. Bids cannot be lowered or withdrawn.
- **Close** 15 minutes after the 1/1's final end, plus any soft-close extension.
- **Settle** after the 1/1 settles or is cancelled. A capped sale with holes may take several
  calls: pass the departure order `settlementOrderFor` returns.
- **Claim** each bid with `claimBid` (or anyone with `claimBidFor`): it mints the copies won and
  refunds the rest.
- A cancelled 1/1 voids its edition sale and refunds every bid. A 1/1 sale that closed because
  the network rescued its work (`RescuedSaleClosed`) reads as cancelled too.

## Claiming

| What | How |
| --- | --- |
| Auction credits | `claim(...)` by the account |
| Escrow credits | anyone flushes a credit to its own wallet |
| A fixed payee's vault share | anyone calls `release` for it; it pays only that payee |
| An artist's vault share | the artist's current payout address calls `release`, `releaseTo`, or signs a release someone else submits |
| Batches | `ClaimRouter` |

Money that waits unclaimed longer than the unclaimed period in force (180 days at launch) may be
sent to the network by anyone: only the part that has itself waited that long.

## Royalties for marketplaces

`royaltyInfo(tokenId, price)` on Stream and Editions returns the stored receiver and exactly
`floor(price × rate / 100,000)`. It asks no other contract. The receiver is a split vault: pay it
ETH directly, or ERC-20s by transfer. The rate is 6.529% at launch.
