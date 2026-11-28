// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IndependentEditionAuction } from "src/independent/IndependentEditionAuction.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { Facts, MintFacts, Outcome } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { IUniformEditionAuction } from "src/interfaces/IUniformEditionAuction.sol";
import { StatementKinds } from "src/interfaces/types/StatementKinds.sol";
import { MockSale } from "test/mocks/core/CoreMocks.sol";
import { IndependentIntegrationBase } from "./IndependentIntegrationBase.sol";
import { IntegrationBase } from "./IntegrationBase.sol";

/// @notice Edition copies whose master is burned afterwards, on the deployed Independent Stream
///         stack (RND-29 in `docs/spec/rendering-and-tokenuri.md`). The path is the designed
///         one: the 1/1 ends unsold, the edition sale settles and its copies are claimed, the
///         work is offered again, and that sale is cancelled after an upheld dispute, which
///         burns the master. The copies keep their metadata: the master's record stays, the
///         renderer draws the edition from it and adds the dispute statement. The burned
///         ERC-721 token itself has no `tokenURI`.
contract BurnedMasterIndependentTest is IndependentIntegrationBase {
    uint256 internal constant CLOSE_OFFSET = 15 minutes;

    address internal artist;
    address internal anyone = makeAddr("anyone");
    address internal alice = makeAddr("burnAlice");
    address internal bob = makeAddr("burnBob");
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;
    IndependentEditionAuction internal indAuction;
    IUniformEditionAuction internal ea;

    bytes internal masterData;
    bytes internal itemData;
    uint256 internal oneSaleId;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        artist = _actor("burnArtist");
        (fStream, fEditions) = _listPair(artist);
        indAuction = IndependentEditionAuction(payable(deployment.independentEditionAuction));
        ea = IUniformEditionAuction(address(indAuction));
        Work memory m = _asMaster(_fedWork(artist), 0);
        masterData = abi.encode(m);
        itemData = abi.encode(m.item);
        _approveInd(address(fStream), artist, m, IND_RATE);
        (oneSaleId, tokenId) = _fedStart(address(fStream), m);
    }

    function _gone() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId);
    }

    function _openRecord() internal {
        Work memory master = abi.decode(masterData, (Work));
        facts.open(address(fStream), tokenId, master.item, master.media);
    }

    /// @dev The 1/1 ends unsold, the edition sale settles and alice claims two copies.
    function _sellCopies() internal {
        uint256 saleId = indAuction.open(address(fEditions), tokenId, itemData);
        uint256 amount = 2 * ea.stepPrice(saleId, 100);
        vm.deal(alice, amount);
        vm.prank(alice);
        indAuction.bid{ value: amount }(saleId, 100, 2);
        uint256 firstEnd = auction.auction(oneSaleId).endTime;
        vm.warp(firstEnd);
        auction.settle(oneSaleId);
        assertEq(uint8(fStream.workOf(tokenId).outcome), uint8(Outcome.NONE), "unsold, no outcome");
        vm.warp(firstEnd + CLOSE_OFFSET);
        assertTrue(indAuction.settle(saleId, new uint256[](0)), "settled");
        vm.prank(alice);
        indAuction.claimBid(saleId, 1, alice);
        assertEq(fEditions.balanceOf(alice, tokenId), 2);
    }

    /// @dev Anyone offers the unsold 1/1 again; a pauser pauses it; the platform records a
    ///      dispute outcome; the network cancels, which burns the master.
    function _restartPauseCancel() internal returns (bytes32 outcome) {
        vm.prank(anyone);
        auction.restart(oneSaleId);
        vm.warp(block.timestamp + 1 hours);
        _govern(
            pauser1,
            address(auction),
            abi.encodeWithSignature("pause(uint256,bytes32)", oneSaleId, bytes32("a dispute"))
        );
        outcome = _platformStatement(
            address(fStream), tokenId, StatementKinds.DISPUTE_OUTCOME, "ipfs://outcome"
        );
        _asNetwork(address(auction), abi.encodeCall(auction.cancel, (oneSaleId, outcome)));
        assertEq(fStream.totalBurned(), 1, "the master is burned");
        vm.expectRevert(_gone());
        fStream.ownerOf(tokenId);
    }

    /// @dev After the burn: `uri` of the copies is exactly what the renderer draws for the
    ///      edition, with the dispute statement; the burned master has no `tokenURI`; the
    ///      copies are held and move as before.
    function _checkTheCopiesAfterTheBurn(string memory before, bytes32 outcome) internal {
        string memory uri = fEditions.uri(tokenId);
        assertEq(uri, renderer.tokenURI(address(fEditions), tokenId), "the renderer's own answer");
        assertFalse(_contains(before, "Dispute statement"), "no dispute before");
        assertTrue(_contains(uri, '"Dispute statement"'), "the dispute is shown");
        assertTrue(_contains(uri, vm.toString(outcome)), "by its statement");
        assertEq(fStream.rendererOf(tokenId), address(renderer));
        vm.expectRevert(_gone());
        fStream.tokenURI(tokenId);
        assertEq(fEditions.balanceOf(alice, tokenId), 2, "the copies are still held");
        vm.prank(alice);
        fEditions.safeTransferFrom(alice, bob, tokenId, 1, "");
        assertEq(fEditions.balanceOf(bob, tokenId), 1, "and still move");
        // An ID that was never minted still has no renderer.
        uint256 never = fStream.totalMinted() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, never)
        );
        fStream.rendererOf(never);
    }

    /// @dev A finalized master (its renderer pinned): the copies keep their metadata, and the
    ///      pin's code check still holds after the burn.
    function test_BurnedMaster_CopiesOfAFinalizedWorkKeepTheirUri() public {
        _openRecord();
        bytes32 state = rules.workStateHash(address(fStream), tokenId);
        vm.prank(artist);
        rules.finalize(address(fStream), tokenId, state);
        _sellCopies();
        string memory before = fEditions.uri(tokenId);
        assertFalse(_contains(before, "record_status"), "the record renders");
        bytes32 outcome = _restartPauseCancel();
        _checkTheCopiesAfterTheBurn(before, outcome);
        assertFalse(_contains(fEditions.uri(tokenId), "record_status"), "the record still renders");

        Facts memory f = facts.factsOf(address(fStream), tokenId);
        assertTrue(f.finalized && f.rendererCodeHash == address(renderer).codehash, "pinned");
        // A pinned renderer whose code changed draws nothing, burned master or not.
        vm.etch(address(renderer), hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(IWorkFacts.RendererCodeChanged.selector, address(renderer))
        );
        fEditions.uri(tokenId);
    }

    /// @dev A master whose record is open and not finalized: the token's RENDERER module draws
    ///      the copies after the burn, as before it.
    function test_BurnedMaster_CopiesOfAnUnfinalizedWorkKeepTheirUri() public {
        _openRecord();
        _sellCopies();
        string memory before = fEditions.uri(tokenId);
        assertFalse(_contains(before, "record_status"), "the record renders");
        bytes32 outcome = _restartPauseCancel();
        _checkTheCopiesAfterTheBurn(before, outcome);
        assertFalse(_contains(fEditions.uri(tokenId), "record_status"), "the record still renders");
        assertFalse(facts.factsOf(address(fStream), tokenId).finalized);
    }

    /// @dev The remaining limit (LIM-CNT-24): a record that nobody opened before the burn can
    ///      never be opened, so the copies render the core facts only, for good.
    function test_BurnedMaster_ARecordNeverOpenedStaysCoreOnly() public {
        _sellCopies();
        string memory before = fEditions.uri(tokenId);
        assertTrue(_contains(before, '"record_status":"not_open"'), "core-only");
        bytes32 outcome = _restartPauseCancel();
        _checkTheCopiesAfterTheBurn(before, outcome);
        assertTrue(_contains(fEditions.uri(tokenId), '"record_status":"not_open"'), "core-only");
        Work memory master = abi.decode(masterData, (Work));
        vm.expectRevert(_gone());
        facts.open(address(fStream), tokenId, master.item, master.media);
    }
}

/// @notice The same rule for the 6529 Stream pair. No sale contract of v1 burns a 6529 Stream
///         master that has copies, so a second sale contract stands in for a later one: admitted
///         by the network as a minter of both tokens, it mints a master, sells copies of it and
///         burns the master while it still holds it with no outcome.
contract BurnedMasterStreamTest is IntegrationBase {
    MockSale internal sale;
    address internal artist;
    address internal holder = makeAddr("copyHolder");

    function setUp() public override {
        super.setUp();
        artist = _actor("burnStreamArtist");
        sale = new MockSale();
        _asNetwork(address(stream), abi.encodeCall(stream.addMinter, (address(sale))));
        _asNetwork(address(editions), abi.encodeCall(editions.addMinter, (address(sale))));
        vm.warp(block.timestamp + stream.moduleDelay());
        assertTrue(stream.isMinter(address(sale)) && editions.isMinter(address(sale)));
    }

    function test_BurnedMaster_CopiesOf6529StreamEditionsKeepTheirUri() public {
        MintFacts memory f;
        f.itemHash = keccak256("a later sale contract's item");
        f.contentHash = keccak256("a later sale contract's content");
        f.artistId = uint160(artist);
        f.collectionId = collectionId;
        uint256 id = sale.mint(address(stream), f);
        sale.createEdition(address(editions), id, 10, address(0), 0);
        sale.mintEdition(address(editions), holder, id, 3, 0.1 ether);
        string memory before = editions.uri(id);
        assertGt(bytes(before).length, 0);
        assertEq(before, renderer.tokenURI(address(editions), id));
        assertFalse(_contains(before, "Dispute statement"));

        bytes32 outcome =
            _platformStatement(address(stream), id, StatementKinds.DISPUTE_OUTCOME, "ar://upheld");
        sale.burn(address(stream), id);
        bytes memory gone =
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id);
        vm.expectRevert(gone);
        stream.ownerOf(id);

        string memory uri = editions.uri(id);
        assertEq(uri, renderer.tokenURI(address(editions), id), "the renderer's own answer");
        assertTrue(_contains(uri, '"Dispute statement"'), "the dispute is shown");
        assertTrue(_contains(uri, vm.toString(outcome)), "by its statement");
        assertEq(editions.balanceOf(holder, id), 3);
        assertEq(stream.rendererOf(id), address(renderer));
        vm.expectRevert(gone);
        stream.tokenURI(id);
    }
}
