// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Dependency } from "src/libraries/Dependency.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { ArtistRegistry } from "src/identity/ArtistRegistry.sol";
import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { CURRENCY_ETH } from "src/interfaces/types/EconomicsTypes.sol";
import { Payment, PaymentMethod, PrimaryOutcome } from "src/interfaces/types/SaleTypes.sol";
import { NonDeliveringAdapter } from "../mocks/federated/FederatedMocks.sol";
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

    /// @dev An admitted adapter whose `claimDelivery` returns without delivering (this test
    ///      contract) cannot leave the token reclaimed: `reclaim` reverts unless it came home.
    function test_Reclaim_RefusesAnAdapterThatReturnsWithoutDelivering() public {
        NonDeliveringAdapter adapter = new NonDeliveringAdapter();
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(adapter), true))
        );
        Work memory w = _fedWork(fedArtist);
        vm.prank(fedArtist);
        fed.approveItem(_itemHash(w), RATE);
        uint256 tokenId = adapter.mint(fed, _mintData(w));
        vm.expectRevert(abi.encodeWithSelector(IFederatedStream.WorkNotRestartable.selector, 1));
        fed.reclaim(tokenId);
        assertEq(fed.ownerOf(tokenId), address(adapter));
    }

    /// @dev Only the network sets listings: a stranger's delisting is refused.
    function test_SetStatus_IsRestricted() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(fed);
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, collector)
        );
        fedRegistry.setStatus(tokens, IFederationRegistry.Status.DELISTED, "no vote");
        assertTrue(fedRegistry.isActive(address(fed)));
    }

    function test_Constructor_ChecksItsDependencies() public {
        address eoa = makeAddr("noCode");
        bytes memory bad = abi.encodeWithSelector(Dependency.InvalidDependency.selector, eoa);
        vm.expectRevert(bad);
        new FederationRegistry(address(manager), eoa, address(economics), address(store));
        vm.expectRevert(bad);
        new FederationRegistry(address(manager), address(artists), eoa, address(store));
        vm.expectRevert(bad);
        new FederationRegistry(address(manager), address(artists), address(economics), eoa);
    }

    /// @dev Template approval checks its deployer; approval, revocation, adapter changes and
    ///      registrations are each logged.
    function test_Templates_DeployerCheckedAndEveryChangeLogged() public {
        address deployer = address(deployment.federatedStreamDeployer);
        IFederationRegistry.Form one = IFederationRegistry.Form.ERC721;
        assertFalse(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.approveTemplate, (keccak256("t"), collector, 3, one))
            ),
            "a deployer without code"
        );
        // An EIP-7702 account delegated to the real deployer answers like it, and is refused.
        address delegated = makeAddr("delegatedDeployer");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", deployer));
        assertFalse(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.approveTemplate, (keccak256("t"), delegated, 3, one))
            ),
            "a delegated account"
        );
        bytes32 topic = FederationRegistry.TemplateSet.selector;
        vm.recordLogs();
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.approveTemplate, (keccak256("t"), deployer, 3, one))
        );
        assertEq(_count(vm.getRecordedLogs(), topic), 1, "approval logged");
        vm.recordLogs();
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.revokeTemplate, (keccak256("t")))
        );
        assertEq(_count(vm.getRecordedLogs(), topic), 1, "revocation logged");
        vm.recordLogs();
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (collector, false))
        );
        assertEq(_count(vm.getRecordedLogs(), FederationRegistry.AdapterSet.selector), 1);
        FederatedStream another = _deployStream(fedArtist);
        vm.recordLogs();
        _join(address(another), fedArtist);
        assertEq(_count(vm.getRecordedLogs(), IFederationRegistry.Registered.selector), 1);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    /// @dev A template is one form (never the pair) under a nonzero code hash.
    function test_Templates_RefuseThePairFormAndAZeroCodeHash() public {
        address deployer = address(deployment.federatedStreamDeployer);
        IFederationRegistry.Form pair = IFederationRegistry.Form.PAIR;
        IFederationRegistry.Form one = IFederationRegistry.Form.ERC721;
        assertFalse(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.approveTemplate, (keccak256("pair"), deployer, 3, pair))
            ),
            "the pair form"
        );
        assertFalse(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.approveTemplate, (bytes32(0), deployer, 3, one))
            ),
            "a zero code hash"
        );
        assertTrue(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.approveTemplate, (keccak256("fresh"), deployer, 3, one))
            )
        );
    }

    /// @dev Removing an adapter checks nothing about it: even an account that is no adapter.
    function test_Adapters_RemovalChecksNothing() public {
        assertTrue(
            _governTry(
                hotAdmin,
                address(fedRegistry),
                abi.encodeCall(fedRegistry.setAdapter, (collector, false))
            )
        );
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

    /// @dev Once replaced, the old registry answers every read as the current one does: here
    ///      the version the replacement approved, not its own.
    function test_Replacement_TheOldRegistryForwardsItsReads() public {
        FederationRegistry next = new FederationRegistry(
            address(manager), address(artists), address(economics), address(store)
        );
        _mapRegistryRoles(address(next));
        _approveTemplate(
            next, type(FederatedStream).creationCode, streamHash, 7, IFederationRegistry.Form.ERC721
        );
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.setFederationRegistry, (address(fedRegistry), address(next)))
        );
        assertEq(next.entry(address(fed)).templateVersion, 7);
        assertEq(fedRegistry.entry(address(fed)).templateVersion, 7, "forwarded");
    }

    /// @dev A registry the artist registry does not name yet answers for itself (an unlisted
    ///      token reads empty) rather than forwarding to nobody.
    function test_Registry_AnswersItselfBeforeItIsBound() public {
        ArtistRegistry fresh = new ArtistRegistry(
            address(manager),
            IConsolidationSource(address(consolidation)),
            address(consolidation).codehash
        );
        FederationRegistry unbound = new FederationRegistry(
            address(manager), address(fresh), address(economics), address(store)
        );
        IFederationRegistry.Entry memory e = unbound.entry(address(fed));
        assertEq(uint8(e.status), uint8(IFederationRegistry.Status.NONE));
        assertEq(e.artistId, 0);
    }

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

    function test_Revocation_OnlyAnApprovedOrSuspendedTemplate() public {
        bytes32 unknown = keccak256("never approved");
        _governExpectRevert(
            address(fedRegistry),
            abi.encodeCall(fedRegistry.revokeTemplate, (unknown)),
            abi.encodeWithSelector(
                FederationRegistry.TemplateStatusInvalid.selector,
                unknown,
                FederationRegistry.TemplateStatus.NONE
            )
        );
        _govern(
            hotAdmin, address(fedRegistry), abi.encodeCall(fedRegistry.revokeTemplate, (streamHash))
        );
        _governExpectRevert(
            address(fedRegistry),
            abi.encodeCall(fedRegistry.revokeTemplate, (streamHash)),
            abi.encodeWithSelector(
                FederationRegistry.TemplateStatusInvalid.selector,
                streamHash,
                FederationRegistry.TemplateStatus.REVOKED
            )
        );
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
