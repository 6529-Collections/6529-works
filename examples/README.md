# Integration examples

Short, runnable examples of the common integration jobs against 6529 Stream. Each is one Foundry
test file. They share one setup, [`ExampleBase.sol`](ExampleBase.sol), which deploys the whole
system with the deploy library the deploy script uses ([`script/DeployCore.sol`](../script/DeployCore.sol))
and the committed genesis policy ([`config/genesis.core.example.json`](../config/genesis.core.example.json)).
The only differences from a real deployment: the network is one test key, and the first curation
signer is a test key so the examples can sign approvals. Each example then does one job through
the real contracts. They compile with the test suite (through
[`test/Integrators.t.sol`](../test/Integrators.t.sol)) and run in CI, so they cannot drift from
the contracts.

> Pre-audit. Interfaces may still change before the audit; these examples change with them.

```bash
forge test --match-path "examples/*"                   # all of them, in about a second
forge test --match-path examples/BidInEth.t.sol -vvvv  # one, with a full call trace
```

The trace (`-vvvv`) shows every call and event with decoded arguments: the quickest way to see
exactly what a transaction does.

| Example | What it shows |
| --- | --- |
| [`ReadAWork.t.sol`](ReadAWork.t.sol) | Everything a marketplace or wallet shows for one work: owner, what Stream stores (`workOf`, one plain struct), its collection, how the first sale ended (and the price, from the `PrimarySale` log), the permanent record in `StreamWorkFacts6529` (media, record file, license, pinned renderer), `tokenURI` and `royaltyInfo`; and the network's settings and the modules in force |
| [`StartASale.t.sol`](StartASale.t.sol) | Starting a sale from the artist's signed move, with the proof `abi.encodePacked(wallet, signature)`: a preview first, then `SaleStarter` (vaults and record in the same transaction), and what to do when someone started it directly |
| [`BidInEth.t.sol`](BidInEth.t.sol) | Watching a 1/1 sale and bidding in ETH: the opening bid, the increment, the anti-snipe extension, being outbid (a credit, never pushed back), when a credit can expire, and claiming it |
| [`SettleASale.t.sol`](SettleASale.t.sol) | Settling a 1/1 and what each party receives: the winner the token, the seller split wallet the price less the fee, the network's fee recipient the fee; `SaleSettled` decoded; with no bid, the work going to the museum |
| [`EditionSale.t.sol`](EditionSale.t.sol) | An edition sale beside an EDITION_MASTER's 1/1: opening it (which creates the edition), steps and escrow, `quote`, `clearing` and `bidOutcome`, the close following the 1/1, settlement, claiming copies and the refund, and pushing a claim for a bidder |
| [`ReleaseFromASplit.t.sol`](ReleaseFromASplit.t.sol) | Releasing from split wallets: the artist pulls sale proceeds; a royalty release that pays the network its share in the same call; a ClaimRouter batch that leaves the network's own index out |
| [`IndexFromEvents.t.sol`](IndexFromEvents.t.sol) | Rebuilding Stream's state (owners, the facts of each work, outcomes and prices, the content index, the supply) and each work's record in `StreamWorkFacts6529` from logs alone, then checking it against the views |
| [`IndependentStreamDirectory.t.sol`](IndependentStreamDirectory.t.sol) | An artist's Independent Stream pair deployed from the approved templates and joined; discovering Independent Stream contracts from `Registered` events and reading each entry; selling one Independent Stream work through the same English auction |
| [`ModuleSwap.t.sol`](ModuleSwap.t.sol) | What a module swap looks like to an integrator: the network proposes a renderer (`ModuleProposed`), it waits `moduleDelay`, anyone activates it (`ModuleSet`); open records draw with the new renderer while finalized ones keep their pinned one; a minter added after the wait and removed at once |

The base's helpers do what off-chain tools do (uploading files, building a package, the curation
signer's approval, the artist's signatures, moving time with `vm.warp`). The calls each example
demonstrates are the ones a client makes. The ABIs to make them from another language are in
[`abi/`](../abi/) ([how to use them](../docs/integrators/abis-and-interface-ids.md)), and the
contract addresses in [Addresses](../docs/integrators/addresses.md).

## The same reads with `cast`

With `RPC_URL` and the addresses from a deployment record (`STREAM`, `FACTS` for WorkFacts,
`AUCTION`, `EDITION_AUCTION`, `EDITIONS`, `LEDGER` for SplitLedger, `DIRECTORY`,
`INDEPENDENT_STREAM`):

```bash
# A work: owner, metadata, royalty, what Stream stores, and its record in WorkFacts
cast call "$STREAM" "ownerOf(uint256)(address)" 1 --rpc-url "$RPC_URL"
cast call "$STREAM" "tokenURI(uint256)(string)" 1 --rpc-url "$RPC_URL"
cast call "$STREAM" "royaltyInfo(uint256,uint256)(address,uint256)" 1 1000000000000000000 --rpc-url "$RPC_URL"
cast call "$STREAM" "workOf(uint256)((bytes32,uint160,uint32,uint32,uint8,uint8,uint8,address,uint24,bool,bytes32))" 1 --rpc-url "$RPC_URL"
cast call "$FACTS" "factsOf(address,uint256)((bytes32,bytes32,address,bool,bool,bool,bool,bool,bytes32,string,(bytes32,uint8)[]))" "$STREAM" 1 --rpc-url "$RPC_URL"

# The network's settings (read them; never assume a number) and a module slot
cast call "$STREAM" "moduleDelay()(uint48)" --rpc-url "$RPC_URL"
cast call "$STREAM" "rescueDelay()(uint48)" --rpc-url "$RPC_URL"
cast call "$DIRECTORY" "unclaimedPeriod()(uint48)" --rpc-url "$RPC_URL"
cast call "$STREAM" "moduleOf(bytes32)(address)" "$(cast format-bytes32-string RENDERER)" --rpc-url "$RPC_URL"
cast call "$STREAM" "pendingModule(bytes32)((address,uint48))" "$(cast format-bytes32-string RENDERER)" --rpc-url "$RPC_URL"

# A 1/1 sale: its derived ID, state and end, the minimum bid, your credit
SALE=$(cast call "$AUCTION" "saleIdOf(address,uint256)(uint256)" "$STREAM" 1 --rpc-url "$RPC_URL" | cut -d' ' -f1)
cast call "$AUCTION" "auction(uint256)((address,uint256,address,uint256,address,address,uint256,uint64,uint64,uint8))" "$SALE" --rpc-url "$RPC_URL"
cast call "$AUCTION" "minimumBid(uint256)(uint256)" "$SALE" --rpc-url "$RPC_URL"
cast call "$AUCTION" "claimable(address)(uint256)" "$ME" --rpc-url "$RPC_URL"

# Bid 0.1 ETH (recipient zero: the token goes to you if the bid wins)
cast send "$AUCTION" "bid(uint256,address)" "$SALE" 0x0000000000000000000000000000000000000000 \
  --value 0.1ether --account me --rpc-url "$RPC_URL"

# An edition sale: its ID, the price of a step, and what a bid of 2 at step 10 would win
ESALE=$(cast call "$EDITION_AUCTION" "saleIdOf(address,uint256)(uint256)" "$EDITIONS" 1 --rpc-url "$RPC_URL" | cut -d' ' -f1)
cast call "$EDITION_AUCTION" "stepPrice(uint256,uint256)(uint256)" "$ESALE" 10 --rpc-url "$RPC_URL"
cast call "$EDITION_AUCTION" "quote(uint256,uint256,uint256)((uint256,uint256,uint256,uint256,(uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256)))" "$ESALE" 10 2 --rpc-url "$RPC_URL"

# A split wallet: what a payee can release (ETH), named by its payee list and salt. A seller
# wallet with the artist as its only payee: (artistId, zero account, 100% = 100,000).
cast call "$LEDGER" "releasable((uint256,address,uint32)[],bytes32,address,uint256)(uint256)" \
  "[($ARTIST_ID,0x0000000000000000000000000000000000000000,100000)]" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000 0 --rpc-url "$RPC_URL"

# The Independent Stream entry of an Independent Stream contract
cast call "$INDEPENDENT_STREAM" "entry(address)((uint8,address,uint256,uint32,bytes32,uint32,uint8))" "$TOKEN" --rpc-url "$RPC_URL"
```

`cast call` prints large numbers with a scientific-notation suffix (`1234 [1.234e3]`); `cut -d' '
-f1` keeps the number. Events: `cast logs --address "$AUCTION" "BidPlaced(uint256,address,address,uint256,uint64)" --from-block <deploy block> --rpc-url "$RPC_URL"`.

## Running the jobs as a keeper

The permissionless steps that keep sales moving (start through `SaleStarter`, open edition
sales, settle, finalize, expire aged credits, forfeit marks, deploy vaults) are implemented,
with tests on a local anvil chain, by the [reference keeper](../keeper/README.md).
