// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { IndependentStreamDeployer } from "src/independent/IndependentStreamDeployer.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { IIndependentStream } from "src/interfaces/IIndependentStream.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_INDEPENDENT } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    License,
    PackageItem,
    Party,
    SaleTerms
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IndSale } from "../independent/IndependentStreamFixture.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { EditionsCoreIndexer } from "./EditionsCoreIndexer.sol";
import {
    IndependentStreamIndexer,
    IndependentStreamRegistryIndexer
} from "./IndependentStreamIndexer.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of an Independent Stream artist's pair (`IndependentStream6529` and
///         `IndependentStreamEditions6529`) on the deployed stack, each from its deployment through
///         the stack's template deployers: a history that emits every event either can emit
///         (listing, items minted by an admitted sale contract, sold, unsold and burned works,
///         approvals and transfers, the shared rules module's royalty change and lock, metadata
///         refreshes, the artist's page and renderer, the network's settings, a rescue and a rebind
///         after the Independent Stream module removes the sale contract) rebuilds every getter of
///         both, and of the Independent Stream module, from their logs alone.
/// @dev `URI` is declared by ERC-1155 and never emitted.
contract LogReplayIndependentTest is ReplayBase {
    bytes32 internal constant PROFILE = keccak256("Independent Stream profile");
    bytes32 internal constant PROFILE_DOC = keccak256("Independent Stream profile document");

    address internal artist;
    address internal collector = makeAddr("indCollector");
    address internal second = makeAddr("indSecond");
    uint256 internal artistId;
    bytes32 internal licenseText;
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;
    IndSale internal indSale;
    IndSale internal nextSale;
    /// @dev A sale contract is admitted for one token form: these two serve the editions.
    IndSale internal edSale;
    IndSale internal nextEdSale;
    IndependentStreamIndexer internal fStreamIdx;
    EditionsCoreIndexer internal fEditionsIdx;
    IndependentStreamRegistryIndexer internal indIdx;
    uint256 internal salt;

    /// @dev The pair is deployed and listed before the first comparison, so both are replayed
    ///      from their constructors.
    function _extraIndexers() internal override {
        artist = _actor("indArtist");
        artistId = uint256(uint160(artist));
        licenseText = _storeText("Independent Stream license text (replay fixture)", "text/plain");
        IndependentStreamDeployer streamDeployer =
            IndependentStreamDeployer(deployment.independentStream721Deployer);
        IndependentStreamDeployer editionsDeployer =
            IndependentStreamDeployer(deployment.independentStreamEditionsDeployer);
        fStream = IndependentStream6529(
            streamDeployer.deploy(
                bytes32(0),
                abi.encode(
                    "Artist Works",
                    "ART",
                    address(facts),
                    address(directory),
                    artistId,
                    marketOwner,
                    address(renderer)
                )
            )
        );
        fEditions = IndependentStreamEditions6529(
            editionsDeployer.deploy(
                bytes32(0),
                abi.encode(
                    "Artist Editions",
                    "ARTED",
                    address(fStream),
                    address(directory),
                    artistId,
                    marketOwner
                )
            )
        );
        fStreamIdx = new IndependentStreamIndexer(address(fStream));
        fEditionsIdx = new EditionsCoreIndexer(address(fEditions), false);
        indIdx = new IndependentStreamRegistryIndexer(address(independentStream));
        indexers.push(fStreamIdx);
        indexers.push(fEditionsIdx);
        indexers.push(indIdx);

        _join(address(fStream), address(streamDeployer), true);
        _join(address(fEditions), address(editionsDeployer), false);
        _asNetwork(
            address(terms),
            abi.encodeCall(terms.setEditions, (address(fStream), address(fEditions)))
        );
        indSale = new IndSale();
        nextSale = new IndSale();
        edSale = new IndSale();
        nextEdSale = new IndSale();
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(indSale), IIndependentStreamRegistry.Form.ERC721, true)
            )
        );
        _asNetwork(
            address(independentStream),
            abi.encodeCall(
                independentStream.setAdapter,
                (address(edSale), IIndependentStreamRegistry.Form.ERC1155, true)
            )
        );
        indIdx.addProbe(address(this));
    }

    function _setAdapter(IndSale sale, IIndependentStreamRegistry.Form form, bool admitted)
        internal
    {
        _asNetwork(
            address(independentStream),
            abi.encodeCall(independentStream.setAdapter, (address(sale), form, admitted))
        );
    }

    function _join(address token, address deployer, bool register) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        IIndependentStreamRegistry.Form form = independentStream.templateOf(deployer).form;
        address partner = form == IIndependentStreamRegistry.Form.ERC1155
            ? IndependentStreamEditions6529(token).stream()
            : address(0);
        bytes memory registration;
        if (register) {
            registration = _sign(
                artist, accounts.registrationDigest(artist, PROFILE, PROFILE_DOC, deadline)
            );
        }
        uint32 share = economics.economics(PRODUCT_INDEPENDENT).feeShare;
        bytes32 subject = independentStream.listingSubject(token, form, partner, share, deadline);
        bytes memory consent = abi.encodePacked(
            artist, _sign(artist, accounts.consentDigest(address(independentStream), subject))
        );
        independentStream.register(
            token,
            IIndependentStreamRegistry.Join(
                deployer, PROFILE, PROFILE_DOC, deadline, registration, consent
            )
        );
    }

    /// @dev An item of the artist, its media and record stored, approved by the artist.
    function _fedWork() internal returns (Work memory w) {
        bytes memory data = abi.encodePacked("Independent Stream replay work ", vm.toString(++salt));
        bytes32 sha = sha256(data);
        bytes32 fileId = _upload(data, IContentStore.Encoding.Identity, "image/png", sha);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(fileId, sha, 0);
        w.item.collectionId = 1;
        w.item.contentHash = sha;
        w.item.mediaHash = WorksHashing.mediaHash(w.media);
        w.item.recordFileId = _record(string.concat("Independent Stream ", vm.toString(salt)));
        w.item.parties = new Party[](1);
        w.item.parties[0] = Party(artist, 0);
        w.item.payees = new ISplitWallet.Payee[](1);
        w.item.payees[0] = ISplitWallet.Payee(artistId, address(0), 100_000);
        w.item.license = License("CC-BY-4.0", licenseText);
        w.item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        w.item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
        vm.prank(artist);
        independentStream.approveItem(address(fStream), WorksHashing.itemHash(w.item), 5_000);
    }

    function _mint(IndSale sale, Work memory w) internal returns (uint256 tokenId) {
        (tokenId,,) = sale.start(
            address(independentStream),
            address(fStream),
            abi.encode(IIndependentStream.IndependentMint(w.item, w.media, new bytes[](0)))
        );
    }

    function test_Independent_EveryEventReplaysToTheSameState() public {
        // Works minted by the admitted sale contract: one sold and delivered, one unsold, one
        // burned before its outcome.
        Work memory wa = _fedWork();
        uint256 a = _mint(indSale, wa);
        indSale.record(address(fStream), a, true, collector, 1 ether);
        indSale.send(address(fStream), a, collector);
        uint256 b = _mint(indSale, _fedWork());
        indSale.record(address(fStream), b, false, address(0), 0);
        uint256 c = _mint(indSale, _fedWork());
        indSale.burn(address(fStream), c);
        _sync();

        // Approvals and an operator's transfer.
        vm.startPrank(collector);
        fStream.approve(second, a);
        fStream.setApprovalForAll(second, true);
        vm.stopPrank();
        vm.prank(second);
        fStream.transferFrom(collector, second, a);
        _sync();

        // The shared rules module: record opened, royalty changed (the edition follows) and
        // locked; a batch refresh through delivery.
        facts.open(address(fStream), a, wa.item, wa.media);
        _sync();

        // Editions: two created by the sale contract, minted, transferred and burned, one
        // sealed; one left unminted for the rebind.
        edSale.createEdition(address(fEditions), a, 10, address(0xFEE), 5_000);
        edSale.createEdition(address(fEditions), b, 0, address(0), 0);
        uint256 d = _mint(indSale, _fedWork());
        edSale.createEdition(address(fEditions), d, 5, address(0), 0);
        edSale.mintEdition(address(fEditions), collector, a, 4, 0.1 ether);
        edSale.mintEdition(address(fEditions), collector, b, 3, 0.1 ether);
        edSale.seal(address(fEditions), a, 6);
        vm.startPrank(collector);
        fEditions.safeTransferFrom(collector, second, a, 1, "");
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (a, b, 1, 1);
        fEditions.safeBatchTransferFrom(collector, second, ids, amounts, "");
        fEditions.setApprovalForAll(second, true);
        fEditions.burn(b, 1);
        vm.stopPrank();
        _sync();

        _setRoyaltyRateOn(address(fStream), a, wa, 7_000);
        _sync();
        _renounceOn(address(fStream), a, artist, WorkPowers.ROYALTY_RATE);
        bytes32 state = rules.workStateHash(address(fStream), a);
        vm.prank(artist);
        rules.finalize(address(fStream), a, state);
        _govern(
            storageOperator,
            address(delivery),
            abi.encodeCall(delivery.setPreferredKind, (address(fStream), LocatorKind.IPFS))
        );
        _sync();

        // The artist's page and renderer; the network's settings on both tokens.
        vm.startPrank(artist);
        fStream.setContractURI("ar://artist-works");
        fStream.setOwner(makeAddr("artistMarket"));
        fEditions.setContractURI("ar://artist-editions");
        fEditions.setOwner(makeAddr("artistMarket"));
        fStream.proposeModule(Slots.RENDERER, address(new MockRenderer()));
        vm.stopPrank();
        _sync();
        vm.startPrank(network);
        fStream.setModuleDelay(1 days);
        fStream.setRescueDelay(2 days);
        fEditions.setRebindDelay(2 days);
        vm.stopPrank();
        skip(7 days);
        fStream.activateModule(Slots.RENDERER);
        _sync();

        // The Independent Stream module removes the sale contract and admits another: a work still
        // in the old one's custody is rescued, and the unminted edition is rebound.
        uint256 stranded = _mint(indSale, _fedWork());
        _setAdapter(indSale, IIndependentStreamRegistry.Form.ERC721, false);
        _setAdapter(edSale, IIndependentStreamRegistry.Form.ERC1155, false);
        _setAdapter(nextSale, IIndependentStreamRegistry.Form.ERC721, true);
        _setAdapter(nextEdSale, IIndependentStreamRegistry.Form.ERC1155, true);
        indIdx.addProbe(address(nextSale));
        indIdx.addProbe(address(nextEdSale));
        _sync();
        skip(2 days);
        vm.startPrank(network);
        fStream.rescue(stranded, museum);
        fEditions.rebind(d, address(nextEdSale));
        vm.stopPrank();
        nextEdSale.mintEdition(address(fEditions), collector, d, 2, 0);
        _sync();
        assertEq(fStream.ownerOf(stranded), museum);
        assertEq(fEditions.editionOf(d).minter, address(nextEdSale));

        _assertEveryEventReplayed(
            "IndependentStream6529", fStreamIdx, ReplayEvents.independentStream(), _none()
        );
        _assertEveryEventReplayed(
            "IndependentStreamEditions6529",
            fEditionsIdx,
            ReplayEvents.independentEditions(),
            _list("URI(string,uint256)")
        );
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 11 holds the contract URI: a value no `ContractURISet` logged.
    function test_Independent_ReplayFailsOnStateNoLogExplains() public {
        fStreamIdx.assertMatches();
        vm.store(address(fStream), bytes32(uint256(11)), bytes32(uint256(0x41 << 248 | 2)));
        vm.expectRevert();
        fStreamIdx.assertMatches();
    }

    /// @dev A sale whose `PrimarySale` log is dropped: the rebuilt outcome is stale.
    function test_Independent_ReplayFailsOnADroppedLog() public {
        uint256 a = _mint(indSale, _fedWork());
        _sync();
        indSale.record(address(fStream), a, true, collector, 1 ether);
        _apply(_dropOne(address(fStream), IStream.PrimarySale.selector));
        vm.expectRevert();
        fStreamIdx.assertMatches();
    }

    /// @dev An edition claim whose `TransferSingle` log is dropped: the balance is stale.
    function test_IndependentStreamEditions_ReplayFailsOnADroppedLog() public {
        uint256 a = _mint(indSale, _fedWork());
        edSale.createEdition(address(fEditions), a, 10, address(0), 0);
        _sync();
        edSale.mintEdition(address(fEditions), collector, a, 2, 0);
        _apply(
            _dropOne(
                address(fEditions),
                keccak256("TransferSingle(address,address,address,uint256,uint256)")
            )
        );
        vm.expectRevert(bytes("balanceOf: 2 != 0"));
        fEditionsIdx.assertMatches();
    }
}
