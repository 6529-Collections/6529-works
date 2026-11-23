// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MintFacts } from "src/interfaces/core/CoreTypes.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { AuctionFixture } from "./AuctionFixture.sol";
import { BidderContract, MockMintPolicy } from "./AuctionMocks.sol";

/// @notice A token the Independent Stream module admits but that lies: it reports any minter, mints
///         nothing (or into someone else's hands), repeats IDs, and can re-enter the auction.
contract HostileToken {
    enum Mode {
        ELSEWHERE,
        REPEAT,
        REENTER
    }

    Mode public mode;
    address public auction;
    bytes public reentry;
    bool public reentered;
    mapping(uint256 => address) public ownerOf;

    function setMode(Mode m, address auction_, bytes calldata data) external {
        (mode, auction, reentry) = (m, auction_, data);
    }

    function isMinter(address) external pure returns (bool) {
        return true;
    }

    function mint(address to, MintFacts calldata) external returns (uint256) {
        if (mode == Mode.ELSEWHERE) {
            ownerOf[7] = address(0xBEEF);
            return 7;
        }
        if (mode == Mode.REENTER) {
            (bool ok,) = auction.call(reentry);
            reentered = ok;
        }
        ownerOf[1] = to;
        return 1;
    }
}

/// @notice Hostile policy, token, recipient and bidder: none of them moves a token, changes a
///         recorded fact, or takes or strands money.
contract EnglishAuctionHostileTest is AuctionFixture {
    function test_HostilePolicy_RevertingMintsNothing() public {
        policy.setMode(MockMintPolicy.Mode.REVERT);
        vm.expectRevert(bytes("policy says no"));
        _start(1);
        assertEq(stream.totalMinted(), 0);
    }

    function test_HostilePolicy_BurningAllGasMintsNothing() public {
        policy.setMode(MockMintPolicy.Mode.BURN_GAS);
        vm.expectRevert();
        auction.start{ gas: 1_000_000 }(address(stream), abi.encode(1));
        assertEq(stream.totalMinted(), 0);
    }

    function test_HostilePolicy_CannotReenter() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        policy.setMode(MockMintPolicy.Mode.REENTER);
        policy.setReentry(abi.encodeCall(IEnglishAuction.start, (address(stream), abi.encode(9))));
        _start(2);
        assertFalse(policy.reentered());
        policy.setReentry(abi.encodeCall(IEnglishAuction.withdrawBid, (saleId)));
        _start(3);
        assertFalse(policy.reentered());
        assertEq(stream.totalMinted(), 3);
        assertEq(auction.auction(saleId).bidder, alice);
    }

    function test_HostilePolicy_LyingTermsAreRefused() public {
        policy.setTerms(SaleKind.ENGLISH_AUCTION, "", address(escrow), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidSaleTerms.selector, address(stream), 0)
        );
        _start(1);
        assertEq(stream.totalMinted(), 0);
    }

    function test_HostileToken_AMintThatLandsElsewhereIsRefused() public {
        HostileToken t = new HostileToken();
        t.setMode(HostileToken.Mode.ELSEWHERE, address(auction), "");
        vm.expectRevert(
            abi.encodeWithSelector(IEnglishAuction.InvalidSaleTerms.selector, address(t), 7)
        );
        auction.start(address(t), abi.encode(1));
    }

    function test_HostileToken_ARepeatedIdCannotOverwriteASale() public {
        HostileToken t = new HostileToken();
        t.setMode(HostileToken.Mode.REPEAT, address(auction), "");
        independentStream.setMinter(address(t), address(auction), true); // the module serves it
        uint256 saleId = auction.start(address(t), abi.encode(1));
        vm.prank(alice);
        auction.bid{ value: 1 ether }(saleId, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.ACTIVE
            )
        );
        auction.start(address(t), abi.encode(2));
        assertEq(auction.auction(saleId).bidder, alice);
        assertEq(auction.auction(saleId).bid, 1 ether);
    }

    function test_HostileToken_CannotReenterFromItsMint() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        HostileToken t = new HostileToken();
        t.setMode(
            HostileToken.Mode.REENTER,
            address(auction),
            abi.encodeCall(IEnglishAuction.claim, (address(0xBAD)))
        );
        auction.start(address(t), abi.encode(1));
        assertFalse(t.reentered());
        assertEq(address(auction).balance, 1 ether);
    }

    function test_HostileToken_CannotTouchAStreamSale() public {
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        HostileToken t = new HostileToken();
        t.setMode(HostileToken.Mode.REPEAT, address(auction), "");
        auction.start(address(t), abi.encode(1));
        assertEq(stream.ownerOf(1), address(auction));
        assertEq(auction.auction(saleId).bidder, alice);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
    }

    function test_HostileRecipient_ReenteringOnDeliveryChangesNothing() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        uint256 other = _start(2);
        _bid(carol, other, 1 ether);
        _bid(alice, other, 2 ether);
        uint256 saleId = _start(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        b.setReentry(abi.encodeCall(IEnglishAuction.settle, (other)));
        _end(saleId);
        auction.settle(saleId);
        assertFalse(b.reentered());
        // The re-entry failed on the guard; the recipient took the work.
        assertEq(stream.ownerOf(_tokenId(saleId)), address(b));
        assertEq(auction.pendingDelivery(saleId), address(0));
        assertEq(seller.balance, 0.9 ether);
        assertEq(auction.auction(other).bidder, alice);
        assertEq(address(auction).balance, 3 ether);
    }

    function test_HostileBidder_RefusingItsRefundBlocksNoOne() public {
        BidderContract b = new BidderContract(IEnglishAuction(address(auction)));
        b.set(true, true, false);
        uint256 saleId = _start(1);
        b.bid{ value: 1 ether }(saleId, address(0));
        _bid(alice, saleId, 2 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(stream.ownerOf(1), alice);
        assertEq(auction.claimable(address(b)), 1 ether);
    }

    function test_HostileFeeRecipient_IsPaidThroughTheEscrow() public {
        address refusing = address(new BidderContract(IEnglishAuction(address(auction))));
        BidderContract(payable(refusing)).set(true, false, false);
        (uint64 rev,,) = economics.revisions(keccak256("PRODUCT_STREAM"));
        economics.setFeeTerms(keccak256("PRODUCT_STREAM"), rev, refusing, 5_000);
        uint256 saleId = _start(1);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(escrow.owed(refusing, address(0)), 0.1 ether);
        assertEq(stream.ownerOf(1), alice);
    }
}
