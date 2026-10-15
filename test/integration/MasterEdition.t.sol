// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEditions } from "src/interfaces/IEditions.sol";
import { IFixedPriceSale } from "src/interfaces/IFixedPriceSale.sol";
import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { ISignatureTransfer } from "src/interfaces/external/ISignatureTransfer.sol";
import { CURRENCY_ETH, PRODUCT_EDITIONS, WorkTerms } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionFormat, EditionTerms, ItemKind } from "src/interfaces/types/PackageTypes.sol";
import { DutchParams, Payment, PaymentMethod, SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "./IntegrationBase.sol";
import { IMintSale } from "src/interfaces/IMintSale.sol";

/// @notice Flow 2 (integration brief, lane B): an edition master and its linked 6529 Editions
///         edition on the real contracts. The master settles; `createEdition` proves the item
///         against the approved root; a fixed-price sale runs allowlist phases with the artist's
///         signed consent and a relayed Permit2 payment; a Dutch sale charges the current price;
///         the edition renders its master's metadata; and the edition royalty follows a re-rate
///         of the master.
contract MasterEditionFlowTest is IntegrationBase {
    uint256 internal constant FIXED_PRICE = 10e18;
    uint256 internal constant LEAF_PRICE = 8e18;
    uint256 internal constant DUTCH_START = 0.1 ether;
    uint256 internal constant DUTCH_REST = 0.01 ether;

    address internal artist;
    address internal buyer1;
    address internal buyer2 = makeAddr("editionBuyer2");
    address internal relayer = makeAddr("relayer");
    address internal collector = makeAddr("masterCollector");
    bytes32 internal root;

    function setUp() public override {
        super.setUp();
        artist = _actor("editionArtist");
        buyer1 = _actor("editionBuyer1");
        // The ERC-20 the fixed-price edition is priced in: a 14-day FUNDS_SETTER admission.
        _govern(
            hotAdmin,
            address(allowlist),
            abi.encodeCall(allowlist.admitAsset, (address(usd), 0, 1e16))
        );
        assertTrue(allowlist.isActive(address(usd)));

        Work[] memory works = new Work[](3);
        works[0] = _master(_work(artist, collectionId), _fixedTerms());
        works[1] = _master(_work(artist, collectionId), _dutchTerms());
        works[2] = _master(_work(artist, collectionId), _fixedTerms());
        root = _publish(works);
        _keep(root, works);
    }

    function _fixedTerms() internal view returns (EditionTerms memory) {
        return EditionTerms(
            EditionFormat.FIXED, 50, 0, FIXED_PRICE, address(usd), SaleKind.FIXED_PRICE, ""
        );
    }

    function _dutchTerms() internal pure returns (EditionTerms memory) {
        return EditionTerms(
            EditionFormat.FIXED,
            20,
            0,
            DUTCH_START,
            CURRENCY_ETH,
            SaleKind.DUTCH,
            abi.encode(DutchParams(DUTCH_REST, 1 hours, 0))
        );
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

    // ------------------------------------------------------------------ fixed price

    function _phases()
        internal
        view
        returns (IFixedPriceSale.Phase[] memory phases, bytes32[] memory leaves)
    {
        leaves = new bytes32[](2);
        phases = new IFixedPriceSale.Phase[](2);
        uint64 nowTs = uint64(block.timestamp);
        phases[0] = IFixedPriceSale.Phase(nowTs, nowTs + 1 days, bytes32(0), 0, false, true);
        phases[1] =
            IFixedPriceSale.Phase(nowTs + 1 days, nowTs + 2 days, bytes32(0), 5, false, false);
        return (phases, leaves);
    }

    function _consent(uint256 workId, IFixedPriceSale.Phase[] memory phases)
        internal
        view
        returns (IFixedPriceSale.ArtistConsent memory consent)
    {
        consent.deadline = uint64(block.timestamp + 1 days);
        bytes32 digest = fixedSale.phaseConfigurationDigest(
            address(editions), workId, address(usd), FIXED_PRICE, phases, 0, consent.deadline
        );
        consent.signature = _sign(artist, digest);
    }

    function _permit2Purchase(IFixedPriceSale.Purchase memory p, uint256 total, uint256 nonce)
        internal
        view
        returns (Payment memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 witness = keccak256(
            abi.encode(
                Typehashes.PURCHASE_WITNESS,
                p.saleId,
                p.phase,
                p.recipient,
                p.quantity,
                total,
                deadline
            )
        );
        bytes32 digest = permit2.witnessDigest(
            address(fixedSale),
            ISignatureTransfer.PermitTransferFrom(
                ISignatureTransfer.TokenPermissions(address(usd), total), nonce, deadline
            ),
            witness,
            Typehashes.PURCHASE_WITNESS_TYPE
        );
        return Payment(PaymentMethod.PERMIT2, buyer1, total, deadline, nonce, _sign(buyer1, digest));
    }

    function test_FixedPriceAllowlistConsentAndPermit2() public {
        uint256 workId = _masterAndEdition(0);
        (IFixedPriceSale.Phase[] memory phases, bytes32[] memory leaves) = _phases();
        leaves[0] = fixedSale.allowlistLeaf(address(editions), workId, 0, buyer1, 2, LEAF_PRICE);
        leaves[1] = fixedSale.allowlistLeaf(address(editions), workId, 0, buyer2, 1, LEAF_PRICE);
        phases[0].root = _root(leaves);

        // An outsider cannot open the sale; the PLATFORM role can, through the manual check,
        // and the artist's signed consent allows leaf prices below the package price.
        IFixedPriceSale.ArtistConsent memory consent = _consent(workId, phases);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, relayer));
        fixedSale.openSale(address(editions), workId, phases, consent);
        vm.prank(platform);
        uint256 saleId = fixedSale.openSale(address(editions), workId, phases, consent);
        (, bool approved,) = fixedSale.sale(saleId);
        assertTrue(approved, "artist-approved phases");

        // Phase 0: buyer 1's allowlist leaf, paid by Permit2 and relayed by someone else.
        usd.mint(buyer1, 100e18);
        vm.prank(buyer1);
        usd.approve(PERMIT2, type(uint256).max);
        IFixedPriceSale.Purchase memory p =
            IFixedPriceSale.Purchase(saleId, 0, buyer1, 2, 2, LEAF_PRICE);
        Payment memory pay = _permit2Purchase(p, 2 * LEAF_PRICE, 1);
        vm.prank(relayer);
        fixedSale.purchase(p, _proof(leaves, 0), pay);
        assertEq(editions.balanceOf(buyer1, workId), 2);
        WorkTerms memory terms =
            economics.newWorkTerms(PRODUCT_EDITIONS, _package(root)[0].item.payees);
        assertEq(usd.balanceOf(terms.seller), 12e18, "75% to the edition seller wallet");
        assertEq(usd.balanceOf(networkFee), 4e18, "25% to the network");

        // The leaf is checked against the wallet that receives the token (#744's High finding).
        p = IFixedPriceSale.Purchase(saleId, 0, relayer, 1, 2, LEAF_PRICE);
        pay = _permit2Purchase(p, LEAF_PRICE, 2);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.NotAllowlisted.selector, saleId, 0, relayer)
        );
        fixedSale.purchase(p, _proof(leaves, 0), pay);
        // The leaf cap persists.
        p = IFixedPriceSale.Purchase(saleId, 0, buyer1, 1, 2, LEAF_PRICE);
        pay = _permit2Purchase(p, LEAF_PRICE, 3);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IFixedPriceSale.WalletCapExceeded.selector, saleId, 0, buyer1)
        );
        fixedSale.purchase(p, _proof(leaves, 0), pay);

        // Phase 1: public, at the package price, paid directly.
        vm.warp(block.timestamp + 1 days);
        usd.mint(buyer2, FIXED_PRICE);
        vm.startPrank(buyer2);
        usd.approve(address(fixedSale), FIXED_PRICE);
        fixedSale.purchase(
            IFixedPriceSale.Purchase(saleId, 1, address(0), 1, 0, 0),
            new bytes32[](0),
            Payment(PaymentMethod.DIRECT, buyer2, FIXED_PRICE, 0, 0, "")
        );
        vm.stopPrank();
        assertEq(editions.balanceOf(buyer2, workId), 1);

        // Anyone closes a sale whose phases have all ended.
        vm.warp(block.timestamp + 1 days);
        vm.prank(relayer);
        fixedSale.closeSale(saleId);
        (,, bool closed) = fixedSale.sale(saleId);
        assertTrue(closed);
    }

    // ------------------------------------------------------------------ Dutch

    function test_DutchSaleChargesTheCurrentPrice() public {
        uint256 workId = _masterAndEdition(1);
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), workId, uint64(block.timestamp));
        vm.warp(block.timestamp + 30 minutes);
        uint256 price = dutchSale.currentPrice(saleId);
        assertEq(price, DUTCH_START - (DUTCH_START - DUTCH_REST) / 2, "linear descent");
        vm.deal(buyer2, 1 ether);
        vm.prank(buyer2);
        dutchSale.purchase{ value: 0.06 ether }(
            saleId,
            address(0),
            1,
            0.06 ether,
            Payment(PaymentMethod.DIRECT, buyer2, 0.06 ether, 0, 0, "")
        );
        assertEq(editions.balanceOf(buyer2, workId), 1);
        assertEq(
            dutchSale.claimable(buyer2, CURRENCY_ETH), 0.06 ether - price, "overpayment credited"
        );
        vm.warp(block.timestamp + 2 hours);
        assertEq(dutchSale.currentPrice(saleId), DUTCH_REST, "rests");
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(IMintSale.NotSaleManager.selector, platform));
        dutchSale.closeSale(saleId);
        vm.prank(artist);
        dutchSale.closeSale(saleId);
        (,, bool closed) = dutchSale.sale(saleId);
        assertTrue(closed, "the artist closes the sale it opened; PLATFORM cannot (MARKET-6)");
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

    /// @dev Zero-fee terms with no fee recipient (formerly finding L-1, fixed by #35): an
    ///      edition sale opens and settles, the artist side takes the whole price, and the
    ///      edition's royalty receiver is the seller wallet itself.
    function test_ZeroFeeEditionSaleOpensAndSettles() public {
        _govern(
            hotAdmin,
            address(economics),
            abi.encodeCall(economics.setFeeTerms, (PRODUCT_EDITIONS, 1, address(0), 0))
        );
        uint256 workId = _masterAndEdition(1);
        address seller = editions.edition(workId).seller;
        assertEq(editions.edition(workId).feeShare, 0);
        assertEq(editions.edition(workId).royaltyReceiver, seller, "no fee payee");
        vm.prank(artist);
        uint256 saleId = dutchSale.openSale(address(editions), workId, uint64(block.timestamp));
        uint256 price = dutchSale.currentPrice(saleId);
        uint256 feeBefore = networkFee.balance;
        // The master's own sale already paid this wallet: an edition shares its master's payees.
        uint256 sellerBefore = seller.balance;
        vm.deal(buyer2, price);
        vm.prank(buyer2);
        dutchSale.purchase{ value: price }(
            saleId, address(0), 1, price, Payment(PaymentMethod.DIRECT, buyer2, price, 0, 0, "")
        );
        assertEq(editions.balanceOf(buyer2, workId), 1);
        assertEq(seller.balance - sellerBefore, price, "the whole price to the seller wallet");
        assertEq(networkFee.balance, feeBefore, "no fee");
    }
}
