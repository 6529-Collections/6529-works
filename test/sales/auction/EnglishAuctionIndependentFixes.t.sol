// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { Core, MintFacts, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { IndependentStreamFixture } from "../../independent/IndependentStreamFixture.sol";
import { MockStatementLog } from "./AuctionMocks.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IIndependentStreamMembership } from "src/interfaces/IIndependentStreamMembership.sol";
import { IMintPolicy } from "src/interfaces/core/IMintPolicy.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";

/// @notice The English auction on the real Independent Stream stack (`IndependentStreamRegistry`,
///         `IndependentStream6529`, `Accounts`, `SplitLedger`), for review C M-1, L-2 and L-3 and
///         the freeze rule of M-2: an Independent Stream sale closes with refunds only when its
///         token is no longer served; removing the auction or suspending a version lets running
///         sales finish and keeps unsold works restartable in the auction that minted them; a
///         restart takes the share in force now and refuses a work that already has an outcome.
contract EnglishAuctionIndependentFixesTest is IndependentStreamFixture {
    EnglishAuction internal auction;
    RevenueEscrow internal escrow;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal n;

    function setUp() public override {
        super.setUp();
        escrow = new RevenueEscrow(address(manager), ISplitFactory(address(ledger)));
        AssetAllowlist allowlist = new AssetAllowlist(address(manager), 0.001 ether);
        EconomicsResolver economics = new EconomicsResolver(
            address(manager),
            allowlist,
            ISplitFactory(address(ledger)),
            feeVault,
            makeAddr("museum"),
            CC0_TEXT
        );
        auction = new EnglishAuction(
            address(manager),
            address(stream),
            IDirectory(address(indDirectory)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(new MockStatementLog())),
            address(0),
            IEnglishAuction.AuctionConfig(1 days, 15 minutes, 5_000, 3_000_000)
        );
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, true);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _start() internal returns (uint256 saleId) {
        (PackageItem memory item, MediaFile[] memory media) = _item(++n);
        _approve(address(fStream), item, RATE);
        saleId = auction.start(address(fStream), _request(item, media, new bytes[](0)));
    }

    function _bid(address who, uint256 saleId, uint256 amount) internal {
        vm.prank(who);
        auction.bid{ value: amount }(saleId, address(0));
    }

    function _end(uint256 saleId) internal {
        vm.warp(auction.auction(saleId).endTime);
    }

    function _tokenId(uint256 saleId) internal view returns (uint256) {
        return auction.auction(saleId).tokenId;
    }

    // ------------------------------------------------- removal and suspension (M-1)

    function test_RemovedAuction_ItsRunningSaleStillSells() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, false);
        _bid(bob, saleId, 2 ether);
        _end(saleId);
        auction.settle(saleId);
        uint256 id = _tokenId(saleId);
        assertEq(fStream.ownerOf(id), bob);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.SOLD));
        assertEq(auction.claimable(bob), 0, "the winner's bid was paid out, not refunded");
        assertEq(auction.claimable(alice), 1 ether);
    }

    function test_SuspendedVersion_ItsRunningSaleStillSells() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        registry.suspendTemplate(address(streamDeployer));
        assertTrue(registry.isActive(address(fStream)));
        _end(saleId);
        auction.settle(saleId);
        assertEq(fStream.ownerOf(_tokenId(saleId)), alice);
        assertEq(auction.claimable(alice), 0);
    }

    function test_RemovedAuction_UnsoldWorkIsOfferedAgainAndSold() public {
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        uint256 id = _tokenId(saleId);
        assertEq(fStream.ownerOf(id), address(auction), "unsold: it waits in the auction");
        // The network replaces the auction: the old one is removed and a successor added.
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, false);
        assertFalse(registry.canMint(address(fStream), address(auction)));
        auction.restart(saleId);
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(fStream.ownerOf(id), alice);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.SOLD));
    }

    function test_RemovedAuction_TheNetworkMayStillRescueAfterTheDelay() public {
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        uint256 id = _tokenId(saleId);
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, false);
        skip(fStream.rescueDelay());
        // The network's other path: rescue ends the primary sale and moves the work.
        address to = makeAddr("networkVault");
        fStream.rescue(id, to);
        assertEq(fStream.ownerOf(id), to);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.RESCUED));
        vm.expectRevert();
        auction.restart(saleId);
    }

    /// @dev A running sale's work is rescued to the auction itself. `settle` closes the sale at
    ///      once (no wait for the refusal exit): the bid is credited back, nothing is recorded or
    ///      paid, the work goes to the museum, and the closed sale is never offered again.
    function test_Rescued_ToTheAuctionItselfClosesAtOnceAndNeverRestarts() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        uint256 id = _tokenId(saleId);
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, false);
        skip(fStream.rescueDelay());
        fStream.rescue(id, address(auction));
        assertEq(fStream.ownerOf(id), address(auction));
        uint256 feeBefore = _fee().balance;

        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle(saleId);
        bytes memory closed = abi.encodeWithSelector(
            IEnglishAuction.InvalidAuctionState.selector,
            saleId,
            IEnglishAuction.AuctionState.CANCELLED
        );
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(auction.claimable(alice), 1 ether, "credited back");
        assertEq(address(auction).balance, 1 ether, "only the credit is held");
        assertEq(_fee().balance, feeBefore, "nothing paid");
        assertEq(address(escrow).balance, 0);
        assertEq(fStream.ownerOf(id), makeAddr("museum"), "not left in the auction");
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.RESCUED));

        skip(auction.REFUSAL_DELAY());
        vm.expectRevert(closed);
        auction.restart(saleId);
        vm.expectRevert(closed);
        auction.settleOrRefund(saleId);
        vm.expectRevert(closed);
        auction.settle(saleId);
    }

    /// @dev The rescue's recipient sends the work back before anyone settled, and the sale has
    ///      no bid: it closes with nothing credited and the work goes to the museum.
    function test_Rescued_SentBackWithNoBidClosesAndGoesToTheMuseum() public {
        uint256 saleId = _start();
        uint256 id = _tokenId(saleId);
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, false);
        skip(fStream.rescueDelay());
        address vault = makeAddr("networkVault");
        fStream.rescue(id, vault);
        vm.prank(vault);
        fStream.transferFrom(vault, address(auction), id);

        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(saleId);
        auction.settle(saleId);
        assertEq(
            uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.CANCELLED)
        );
        assertEq(fStream.ownerOf(id), makeAddr("museum"));
        assertEq(address(auction).balance, 0);
    }

    function test_Delisted_RefusesBidsRefundsAndCannotRestart() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(fStream);
        registry.setStatus(tokens, IIndependentStreamRegistry.Status.DELISTED, bytes32("ref"));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fStream))
        );
        auction.bid{ value: 2 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        assertEq(auction.claimable(alice), 1 ether, "refunded");
        assertEq(fStream.ownerOf(_tokenId(saleId)), address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fStream))
        );
        auction.restart(saleId);
        // Listed again: the work can be offered again.
        registry.setStatus(tokens, IIndependentStreamRegistry.Status.ACTIVE, bytes32("ref"));
        auction.restart(saleId);
    }

    // ------------------------------------------------------------------ restart (L-2, L-3)

    function test_Restart_TakesTheLoweredShare() public {
        uint256 saleId = _start();
        assertEq(auction.auction(saleId).feeShare, SHARE);
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        registry.lowerFeeShare(address(fStream), SHARE / 2);
        auction.restart(saleId);
        assertEq(auction.auction(saleId).feeShare, SHARE / 2);
    }

    function test_Restart_RefusesASoldWorkSentBack() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        uint256 id = _tokenId(saleId);
        vm.prank(alice);
        IERC721(address(fStream)).transferFrom(alice, address(auction), id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnglishAuction.InvalidAuctionState.selector,
                saleId,
                IEnglishAuction.AuctionState.SETTLED
            )
        );
        auction.restart(saleId);
    }

    // ------------------------------------------------------------- frozen accounts (M-2)

    function test_FrozenAccount_ApprovedItemCannotStart() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(++n);
        _approve(address(fStream), item, RATE);
        accountsModule.freeze(fArtistId);
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.AccountCannotAct.selector, fArtistId)
        );
        auction.start(address(fStream), _request(item, media, new bytes[](0)));
        accountsModule.unfreeze(fArtistId);
        auction.start(address(fStream), _request(item, media, new bytes[](0)));
    }

    // ===================================================== rules of the specification

    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(fStream);
    }

    /// @dev Approves a new item and starts its sale; returns the item for the record.
    function _startItem()
        internal
        returns (uint256 saleId, PackageItem memory item, MediaFile[] memory media)
    {
        (item, media) = _item(++n);
        _approve(address(fStream), item, RATE);
        saleId = auction.start(address(fStream), _request(item, media, new bytes[](0)));
    }

    /// @dev Where the auction pays the network's share of an Independent Stream sale.
    function _fee() internal view returns (address) {
        return auction.economics().networkFeeRecipient(PRODUCT_INDEPENDENT);
    }

    function _notServed() internal view returns (bytes memory) {
        return abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fStream));
    }

    /// @dev Neither the module's `authorize` nor the token's `mint` lets the auction mint now.
    function _expectNoMint(bytes memory request) internal {
        assertFalse(registry.canMint(address(fStream), address(auction)));
        assertFalse(fStream.isMinter(address(auction)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintPolicy.NotSaleContract.selector, address(fStream), address(auction)
            )
        );
        auction.start(address(fStream), request);
        MintFacts memory f = _facts(900);
        f.artistId = fArtistId;
        vm.prank(address(auction));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(auction)));
        fStream.mint(address(auction), f);
    }

    // ------------------------------------------------------------------ minting (IND-7)

    /// A contract that is delisted (by contract or by account), or whose template is suspended or
    /// revoked, mints nothing: the module refuses to authorize and the token refuses the mint.
    /// Each is lifted in turn, and then the same approved item mints (IND-7).
    function test_Start_ADelistedSuspendedOrRevokedContractMintsNothing() public {
        (PackageItem memory item, MediaFile[] memory media) = _item(++n);
        _approve(address(fStream), item, RATE);
        bytes memory request = _request(item, media, new bytes[](0));
        assertTrue(registry.canMint(address(fStream), address(auction)));

        registry.setStatus(_tokens(), IIndependentStreamRegistry.Status.DELISTED, "ref");
        _expectNoMint(request);
        registry.setStatus(_tokens(), IIndependentStreamRegistry.Status.ACTIVE, "ref");

        registry.setAccountDelisted(fArtistId, true, "ref");
        _expectNoMint(request);
        registry.setAccountDelisted(fArtistId, false, "ref");

        registry.suspendTemplate(address(streamDeployer));
        _expectNoMint(request);
        registry.resumeTemplate(address(streamDeployer));

        registry.revokeTemplate(address(streamDeployer));
        _expectNoMint(request);
        registry.reinstateTemplate(address(streamDeployer));

        assertEq(fStream.totalMinted(), 0, "nothing was minted meanwhile");
        uint256 saleId = auction.start(address(fStream), request);
        assertEq(fStream.ownerOf(_tokenId(saleId)), address(auction));
    }

    // ------------------------------------------------------------------ unsold works (IND-17)

    /// An unsold work stays with the sale contract: no wallet of the artist's account can move it,
    /// claim it, record an outcome for it, burn it or rescue it. It is offered again there, the
    /// same token of the same item, and leaves only by being sold (IND-17).
    function test_Unsold_TheArtistCannotTakeTheWorkOutOfTheSaleContract() public {
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        uint256 id = _tokenId(saleId);
        bytes32 itemHash = fStream.itemHashOf(id);
        assertEq(fStream.ownerOf(id), address(auction));
        assertEq(auction.pendingDelivery(saleId), address(0));

        address[2] memory callers = [artist, wallet];
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];
            vm.startPrank(caller);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC721Errors.ERC721InsufficientApproval.selector, caller, id
                )
            );
            fStream.transferFrom(address(auction), caller, id);
            vm.expectRevert(
                abi.encodeWithSelector(IEnglishAuction.NoPendingDelivery.selector, saleId)
            );
            auction.claimDelivery(saleId, caller);
            vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
            fStream.recordPrimarySale(id, true, caller, 0);
            vm.expectRevert(abi.encodeWithSelector(IStream.NotInPrimarySale.selector, id));
            fStream.burn(id);
            vm.expectRevert(
                abi.encodeWithSelector(IIndependentStreamMembership.NotNetwork.selector, caller)
            );
            fStream.rescue(id, caller);
            vm.stopPrank();
        }
        assertEq(fStream.ownerOf(id), address(auction), "still in the sale contract");
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.NONE));

        // Offered again in the same sale contract: the same token of the same item.
        vm.prank(artist);
        auction.restart(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        assertEq(_tokenId(saleId), id);
        assertEq(fStream.itemHashOf(id), itemHash);
        assertEq(fStream.ownerOf(id), address(auction));
        assertEq(fStream.totalMinted(), 1, "no second token for the item");
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(fStream.ownerOf(id), alice, "it leaves by being sold");
    }

    // ------------------------------------------------------------------ revocation (IND-46)

    /// Revoking a template stops the module serving its contracts: a running sale takes no more
    /// bids and ends unsold with its bid credited back, nothing is paid and the work cannot be
    /// offered again. The network reverses it: reinstated, the contract is served, the work is
    /// offered again and sold (IND-46, IND-74).
    function test_RevokedVersion_ARunningSaleEndsUnsoldWithARefundUntilReinstated() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        uint256 id = _tokenId(saleId);
        address seller = auction.auction(saleId).seller;
        uint256 feeBefore = _fee().balance;

        registry.revokeTemplate(address(streamDeployer));
        assertFalse(registry.isActive(address(fStream)), "no longer served");
        assertFalse(registry.canMint(address(fStream), address(auction)));
        vm.prank(bob);
        vm.expectRevert(_notServed());
        auction.bid{ value: 2 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        assertEq(auction.claimable(alice), 1 ether, "the bid is credited back");
        assertEq(fStream.ownerOf(id), address(auction));
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.NONE), "unsold");
        assertEq(seller.balance, 0, "nothing paid to the seller");
        assertEq(_fee().balance, feeBefore, "nothing paid to the network");
        vm.expectRevert(_notServed());
        auction.restart(saleId);

        registry.reinstateTemplate(address(streamDeployer));
        assertTrue(registry.isActive(address(fStream)), "served again as listed");
        assertTrue(registry.canMint(address(fStream), address(auction)));
        auction.restart(saleId);
        _bid(bob, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(fStream.ownerOf(id), bob);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.SOLD));
    }

    // ------------------------------------------------------------------ suspension

    /// While a template is suspended the module authorizes no new work for its contracts and lists
    /// no new contract of it, and a sale that was running settles as sold.
    function test_SuspendedVersion_NoNewWorkOrContractAndTheRunningSaleSells() public {
        uint256 running = _start();
        _bid(alice, running, 1 ether);
        (PackageItem memory item, MediaFile[] memory media) = _item(++n);
        _approve(address(fStream), item, RATE);
        IndependentStream6529 another = _deployStream(fArtistId, keccak256("another"));
        IIndependentStreamRegistry.Join memory j =
            _joinData(address(another), artistKey, artistKey, address(streamDeployer));

        registry.suspendTemplate(address(streamDeployer));
        _expectNoMint(_request(item, media, new bytes[](0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                IIndependentStreamRegistry.NotListable.selector, address(another)
            )
        );
        registry.register(address(another), j);

        _bid(bob, running, 2 ether);
        _end(running);
        auction.settle(running);
        assertEq(fStream.ownerOf(_tokenId(running)), bob, "the running sale finished");
        assertEq(uint8(fStream.workOf(_tokenId(running)).outcome), uint8(Outcome.SOLD));
    }

    /// A suspended template's contracts are still served, so an unsold work already in the
    /// auction's custody is offered again there during the suspension.
    function test_Restart_AnUnsoldWorkOfASuspendedVersionIsOfferedAgain() public {
        uint256 saleId = _start();
        _end(saleId);
        auction.settle(saleId);
        vm.warp(block.timestamp + auction.RESTART_DELAY());
        registry.suspendTemplate(address(streamDeployer));
        assertTrue(registry.isActive(address(fStream)));
        assertFalse(registry.canMint(address(fStream), address(auction)));
        auction.restart(saleId);
        assertEq(uint8(auction.auction(saleId).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
        _bid(alice, saleId, 1 ether);
        _end(saleId);
        auction.settle(saleId);
        assertEq(fStream.ownerOf(_tokenId(saleId)), alice);
    }

    // ------------------------------------------------------------------ the network's share

    /// A sold sale pays the network exactly its share of the price at the share the sale stored
    /// when it started, and the seller the rest: a share lowered while the sale runs does not
    /// change what this sale pays (IND-52).
    function testFuzz_Settle_TheNetworkReceivesExactlyTheShareStoredInTheSale(
        uint96 price,
        uint32 lowered
    ) public {
        uint256 saleId = _start();
        uint256 stored = auction.auction(saleId).feeShare;
        assertEq(stored, registry.feeShareOf(address(fStream)), "the share in force at the start");
        price = uint96(bound(price, auction.minimumBid(saleId), 50 ether));
        lowered = uint32(bound(lowered, 0, stored - 1));
        _bid(alice, saleId, price);
        registry.lowerFeeShare(address(fStream), lowered);
        assertEq(auction.auction(saleId).feeShare, stored, "the sale keeps its share");

        address seller = auction.auction(saleId).seller;
        uint256 feeBefore = _fee().balance;
        uint256 sellerBefore = seller.balance;
        _end(saleId);
        auction.settle(saleId);
        uint256 expected = price - uint256(price) * (Core.DENOMINATOR - stored) / Core.DENOMINATOR;
        assertEq(_fee().balance - feeBefore, expected, "exactly the stored share");
        assertEq(seller.balance - sellerBefore, price - expected, "the seller takes the rest");
        assertEq(address(auction).balance, 0, "nothing stays in the auction");
    }

    /// The network receives nothing from a sale that does not sell: one with no bid, one whose
    /// contract was delisted while it ran (the bid is credited back), and one whose work the
    /// network rescued (IND-52).
    function test_Settle_TheNetworkReceivesNothingWhenTheSaleDoesNotSell() public {
        uint256 feeBefore = _fee().balance;

        uint256 noBid = _start();
        _end(noBid);
        auction.settle(noBid);
        assertEq(_fee().balance, feeBefore, "no bid");

        uint256 delisted = _start();
        _bid(alice, delisted, 1 ether);
        registry.setStatus(_tokens(), IIndependentStreamRegistry.Status.DELISTED, "ref");
        _end(delisted);
        auction.settle(delisted);
        assertEq(_fee().balance, feeBefore, "delisted");
        assertEq(auction.claimable(alice), 1 ether);
        registry.setStatus(_tokens(), IIndependentStreamRegistry.Status.ACTIVE, "ref");

        uint256 rescued = _start();
        _bid(bob, rescued, 1 ether);
        registry.setAdapter(address(auction), IIndependentStreamRegistry.Form.ERC721, false);
        skip(fStream.rescueDelay());
        fStream.rescue(_tokenId(rescued), makeAddr("networkVault"));
        if (block.timestamp < auction.auction(rescued).endTime) _end(rescued);
        vm.expectEmit(address(auction));
        emit IEnglishAuction.RescuedSaleClosed(rescued);
        auction.settle(rescued);
        assertEq(_fee().balance, feeBefore, "rescued");
        assertEq(auction.claimable(bob), 1 ether);
        assertEq(address(auction).balance, 2 ether, "only the two credits are held");
        assertEq(address(escrow).balance, 0, "nothing was routed to the escrow");
    }

    // ------------------------------------------------------------------ what stays (IND-50)

    uint256 internal soldId;
    uint256 internal unsoldId;
    address internal soldSeller;

    /// @dev Tokens, ownership, the work's facts and record, the royalty terms, the seller vault's
    ///      money and a bidder's credit, as one hash.
    function _held() internal view returns (bytes32) {
        bytes32 tokens = keccak256(
            abi.encode(
                fStream.totalMinted(),
                fStream.ownerOf(soldId),
                fStream.ownerOf(unsoldId),
                fStream.workOf(soldId),
                fStream.workOf(unsoldId)
            )
        );
        bytes32 record = keccak256(abi.encode(facts.factsOf(address(fStream), soldId)));
        (address receiver, uint256 royalty) = fStream.royaltyInfo(soldId, 1 ether);
        return keccak256(
            abi.encode(
                tokens, record, receiver, royalty, soldSeller.balance, auction.claimable(bob)
            )
        );
    }

    /// A delisting by contract, a delisting by account and a revocation each leave every token,
    /// its owner, its facts and record, its royalty terms, the money in its seller vault and a
    /// bidder's credit exactly as they were; afterwards the holder still transfers, the bidder
    /// still claims and the vault still pays the artist (IND-50).
    function test_Delisting_TouchesNoTokenRecordVaultOrCredit() public {
        (uint256 sold, PackageItem memory item, MediaFile[] memory media) = _startItem();
        _bid(bob, sold, 1 ether);
        _bid(alice, sold, 2 ether);
        _end(sold);
        auction.settle(sold);
        soldId = _tokenId(sold);
        soldSeller = auction.auction(sold).seller;
        facts.open(address(fStream), soldId, item, media);
        uint256 unsold = _start();
        _end(unsold);
        auction.settle(unsold);
        unsoldId = _tokenId(unsold);
        assertEq(auction.claimable(bob), 1 ether, "the outbid bidder's credit");
        assertGt(soldSeller.balance, 0, "the seller vault holds the price");
        assertTrue(facts.factsOf(address(fStream), soldId).opened);
        bytes32 before = _held();

        registry.setStatus(_tokens(), IIndependentStreamRegistry.Status.DELISTED, "ref");
        assertEq(_held(), before, "delisting by contract");
        registry.setAccountDelisted(fArtistId, true, "ref");
        assertEq(_held(), before, "delisting by account");
        registry.revokeTemplate(address(streamDeployer));
        assertEq(_held(), before, "revocation");
        assertFalse(registry.isActive(address(fStream)));

        vm.prank(alice);
        fStream.transferFrom(alice, makeAddr("nextHolder"), soldId);
        assertEq(fStream.ownerOf(soldId), makeAddr("nextHolder"));
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        assertEq(auction.claim(bob), 1 ether);
        assertEq(bob.balance - bobBefore, 1 ether);
        uint256 vault = soldSeller.balance;
        uint256 artistBefore = artist.balance;
        vm.prank(artist);
        assertEq(ledger.release(item.payees, bytes32(0), address(0), 0), vault);
        assertEq(artist.balance - artistBefore, vault, "the vault pays the artist");
    }
}
