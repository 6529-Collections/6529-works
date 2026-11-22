// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { AssetAllowlist } from "src/economics/AssetAllowlist.sol";
import { EconomicsResolver } from "src/economics/EconomicsResolver.sol";
import { ISplitFactory } from "src/economics/interfaces/ISplitFactory.sol";
import { IRevenueEscrow } from "src/economics/interfaces/IRevenueEscrow.sol";
import { RevenueEscrow } from "src/economics/RevenueEscrow.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IDirectory } from "src/interfaces/core/IDirectory.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { EnglishAuction } from "src/sales/EnglishAuction.sol";
import { FederationFixture } from "../../federated/FederationFixture.sol";
import { MockStatementLog } from "./AuctionMocks.sol";

/// @notice The English auction on the real federation stack (`FederationRegistry`,
///         `FederatedStream`, `Accounts`, `SplitLedger`), for review C M-1, L-2 and L-3 and the
///         freeze rule of M-2: a federated sale closes with refunds only when its token is no
///         longer served; removing the auction or suspending a version lets running sales finish
///         and keeps unsold works restartable in the auction that minted them; a restart takes
///         the share in force now and refuses a work that already has an outcome.
contract EnglishAuctionFederatedFixesTest is FederationFixture {
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
            IDirectory(address(fedDirectory)),
            IEconomicsResolver(address(economics)),
            IRevenueEscrow(address(escrow)),
            IStatementLog(address(new MockStatementLog())),
            address(0),
            IEnglishAuction.AuctionConfig(1 days, 15 minutes, 5_000, 3_000_000)
        );
        registry.setAdapter(address(auction), IFederationRegistry.Form.ERC721, true);
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
        registry.setAdapter(address(auction), IFederationRegistry.Form.ERC721, false);
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
        uint256 id = _tokenId(saleId);
        assertEq(fStream.ownerOf(id), address(auction), "unsold: it waits in the auction");
        // The network replaces the auction: the old one is removed and a successor added.
        registry.setAdapter(address(auction), IFederationRegistry.Form.ERC721, false);
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
        registry.setAdapter(address(auction), IFederationRegistry.Form.ERC721, false);
        skip(fStream.rescueDelay());
        // The network's other path: rescue ends the primary sale and moves the work.
        address to = makeAddr("networkVault");
        fStream.rescue(id, to);
        assertEq(fStream.ownerOf(id), to);
        assertEq(uint8(fStream.workOf(id).outcome), uint8(Outcome.RESCUED));
        vm.expectRevert();
        auction.restart(saleId);
    }

    function test_Delisted_RefusesBidsRefundsAndCannotRestart() public {
        uint256 saleId = _start();
        _bid(alice, saleId, 1 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(fStream);
        registry.setStatus(tokens, IFederationRegistry.Status.DELISTED, bytes32("ref"));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fStream))
        );
        auction.bid{ value: 2 ether }(saleId, address(0));
        _end(saleId);
        auction.settle(saleId);
        assertEq(auction.claimable(alice), 1 ether, "refunded");
        assertEq(fStream.ownerOf(_tokenId(saleId)), address(auction));
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fStream))
        );
        auction.restart(saleId);
        // Listed again: the work can be offered again.
        registry.setStatus(tokens, IFederationRegistry.Status.ACTIVE, bytes32("ref"));
        auction.restart(saleId);
    }

    // ------------------------------------------------------------------ restart (L-2, L-3)

    function test_Restart_TakesTheLoweredShare() public {
        uint256 saleId = _start();
        assertEq(auction.auction(saleId).feeShare, SHARE);
        _end(saleId);
        auction.settle(saleId);
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
            abi.encodeWithSelector(IFederationRegistry.AccountCannotAct.selector, fArtistId)
        );
        auction.start(address(fStream), _request(item, media, new bytes[](0)));
        accountsModule.unfreeze(fArtistId);
        auction.start(address(fStream), _request(item, media, new bytes[](0)));
    }
}
