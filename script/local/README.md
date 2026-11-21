# script/local

A local walkthrough: the whole system deployed on a fresh `anvil` node and one curated work
taken from upload to payout, with one command. It is for developers learning the protocol and
checking a change against the real deploy; it is not a deployment procedure (the
[runbook](../README.md) is).

```bash
bash script/local/walkthrough.sh
```

Run it from the repository root, in bash (Git Bash on Windows), after `forge build`. It needs
`forge`, `cast`, `anvil` and Python 3.12 or later, and takes about a minute after the build.

| File | What it is |
| --- | --- |
| [`walkthrough.sh`](walkthrough.sh) | Starts `anvil`, deploys, accepts, verifies, runs the three phases with the clock moved between them, and stops the node |
| [`make_genesis.py`](make_genesis.py) | Writes `config/local/genesis.anvil.json`: the committed policy (`config/genesis.example.json`) with anvil's test accounts as the network and holders. Git-ignored |
| [`Walkthrough.s.sol`](Walkthrough.s.sol) | The flow, as a forge script with three entry points: `curate()`, `settle()` and `editions()` |

## What it runs

1. **Deploy.** `script/Deploy.s.sol` with the local genesis file, anvil account 14 as the fee recipient and
   `ACCEPT_NETWORK=1`, so the network (anvil account 1) accepts in the same run. The record is
   written to `deployments/31337/<timestamp>.json` (git-ignored).
2. **Verify.** The clock moves the manager's 5-day `minSetback`, then `script/Verify.s.sol`
   reads the deployment back.
3. **`curate()`.** PLATFORM creates a collection; the artist stores a small SVG and a JSON
   record in the content store; curation signer 1 signs the package root, which anyone
   registers, and CURATOR appends the curation evidence statement; the artist accepts the
   package (registering the artist's account) and signs "move to Stream"; bidder A starts the
   1/1 auction with a 0.1 ETH bid; the keeper opens the edition auction beside it, and two
   accounts bid for copies; bidder B bids 0.2 ETH.
4. **24 hours later, `settle()`.** The keeper settles the 1/1 (bidder B owns it); bidder A
   pulls the outbid refund; the keeper creates the edition and opens the work's record; the
   artist finalizes the record, which pins the renderer; `tokenURI` returns the on-chain JSON.
5. **One hour later, `editions()`.** The keeper settles the edition auction at one clearing
   price; both bidders claim their copies and refunds; anyone deploys the seller wallet; the
   artist releases its 75%, and the network's fee vault forwards the 25% fee to the fee
   recipient.

The accounts are anvil's defaults (mnemonic `test test ... junk`), which are public test keys:

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
  `EnglishAuction.settle`, which forwards 300,000 gas to deliver the work: with that limit the
  transaction reverts on chain although the simulation passed. A client that sends `settle`
  needs a limit from `eth_estimateGas` or a generous fixed one
  ([gas the caller must forward](../../docs/integrators/buying-bidding-settling.md#gas-the-caller-must-forward)).
- **Exploring.** `KEEP_ANVIL=1 bash script/local/walkthrough.sh` leaves the node running; the
  addresses are in the deployment record. For example:
  `cast call <Stream> "tokenURI(uint256)(string)" 1 --rpc-url http://127.0.0.1:8545`.
- **What it does not cover.** VRF seeds (the local deploy has no entropy module), Permit2 and
  ERC-20 payments, disputes, governance actions after genesis, federation and the Glamsterdam gas
  schedule. The [integration tests](../../test/integration/README.md) cover those on the same
  contracts, and the Sepolia rehearsals on a live chain
  ([flows](../../deployments/11155111/flows.md)).
- **As a check.** The script exits non-zero when any step fails, so CI can run it after
  `forge build`.
