# Reference keeper

A small, readable reference implementation of the permissionless steps that keep 6529 Works
sales moving: [`keeper.py`](keeper.py), standard-library Python that reads the chain over
JSON-RPC and sends transactions with Foundry's `cast send`.

> Pre-audit. This is reference code, not production software: it has not been audited, and
> it has no monitoring, alerting, retry schedule, gas-price policy or key management. Use it
> to learn what a keeper does, to test locally, or as the starting point of your own.

## What it does

Each run is stateless and idempotent. It reads the deployment's event logs from
`--from-block` and the contracts' views, decides which steps are due now, simulates each with
`eth_call`, and sends only those that would succeed. A step someone else already took is no
longer due, so two keepers, or a keeper and anyone else, can run side by side. Run it on a
schedule (every few minutes); each run picks up where the chain is.

| Step | When it is due | Call |
| --- | --- | --- |
| `start` | A request in `--starts` whose item is not on chain yet | `SaleStarter.start(auction, stream, mintData, media)`: the sale, the work's seller and royalty vaults and its record in one transaction |
| `start`, already started | Someone started the same item directly (`Stream.consumedItemOf(contentHash)` is set), so `SaleStarter.start` would revert | `SplitLedger.createWallet` for each missing vault and `WorkRecords.openRecord`, both permissionless |
| `open` | An `EDITION_MASTER` 1/1 started and its edition sale is not open, before the 1/1 settles | `UniformEditionAuction.open(editions, tokenId, abi.encode(item, packageRoot, proof))` |
| `settle` | A 1/1 auction is `ENDED` | `EnglishAuction.settle(saleId)` |
| `create` | An `EDITION_MASTER` whose primary sale settled has no edition | `Editions.createEdition(tokenId, item)` |
| `editions` | An edition sale is past its close (or its 1/1 was cancelled) and not settled | `settle(saleId, settlementOrderFor(saleId, keeper))`, repeated until it returns true, from the keeper's own address |
| `abandon` | `abandonable(saleId)` is true (21 days after the close) | `abandon(saleId, abi.encode(item))` |
| `finalize` | A `FinalizeNoticeRecorded` notice is 14 days old and the work is not finalized | `WorkRecords.finalize(tokenId, 0)` |
| `vaults` | A 6529 Stream work's seller vault (payees known from its record) or royalty vault is not deployed | `SplitLedger.createWallet(payees, 0)` |
| `expire` | A credit on either auction is unclaimed 180 days after it went from zero; an escrow credit has a part that `RevenueEscrow.expirableAt(wallet, asset, now)` answers as due (a window 180 days past its last credit) | `expireCredit(account, currency)`, `RevenueEscrow.expire(wallet, asset)` |
| `forfeit` | A split-wallet mark the payee has not released up to is 180 days old | `SplitLedger.forfeit(payees, salt, asset, index)` |
| `release` (opt-in, `--release`) | A fixed payee of a split wallet has ETH to release | `ClaimRouter.claim(claims, true)` in batches of at most the router's `MAX_CONTINUE_CLAIMS` (8); the network's own index is left out of a batch that releases another payee of the same wallet and asset, because that release already paid the network |
| `mark` (opt-in, `--mark`) | A payee other than the network has ETH releasable and no pending mark (none, or one it has since released up to) | `SplitLedger.mark(payees, salt, asset, index)`, which starts the payee's 180 days |
| `notice` (opt-in, `--notice`) | A work's primary sale settled and it has no finalize notice | `WorkRecords.finalize(tokenId, 0)` from a non-artist, which records the notice |

The rules behind each step are in the [script README's operating procedures](../script/README.md#operating-procedures)
and [Buying, bidding, settling and claiming](../docs/integrators/buying-bidding-settling.md).
`mark` and `notice` start clocks that move funds or freeze a record, so they run only when asked.

### Start requests

A start needs the artist's signed move, which only exists off chain. Each file in `--starts`
is one request:

```json
{
  "mintData": "0x...  abi.encode(StreamMintRequest(packageRoot, item, proof, move))",
  "media": "0x...     abi.encode(MediaFile[]), in the order the item's mediaHash commits to",
  "proof": "0x...     optional: abi.encode(bytes32[]), the item's Merkle proof for the edition sale's open (default: the proof in mintData)"
}
```

The keeper reads the item, its payees and its content hash out of `mintData`. It assumes the
standard (canonical) ABI encoding that `abi.encode` and ethers produce.

### What it does not do

- It does not watch for anything between runs, alert anyone, or retry on a schedule.
- It does not bid, claim on anyone's behalf (except the fixed-payee pushes of `--release`), push
  edition claims (`claimBidFor`), flush the escrow, or call `settleOrRefund` for a federated
  sale that will not settle.
- It handles ETH only for marks, forfeits and releases, and does not page
  `settlementOrderFor` for very large edition books.
- It does not hold a role: anything it sends, anyone may send. Its key only pays gas.
- It never reads, prints or accepts a private key. Signing is Foundry's: `--account <name>`
  uses a keystore created with `cast wallet import` (cast asks for the password, or reads
  `--password-file`), and `--unlocked` lets a local node sign with its own accounts.

## Run it locally

Prerequisites: Foundry (`forge`, `cast`, `anvil`) and Python 3.10 or later.

```bash
# The tests build their own chain: the whole system deployed with the committed genesis,
# a curated two-work package, and the artist's signed start requests. They need anvil.
forge build
python -m unittest keeper.test_keeper -v
```

Against your own node and deployment record (for example the local dry run in the
[script README](../script/README.md#local-dry-run-anvil)):

```bash
# See what is due, sending nothing:
python keeper/keeper.py --rpc-url http://127.0.0.1:8545 \
  --deployment deployments/31337/<timestamp>.json \
  --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --dry-run

# Send, signed by anvil's own account:
python keeper/keeper.py --rpc-url http://127.0.0.1:8545 \
  --deployment deployments/31337/<timestamp>.json \
  --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --unlocked --starts ./starts

# On a public network, with a Foundry keystore:
python keeper/keeper.py --rpc-url "$RPC_URL" --deployment <record>.json \
  --from <keeper address> --account keeper
```

`--steps` picks the steps to run (comma-separated); `--from-block` sets where log reading
starts (default: the record's `startBlock`). On a long-lived chain, set it to the deployment
block and use a node whose `eth_getLogs` range limit allows it.

## How it is tested

[`test_keeper.py`](test_keeper.py):

- **Unit tests**, no node needed: the hand-written ABI encoding, the royalty payee ordering, the
  ClaimRouter batch rule, request validation, and that every function and event signature the
  keeper writes by hand is in the exported ABIs in [`abi/`](../abi/).
- **End to end on anvil**: [`test/KeeperFixture.t.sol`](test/KeeperFixture.t.sol) builds the
  chain in a Foundry test and dumps its state (`vm.dumpState`); each test loads it into a fresh
  anvil node and runs the keeper with `--unlocked`. One test takes a full sale: two starts
  through `SaleStarter`, the edition sale opened, bids on both auctions, both 1/1s settled, the
  edition created and its sale settled, a royalty pushed through the ClaimRouter (the network
  paid in the same call), an outbid credit expired after 180 days, a finalize notice and the
  finalize 14 days later, and a mark and its forfeit. The others cover steps someone else took
  first (a direct start, so `SaleStarter` would revert; a settlement and an edition created by
  a stranger) and `--dry-run`, which sends nothing.

Without `anvil`, `forge` or `cast` on the PATH the end-to-end tests are skipped; with
`KEEPER_E2E_REQUIRE=1` set they fail instead, which is what CI should set.
