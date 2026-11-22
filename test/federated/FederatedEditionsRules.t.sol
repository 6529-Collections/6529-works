// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedEditionAuctionLens } from "src/federated/FederatedEditionAuctionLens.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { FedAdapterMock } from "./FederatedStateHandler.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The federated editions template's own rules, each pinned directly: the master check
///         and the sale kind when an adapter binds, binding an edition that already exists,
///         creation (its logs and its maximum), the bound adapter's mints (exact data, the
///         remaining supply, the running count, the terms and the log), seals below what was
///         minted, an unsealed mint by an adapter the network removed, and the partner check at
///         deployment.
contract FederatedEditionsRulesTest is FederationBase {
    FederatedEditionAuction internal fea;
    FederatedStream internal pairStream;
    FederatedEditions internal pairEditions;
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        FederatedEditionAuctionLens lens = new FederatedEditionAuctionLens(
            address(auction), address(escrow), address(artists), address(economics)
        );
        fea = new FederatedEditionAuction(
            address(manager),
            address(escrow),
            address(auction),
            address(lens),
            address(lens).codehash,
            DeployV1.editionAuctionDefaults(),
            DeployV1.editionAuctionLimits()
        );
        _admit(address(fea), true);
        (pairStream, pairEditions) = _pair(fedArtist);
    }

    function _admit(address adapter, bool on) internal {
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.setAdapter, (adapter, on))
        );
    }

    /// @dev A master sold on the English auction, its edition neither bound nor created.
    function _soldMaster(uint32 maxCount) internal returns (Work memory w, uint256 tokenId) {
        w = _fedMaster(fedArtist, maxCount);
        uint256 saleId;
        (saleId, tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encode(address(0), uint256(1 ether));
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    // ------------------------------------------------------------------ binding

    function test_Bind_RefusesAnItemThatIsNotTheMasters() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        PackageItem memory wrong = abi.decode(abi.encode(w.item), (PackageItem));
        wrong.contentHash = keccak256("another work");
        vm.prank(address(fea));
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.NotEditionMaster.selector, tokenId)
        );
        pairEditions.bindMinter(tokenId, wrong);
        vm.expectEmit(address(pairEditions));
        emit IFederatedEditions.EditionMinterBound(tokenId, address(fea));
        vm.prank(address(fea));
        pairEditions.bindMinter(tokenId, w.item);
    }

    /// @dev An adapter whose sale kind is not the master's edition terms' kind cannot bind it,
    ///      whichever side of the terms' label its own falls.
    function test_Bind_RefusesAnAdapterOfAnotherSaleKind() public {
        Work memory w = _fedMaster(fedArtist, 0);
        (, uint256 tokenId) = _startFed(pairStream, fedArtist, w, RATE);
        FedAdapterMock high = new FedAdapterMock(bytes32(type(uint256).max));
        FedAdapterMock low = new FedAdapterMock(bytes32(uint256(1)));
        _admit(address(high), true);
        _admit(address(low), true);
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.NotEditionMaster.selector, tokenId)
        );
        high.bind(address(pairEditions), tokenId, w.item);
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.NotEditionMaster.selector, tokenId)
        );
        low.bind(address(pairEditions), tokenId, w.item);
    }

    /// @dev An edition created before any adapter bound it already has its terms: the binding
    ///      neither checks the item again nor locks the terms a second time, and the bound
    ///      adapter may bind again.
    function test_Bind_ACreatedEditionKeepsTheTermsItWasCreatedWith() public {
        (Work memory w, uint256 tokenId) = _soldMaster(0);
        pairEditions.createEdition(tokenId, w.item);
        PackageItem memory other = abi.decode(abi.encode(w.item), (PackageItem));
        other.contentHash = keccak256("not the master");
        bytes32 locked = IFederatedEditions.EditionTermsLocked.selector;
        vm.recordLogs();
        vm.prank(address(fea));
        pairEditions.bindMinter(tokenId, other);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, locked), 0, "terms locked once, at creation");
        assertEq(_count(logs, IFederatedEditions.EditionMinterBound.selector), 1);
        vm.prank(address(fea));
        pairEditions.bindMinter(tokenId, other);
        assertEq(pairEditions.edition(tokenId).minter, address(fea));
    }

    // ------------------------------------------------------------------ creation

    function test_Create_LogsAndKeepsTheMastersMaximum() public {
        (Work memory w, uint256 tokenId) = _soldMaster(5);
        vm.expectEmit(address(pairEditions));
        emit IFederatedEditions.EditionCreated(tokenId, w.item.contentHash, w.item.edition);
        vm.expectEmit(address(pairEditions));
        emit IFederatedToken.MetadataUpdate(tokenId);
        pairEditions.createEdition(tokenId, w.item);
        assertEq(pairEditions.edition(tokenId).maxSupply, 5);
        assertFalse(pairEditions.edition(tokenId).supplySealed);
    }

    // ------------------------------------------------------------------ copies

    function test_Mint_ExactDataTheRunningCountTheTermsAndTheLog() public {
        (Work memory w, uint256 tokenId) = _soldMaster(10);
        pairEditions.createEdition(tokenId, w.item);
        vm.startPrank(address(fea));
        pairEditions.bindMinter(tokenId, w.item);
        vm.expectRevert(IMintTarget.InvalidMintRequest.selector);
        pairEditions.mint(collector, tokenId, 1, abi.encode(address(0), uint256(1), uint256(0)));
        vm.expectEmit(address(pairEditions));
        emit IFederatedEditions.EditionPrimaryMint(tokenId, collector, 2, address(0), 1 ether);
        (uint256 id, PrimaryTerms memory terms) = pairEditions.mint(collector, tokenId, 2, _data());
        assertEq(id, tokenId);
        assertEq(terms.saleKind, SaleKind.UNIFORM_AUCTION);
        pairEditions.mint(collector, tokenId, 3, _data());
        assertEq(pairEditions.edition(tokenId).minted, 5);
        assertEq(pairEditions.balanceOf(collector, tokenId), 5);
        // 5 of 10 minted: 6 more is one too many.
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.EditionUnavailable.selector, tokenId)
        );
        pairEditions.mint(collector, tokenId, 6, _data());
        // A seal below what was minted is refused; at it, accepted.
        vm.expectRevert(
            abi.encodeWithSelector(IFederatedEditions.InvalidSealCount.selector, tokenId, 4)
        );
        pairEditions.sealSupply(tokenId, 4);
        pairEditions.sealSupply(tokenId, 5);
        vm.stopPrank();
        assertEq(pairEditions.edition(tokenId).maxSupply, 5);
    }

    /// @dev Until it seals the edition, the bound adapter mints only while the network admits
    ///      it.
    function test_Mint_AnUnsealedMintNeedsTheAdapterStillAdmitted() public {
        (Work memory w, uint256 tokenId) = _soldMaster(10);
        pairEditions.createEdition(tokenId, w.item);
        vm.prank(address(fea));
        pairEditions.bindMinter(tokenId, w.item);
        _admit(address(fea), false);
        vm.prank(address(fea));
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(fea))
        );
        pairEditions.mint(collector, tokenId, 1, _data());
    }

    // ------------------------------------------------------------------ deployment

    function test_Constructor_RefusesAPartnerWithoutCode() public {
        address eoa = makeAddr("notAStream");
        IFederatedEditions.Config memory c = _editionsConfig(fedArtist, eoa);
        vm.expectRevert(abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa));
        new FederatedEditions(c);
    }
}
