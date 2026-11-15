// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Roles } from "src/governance/Roles.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PRODUCT_FEDERATED, ProductEconomics } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The real genesis stack plus a governed federation registry, wired as ADR 0008
///         describes: the artist registry and the English auction point at it, the two v1
///         template code hashes are approved, the English auction is admitted for new federated
///         works. Helpers deploy an artist's templates, join, approve items and start sales.
abstract contract FederationBase is IntegrationBase {
    uint32 internal constant FED_SHARE = 10_000;
    uint32 internal constant RATE = 7_500;

    FederationRegistry internal fedRegistry;
    address internal fedArtist;
    FederatedStream internal fed;
    bytes32 internal streamHash;
    bytes32 internal editionsHash;

    function setUp() public virtual override {
        super.setUp();
        fedArtist = _actor("federatedArtist");
        fedRegistry = new FederationRegistry(address(manager), address(artists), address(economics));
        _mapRegistryRoles(address(fedRegistry));
        _govern(
            hotAdmin,
            address(artists),
            abi.encodeCall(artists.bindFederationRegistry, (address(fedRegistry)))
        );
        _govern(
            hotAdmin,
            address(auction),
            abi.encodeCall(auction.setFederationRegistry, (address(0), address(fedRegistry)))
        );
        fed = _deployStream(fedArtist);
        streamHash = address(fed).codehash;
        editionsHash = address(_deployEditions(fedArtist, address(fed))).codehash;
        _approveTemplates(fedRegistry);
        _govern(
            hotAdmin,
            address(fedRegistry),
            abi.encodeCall(fedRegistry.setAdapter, (address(auction), true))
        );
    }

    // ------------------------------------------------------------------ governance

    /// @dev Maps a federation registry's selectors to their genesis roles.
    function _mapRegistryRoles(address reg) internal {
        bytes4[] memory successor = new bytes4[](3);
        successor[0] = FederationRegistry.approveTemplate.selector;
        successor[1] = FederationRegistry.revokeTemplate.selector;
        successor[2] = FederationRegistry.setAdapter.selector;
        bytes4[] memory parameter = new bytes4[](2);
        parameter[0] = FederationRegistry.resumeTemplate.selector;
        parameter[1] = FederationRegistry.setStatus.selector;
        bytes4[] memory guardian = new bytes4[](1);
        guardian[0] = FederationRegistry.suspendTemplate.selector;
        _mapRole(reg, successor, Roles.SUCCESSOR_SETTER);
        _mapRole(reg, parameter, Roles.PARAMETER_SETTER);
        _mapRole(reg, guardian, Roles.GUARDIAN);
    }

    function _mapRole(address reg, bytes4[] memory selectors, uint64 role) internal {
        _govern(
            hotAdmin,
            address(manager),
            abi.encodeCall(IAccessManager.setTargetFunctionRole, (reg, selectors, role))
        );
    }

    function _approveTemplates(FederationRegistry reg) internal {
        _govern(
            hotAdmin,
            address(reg),
            abi.encodeCall(reg.approveTemplate, (streamHash, 1, IFederationRegistry.Form.ERC721))
        );
        _govern(
            hotAdmin,
            address(reg),
            abi.encodeCall(reg.approveTemplate, (editionsHash, 1, IFederationRegistry.Form.ERC1155))
        );
    }

    // ------------------------------------------------------------------ templates

    function _streamConfig(address artist)
        internal
        view
        returns (IFederatedStream.Config memory c)
    {
        ProductEconomics memory e = economics.economics(PRODUCT_FEDERATED);
        c = IFederatedStream.Config(
            "Artist Works",
            "ARTW",
            address(artists),
            address(splitFactory),
            address(store),
            uint160(artist),
            e.feeShare,
            e.feeRecipient,
            address(renderer),
            address(renderer).codehash,
            artist
        );
    }

    function _deployStream(address artist) internal returns (FederatedStream) {
        return new FederatedStream(_streamConfig(artist));
    }

    function _deployEditions(address artist, address partner) internal returns (FederatedEditions) {
        ProductEconomics memory e = economics.economics(PRODUCT_FEDERATED);
        return new FederatedEditions(
            IFederatedEditions.Config(
                "Artist Editions",
                "ARTE",
                address(artists),
                address(splitFactory),
                uint160(artist),
                e.feeShare,
                e.feeRecipient,
                partner,
                artist
            )
        );
    }

    /// @dev `token` joins, creating `artist`'s identity from its own signature if needed.
    function _join(address token, address artist) internal {
        _join(token, artist, "");
    }

    /// @dev `_join`, expecting the join to revert with `reason` when it is not empty.
    function _join(address token, address artist, bytes memory reason) internal {
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig;
        if (artists.artistIdOf(artist) == 0) {
            sig = _sign(
                artist,
                artists.registrationDigest(
                    artist, _profileId(artist), _profileDoc(artist), deadline
                )
            );
        }
        if (reason.length != 0) vm.expectRevert(reason);
        vm.prank(artist);
        IFederatedStream(token)
            .joinFederation(_profileId(artist), _profileDoc(artist), deadline, sig);
    }

    /// @dev An artist's pair, both halves linked and joined.
    function _pair(address artist) internal returns (FederatedStream s, FederatedEditions ed) {
        s = _deployStream(artist);
        ed = _deployEditions(artist, address(s));
        vm.prank(artist);
        s.linkEditions(address(ed));
        _join(address(s), artist);
        _join(address(ed), artist);
    }

    // ------------------------------------------------------------------ works and sales

    /// @dev A federated ORIGINAL by `artist` (sole payee), sold in ETH by the English auction.
    function _fedWork(address artist) internal returns (Work memory w) {
        w = _work(artist, 0);
    }

    /// @dev A federated EDITION_MASTER by `artist`, its edition sold by the edition auction.
    function _fedMaster(address artist, uint32 maxCount) internal returns (Work memory w) {
        w = _work(artist, 0);
        w.item.kind = uint8(ItemKind.EDITION_MASTER);
        w.item.edition = EditionTerms(maxCount, address(0), SaleKind.UNIFORM_AUCTION, "");
    }

    /// @dev The mint request an adapter forwards: `abi.encode(FederatedMint(item, media))`.
    function _mintData(Work memory w) internal pure returns (bytes memory) {
        return abi.encode(IFederatedStream.FederatedMint(w.item, w.media));
    }

    function _itemHash(Work memory w) internal pure returns (bytes32) {
        return WorksHashing.itemHash(w.item);
    }

    /// @dev The artist approves `w` with `rate`; anyone starts it on the English auction.
    function _startFed(FederatedStream token, address artist, Work memory w, uint32 rate)
        internal
        returns (uint256 saleId, uint256 tokenId)
    {
        vm.prank(artist);
        token.approveItem(_itemHash(w), rate);
        saleId = auction.start(address(token), _mintData(w));
        tokenId = auction.auction(saleId).tokenId;
    }

    function _startFed(Work memory w) internal returns (uint256 saleId, uint256 tokenId) {
        return _startFed(fed, fedArtist, w, RATE);
    }

    function _joinedFed() internal {
        _join(address(fed), fedArtist);
    }

    function _mediaOf(Work memory w) internal pure returns (MediaFile[] memory) {
        return w.media;
    }

    function _itemOf(Work memory w) internal pure returns (PackageItem memory) {
        return w.item;
    }
}
