// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IWorkPowers, WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { Edition } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModules } from "src/interfaces/core/IModules.sol";
import { PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice A second edition sale contract: creates and mints editions as the network lets it.
contract PortedEditionMinter {
    function create(IEditions editions, uint256 id, uint40 max, address receiver, uint24 rate)
        external
    {
        editions.create(id, max, receiver, rate);
    }

    function mint(IEditions editions, address to, uint256 id, uint256 amount) external {
        editions.mint(to, id, amount, 1 ether);
    }
}

/// @notice An edition master and its 6529 Stream Editions edition on the deployed stack,
///         re-ported from the retired `MasterEdition` suite (and the stack half of the old
///         `WorkPowersStack` edition cases). The edition is created when the uniform edition
///         auction opens during the master's 1/1 auction; the lens proves the master's own item
///         against a package root the registry still approves; the edition renders its master's
///         metadata; the edition's rate follows the master's through the RECORDS and TERMS
///         modules, and a renounced rate fixes both; a sale contract the network adds later
///         creates and mints its own editions only.
contract MasterEditionPortedTest is IntegrationBase {
    address internal artist;
    address internal collector = makeAddr("masterCollector");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("editionArtist");
        Work[] memory works = new Work[](2);
        works[0] = _asMaster(_work(artist, collectionId), 50);
        works[1] = _asMaster(_work(artist, collectionId), 25);
        root = _publish(works);
        _keep(root, works);
    }

    function _openData(uint256 index) internal view returns (bytes memory) {
        Work[] memory works = _package(root);
        return abi.encode(works[index].item, root, _proofOf(works, index));
    }

    /// @dev Starts master `index`'s 1/1 auction; returns its sale and token IDs.
    function _startMaster(uint256 index) internal returns (uint256 saleId, uint256 tokenId) {
        (saleId, tokenId) = _start(root, _package(root), index);
    }

    function _openEdition(uint256 tokenId, uint256 index) internal returns (uint256 saleId) {
        saleId = editionAuction.open(address(editions), tokenId, _openData(index));
    }

    function _rateDigest(uint256 tokenId, uint24 rate, bytes32 state, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        return _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.ROYALTY_RATE_TYPEHASH(), address(stream), tokenId, rate, state, deadline
                )
            )
        );
    }

    /// @dev The artist's consent and the network's scheduled call (FUNDS_SETTER, 3 days)
    ///      re-rating the master; the record must be open.
    function _rerateCall(uint256 tokenId, uint256 index, uint24 rate)
        internal
        view
        returns (bytes memory)
    {
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] =
            abi.encodePacked(artist, _sign(artist, _rateDigest(tokenId, rate, state, deadline)));
        return abi.encodeCall(
            rules.setRoyaltyRate,
            (address(stream), tokenId, rate, _package(root)[index].item, state, deadline, sigs)
        );
    }

    // ------------------------------------------------------------------ the link

    /// @dev The edition opens during the 1/1 sale; its ID is the master's token ID, the edition
    ///      auction is its only minter, its rate is the master's and its receiver the vault the
    ///      lens deployed; a second open is refused.
    function test_TheEditionOpensDuringTheOneOfOneAndLinksToItsMaster() public {
        (, uint256 tokenId) = _startMaster(0);
        uint256 saleId = _openEdition(tokenId, 0);
        assertEq(
            saleId,
            IUniformEditionAuction(address(editionAuction)).saleIdOf(address(editions), tokenId)
        );
        Edition memory e = editions.editionOf(tokenId);
        assertEq(e.minter, address(editionAuction), "the edition auction is its minter");
        assertEq(e.maxSupply, 50, "the approved cap");
        assertEq(e.royaltyRate, stream.workOf(tokenId).royaltyRate, "the master's rate");
        assertGt(e.royaltyReceiver.code.length, 0, "the royalty vault is deployed at open");
        assertEq(editions.stream(), address(stream));
        assertEq(terms.editionsOf(address(stream)), address(editions), "paired for the rate");
        vm.expectRevert(
            abi.encodeWithSelector(IUniformEditionAuction.AuctionExists.selector, saleId)
        );
        _openEdition(tokenId, 0);
    }

    /// @dev No master token, no edition: the 1/1 has not started.
    function test_NoEditionBeforeItsMasterIsMinted() public {
        uint256 next = stream.totalMinted() + 1;
        vm.expectRevert();
        _openEdition(next, 0);
        assertEq(editions.editionOf(next).minter, address(0));
    }

    /// @dev The master's stored item hash decides: another item of the same package is refused,
    ///      the master's own item is accepted.
    function test_AnEditionNeedsOnlyTheMastersStoredItem() public {
        (, uint256 tokenId) = _startMaster(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), tokenId
            )
        );
        _openEdition(tokenId, 1);
        _openEdition(tokenId, 0);
    }

    /// @dev The retired rule let a sold master's edition through a revoked root. Now the lens
    ///      requires the item's package to be still approved (`isApprovedItem`): a revocation
    ///      stops a master's edition that has not opened, and the package's unminted masters;
    ///      an edition already open is untouched.
    function test_ARevokedPackageStopsAnEditionNotYetOpened() public {
        (, uint256 first) = _startMaster(0);
        uint256 openSale = _openEdition(first, 0);
        (, uint256 second) = _startMaster(1);
        _asNetwork(
            address(registry),
            abi.encodeCall(registry.revokePackage, (root, keccak256("another item is disputed")))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                ISaleAdapter.InvalidSaleTerms.selector, address(editions), second
            )
        );
        _openEdition(second, 1);
        assertEq(editions.editionOf(second).minter, address(0));
        assertEq(
            uint8(IUniformEditionAuction(address(editionAuction)).auction(openSale).status),
            uint8(IUniformEditionAuction.AuctionStatus.OPEN),
            "the open edition keeps its sale"
        );
        // A fresh master from the revoked package cannot start either.
        Work memory w = _asMaster(_work(artist, collectionId), 5);
        Work[] memory more = _one(w);
        bytes32 other = _publish(more);
        _asNetwork(address(registry), abi.encodeCall(registry.revokePackage, (other, bytes32("x"))));
        bytes memory data = _mintData(other, more, 0);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, other));
        auction.start(address(stream), data);
    }

    // ------------------------------------------------------------------ metadata and royalties

    function test_TheEditionRendersItsMastersMetadata() public {
        (, uint256 tokenId) = _startMaster(0);
        _openEdition(tokenId, 0);
        string memory uri = editions.uri(tokenId);
        assertTrue(_contains(uri, '"record_status":"not_open"'), "the master's record is not open");
        _open(tokenId, _package(root)[0]);
        uri = editions.uri(tokenId);
        assertTrue(_contains(uri, '"name":"Work'), "the master's record");
        assertTrue(_contains(uri, '"trait_type":"Edition of"'), "marked as an edition");
        assertTrue(_contains(uri, "CC0-1.0"), "the master's license");
    }

    /// @dev Every party consents and the network re-rates the master (FUNDS_SETTER): the
    ///      edition follows through the TERMS module; neither receiver changes.
    function test_TheEditionsRateFollowsAMasterRerate() public {
        (, uint256 tokenId) = _startMaster(0);
        _openEdition(tokenId, 0);
        _open(tokenId, _package(root)[0]);
        (address editionReceiver,) = editions.royaltyInfo(tokenId, 1 ether);
        (address masterReceiver,) = stream.royaltyInfo(tokenId, 1 ether);
        _asNetwork(address(rules), _rerateCall(tokenId, 0, 5_000));
        (address m, uint256 masterAmount) = stream.royaltyInfo(tokenId, 1 ether);
        (address e, uint256 editionAmount) = editions.royaltyInfo(tokenId, 1 ether);
        assertEq(masterAmount, 0.05 ether, "the master re-rated to 5%");
        assertEq(editionAmount, 0.05 ether, "the edition follows");
        assertEq(m, masterReceiver);
        assertEq(e, editionReceiver, "payees never change");
    }

    /// @dev The edition takes the master's rate as it is when the edition opens: a master
    ///      re-rated during its 1/1 sale (paused for a dispute, so the 3-day call lands while
    ///      the edition can still open) passes the new rate on.
    function test_TheEditionTakesTheMastersCurrentRate() public {
        (uint256 saleId, uint256 tokenId) = _startMaster(1);
        _open(tokenId, _package(root)[1]);
        bytes memory rerate = _rerateCall(tokenId, 1, 4_000);
        vm.prank(network);
        manager.schedule(address(rules), rerate, 0);
        vm.prank(pauser1);
        auction.pause(saleId, keccak256("dispute"));
        vm.warp(block.timestamp + 3 days);
        vm.prank(network);
        manager.execute(address(rules), rerate);
        _openEdition(tokenId, 1);
        assertEq(editions.editionOf(tokenId).royaltyRate, 4_000, "the master's current rate");
        assertEq(stream.workOf(tokenId).royaltyRate, 4_000);
    }

    /// @dev Renouncing the royalty power on the master (artist signature and the network's
    ///      24-hour role) fixes the rate of both: a later re-rate is refused, the edition's rate
    ///      unchanged.
    function test_RenouncingTheRateOnTheMasterFixesItsEdition() public {
        (, uint256 tokenId) = _startMaster(0);
        _openEdition(tokenId, 0);
        _open(tokenId, _package(root)[0]);
        uint24 rate = editions.editionOf(tokenId).royaltyRate;
        bytes32 state = rules.workStateHash(address(stream), tokenId);
        uint64 deadline = uint64(block.timestamp + 7 days);
        bytes32 digest = _typedDigest(
            address(rules),
            keccak256(
                abi.encode(
                    rules.RENOUNCE_POWERS_TYPEHASH(),
                    address(stream),
                    tokenId,
                    WorkPowers.ROYALTY_RATE,
                    state,
                    deadline
                )
            )
        );
        _asNetwork(
            address(rules),
            abi.encodeCall(
                rules.renounce,
                (
                    address(stream),
                    tokenId,
                    WorkPowers.ROYALTY_RATE,
                    state,
                    deadline,
                    abi.encodePacked(artist, _sign(artist, digest))
                )
            )
        );
        assertTrue(stream.workOf(tokenId).royaltyRateLocked);
        bytes memory rerate = _rerateCall(tokenId, 0, 1_000);
        vm.prank(network);
        manager.schedule(address(rules), rerate, 0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(network);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWorkPowers.PowerRenounced.selector,
                address(stream),
                tokenId,
                WorkPowers.ROYALTY_RATE
            )
        );
        manager.execute(address(rules), rerate);
        assertEq(editions.editionOf(tokenId).royaltyRate, rate, "the edition keeps its rate");
    }

    /// @dev Zero-fee edition terms (FUNDS_SETTER): the edition's sale locks no fee and its
    ///      royalty receiver is the seller's vault itself.
    function test_AZeroFeeEditionLocksNoFee() public {
        (uint64 feeRevision,,) = economics.revisions(PRODUCT_EDITIONS);
        _asNetwork(
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_EDITIONS, feeRevision, networkFee, 0))
        );
        (, uint256 tokenId) = _startMaster(0);
        _openEdition(tokenId, 0);
        address seller = ledger.walletFor(_package(root)[0].item.payees, bytes32(0));
        assertEq(editions.editionOf(tokenId).royaltyReceiver, seller, "no fee payee");
        assertGt(seller.code.length, 0, "the seller's vault is deployed at open");
        assertEq(
            economics.newWorkTerms(PRODUCT_EDITIONS, _package(root)[0].item.payees).feeShare, 0
        );
    }

    // ------------------------------------------------------------------ sale methods

    /// @dev A sale contract added after genesis is the network's call (NETWORK, at once) and
    ///      active after the module delay; it creates and mints its own editions, and never an
    ///      edition the edition auction holds.
    function test_ASaleContractAddedLaterMintsOnlyItsOwnEditions() public {
        (, uint256 auctioned) = _startMaster(0);
        _openEdition(auctioned, 0);
        (, uint256 other) = _startMaster(1);
        PortedEditionMinter later = new PortedEditionMinter();
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(later)));
        later.create(editions, other, 10, address(0), 0);

        _asNetwork(address(editions), abi.encodeCall(IModules.addMinter, (address(later))));
        vm.expectRevert(abi.encodeWithSelector(IModules.NotMinter.selector, address(later)));
        later.create(editions, other, 10, address(0), 0);
        vm.warp(block.timestamp + editions.moduleDelay());
        assertTrue(editions.isMinter(address(later)));

        later.create(editions, other, 10, address(0), 0);
        later.mint(editions, collector, other, 10);
        assertEq(editions.balanceOf(collector, other), 10);
        vm.expectRevert(abi.encodeWithSelector(IEditions.SupplyExceeded.selector, other));
        later.mint(editions, collector, other, 1);

        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, auctioned));
        later.create(editions, auctioned, 10, address(0), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IEditions.NotEditionMinter.selector, auctioned, address(later))
        );
        later.mint(editions, collector, auctioned, 1);
    }
}
