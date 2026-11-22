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

Sales are in ETH only. The waiting periods that are network settings are read on every run,
never assumed: the unclaimed period (`Directory.unclaimedPeriod()`, 180 days at launch) and the
rescue period (`Stream.rescueDelay()`, 14 days at launch).

| Step | When it is due | Call |
| --- | --- | --- |
| `start` | A request in `--starts` whose content has no live token | `SaleStarter.start(auction, stream, mintData, media)`: the sale, the work's vaults and its record in one transaction |
| `start`, already started | Someone started the same item directly, so `SaleStarter.start` would revert | `SplitFactory.createWallet` for each missing vault and `WorkFacts.open(stream, tokenId, item, media)`, all permissionless |
| `open` | An edition master's 1/1 has started, its edition sale is not open, and the 1/1 has not settled | `UniformEditionAuction.open(editions, tokenId, abi.encode(item, packageRoot, proof))`, which also creates the edition |
| `settle` | A 1/1 auction has ended | `EnglishAuction.settle(saleId)` |
| `editions` | An edition sale is past its close (or its 1/1 was cancelled) and not settled | `settle(saleId, settlementOrderFor(saleId, keeper))`, repeated until it returns true; the settlement seals the edition at the count sold |
| `abandon` | `abandonable(saleId)` is true (21 days after the close, when the 1/1 never completed) | `UniformEditionAuction.abandon(saleId)` |
| `adopt` | The network moved an edition to the edition auction (`EditionRebound`) and it has no sale there | Nothing is sent: `adopt` is the network's action. The keeper prints it |
| `finalize` | A work's finalize notice has come due (`WorkRules.FINALIZE_NOTICE`, 14 days) | `WorkRules.finalize(stream, tokenId, 0)` |
| `vaults` | A work's seller vault, or its royalty vault, is not deployed | `SplitFactory.createWallet(payees, 0)`: the seller vault from the item's payees; the royalty vault from the seller vault, the network fee recipient and the sale's fee share, sent only when that list gives the work's royalty receiver |
| `attest` | An opened work is not marked complete on chain | `ContentStore.attestComplete(fileId, 512)` for each media file not yet walked, then `WorkFacts.markOnChainComplete(stream, tokenId)`. A file with a missing chunk is skipped until the chunk is written |
| `expire` | Money credited in either auction, or in the revenue escrow, has itself waited the unclaimed period | `EnglishAuction.expireCredit(account)`, `UniformEditionAuction.expireCredit(account, 0)`, `RevenueEscrow.expire(wallet, 0)` |
| `forfeit` | A split-wallet mark the payee has not released up to is older than the unclaimed period | `SplitFactory.forfeit(payees, salt, 0, index)` |
| `rescues` | A removed minter still holds an unsold token, and the rescue period has passed since the removal | Nothing is sent: `Stream.rescue(tokenId, to)` is the network's action. The keeper prints it |
| `release` (opt-in, `--release`) | A fixed payee of a split wallet has ETH to release | `ClaimRouter.claim(claims, true)` in batches of at most `MAX_CONTINUE_CLAIMS` (8); the network's own index is left out of a batch that releases another payee of the same wallet |
| `mark` (opt-in, `--mark`) | A payee other than the network has ETH releasable and no pending mark | `SplitFactory.mark(payees, salt, 0, index)`, which starts the payee's unclaimed period |
| `notice` (opt-in, `--notice`) | A work's first sale has an outcome and it has no finalize notice | `WorkRules.finalize(stream, tokenId, 0)` from a non-artist, which records the notice |

`mark` and `notice` start clocks that move money or fix a record, so they run only when asked.
The rules behind each step are in the specification ([sales](../docs/spec/stream-and-auctions.md),
[editions](../docs/spec/editions-and-sales.md), [payouts](../docs/spec/economics-and-payouts.md))
and in [Buying, bidding, settling and claiming](../docs/integrators/buying-bidding-settling.md).

### Expiry: only money that has waited

Both auctions keep one credit per account under one rule (`src/libraries/AgedCredits.sol`): a
total, the part that has been waiting (`aged`) and when it started (`since`). Only `aged` can go
to the network, once `since` plus the unclaimed period has passed; money credited later waits
on its own. The keeper reads `creditOf(account)` from the edition auction and `expiresAt(account)`
(`since` plus the period) from the English auction. The escrow keeps its own windows; the keeper
asks it what an expiry would move now (`expirableAt(wallet, 0, now)`).

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
- It does not page `settlementOrderFor` for very large edition books.
- It holds no role: anything it sends, anyone may send. Its key only pays gas. Network actions
  (`rescue`, `adopt`) are printed, never sent.
- It never reads, prints or accepts a private key. Signing is Foundry's: `--account <name>`
  uses a keystore created with `cast wallet import` (cast asks for the password, or reads
  `--password-file`), and `--unlocked` lets a local node sign with its own accounts.

## Run it

Prerequisites: Foundry (`forge`, `cast`, `anvil`) and Python 3.10 or later.

The deployment record is the JSON file `script/DeployCore.s.sol` writes
(`deployments/<chain>/core-<time>.json`, contract name to address); the local walkthrough
writes one on anvil ([script/README.md](../script/README.md)).

```bash
# See what is due, sending nothing:
python keeper/keeper.py --rpc-url http://127.0.0.1:8545 \
  --deployment deployments/31337/core-<time>.json \
  --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --dry-run

# Send, signed by anvil's own account:
python keeper/keeper.py --rpc-url http://127.0.0.1:8545 \
  --deployment deployments/31337/core-<time>.json \
  --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --unlocked --starts ./starts

# On a public network, with a Foundry keystore:
python keeper/keeper.py --rpc-url "$RPC_URL" --deployment <record>.json \
  --from <keeper address> --account keeper
```

`--steps` picks the steps to run (comma-separated); `--from-block` sets where log reading
starts (default: the record's `startBlock`, else 0). On a long-lived chain, set it to the
deployment block and use a node whose `eth_getLogs` range limit allows it.

## How it is tested

```bash
forge build
KEEPER_E2E_REQUIRE=1 python -m unittest keeper.test_keeper -v
```

[`test_keeper.py`](test_keeper.py) has two layers:

- **Unit tests**, no node needed: the hand-written ABI encoding, the royalty payee ordering, the
  ClaimRouter batch rule, the mark rule, the expiry rule under the period in force, the royalty
  vault check, the rescue and adopt reports, request and record parsing, and that every
  function and event signature the keeper writes by hand is in the exported ABIs in
  [`abi/`](../abi/).
- **End to end on anvil**: [`test/KeeperFixture.t.sol`](test/KeeperFixture.t.sol) deploys the
  whole stack with the deploy library and the committed genesis policy, registers a curated
  two-work package (an edition master and an original) and writes the chain state
  (`vm.dumpState`); each test loads it into a fresh anvil node and runs the keeper with
  `--unlocked`. One test takes a full sale: two starts through `SaleStarter`, the edition sale
  opened, a stored file marked complete on chain (and a second once its missing chunk is
  written), bids on both auctions, both 1/1s and the edition sale settled and the edition
  sealed, a royalty pushed through the ClaimRouter (the network paid in the same call), an outbid
  credit and an edition refund expired after the unclaimed period, a finalize notice and the
  finalize after it, and a mark and its forfeit. Others cover steps someone else took first (a
  direct start, a settlement by a stranger), `--dry-run`, and a rescue reported only after the
  rescue period.

Without `anvil`, `forge` or `cast` on the PATH the end-to-end tests are skipped; with
`KEEPER_E2E_REQUIRE=1` they fail instead, which is what CI sets. The fixture is compiled with the
test suite through `test/Integrators.t.sol`.
