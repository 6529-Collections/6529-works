# src/terms

The royalty policy of existing works: a replaceable module behind the permanent tokens.

| File | What it is |
| --- | --- |
| `StreamTerms.sol` | The TERMS module ([`ITerms`](../interfaces/core/ITerms.sol)) of 6529 Stream and 6529 Stream Editions, and, through the directory's `INDEPENDENT_TERMS` slot, of Independent Stream tokens. The only caller of the tokens' royalty setters. |

## Rules it holds

- **The royalty rate changes only through the token's RECORDS module** (`WorkRules`), which
  has checked every party's consent and the network's call. The receiver stays as it is. A
  master's edition takes the same rate. Locking the rate for good also comes only from the
  RECORDS module, when the lead artist renounces the royalty power.
- **The network's share of a work's royalties only goes down.** `lowerFeeShare` is the
  network's. The caller states the seller, the fee recipient and the share in force; they must
  derive the receiver the token stores (`ISplitFactory.walletFor(Splits.royaltyPayees(...), 0)`,
  or the seller at a zero share), so this module stores nothing per work. The fee recipient
  must be the split ledger's network fee vault (`ISplitFactory.network()`, fixed in permanent
  code): the share that goes down is always the network's, and the two parties cannot be
  stated the other way round. A work whose vault names another fee recipient is not lowered by
  this module. The new split vault is deployed (`createWallet`) before it is set, so royalties
  never point at an address without code.
- **Editions.** A master's edition moves with it when the edition's receiver is the master's
  old receiver. An edition with a receiver of its own is lowered by naming the editions
  contract as the token. The network pairs each editions contract with its token contract
  (`setEditions`).
- **Independent Stream tokens.** Any token but 6529 Stream counts as Independent Stream: a new share
  may not exceed the Independent Stream module's current share for that token
  (`IIndependentStreamGate.feeShareOf`), which only ever goes down.

## What it cannot do

It cannot move a token, change a fact of a work, or touch money already paid into a vault.
The token refuses a rate over 100,000 and any change of a locked rate, whatever this module
asks. If the module is removed, the last receiver and rate stand: `royaltyInfo` reads only the
token's own storage.

## Tests

`forge test --match-path "test/terms/*"`.
