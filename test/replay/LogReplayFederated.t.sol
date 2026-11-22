// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { WorkPowers } from "src/interfaces/IWorkPowers.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { LocatorKind, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { CURRENCY_ETH, PRODUCT_FEDERATED } from "src/interfaces/types/EconomicsTypes.sol";
import {
    EditionTerms,
    License,
    PackageItem,
    Party,
    SaleTerms
} from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { FedSale } from "../federated/FederationFixture.sol";
import { MockRenderer } from "../mocks/core/CoreMocks.sol";
import { EditionsCoreIndexer } from "./EditionsCoreIndexer.sol";
import { FederatedStreamIndexer, FederationRegistryIndexer } from "./FederationIndexer.sol";
import { ReplayBase } from "./ReplayBase.sol";
import { ReplayEvents } from "./ReplayEvents.sol";

/// @notice Log replay of a federated artist's pair (`FederatedStream` and `FederatedEditions`)
///         on the deployed stack, each from its deployment through the stack's template
///         deployers: a history that emits every event either can emit (listing, items minted
///         by an admitted sale contract, sold, unsold and burned works, approvals and transfers,
///         the shared rules module's royalty change and lock, metadata refreshes, the artist's
///         page and renderer, the network's settings, a rescue and a rebind after the federation
///         module removes the sale contract) rebuilds every getter of both, and of the
///         federation module, from their logs alone.
/// @dev `URI` is declared by ERC-1155 and never emitted.
contract LogReplayFederatedTest is ReplayBase {
    bytes32 internal constant PROFILE = keccak256("federated profile");
    bytes32 internal constant PROFILE_DOC = keccak256("federated profile document");

    address internal artist;
    address internal collector = makeAddr("fedCollector");
    address internal second = makeAddr("fedSecond");
    uint256 internal artistId;
    bytes32 internal licenseText;
    FederatedStream internal fStream;
    FederatedEditions internal fEditions;
    FedSale internal fedSale;
    FedSale internal nextSale;
    FederatedStreamIndexer internal fStreamIdx;
    EditionsCoreIndexer internal fEditionsIdx;
    FederationRegistryIndexer internal fedIdx;
    uint256 internal salt;

    /// @dev The pair is deployed and listed before the first comparison, so both are replayed
    ///      from their constructors.
    function _extraIndexers() internal override {
        artist = _actor("fedArtist");
        artistId = uint256(uint160(artist));
        licenseText = _storeText("Federated license text (replay fixture)", "text/plain");
        FederatedDeployer streamDeployer = FederatedDeployer(deployment.federatedStreamDeployer);
        FederatedDeployer editionsDeployer = FederatedDeployer(deployment.federatedEditionsDeployer);
        fStream = FederatedStream(
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
        fEditions = FederatedEditions(
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
        fStreamIdx = new FederatedStreamIndexer(address(fStream));
        fEditionsIdx = new EditionsCoreIndexer(address(fEditions), false);
        fedIdx = new FederationRegistryIndexer(address(federation));
        indexers.push(fStreamIdx);
        indexers.push(fEditionsIdx);
        indexers.push(fedIdx);

        _join(address(fStream), address(streamDeployer), true);
        _join(address(fEditions), address(editionsDeployer), false);
        _asNetwork(
            address(terms),
            abi.encodeCall(terms.setEditions, (address(fStream), address(fEditions)))
        );
        fedSale = new FedSale();
        nextSale = new FedSale();
        _asNetwork(
            address(federation), abi.encodeCall(federation.setAdapter, (address(fedSale), true))
        );
        fedIdx.addProbe(address(this));
    }

    function _join(address token, address deployer, bool register) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        IFederationRegistry.Form form = federation.templateOf(deployer).form;
        address partner = form == IFederationRegistry.Form.ERC1155
            ? FederatedEditions(token).stream()
            : address(0);
        bytes memory registration;
        if (register) {
            registration = _sign(
                artist, accounts.registrationDigest(artist, PROFILE, PROFILE_DOC, deadline)
            );
        }
        uint32 share = economics.economics(PRODUCT_FEDERATED).feeShare;
        bytes32 subject = federation.listingSubject(token, form, partner, share, deadline);
        bytes memory consent = abi.encodePacked(
            artist, _sign(artist, accounts.consentDigest(address(federation), subject))
        );
        federation.register(
            token,
            IFederationRegistry.Join(
                deployer, PROFILE, PROFILE_DOC, deadline, registration, consent
            )
        );
    }

    /// @dev An item of the artist, its media and record stored, approved by the artist.
    function _fedWork() internal returns (Work memory w) {
        bytes memory data = abi.encodePacked("federated replay work ", vm.toString(++salt));
        bytes32 sha = sha256(data);
        bytes32 fileId = _upload(data, IContentStore.Encoding.Identity, "image/png", sha);
        w.media = new MediaFile[](1);
        w.media[0] = MediaFile(fileId, sha, 0);
        w.item.collectionId = 1;
        w.item.contentHash = sha;
        w.item.mediaHash = WorksHashing.mediaHash(w.media);
        w.item.recordFileId = _record(string.concat("Federated ", vm.toString(salt)));
        w.item.parties = new Party[](1);
        w.item.parties[0] = Party(artist, 0);
        w.item.payees = new ISplitWallet.Payee[](1);
        w.item.payees[0] = ISplitWallet.Payee(artistId, address(0), 100_000);
        w.item.license = License("CC-BY-4.0", licenseText);
        w.item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        w.item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
        vm.prank(artist);
        federation.approveItem(address(fStream), WorksHashing.itemHash(w.item), 5_000);
    }

    function _mint(FedSale sale, Work memory w) internal returns (uint256 tokenId) {
        (tokenId,,) = sale.start(
            address(federation),
            address(fStream),
            abi.encode(IFederatedStream.FederatedMint(w.item, w.media, new bytes[](0)))
        );
    }

    function test_Federated_EveryEventReplaysToTheSameState() public {
        // Works minted by the admitted sale contract: one sold and delivered, one unsold, one
        // burned before its outcome.
        Work memory wa = _fedWork();
        uint256 a = _mint(fedSale, wa);
        fedSale.record(address(fStream), a, true, collector, 1 ether);
        fedSale.send(address(fStream), a, collector);
        uint256 b = _mint(fedSale, _fedWork());
        fedSale.record(address(fStream), b, false, address(0), 0);
        uint256 c = _mint(fedSale, _fedWork());
        fedSale.burn(address(fStream), c);
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
        fedSale.createEdition(address(fEditions), a, 10, address(0xFEE), 5_000);
        fedSale.createEdition(address(fEditions), b, 0, address(0), 0);
        uint256 d = _mint(fedSale, _fedWork());
        fedSale.createEdition(address(fEditions), d, 5, address(0), 0);
        fedSale.mintEdition(address(fEditions), collector, a, 4, 0.1 ether);
        fedSale.mintEdition(address(fEditions), collector, b, 3, 0.1 ether);
        fedSale.seal(address(fEditions), a, 6);
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

        // The federation module removes the sale contract and admits another: a work still in
        // the old one's custody is rescued, and the unminted edition is rebound.
        uint256 stranded = _mint(fedSale, _fedWork());
        _asNetwork(
            address(federation), abi.encodeCall(federation.setAdapter, (address(fedSale), false))
        );
        _asNetwork(
            address(federation), abi.encodeCall(federation.setAdapter, (address(nextSale), true))
        );
        fedIdx.addProbe(address(nextSale));
        _sync();
        skip(2 days);
        vm.startPrank(network);
        fStream.rescue(stranded, museum);
        fEditions.rebind(d, address(nextSale));
        vm.stopPrank();
        nextSale.mintEdition(address(fEditions), collector, d, 2, 0);
        _sync();
        assertEq(fStream.ownerOf(stranded), museum);
        assertEq(fEditions.editionOf(d).minter, address(nextSale));

        _assertEveryEventReplayed(
            "FederatedStream", fStreamIdx, ReplayEvents.federatedStream(), _none()
        );
        _assertEveryEventReplayed(
            "FederatedEditions",
            fEditionsIdx,
            ReplayEvents.federatedEditions(),
            _list("URI(string,uint256)")
        );
    }

    // ------------------------------------------------------------------ negative controls

    /// @dev Slot 11 holds the contract URI: a value no `ContractURISet` logged.
    function test_Federated_ReplayFailsOnStateNoLogExplains() public {
        fStreamIdx.assertMatches();
        vm.store(address(fStream), bytes32(uint256(11)), bytes32(uint256(0x41 << 248 | 2)));
        vm.expectRevert();
        fStreamIdx.assertMatches();
    }

    /// @dev A sale whose `PrimarySale` log is dropped: the rebuilt outcome is stale.
    function test_Federated_ReplayFailsOnADroppedLog() public {
        uint256 a = _mint(fedSale, _fedWork());
        _sync();
        fedSale.record(address(fStream), a, true, collector, 1 ether);
        _apply(_dropOne(address(fStream), IStream.PrimarySale.selector));
        vm.expectRevert();
        fStreamIdx.assertMatches();
    }

    /// @dev An edition claim whose `TransferSingle` log is dropped: the balance is stale.
    function test_FederatedEditions_ReplayFailsOnADroppedLog() public {
        uint256 a = _mint(fedSale, _fedWork());
        fedSale.createEdition(address(fEditions), a, 10, address(0), 0);
        _sync();
        fedSale.mintEdition(address(fEditions), collector, a, 2, 0);
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
