// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { FederationBase } from "./FederationBase.sol";

/// @notice The federation registry's governed paths and their exact effects: template approval,
///         suspension (immediate, new works only), revocation (running sales end unsold),
///         adapter admission, delisting by vote and relisting, propagation, a replacement
///         registry inheriting every listing, and the artist's one-way exit.
contract FederationGovernanceTest is FederationBase {
    address internal collector = makeAddr("collector");

    function setUp() public override {
        super.setUp();
        _joinedFed();
    }

    // ------------------------------------------------------------------ templates

    function test_Templates_ApprovedOnceAndOnlyByGovernance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        vm.prank(collector);
        fedRegistry.approveTemplate(
            keccak256("x"),
            address(deployment.federatedStreamDeployer),
            2,
            IFederationRegistry.Form.ERC721
        );
        (, uint32 delay) =
            manager.canCall(hotAdmin, address(fedRegistry), fedRegistry.approveTemplate.selector);
        assertEq(delay, 24 hours, "template approval: the network at 24 hours");
        bytes memory again = abi.encodeCall(
            fedRegistry.approveTemplate,
            (
                streamHash,
                address(deployment.federatedStreamDeployer),
                2,
                IFederationRegistry.Form.ERC721
            )
        );
        assertFalse(_governTry(hotAdmin, address(fedRegistry), again), "once per code hash");
        FederationRegistry.Template memory t = fedRegistry.templateOf(streamHash);
        assertEq(t.version, 1);
        assertEq(t.deployer, address(deployment.federatedStreamDeployer));
        assertEq(uint8(t.status), uint8(FederationRegistry.TemplateStatus.APPROVED));
    }

    /// @dev Suspension is the network's at 24 hours (PLAN-2 B2) and stops only new works.
    function test_Suspension_IsTheNetworksAndStopsOnlyNewWorks() public {
        (uint256 running,) = _startFed(_fedWork(fedArtist));
        _ethBid(running, collector, 1 ether);
        (, uint32 delay) =
            manager.canCall(hotAdmin, address(fedRegistry), fedRegistry.suspendTemplate.selector);
        assertEq(delay, 24 hours, "the network, 24 hours");
        bytes memory suspend = abi.encodeCall(fedRegistry.suspendTemplate, (streamHash));
        vm.prank(hotAdmin);
        manager.schedule(address(fedRegistry), suspend, 0);
        vm.warp(block.timestamp + delay);
        vm.expectEmit(address(fedRegistry));
        emit FederationRegistry.TemplateSet(
            streamHash,
            address(deployment.federatedStreamDeployer),
            keccak256(type(FederatedStream).creationCode),
            1,
            IFederationRegistry.Form.ERC721,
            FederationRegistry.TemplateStatus.SUSPENDED
        );
        vm.prank(hotAdmin);
        manager.execute(address(fedRegistry), suspend);
        assertFalse(fedRegistry.canMint(address(fed), address(auction)));
        assertTrue(fedRegistry.isActive(address(fed)), "running sales still served");
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(auction))
        );
        auction.start(address(fed), _mintData(w));
        _settleAtEnd(running);
        assertEq(fed.ownerOf(1), collector, "the running sale finished");
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.resumeTemplate, (streamHash))
        );
        auction.start(address(fed), _mintData(w));
    }

    function test_Revocation_EndsRunningSalesUnsoldAndTheWorkStaysHome() public {
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.revokeTemplate, (streamHash))
        );
        assertFalse(fedRegistry.isActive(address(fed)));
        assertFalse(auction.isTarget(address(fed)));
        _settleAtEnd(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether, "refunded");
        assertEq(fed.ownerOf(tokenId), address(fed), "never confiscated, never to a person");
        (PrimaryOutcome outcome,,) = fed.primarySale(tokenId);
        assertEq(uint8(outcome), uint8(PrimaryOutcome.FROZEN_OUT));
        // The revocation acts through the registry's reads; the directory is not written.
        (, IArtistRegistry.FederationStatus status) = artists.federatedListing(address(fed));
        assertEq(uint8(status), uint8(IArtistRegistry.FederationStatus.ACTIVE));
    }

    // ------------------------------------------------------------------ delisting

    function test_Delisting_ByVoteStopsSalesAndRelistingRestores() public {
        Work memory w = _fedWork(fedArtist);
        (uint256 saleId, uint256 tokenId) = _startFed(w);
        _ethBid(saleId, collector, 1 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(fed);
        (, uint32 delay) =
            manager.canCall(hotAdmin, address(fedRegistry), fedRegistry.setStatus.selector);
        assertEq(delay, 24 hours);
        bytes32 vote = keccak256("vote 7");
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(
                fedRegistry.setStatus, (tokens, IFederationRegistry.Status.DELISTED, vote)
            )
        );
        assertEq(
            uint8(fedRegistry.entry(address(fed)).status),
            uint8(IFederationRegistry.Status.DELISTED)
        );
        (, IArtistRegistry.FederationStatus listed) = artists.federatedListing(address(fed));
        assertEq(
            uint8(listed), uint8(IArtistRegistry.FederationStatus.DELISTED), "in the directory"
        );
        assertFalse(auction.isTarget(address(fed)), "no new starts or bids");
        Work memory other = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(other), RATE);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.TargetNotAllowed.selector, address(fed))
        );
        auction.start(address(fed), _mintData(other));
        _settleAtEnd(saleId);
        assertEq(auction.claimable(collector, CURRENCY_ETH), 1 ether);
        assertEq(fed.ownerOf(tokenId), address(fed));
        // Delisting touches nothing the artist or a collector owns.
        (address royaltyVault,) = fed.royaltyInfo(tokenId, 1 ether);
        assertGt(royaltyVault.code.length, 0);
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setStatus, (tokens, IFederationRegistry.Status.ACTIVE, vote))
        );
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        uint256 again = auction.start(address(fed), _mintData(w));
        _ethBid(again, collector, 1 ether);
        _settleAtEnd(again);
        assertEq(fed.ownerOf(tokenId + 1), collector);
    }

    // ------------------------------------------------------------------ adapters

    function test_Adapters_RemovalStopsNewWorksButTheAdapterStillSettles() public {
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(auction), false))
        );
        assertFalse(fed.isAdmittedMinter(address(auction)));
        _settleAtEnd(saleId);
        assertEq(fed.ownerOf(tokenId), collector);
    }

    function test_Adapters_MustBeSaleAdapters() public {
        assertFalse(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.setAdapter, (collector, true))
            )
        );
    }

    // ------------------------------------------------------------------ replacement

    function test_Replacement_InheritsEveryListingWithNothingToMigrate() public {
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _mapRegistryRoles(address(next));
        _approveTemplates(next);
        _govern(hotAdmin, address(next), abi.encodeCall(next.setAdapter, (address(auction), true)));
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        _govern(
            hotAdmin,
            address(auction),
            abi.encodeCall(auction.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        IFederationRegistry.Entry memory e = next.entry(address(fed));
        assertEq(e.artistId, uint160(fedArtist));
        assertEq(e.feeShare, FED_SHARE);
        assertEq(e.codeHash, streamHash);
        uint256 feeBefore = networkFee.balance;
        auction.settle(saleId);
        assertEq(fed.ownerOf(tokenId), collector);
        assertEq(networkFee.balance - feeBefore, 0.1 ether, "the fee locked at start");
        (uint256 again,) = _startFed(_fedWork(fedArtist));
        assertEq(uint8(auction.auction(again).state), uint8(IEnglishAuction.AuctionState.ACTIVE));
    }

    function _payment(address payer, uint256 amount) internal pure returns (Payment memory) {
        return Payment(PaymentMethod.DIRECT, payer, amount, 0, 0, "");
    }

    /// @dev The test contract as a minter the artist admits after the exit.
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}
