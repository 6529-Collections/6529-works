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
            keccak256("x"), keccak256("y"), 2, IFederationRegistry.Form.ERC721
        );
        (, uint32 delay) =
            manager.canCall(hotAdmin, address(fedRegistry), fedRegistry.approveTemplate.selector);
        assertEq(delay, 30 days);
        bytes memory again = abi.encodeCall(
            fedRegistry.approveTemplate,
            (streamHash, keccak256("y"), 2, IFederationRegistry.Form.ERC721)
        );
        assertFalse(_governTry(hotAdmin, address(fedRegistry), again), "once per code hash");
        FederationRegistry.Template memory t = fedRegistry.templateOf(streamHash);
        assertEq(t.version, 1);
        assertEq(uint8(t.status), uint8(FederationRegistry.TemplateStatus.APPROVED));
    }

    function test_Suspension_IsImmediateAndStopsOnlyNewWorks() public {
        (uint256 running,) = _startFed(_fedWork(fedArtist));
        _ethBid(running, collector, 1 ether);
        (bool immediate,) =
            manager.canCall(guardian1, address(fedRegistry), fedRegistry.suspendTemplate.selector);
        assertTrue(immediate, "GUARDIAN, no delay");
        vm.prank(guardian1);
        vm.expectEmit(address(fedRegistry));
        emit FederationRegistry.TemplateSet(
            streamHash,
            keccak256(type(FederatedStream).creationCode),
            1,
            IFederationRegistry.Form.ERC721,
            FederationRegistry.TemplateStatus.SUSPENDED
        );
        fedRegistry.suspendTemplate(streamHash);
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
        // The directory learns it permissionlessly.
        address[] memory tokens = new address[](1);
        tokens[0] = address(fed);
        vm.expectEmit(address(artists));
        emit IArtistRegistry.FederatedContractStatus(
            address(fed),
            uint160(fedArtist),
            IArtistRegistry.FederationStatus.ACTIVE,
            IArtistRegistry.FederationStatus.DELISTED,
            streamHash
        );
        fedRegistry.propagateRevocation(tokens);
        fedRegistry.propagateRevocation(tokens); // a no-op the second time
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
        assertEq(delay, 48 hours);
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

    // ------------------------------------------------------------------ exit

    function test_Exit_IsOneWayRunningSalesFinishAndOldWorksKeepTheirSplit() public {
        (uint256 saleId, uint256 tokenId) = _startFed(_fedWork(fedArtist));
        _ethBid(saleId, collector, 1 ether);
        vm.expectEmit(address(artists));
        emit IArtistRegistry.FederatedContractStatus(
            address(fed),
            uint160(fedArtist),
            IArtistRegistry.FederationStatus.ACTIVE,
            IArtistRegistry.FederationStatus.LEFT,
            bytes32(0)
        );
        vm.prank(fedArtist);
        fed.leaveFederation();
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedToken.FederationStateInvalid.selector);
        fed.leaveFederation();
        assertFalse(fed.isAdmittedMinter(address(auction)), "no network minting after exit");
        uint256 feeBefore = networkFee.balance;
        _settleAtEnd(saleId);
        assertEq(networkFee.balance - feeBefore, 0.1 ether, "the running sale paid the 10%");
        (address receiver,) = fed.royaltyInfo(tokenId, 1 ether);
        assertTrue(receiver != fed.work(tokenId).seller, "still the 90/10 vault");
        // Delisting can never undo an exit.
        address[] memory tokens = new address[](1);
        tokens[0] = address(fed);
        assertFalse(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(
                    fedRegistry.setStatus, (tokens, IFederationRegistry.Status.ACTIVE, "")
                )
            )
        );
    }

    function test_Exit_TheArtistAdmitsItsOwnMintersAndNewWorksPayNoFee() public {
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedToken.FederationStateInvalid.selector);
        fed.setAdmittedMinter(address(this), true);
        vm.prank(fedArtist);
        fed.leaveFederation();
        vm.prank(fedArtist);
        fed.setAdmittedMinter(address(this), true);
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        (uint256 tokenId,) = fed.mint(address(this), 0, 1, _mintData(w));
        assertEq(fed.ownerOf(tokenId), address(this));
        (address receiver,) = fed.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, fed.work(tokenId).seller, "no network share after exit");
        assertEq(fed.primaryTerms(tokenId, "").feeShare, 0);
    }

    function test_Exit_BeforeJoiningNeedsNoDirectory() public {
        FederatedStream solo = _deployStream(fedArtist);
        vm.prank(fedArtist);
        solo.leaveFederation();
        (bool joined, bool left) = solo.federationState();
        assertFalse(joined);
        assertTrue(left);
        vm.prank(fedArtist);
        vm.expectRevert(IFederatedToken.FederationStateInvalid.selector);
        solo.joinFederation(_noJoin());
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
