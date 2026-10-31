// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IMintTarget } from "src/interfaces/IMintTarget.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { CURRENCY_ETH, PRODUCT_EDITIONS } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { PrimaryTerms, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { EditionsAdapterMock } from "../mocks/editions/EditionsMocks.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Flow 2 (integration brief, lane B): an edition master and its linked 6529 Stream
///         Editions edition on the real contracts. The master settles; `createEdition` proves the
///         item against the approved root; the edition renders its master's metadata; the
///         edition royalty follows a re-rate of the master; and a sale method added after
///         genesis is admitted by governance and mints the editions of its kind, with no
///         redeployment (owner decision 14). The edition auction's own flows are in its suites.
contract MasterEditionFlowTest is IntegrationBase {
    /// @dev rc.1's fixed-price label, claimed again by a sale method added later.
    bytes32 internal constant FIXED_PRICE = keccak256("FIXED_PRICE");
    uint256 internal constant FIXED_UNIT_PRICE = 10e18;

    address internal artist;
    address internal buyer = makeAddr("editionBuyer");
    address internal collector = makeAddr("masterCollector");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("editionArtist");
        Work[] memory works = new Work[](3);
        works[0] = _master(_work(artist, collectionId), _auctionTerms(50));
        works[1] = _master(_work(artist, collectionId), _auctionTerms(0));
        works[2] = _master(_work(artist, collectionId), _fixedPriceTerms());
        root = _publish(works);
        _keep(root, works);
    }

    /// @dev The uniform-price edition auction in ETH, capped at `maxCount` (zero: no cap).
    function _auctionTerms(uint32 maxCount) internal pure returns (EditionTerms memory) {
        return EditionTerms(maxCount, CURRENCY_ETH, SaleKind.UNIFORM_AUCTION, "");
    }

    /// @dev Terms of a sale method no genesis adapter serves: a fixed price in an ERC-20,
    ///      carried in its params.
    function _fixedPriceTerms() internal view returns (EditionTerms memory) {
        return EditionTerms(25, address(usd), FIXED_PRICE, abi.encode(FIXED_UNIT_PRICE));
    }

    function _master(Work memory w, EditionTerms memory terms) internal pure returns (Work memory) {
        w.item.kind = ItemKind.EDITION_MASTER;
        w.item.edition = terms;
        return w;
    }

    /// @dev Sells master `index` and creates its edition.
    function _masterAndEdition(uint256 index) internal returns (uint256 workId) {
        Work[] memory works = _package(root);
        uint256 saleId;
        (saleId, workId) = _start(root, works, index);
        _ethBid(saleId, collector, 1 ether);
        // Not before the master's sale settles.
        vm.expectRevert(abi.encodeWithSelector(IEditions.NotEditionMaster.selector, workId));
        editions.createEdition(workId, works[index].item, root, _proofOf(works, index));
        _settleAtEnd(saleId);
        assertEq(
            editions.createEdition(workId, works[index].item, root, _proofOf(works, index)), workId
        );
    }

    // ------------------------------------------------------------------ the link

    /// Regression: SIGS-4 (docs/security/internal-review-2026-10.md)
    /// @dev SIGS-4: the guardian revokes the root over another item after a master from it sold.
    ///      Revocation stops unconsumed items only: the sold master still gets its edition
    ///      through the root it was minted from, with no new curation step.
    function test_RevokingTheRootDoesNotStrandASoldMastersEdition() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 workId) = _start(root, works, 0);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        vm.prank(guardian1);
        registry.revokePackage(root, keccak256("another item of the package is disputed"));

        assertEq(editions.createEdition(workId, works[0].item, root, _proofOf(works, 0)), workId);
        assertTrue(editions.exists(workId));
        // The revocation still stops the package's unconsumed masters.
        bytes memory unsold = _mintData(root, works, 1);
        vm.expectRevert(abi.encodeWithSelector(IPackageRegistry.PackageNotApproved.selector, root));
        auction.start(address(stream), unsold);
    }

    /// @dev The root must be one the registry registered: a root revoked before anyone
    ///      registered it, or never seen, proves nothing.
    function test_AnEditionNeedsARegisteredRoot() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 workId) = _start(root, works, 0);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        Work[] memory alone = _one(works[0]);
        bytes32 unregistered = _rootOf(alone);
        bytes memory notMaster = abi.encodeWithSelector(IEditions.NotEditionMaster.selector, workId);
        vm.expectRevert(notMaster);
        editions.createEdition(workId, works[0].item, unregistered, _proofOf(alone, 0));
        vm.prank(guardian1);
        registry.revokePackage(unregistered, keccak256("pre-revoked"));
        vm.expectRevert(notMaster);
        editions.createEdition(workId, works[0].item, unregistered, _proofOf(alone, 0));
    }

    function test_EditionLinksBothWaysToItsMaster() public {
        uint256 workId = _masterAndEdition(0);
        Work memory w = _package(root)[0];
        (address linked, uint256 editionId) = stream.editionOf(workId);
        assertEq(linked, address(editions));
        assertEq(editionId, workId, "edition ID = master token ID");
        (address master, uint256 masterId, bytes32 contentHash) = editions.masterOf(workId);
        assertEq(master, address(stream));
        assertEq(masterId, workId);
        assertEq(contentHash, w.item.contentHash, "the master's own content hash");
        assertEq(registry.editionClaimOf(w.item.contentHash), WorksHashing.itemHash(w.item));
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionExists.selector, workId));
        editions.createEdition(workId, w.item, root, _proofOf(_package(root), 0));
    }

    // ------------------------------------------------------------------ sale methods

    /// @dev Owner decision 14: a sale method added after genesis (here a fixed-price adapter, as
    ///      rc.1's `FixedPriceSale` restored would be) is deployed, then admitted by governance in
    ///      the 30-day SUCCESSOR_SETTER class, and mints the editions whose approved terms name
    ///      its kind, with their own currency and params. Nothing is redeployed, and each edition
    ///      stays bound to the first adapter that minted it.
    function test_ANewSaleMethodIsAdmittedByGovernanceAndMints() public {
        uint256 workId = _masterAndEdition(2);
        EditionsAdapterMock fixedPrice = new EditionsAdapterMock(FIXED_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(IMintTarget.NotAdmittedMinter.selector, address(fixedPrice))
        );
        fixedPrice.buy(editions, workId, buyer, 1);

        bytes memory admit = abi.encodeCall(editions.setAdmittedMinter, (address(fixedPrice), true));
        (bool immediate, uint32 delay) = manager.canCall(hotAdmin, address(editions), bytes4(admit));
        assertFalse(immediate);
        assertEq(delay, 30 days, "the 30-day successor class");
        _govern(hotAdmin, address(editions), admit);
        assertTrue(editions.isAdmittedMinter(address(fixedPrice)));

        PrimaryTerms memory t = editions.primaryTerms(workId, "");
        assertEq(t.saleKind, FIXED_PRICE);
        assertEq(t.currency, address(usd));
        assertEq(abi.decode(t.params, (uint256)), FIXED_UNIT_PRICE, "its params, as approved");
        fixedPrice.buy(editions, workId, buyer, 25);
        assertEq(editions.balanceOf(buyer, workId), 25);
        assertEq(editions.edition(workId).minter, address(fixedPrice));
        vm.expectRevert(abi.encodeWithSelector(IEditions.EditionUnavailable.selector, workId));
        fixedPrice.buy(editions, workId, buyer, 1);

        // It sells only its own kind: an auction edition refuses it.
        uint256 auctionEdition = _masterAndEdition(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMintTarget.SaleKindMismatch.selector, SaleKind.UNIFORM_AUCTION, FIXED_PRICE
            )
        );
        fixedPrice.buy(editions, auctionEdition, buyer, 1);
    }

    // ------------------------------------------------------------------ metadata and royalties

    function test_EditionRendersItsMastersMetadata() public {
        uint256 workId = _masterAndEdition(0);
        string memory uri = editions.uri(workId);
        assertTrue(_contains(uri, '"record_status":"not_open"'), "the master's record is not open");
        assertTrue(_contains(uri, '"trait_type":"Edition of"'));
        Work memory w = _package(root)[0];
        records.openRecord(workId, w.item, w.media);
        uri = editions.uri(workId);
        assertTrue(_contains(uri, '"name":"Work'), "the master's record");
        assertTrue(_contains(uri, '"trait_type":"Edition of","value":'));
        assertEq(editions.licenseOf(workId).spdxId, "CC0-1.0", "the master's license");
    }

    /// @dev WorkRecords' EIP-712 digest of a royalty-rate change, as every party signs it.
    function _rateDigest(uint256 tokenId, uint32 rate, uint64 deadline)
        internal
        view
        returns (bytes32)
    {
        return _typedDigest(
            address(records),
            keccak256(
                abi.encode(
                    Typehashes.ROYALTY_RATE_CHANGE,
                    tokenId,
                    rate,
                    records.workStateHash(tokenId),
                    deadline
                )
            )
        );
    }

    /// @dev Every party agrees and FUNDS_SETTER (14 days) applies a new rate to the master.
    function _rerate(uint256 workId, Work memory w, uint32 rate) internal {
        if (!records.isOpen(workId)) records.openRecord(workId, w.item, w.media);
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(artist, _rateDigest(workId, rate, deadline));
        bytes32 state = records.workStateHash(workId);
        _govern(
            hotAdmin,
            address(records),
            abi.encodeCall(records.setRoyaltyRate, (workId, rate, w.item, state, deadline, sigs))
        );
    }

    function test_EditionRoyaltyFollowsAMasterRerate() public {
        uint256 workId = _masterAndEdition(0);
        (address receiver, uint256 amount) = editions.royaltyInfo(workId, 1 ether);
        assertEq(amount, 0.06529 ether, "6.529% at creation");
        assertEq(receiver, editions.edition(workId).royaltyReceiver);
        _rerate(workId, _package(root)[0], 10_000);
        (, amount) = stream.royaltyInfo(workId, 1 ether);
        assertEq(amount, 0.1 ether, "the master re-rated to 10%");
        (address after_, uint256 editionAmount) = editions.royaltyInfo(workId, 1 ether);
        assertEq(editionAmount, 0.1 ether, "the edition follows");
        assertEq(after_, receiver, "payees never change");
    }

    /// @dev ADR 0003: an edition takes its master's current royalty rate, so a master re-rated
    ///      before its edition is created passes the new rate on (formerly finding E-1).
    function test_EditionTakesTheMastersCurrentRate() public {
        Work[] memory works = _package(root);
        (uint256 saleId, uint256 workId) = _start(root, works, 2);
        _ethBid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        _rerate(workId, works[2], 10_000);
        editions.createEdition(workId, works[2].item, root, _proofOf(works, 2));
        (, uint256 amount) = editions.royaltyInfo(workId, 1 ether);
        assertEq(amount, 0.1 ether, "the master's current rate");
        assertEq(editions.edition(workId).royaltyRate, stream.work(workId).royaltyRate);
    }

    /// @dev Zero-fee terms with no fee recipient (formerly finding L-1, fixed by #35): the
    ///      edition locks no fee, and its royalty receiver is the seller wallet itself.
    function test_ZeroFeeEditionLocksNoFee() public {
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_EDITIONS, 1, address(0), 0))
        );
        uint256 workId = _masterAndEdition(1);
        IEditions.Edition memory e = editions.edition(workId);
        assertEq(e.feeShare, 0);
        assertEq(e.feeRecipient, address(0));
        assertEq(e.royaltyReceiver, e.seller, "no fee payee");
        assertEq(editions.primaryTerms(workId, "").feeShare, 0);
    }
}
