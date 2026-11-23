// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: read the Independent Stream directory, and sell one Independent Stream work.
//
// An artist may deploy their own 6529 Stream-compatible contracts from the network's approved
// templates and join Independent Stream. The directory is the Independent Stream module (the
// Directory's INDEPENDENT_STREAM slot): one entry per token contract, with its artist, form,
// partner, template and the network share in force. There is no on-chain list of every Independent
// Stream contract: discover them from the Independent Stream module's `Registered` events, then
// read each one. A listed 1/1 contract sells through the same English auction as 6529 Stream: the
// auction asks the Independent Stream module, not the package registry, whether a work may start.

import { Vm } from "forge-std/Vm.sol";
import { IndependentStreamEditions6529 } from "src/independent/IndependentStreamEditions6529.sol";
import { IndependentStream6529 } from "src/independent/IndependentStream6529.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IIndependentStreamDeployer } from "src/interfaces/IIndependentStreamDeployer.sol";
import { IIndependentStream } from "src/interfaces/IIndependentStream.sol";
import { IIndependentStreamRegistry } from "src/interfaces/IIndependentStreamRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
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
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleIndependentStreamDirectory is ExampleBase {
    bytes32 internal constant PROFILE = keccak256("6529 profile");
    bytes32 internal constant PROFILE_DOC = keccak256("6529 profile document");
    uint256 internal artistId;
    IndependentStream6529 internal fStream;
    IndependentStreamEditions6529 internal fEditions;

    function setUp() public override {
        super.setUp();
        artistId = uint256(uint160(artist));
        // The artist deploys a linked pair from the approved templates (anyone may deploy; the
        // artist ID is fixed in each contract) and joins both to Independent Stream.
        vm.recordLogs();
        fStream = IndependentStream6529(
            IIndependentStreamDeployer(d.independentStream721Deployer)
                .deploy(
                    bytes32(0),
                    abi.encode(
                        "Artist Works",
                        "ART",
                        address(facts),
                        address(directory),
                        artistId,
                        artist,
                        d.renderer
                    )
                )
        );
        _join(address(fStream), d.independentStream721Deployer);
        fEditions = IndependentStreamEditions6529(
            IIndependentStreamDeployer(d.independentStreamEditionsDeployer)
                .deploy(
                    bytes32(0),
                    abi.encode(
                        "Artist Editions",
                        "ARTED",
                        address(fStream),
                        address(directory),
                        artistId,
                        artist
                    )
                )
        );
        _join(address(fEditions), d.independentStreamEditionsDeployer);
    }

    /// @dev Joins `token`: the account's consent to the listing (form, partner, the network
    ///      share and a deadline), and, because the account has no identity yet, its
    ///      registration, both signed by the artist's wallet.
    function _join(address token, address deployer) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        IIndependentStreamRegistry.Form form = independentStream.templateOf(deployer).form;
        address partner =
            form == IIndependentStreamRegistry.Form.ERC1155 ? address(fStream) : address(0);
        bytes memory registration;
        if (accounts.artistIdOf(artist) == 0) {
            registration = _sign(
                ARTIST_KEY, accounts.registrationDigest(artist, PROFILE, PROFILE_DOC, deadline)
            );
        }
        uint32 share =
            IEconomicsResolver(d.economicsResolver).economics(PRODUCT_INDEPENDENT).feeShare;
        bytes32 subject = independentStream.listingSubject(token, form, partner, share, deadline);
        bytes memory consent =
            _proof(ARTIST_KEY, accounts.consentDigest(address(independentStream), subject));
        independentStream.register(
            token,
            IIndependentStreamRegistry.Join(
                deployer, PROFILE, PROFILE_DOC, deadline, registration, consent
            )
        );
    }

    function test_ReadTheDirectory() public view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // The directory's Independent Stream module is a module of Directory, replaceable like any
        // other.
        assertEq(directory.moduleOf(Slots.INDEPENDENT_STREAM), address(independentStream));

        // 1. Discover: every Registered event of the Independent Stream module.
        address[] memory found = new address[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(independentStream)
                    && logs[i].topics[0] == IIndependentStreamRegistry.Registered.selector
            ) found[n++] = address(uint160(uint256(logs[i].topics[1])));
        }
        assertEq(n, 2, "both halves of the pair are listed");

        for (uint256 i; i < n; ++i) {
            address token = found[i];
            // 2. The entry, as the sale contracts read it: form, partner, template version and
            //    code hash, the artist, the network share in force, and the status.
            IIndependentStreamRegistry.Entry memory e = independentStream.entry(token);
            assertEq(e.artistId, artistId);
            assertEq(e.codeHash, token.codehash, "runs an approved template's code");
            assertEq(uint8(e.status), uint8(IIndependentStreamRegistry.Status.ACTIVE));
            assertTrue(independentStream.isActive(token));
            // 3. The network's share for this contract: fixed at listing; the network may lower
            //    it later (`FeeShareLowered`), never raise it.
            assertEq(independentStream.feeShareOf(token), e.feeShare);
        }
        IIndependentStreamRegistry.Entry memory pair = independentStream.entry(address(fEditions));
        assertEq(uint8(pair.form), uint8(IIndependentStreamRegistry.Form.ERC1155));
        assertEq(pair.partner, address(fStream), "the other half of the pair");
        // 4. Whether a given sale contract may mint into a listed token now.
        assertTrue(independentStream.canMint(address(fStream), address(auction)));
    }

    function test_SellAIndependentWork() public {
        // The artist approves one item for one mint, with its royalty rate.
        (PackageItem memory item, MediaFile[] memory media) = _independentItem();
        vm.prank(artist);
        independentStream.approveItem(address(fStream), WorksHashing.itemHash(item), 5_000);

        // Anyone starts it in the English auction; the auction asks the Independent Stream module.
        assertEq(auction.policyOf(address(fStream)), address(independentStream));
        bytes memory request =
            abi.encode(IIndependentStream.IndependentMint(item, media, new bytes[](0)));
        uint256 saleId = auction.start(address(fStream), request);
        uint256 tokenId = auction.auction(saleId).tokenId;
        assertEq(fStream.ownerOf(tokenId), address(auction));

        address collector = makeAddr("collector");
        _bid(saleId, collector, 1 ether);
        _settleAtEnd(saleId);
        assertEq(fStream.ownerOf(tokenId), collector);
        (, uint256 royalty) = fStream.royaltyInfo(tokenId, 1 ether);
        assertEq(royalty, 1 ether * 5_000 / 100_000, "the approved royalty rate");
    }

    function _independentItem()
        internal
        returns (PackageItem memory item, MediaFile[] memory media)
    {
        bytes memory data = "an Independent Stream work";
        media = new MediaFile[](1);
        media[0] = MediaFile(_file(data, "image/png"), sha256(data), 0);
        item.collectionId = 1;
        item.contentHash = sha256(data);
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = _record("An Independent Stream work");
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, 0);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(artistId, address(0), 100_000);
        item.license = License("CC0-1.0", d.cc0TextFileId);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
    }
}
