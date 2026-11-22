# Integration examples

Short, runnable examples of the common integration jobs against 6529 Works. Each is one Foundry
test file that deploys the whole system the way the deploy script does (the integration
fixture, [`test/integration/IntegrationBase.sol`](../test/integration/IntegrationBase.sol), with
the committed genesis) and then does one job through the real interfaces. They compile with the
test suite and run in CI with every `forge test`, so they cannot drift from the contracts.

> Pre-audit. Interfaces may still change before the audit; these examples change with them.

> The plain permanent core (ADR 0010) is being built. `ReadAWork` and `IndexFromEvents` already
> read the new core (`Stream`, `WorkFacts`, the network's settings), deployed with pass-through
> modules ([`test/mocks/core/CoreFixture.sol`](../test/mocks/core/CoreFixture.sol)). The other
> six still run on the previous stack through the integration fixture, and move to the new
> stack when it is integrated.

```bash
forge test --match-path "examples/*"                 # all of them, in about a second
forge test --match-path examples/BidInEth.t.sol -vvvv  # one, with a full call trace
```

The trace (`-vvvv`) shows every call and event with decoded arguments: the quickest way to see
exactly what a transaction does.

| Example | What it shows |
| --- | --- |
| [`ReadAWork.t.sol`](ReadAWork.t.sol) | Everything a marketplace or wallet shows for one work: owner, what Stream stores (`workOf`, one plain struct), its collection, how the first sale ended (and the price, from the `PrimarySale` log), the permanent record in `WorkFacts`, the renderer, `tokenURI` and `royaltyInfo`; and the network's settings (`moduleDelay`, `rescueDelay`, `rebindDelay`, `unclaimedPeriod`) and the modules in force |
| [`BidInEth.t.sol`](BidInEth.t.sol) | Watching a 1/1 sale and bidding in ETH: the minimum bid, the increment, the anti-snipe extension, being outbid (a credit, never pushed back) and claiming the credit |
| [`StartASale.t.sol`](StartASale.t.sol) | Starting a sale from the artist's signed move, with the wallet-prefixed proof `abi.encodePacked(wallet, signature)`: through `SaleStarter` (vaults and record in the same transaction), and what to do when someone started it directly first |
| [`SettleASale.t.sol`](SettleASale.t.sol) | Settling a 1/1 and what each party receives: the winner the token, the seller split wallet the price less the fee, the network fee recipient the fee; `SaleSettled` decoded; with no bid, the work going to the museum |
| [`EditionSale.t.sol`](EditionSale.t.sol) | Bidding in an edition sale: steps and escrow, `quote`, `clearing` and `bidOutcome`, the close following the 1/1, settlement with the settler's own order, claiming copies and the refund, and pushing a claim for a bidder |
| [`ReleaseFromASplit.t.sol`](ReleaseFromASplit.t.sol) | Releasing from split wallets: the artist pulls sale proceeds; a royalty release that pays the network its share in the same call; a ClaimRouter batch that leaves the network's own index out |
| [`IndexFromEvents.t.sol`](IndexFromEvents.t.sol) | Rebuilding Stream's state (owners, the facts of each work, outcomes and prices, royalties, the content index, the supply) from its logs alone, through a mint, a sale, a burn, a re-mint of the burned content and a royalty change, then checking it against the views |
| [`FederationDirectory.t.sol`](FederationDirectory.t.sol) | Discovering federated contracts from `FederatedContractListed`, then reading each one's listing and status, its federation registry entry, and the network share in force |

The examples use the integration fixture's helpers for setup (publishing a package, signing as
a test key, moving time with `vm.warp`). The calls they demonstrate are the ones a client makes.
The ABIs to make them from another language are in [`abi/`](../abi/)
([how to use them](../docs/integrators/abis-and-interface-ids.md#the-exported-abis)), and the
contract addresses in [Addresses](../docs/integrators/addresses.md).

## The same reads with `cast`

With `RPC_URL` and the addresses from a deployment record (`STREAM`, `RECORDS`, `AUCTION`,
`EDITION_AUCTION`, `EDITIONS`, `LEDGER` for `SplitFactory`, `ARTISTS`):

```bash
# A work: owner, metadata, royalty, record, license and media
cast call "$STREAM" "ownerOf(uint256)(address)" 1 --rpc-url "$RPC_URL"
cast call "$STREAM" "tokenURI(uint256)(string)" 1 --rpc-url "$RPC_URL"
cast call "$STREAM" "royaltyInfo(uint256,uint256)(address,uint256)" 1 1000000000000000000 --rpc-url "$RPC_URL"
cast call "$STREAM" "workOf(uint256)((bytes32,uint160,uint32,uint32,uint8,uint8,uint8,address,uint24,bool,bytes32))" 1 --rpc-url "$RPC_URL"
cast call "$STREAM" "rescueDelay()(uint48)" --rpc-url "$RPC_URL"   # a network setting, read it
cast call "$RECORDS" "licenseOf(uint256)((string,bytes32))" 1 --rpc-url "$RPC_URL"
cast call "$RECORDS" "mediaOf(uint256)((bytes32,bytes32,uint8)[])" 1 --rpc-url "$RPC_URL"

# A 1/1 sale: its ID, state and end, the minimum bid, your credit
SALE=$(cast call "$AUCTION" "saleIdOf(address,uint256)(uint256)" "$STREAM" 1 --rpc-url "$RPC_URL" | cut -d' ' -f1)
cast call "$AUCTION" "auctionClock(uint256)(uint8,uint64,uint64)" "$SALE" --rpc-url "$RPC_URL"   # state, end, pausedAt
cast call "$AUCTION" "minimumBid(uint256)(uint256)" "$SALE" --rpc-url "$RPC_URL"
cast call "$AUCTION" "claimable(address,address)(uint256)" "$ME" 0x0000000000000000000000000000000000000000 --rpc-url "$RPC_URL"

# Bid 0.1 ETH (DIRECT payment: method 0, payer = you, amount = msg.value)
cast send "$AUCTION" "bid(uint256,address,(uint8,address,uint256,uint256,uint256,bytes))" \
  "$SALE" 0x0000000000000000000000000000000000000000 "(0,$ME,100000000000000000,0,0,0x)" \
  --value 0.1ether --account me --rpc-url "$RPC_URL"

# An edition sale: its ID, close, the price of a step, and what a bid of 2 at step 10 would win
ESALE=$(cast call "$EDITION_AUCTION" "saleIdOf(address,uint256)(uint256)" "$EDITIONS" 1 --rpc-url "$RPC_URL" | cut -d' ' -f1)
cast call "$EDITION_AUCTION" "stepPrice(uint256,uint256)(uint256)" "$ESALE" 10 --rpc-url "$RPC_URL"
cast call "$EDITION_AUCTION" "quote(uint256,uint256,uint256)((uint256,uint256,uint256,uint256,(uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256,uint256,uint256)))" "$ESALE" 10 2 --rpc-url "$RPC_URL"

# A split wallet: what a payee can release (ETH), named by its payee list and salt. A royalty
# wallet's payees are the seller wallet and the fee vault sorted by address (here a 25% fee
# share); the payee's index is its position in that order.
if [[ "${SELLER_WALLET,,}" < "${FEE_VAULT,,}" ]]; then
  PAYEES="[(0,$SELLER_WALLET,75000),(0,$FEE_VAULT,25000)]"; SELLER_INDEX=0
else
  PAYEES="[(0,$FEE_VAULT,25000),(0,$SELLER_WALLET,75000)]"; SELLER_INDEX=1
fi
cast call "$LEDGER" "releasable((uint256,address,uint32)[],bytes32,address,uint256)(uint256)" \
  "$PAYEES" 0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000 "$SELLER_INDEX" --rpc-url "$RPC_URL"

# The federation directory entry of a federated contract
cast call "$ARTISTS" "federatedListing(address)(uint256,uint8)" "$TOKEN" --rpc-url "$RPC_URL"
```

`cast call` prints large numbers with a scientific-notation suffix (`1234 [1.234e3]`); `cut -d' '
-f1` keeps the number. Events: `cast logs --address "$AUCTION" "BidPlaced(uint256,address,address,uint256,uint64)" --from-block <deploy block> --rpc-url "$RPC_URL"`.

## Running the jobs as a keeper

The permissionless steps that keep sales moving (start through `SaleStarter`, open edition
sales, settle, create editions, abandon, finalize, expire credits, forfeit marks, deploy vaults)
are implemented, with tests on a local anvil chain, by the [reference keeper](../keeper/README.md).
