# script/local

A local walkthrough: the whole system deployed on a fresh `anvil` node, one curated work taken
from upload to payout, one Independent Stream work sold, and one module swapped, with one command.
It is for developers learning the protocol and checking a change against the real deploy; it is not
a deployment procedure (the [runbook](../README.md) is).

```bash
bash script/local/walkthrough.sh
```

Run it from the repository root, in bash (Git Bash on Windows), after `forge build`. It needs
`forge`, `cast`, `anvil` and Python 3.12 or later, and takes about a minute after the build. It
exits non-zero at the first failed step, so CI runs it after the build.

| File | What it is |
| --- | --- |
| [`walkthrough.sh`](walkthrough.sh) | Starts `anvil`, deploys, accepts, reads back, runs the four phases with the clock moved between them, and stops the node |
| [`make_genesis.py`](make_genesis.py) | Writes `config/local/genesis.core.anvil.json`: the committed policy (`config/genesis.core.example.json`) with anvil's test accounts as the network and holders. Git-ignored |
| [`Walkthrough.s.sol`](Walkthrough.s.sol) | The flow, as a forge script with four entry points: `curate()`, `settle()`, `editions()` and `swap()` |

## What it runs

1. **Deploy.** [`DeployCore.s.sol`](../DeployCore.s.sol) with the local genesis file, anvil
   account 14 as the fee recipient and `ACCEPT_NETWORK=1`, so the network (anvil account 1)
   accepts in the same run. The record is written to `deployments/31337/core-<timestamp>.json`
   (git-ignored).
2. **Read back.** [`VerifyCore.s.sol`](../VerifyCore.s.sol) reads every contract of the record
   back (wiring, genesis modules and minters, the four settings at their launch values, the
   genesis wiring calls and the governance configuration), then deploys the same build again in
   memory from the block before the deployment and compares every contract's runtime code.
3. **`curate()`.** PLATFORM creates a collection; the artist stores a small SVG and a JSON
   record in the content store; curation signer 1 signs the package root, which the keeper
   registers, and CURATOR appends the curation evidence statement; the artist accepts the
   package (creating the artist's account) and signs "move to Stream"; bidder A starts the 1/1
   auction with a 0.1 ETH bid (the work is minted into the auction's custody); the keeper opens
   the edition auction beside it (which creates the edition and deploys the seller and royalty
   vaults) and two accounts bid for copies; bidder B bids 0.2 ETH; the keeper opens the work's
   record in `StreamWorkFacts6529`. The artist then deploys an Independent Stream 1/1 contract from
   the approved template, lists it in the Independent Stream module, approves one work, and bidder B
   starts its auction with a 0.06 ETH bid.
4. **24 hours later, `settle()`.** The keeper settles both 1/1 auctions (bidder B owns both
   works); bidder A claims the outbid refund; the artist finalizes both records, which pins the
   current renderer; `tokenURI` returns the JSON. The network proposes a second renderer for
   6529 Stream.
5. **One hour later, `editions()`.** The keeper settles the edition auction at one clearing
   price; both bidders claim their copies and refunds; the artist releases the seller vault, and
   the network's fee vault forwards the fees to the fee recipient.
6. **`moduleDelay` later, `swap()`.** Anyone activates the proposed renderer. The finalized work
   keeps the renderer it pinned.

The accounts are anvil's defaults (mnemonic `test test ... junk`), which are public test keys.
The node starts with 20 accounts:

| Index | Account |
| --- | --- |
| 0 | Deployer |
| 1 | Network: every network role |
| 2, 3 | Curation signers |
| 4 | Platform |
| 5 | Curator |
| 6 | Artist |
| 7, 8 | Bidders A and B |
| 9 | Keeper, and an edition bidder |
| 10 to 12, 13 | Pausers, storage operator (no transactions) |
| 14 | Network fee recipient (no transactions) |

## Notes for developers

- **Gas limits.** The phases broadcast with `--skip-simulation`, so each transaction's gas limit
  is the node's `eth_estimateGas`. Forge's own estimate (gas used times 1.3) is too low for calls
  that check they can forward a fixed amount of gas before making a call, such as
  `EnglishAuction.settle`, which forwards `DELIVERY_GAS` (300,000) to deliver the work: with that
  limit the transaction reverts on chain although the simulation passed. A client that sends
  `settle` needs a limit from `eth_estimateGas` or a generous fixed one.
- **Exploring.** `KEEP_ANVIL=1 bash script/local/walkthrough.sh` leaves the node running; the
  addresses are in the deployment record. For example:
  `cast call <Stream6529> "tokenURI(uint256)(string)" 1 --rpc-url http://127.0.0.1:8545`.
- **What it does not cover.** VRF seeds (the local deploy has no entropy module), disputes,
  identity changes, rescue and rebind, and credit expiry. The [tests](../../test/README.md) cover
  those on the same contracts.
