// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Example: read the federation directory, and sell one federated work.
//
// An artist may deploy their own 6529 Stream-compatible contracts from the network's approved
// templates and join the federation. The directory is the federation module (the Directory's
// FEDERATION slot): one entry per token contract, with its artist, form, partner, template and
// the network share in force. There is no on-chain list of every federated contract: discover
// them from the federation module's `Registered` events, then read each one. A listed 1/1
// contract sells through the same English auction as 6529 Stream: the auction asks the
// federation module, not the package registry, whether a work may start.

import { Vm } from "forge-std/Vm.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { Slots } from "src/interfaces/core/CoreTypes.sol";
import { IFederatedDeployer } from "src/interfaces/IFederatedDeployer.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
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
import { ExampleBase } from "./ExampleBase.sol";

contract ExampleFederationDirectory is ExampleBase {
    bytes32 internal constant PROFILE = keccak256("6529 profile");
    bytes32 internal constant PROFILE_DOC = keccak256("6529 profile document");
    uint256 internal artistId;
    FederatedStream internal fStream;
    FederatedEditions internal fEditions;

    function setUp() public override {
        super.setUp();
        artistId = uint256(uint160(artist));
        // The artist deploys a linked pair from the approved templates (anyone may deploy; the
        // artist ID is fixed in each contract) and joins both to the federation.
        vm.recordLogs();
        fStream = FederatedStream(
            IFederatedDeployer(d.federatedStreamDeployer)
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
        _join(address(fStream), d.federatedStreamDeployer);
        fEditions = FederatedEditions(
            IFederatedDeployer(d.federatedEditionsDeployer)
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
        _join(address(fEditions), d.federatedEditionsDeployer);
    }

    /// @dev Joins `token`: the account's consent to the listing (form, partner, the network
    ///      share and a deadline), and, because the account has no identity yet, its
    ///      registration, both signed by the artist's wallet.
    function _join(address token, address deployer) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        IFederationRegistry.Form form = federation.templateOf(deployer).form;
        address partner = form == IFederationRegistry.Form.ERC1155 ? address(fStream) : address(0);
        bytes memory registration;
        if (accounts.artistIdOf(artist) == 0) {
            registration = _sign(
                ARTIST_KEY, accounts.registrationDigest(artist, PROFILE, PROFILE_DOC, deadline)
            );
        }
        uint32 share = IEconomicsResolver(d.economicsResolver).economics(PRODUCT_FEDERATED).feeShare;
        bytes32 subject = federation.listingSubject(token, form, partner, share, deadline);
        bytes memory consent =
            _proof(ARTIST_KEY, accounts.consentDigest(address(federation), subject));
        federation.register(
            token,
            IFederationRegistry.Join(
                deployer, PROFILE, PROFILE_DOC, deadline, registration, consent
            )
        );
    }

    function test_ReadTheDirectory() public view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // The directory's federation module is a module of Directory, replaceable like any other.
        assertEq(directory.moduleOf(Slots.FEDERATION), address(federation));

        // 1. Discover: every Registered event of the federation module.
        address[] memory found = new address[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(federation)
                    && logs[i].topics[0] == IFederationRegistry.Registered.selector
            ) found[n++] = address(uint160(uint256(logs[i].topics[1])));
        }
        assertEq(n, 2, "both halves of the pair are listed");

        for (uint256 i; i < n; ++i) {
            address token = found[i];
            // 2. The entry, as the sale contracts read it: form, partner, template version and
            //    code hash, the artist, the network share in force, and the status.
            IFederationRegistry.Entry memory e = federation.entry(token);
            assertEq(e.artistId, artistId);
            assertEq(e.codeHash, token.codehash, "runs an approved template's code");
            assertEq(uint8(e.status), uint8(IFederationRegistry.Status.ACTIVE));
            assertTrue(federation.isActive(token));
            // 3. The network's share for this contract: fixed at listing; the network may lower
            //    it later (`FeeShareLowered`), never raise it.
            assertEq(federation.feeShareOf(token), e.feeShare);
        }
        IFederationRegistry.Entry memory pair = federation.entry(address(fEditions));
        assertEq(uint8(pair.form), uint8(IFederationRegistry.Form.ERC1155));
        assertEq(pair.partner, address(fStream), "the other half of the pair");
        // 4. Whether a given sale contract may mint into a listed token now.
        assertTrue(federation.canMint(address(fStream), address(auction)));
    }

    function test_SellAFederatedWork() public {
        // The artist approves one item for one mint, with its royalty rate.
        (PackageItem memory item, MediaFile[] memory media) = _federatedItem();
        vm.prank(artist);
        federation.approveItem(address(fStream), WorksHashing.itemHash(item), 5_000);

        // Anyone starts it in the English auction; the auction asks the federation module.
        assertEq(auction.policyOf(address(fStream)), address(federation));
        bytes memory request =
            abi.encode(IFederatedStream.FederatedMint(item, media, new bytes[](0)));
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

    function _federatedItem() internal returns (PackageItem memory item, MediaFile[] memory media) {
        bytes memory data = "a federated work";
        media = new MediaFile[](1);
        media[0] = MediaFile(_file(data, "image/png"), sha256(data), 0);
        item.collectionId = 1;
        item.contentHash = sha256(data);
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = _record("A federated work");
        item.parties = new Party[](1);
        item.parties[0] = Party(artist, 0);
        item.payees = new ISplitWallet.Payee[](1);
        item.payees[0] = ISplitWallet.Payee(artistId, address(0), 100_000);
        item.license = License("CC0-1.0", d.cc0TextFileId);
        item.sale = SaleTerms(SaleKind.ENGLISH_AUCTION, CURRENCY_ETH, "");
        item.edition = EditionTerms(0, CURRENCY_ETH, bytes32(0), "");
    }
}
