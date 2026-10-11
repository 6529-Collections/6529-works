// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { Party, PartyRole, StreamMintRequest } from "src/interfaces/types/PackageTypes.sol";
import { Payment, PaymentMethod } from "src/interfaces/types/SaleTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice The integration gas report (integration brief, lane B): the budgets ADR 0001 and
///         ADR 0003 set, measured on the real, wired contracts. Run with
///         `forge test --match-contract IntegrationGasReport -vv` to print the table.
/// @dev Every figure is a whole transaction: 21,000 intrinsic, the calldata (EIP-2028, or the
///      EIP-7623 floor when higher) and the execution measured with every contract cooled first.
///      The execution includes a cold call into the target (2,600 gas a real transaction does not
///      pay), so the figures are slightly pessimistic.
///
///      Steady state (ADR 0003): Stream, the collection, the auction's custody balance and the
///      artist's move-nonce word have all been written before. Items are single-artist works
///      (the artist is the sole, artist-resolved payee) in an eight-item package (proof depth 3).
contract IntegrationGasReport is IntegrationBase {
    uint256 internal constant ITEMS = 8;
    uint256 internal constant SETTLE_BUDGET = 400_000;
    /// @dev Tracked, not gated by an ADR: the first work of a new collection writes its serial
    ///      word from zero; ADR 0003 measures it separately.
    uint256 internal constant FIRST_IN_COLLECTION_CEILING = 400_000;

    address internal artistA;
    address internal artistB;
    address internal starter = makeAddr("starter");
    address internal bidder = makeAddr("gasBidder");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artistA = _actor("gasArtistA");
        artistB = _actor("gasArtistB");
        vm.prank(platform);
        uint256 second = stream.createCollection("Second", keccak256("second"));
        Work[] memory works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            // Items 0-5 in the genesis collection, 6-7 in a second one that is still empty.
            works[i] = _work(i % 2 == 0 ? artistA : artistB, i < 6 ? collectionId : second);
        }
        root = _publish(works);
        _keep(root, works);
    }

    function _steadyState() internal {
        Work[] memory works = _package(root);
        _start(root, works, 0);
        _start(root, works, 1);
    }

    function _startData(uint256 index) internal returns (bytes memory) {
        return
            abi.encodeCall(auction.start, (address(stream), _mintData(root, _package(root), index)));
    }

    function test_Gas_Start_SteadyState() public {
        _steadyState();
        (uint256 total, uint256 execution) = _measure(starter, address(auction), _startData(2), 0);
        _row("start, steady state", total, execution);
        assertLe(total, START_BUDGET, "ADR 0003: start <= 350K at steady state");
    }

    function test_Gas_StartWithBid_SteadyState() public {
        _steadyState();
        bytes memory data = abi.encodeCall(
            auction.startWithBid,
            (
                address(stream),
                _mintData(root, _package(root), 2),
                address(0),
                Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
            )
        );
        (uint256 total, uint256 execution) = _measure(bidder, address(auction), data, 1 ether);
        _row("startWithBid, steady state", total, execution);
        assertLe(total, START_BUDGET, "ADR 0003: startWithBid <= 350K at steady state");
    }

    function test_Gas_Start_FirstWorkInANewCollection() public {
        _steadyState();
        (uint256 total, uint256 execution) = _measure(starter, address(auction), _startData(6), 0);
        _row("start, first work in a new collection", total, execution);
        assertLe(total, FIRST_IN_COLLECTION_CEILING, "first start in a new collection");
    }

    function test_Gas_Start_FirstWorkEver() public {
        (uint256 total, uint256 execution) = _measure(starter, address(auction), _startData(0), 0);
        _row("start, first work ever (empty custody, first nonce)", total, execution);
    }

    function test_Gas_Settle() public {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        vm.warp(auction.auction(saleId).endTime);
        bytes memory data = abi.encodeCall(auction.settle, (saleId));
        (uint256 total, uint256 execution) = _measure(starter, address(auction), data, 0);
        _row("settle (bid, ETH, delivery)", total, execution);
        assertLe(total, SETTLE_BUDGET, "settle");
        assertEq(stream.ownerOf(auction.auction(saleId).tokenId), bidder);
    }

    function test_Gas_Bid() public {
        _steadyState();
        (uint256 saleId,) = _start(root, _package(root), 2);
        _ethBid(saleId, bidder, 1 ether);
        address second = makeAddr("secondBidder");
        bytes memory data = abi.encodeCall(
            auction.bid,
            (saleId, address(0), Payment(PaymentMethod.DIRECT, second, 2 ether, 0, 0, ""))
        );
        (uint256 total, uint256 execution) = _measure(second, address(auction), data, 2 ether);
        _row("bid (outbids, credits the previous bidder)", total, execution);
    }

    /// @dev `IPackageRegistry.consume` alone, as Stream calls it at steady state.
    function test_Gas_Consume() public {
        _steadyState();
        bytes memory request = _mintData(root, _package(root), 2);
        StreamMintRequest memory r = abi.decode(request, (StreamMintRequest));
        bytes memory data =
            abi.encodeCall(IPackageRegistry.consume, (r.packageRoot, r.item, r.proof, r.move));
        (uint256 total, uint256 execution) = _measure(address(stream), address(registry), data, 0);
        _row("consume (registry share of start, as a call)", total, execution);
        total;
    }

    function _row(string memory label, uint256 total, uint256 execution) internal pure {
        console2.log(label);
        console2.log("  execution (cold)", execution);
        console2.log("  whole transaction", total);
    }

    /// @dev A two-party work: the lead artist and a collaborator who is paid as a fixed payee.
    function _twoPartyPackage() internal returns (bytes32 twoRoot, Work[] memory works) {
        address collaborator = _actor("gasCollaborator");
        works = new Work[](ITEMS);
        for (uint256 i; i < ITEMS; ++i) {
            works[i] = _work(artistA, collectionId);
            works[i].item.parties = new Party[](2);
            works[i].item.parties[0] = Party(artistA, PartyRole.ARTIST);
            works[i].item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
            works[i].item.payees = new ISplitWallet.Payee[](2);
            works[i].item.payees[0] = ISplitWallet.Payee(0, collaborator, 20_000);
            works[i].item.payees[1] = ISplitWallet.Payee(uint160(artistA), address(0), 80_000);
        }
        twoRoot = _publish(works);
    }

    function test_Gas_Start_TwoPartyWork() public {
        _steadyState();
        (bytes32 twoRoot, Work[] memory works) = _twoPartyPackage();
        _start(twoRoot, works, 0);
        bytes memory data =
            abi.encodeCall(auction.start, (address(stream), _mintData(twoRoot, works, 1)));
        (uint256 total, uint256 execution) = _measure(starter, address(auction), data, 0);
        _row("start, steady state, two-party work", total, execution);
        assertLe(total, START_BUDGET, "a two-party start");
    }

    /// @dev The steady-state `startWithBid` of a two-party work, as a whole transaction.
    function _startWithBidTwoParty() internal returns (uint256 total, uint256 execution) {
        _steadyState();
        (bytes32 twoRoot, Work[] memory works) = _twoPartyPackage();
        _start(twoRoot, works, 0);
        bytes memory data = abi.encodeCall(
            auction.startWithBid,
            (
                address(stream),
                _mintData(twoRoot, works, 1),
                address(0),
                Payment(PaymentMethod.DIRECT, bidder, 1 ether, 0, 0, "")
            )
        );
        (total, execution) = _measure(bidder, address(auction), data, 1 ether);
        _row("startWithBid, steady state, two-party work", total, execution);
    }

    /// @dev FINDING G-2: a steady-state `startWithBid` of a two-party work (artist plus one
    ///      collaborator, the smallest collaboration) costs more than the 350K ADR 0003 sets for
    ///      starting an auction. The single-artist case passes by about 500 gas.
    function test_Finding_G2_StartWithBidOfATwoPartyWorkExceeds350K() public {
        (uint256 total,) = _startWithBidTwoParty();
        assertGt(total, START_BUDGET, "G-2 fixed: assert the budget in a regular test");
    }

    /// @dev `royaltyInfo` derives the receiver through the split factory (ADR 0003): one cold
    ///      external view call. Marketplaces call it with their own gas limits.
    function test_Gas_RoyaltyInfo() public {
        _steadyState();
        bytes memory data = abi.encodeCall(stream.royaltyInfo, (1, 1 ether));
        (, uint256 execution) = _measure(starter, address(stream), data, 0);
        _row("royaltyInfo (cold)", 21_000 + execution, execution);
        assertLt(execution, 50_000);
    }

    function test_Gas_TokenURIBySize() public {
        _tokenUriMatrix(artistA, starter);
    }
}
