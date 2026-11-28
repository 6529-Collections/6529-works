// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IndependentStreamRegistry } from "src/independent/IndependentStreamRegistry.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IModuleSlots } from "src/interfaces/core/IModules.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { IUniformEditionAuctionLens } from "src/interfaces/IUniformEditionAuctionLens.sol";
import { PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";

/// @notice One editions contract per Independent Stream master, at the place where editions are
///         sold (IND-78 in `docs/spec/independent-stream.md`). The Independent Stream module
///         refuses a second editions contract for a master (IND-67), but a module that was
///         replaced still takes listings and its successor reads them through, so after a
///         replacement two editions contracts can both be listed for one master. The edition
///         auction opens a sale only for the one the master's own entry names.
contract IndependentOnePairTest is IndependentIntegrationBase {
    address internal artist;
    IndependentStream6529 internal master;
    IndependentStreamRegistry internal r1;
    IndependentStreamRegistry internal r2;
    IndependentEditionAuction internal indAuction;
    IUniformEditionAuction internal ea;

    function setUp() public override {
        super.setUp();
        artist = _actor("onePairArtist");
        indAuction = IndependentEditionAuction(payable(deployment.independentEditionAuction));
        ea = IUniformEditionAuction(address(indAuction));
        r1 = independentStream;
        // The 1/1 contract is listed in the genesis module, with no editions contract yet.
        master = _deployIndStream(artist);
        _register(address(master), artist, address(streamDeployer));
        assertEq(r1.listingOf(address(master)).partner, address(0));
    }

    /// @dev The network replaces the Independent Stream module with a successor that reads the
    ///      genesis one through.
    function _replaceTheModule() internal {
        r2 = IndependentStreamRegistry(
            _deployArtifact(
                "IndependentStreamRegistry.sol:IndependentStreamRegistry",
                abi.encode(
                    address(manager),
                    address(directory),
                    address(facts),
                    address(economics),
                    address(store),
                    address(r1)
                )
            )
        );
        _asNetwork(
            address(directory),
            abi.encodeCall(IModuleSlots.proposeModule, (Slots.INDEPENDENT_STREAM, address(r2)))
        );
        vm.warp(block.timestamp + directory.moduleDelay());
        directory.activateModule(Slots.INDEPENDENT_STREAM);
        assertEq(directory.moduleOf(Slots.INDEPENDENT_STREAM), address(r2));
    }

    /// @dev The artist's consent to list `token` (an editions contract of `master`) in `reg`.
    function _join(IndependentStreamRegistry reg, address token)
        internal
        view
        returns (IIndependentStreamRegistry.Join memory)
    {
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint32 share = economics.economics(PRODUCT_INDEPENDENT).feeShare;
        bytes32 subject = reg.listingSubject(
            token, IIndependentStreamRegistry.Form.ERC1155, address(master), share, deadline
        );
        bytes memory consent =
            abi.encodePacked(artist, _sign(artist, accounts.consentDigest(address(reg), subject)));
        return IIndependentStreamRegistry.Join(
            address(editionsDeployer),
            _profileId(artist),
            _profileDoc(artist),
            deadline,
            "",
            consent
        );
    }

    /// @dev Lists a new editions contract of the master in `reg`.
    function _listEditions(IndependentStreamRegistry reg)
        internal
        returns (IndependentStreamEditions6529 e)
    {
        e = _deployIndEditions(address(master), artist);
        reg.register(address(e), _join(reg, address(e)));
    }

    /// @dev Approves and starts a master work through the module the directory names now.
    function _startMaster()
        internal
        returns (uint256 oneSaleId, uint256 tokenId, bytes memory item)
    {
        Work memory w = _asMaster(_fedWork(artist), 0);
        IndependentStreamRegistry module =
            IndependentStreamRegistry(directory.moduleOf(Slots.INDEPENDENT_STREAM));
        vm.prank(artist);
        module.approveItem(address(master), _itemHash(w), IND_RATE);
        oneSaleId = auction.start(address(master), _fedRequest(w, new bytes[](0)));
        tokenId = master.totalMinted();
        item = abi.encode(w.item);
    }

    /// @dev The whole sale of `tokenId`'s edition on `e`: a bid of three copies, the 1/1 sold,
    ///      the edition sale settled, the copies claimed and the edition sealed at three.
    function _sells(
        IndependentStreamEditions6529 e,
        uint256 oneSaleId,
        uint256 tokenId,
        bytes memory item
    ) internal {
        uint256 saleId = indAuction.open(address(e), tokenId, item);
        address bidder = makeAddr("onePairBidder");
        uint256 amount = 3 * ea.stepPrice(saleId, 100);
        vm.deal(bidder, amount);
        vm.prank(bidder);
        indAuction.bid{ value: amount }(saleId, 100, 3);
        _ethBid(oneSaleId, makeAddr("onePairCollector"), 1 ether);
        _settleAtEnd(oneSaleId);
        vm.warp(ea.endTimes(saleId).endTime);
        IUniformEditionAuctionLens l = IUniformEditionAuctionLens(address(indAuction));
        assertTrue(indAuction.settle(saleId, l.settlementOrderFor(saleId, address(this))));
        vm.prank(bidder);
        indAuction.claimBid(saleId, 1, bidder);
        assertEq(e.balanceOf(bidder, tokenId), 3, "the copies");
        assertTrue(e.editionOf(tokenId).supplySealed && e.editionOf(tokenId).maxSupply == 3);
    }

    // ------------------------------------------------------------------ the second contract

    /// @dev After a replacement the artist lists editions contract A through the successor and
    ///      then editions contract B through the replaced module. The successor serves both, and
    ///      lets the edition auction mint both, but the master's entry names A only: a sale
    ///      opens for A and never for B, so the master has one edition.
    function test_OnePair_ASecondEditionsContractListedThroughTheReplacedModuleOpensNoSale()
        public
    {
        _replaceTheModule();
        IndependentStreamEditions6529 a = _listEditions(r2);
        assertEq(r2.entry(address(master)).partner, address(a), "the master names A");
        IndependentStreamEditions6529 b = _listEditions(r1);

        // What the module answers for B: listed, served, mintable by the edition auction.
        assertEq(r2.entry(address(b)).partner, address(master));
        assertTrue(r2.isActive(address(a)) && r2.isActive(address(b)), "both served");
        assertTrue(r2.canMint(address(a), address(indAuction)), "A may mint");
        assertTrue(r2.canMint(address(b), address(indAuction)), "B may mint too");
        assertEq(r2.entry(address(master)).partner, address(a), "the master still names A only");

        (uint256 oneSaleId, uint256 tokenId, bytes memory item) = _startMaster();
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(b), tokenId)
        );
        indAuction.open(address(b), tokenId, item);
        // Nothing was created on B, so no copy of the master can ever be minted there by the
        // auction: it mints only for the sales it opened.
        assertEq(b.editionOf(tokenId).minter, address(0), "no edition on B");

        _sells(a, oneSaleId, tokenId, item);
        vm.expectRevert(
            abi.encodeWithSelector(ISaleAdapter.InvalidSaleTerms.selector, address(b), tokenId)
        );
        indAuction.open(address(b), tokenId, item);
        assertEq(b.editionOf(tokenId).minter, address(0), "still none");
    }

    /// @dev Retiring the replaced module as a taker of listings, as the replacement checklist
    ///      says: the successor takes its own copy of each template version (a suspension and
    ///      its end), then the network revokes the versions in the replaced module. That module
    ///      lists nothing more, and the successor lists, serves and sells as before.
    function test_OnePair_ARetiredModuleTakesNoMoreListings() public {
        _replaceTheModule();
        address[2] memory deployers = [address(streamDeployer), address(editionsDeployer)];
        for (uint256 i; i < deployers.length; ++i) {
            _asNetwork(address(r2), abi.encodeCall(r2.suspendTemplate, (deployers[i])));
            _asNetwork(address(r2), abi.encodeCall(r2.resumeTemplate, (deployers[i])));
            _asNetwork(address(r1), abi.encodeCall(r1.revokeTemplate, (deployers[i])));
        }
        IndependentStreamEditions6529 a = _listEditions(r2);
        IndependentStreamEditions6529 b = _deployIndEditions(address(master), artist);
        IIndependentStreamRegistry.Join memory j = _join(r1, address(b));
        vm.expectRevert(
            abi.encodeWithSelector(IIndependentStreamRegistry.NotListable.selector, address(b))
        );
        r1.register(address(b), j);
        assertTrue(r2.isActive(address(master)) && r2.isActive(address(a)), "served as before");
        (uint256 oneSaleId, uint256 tokenId, bytes memory item) = _startMaster();
        _sells(a, oneSaleId, tokenId, item);
    }

    /// @dev The same retirement for a version that is not approved: each pair of calls in the
    ///      successor leaves the status as it was and makes it the successor's own, so what the
    ///      replaced module records afterwards no longer reaches the successor.
    function test_OnePair_RetiringKeepsASuspendedAndARevokedVersionAsTheyWere() public {
        address d = address(editionsDeployer);
        uint256 snapshot = vm.snapshotState();

        // Suspended: resumed and suspended again in the successor, revoked in the replaced one.
        _asNetwork(address(r1), abi.encodeCall(r1.suspendTemplate, (d)));
        _replaceTheModule();
        _asNetwork(address(r2), abi.encodeCall(r2.resumeTemplate, (d)));
        _asNetwork(address(r2), abi.encodeCall(r2.suspendTemplate, (d)));
        _asNetwork(address(r1), abi.encodeCall(r1.revokeTemplate, (d)));
        assertEq(
            uint8(r2.templateOf(d).status),
            uint8(IIndependentStreamRegistry.TemplateStatus.SUSPENDED),
            "suspended, as it was"
        );
        assertEq(
            uint8(r1.templateOf(d).status), uint8(IIndependentStreamRegistry.TemplateStatus.REVOKED)
        );
        assertTrue(r2.isActive(address(master)), "served as before");

        // Revoked: reinstated and revoked again in the successor; nothing to do in the replaced
        // module, and a later reinstatement there does not reach the successor.
        vm.revertToState(snapshot);
        _asNetwork(address(r1), abi.encodeCall(r1.revokeTemplate, (d)));
        _replaceTheModule();
        _asNetwork(address(r2), abi.encodeCall(r2.reinstateTemplate, (d)));
        _asNetwork(address(r2), abi.encodeCall(r2.revokeTemplate, (d)));
        _asNetwork(address(r1), abi.encodeCall(r1.reinstateTemplate, (d)));
        assertEq(
            uint8(r2.templateOf(d).status),
            uint8(IIndependentStreamRegistry.TemplateStatus.REVOKED),
            "revoked, as it was"
        );
        assertEq(
            uint8(r1.templateOf(d).status),
            uint8(IIndependentStreamRegistry.TemplateStatus.APPROVED)
        );
    }

    // ------------------------------------------------------------------ pairs that still sell

    /// @dev The ordinary pair, with no replacement.
    function test_OnePair_TheOrdinaryPairSells() public {
        IndependentStreamEditions6529 e = _listEditions(r1);
        assertEq(r1.entry(address(master)).partner, address(e));
        (uint256 oneSaleId, uint256 tokenId, bytes memory item) = _startMaster();
        _sells(e, oneSaleId, tokenId, item);
    }

    /// @dev A pair completed before the replacement sells after it, read through.
    function test_OnePair_APairListedBeforeAReplacementStillSells() public {
        IndependentStreamEditions6529 e = _listEditions(r1);
        _replaceTheModule();
        assertEq(r2.entry(address(master)).partner, address(e), "read through");
        (uint256 oneSaleId, uint256 tokenId, bytes memory item) = _startMaster();
        _sells(e, oneSaleId, tokenId, item);
    }

    /// @dev A pair completed through the successor sells.
    function test_OnePair_APairListedThroughASuccessorSells() public {
        _replaceTheModule();
        IndependentStreamEditions6529 e = _listEditions(r2);
        assertEq(r2.entry(address(master)).partner, address(e));
        (uint256 oneSaleId, uint256 tokenId, bytes memory item) = _startMaster();
        _sells(e, oneSaleId, tokenId, item);
    }

    /// @dev An editions contract listed through the replaced module while the successor has not
    ///      copied the master's listing is the master's one editions contract: the successor
    ///      reads the pair through, and it sells.
    function test_OnePair_AFirstEditionsContractListedThroughTheReplacedModuleSells() public {
        _replaceTheModule();
        IndependentStreamEditions6529 e = _listEditions(r1);
        assertEq(r2.entry(address(master)).partner, address(e), "read through");
        (uint256 oneSaleId, uint256 tokenId, bytes memory item) = _startMaster();
        _sells(e, oneSaleId, tokenId, item);
    }
}
