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
import { SSTORE2 } from "src/libraries/SSTORE2.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The real genesis stack, whose genesis wiring sets up the federation as ADR 0008
///         describes: the artist registry is bound to the federation registry and the English
///         auction points at it, the two v1 template versions (code and creation code hashes
///         computed by `DeployV1.templateCodeHash`, the creation code published) are approved,
///         and the English auction and the federated edition auction are admitted for new
///         federated works. Helpers deploy an artist's templates through the deterministic
///         deployment proxy, join (with the artist's consent signature), approve items and start
///         sales.
abstract contract FederationBase is IntegrationBase {
    uint32 internal constant FED_SHARE = 10_000;
    uint32 internal constant RATE = 7_500;

    FederationRegistry internal fedRegistry;
    address internal fedArtist;
    FederatedStream internal fed;
    bytes32 internal streamHash;
    bytes32 internal editionsHash;
    /// @dev Each copy's CREATE2 salt and constructor arguments, which it presents to join.
    mapping(address token => bytes32) internal provenanceSalt;
    mapping(address token => bytes) internal provenanceConfig;
    uint256 private _copies;

    function setUp() public virtual override {
        super.setUp();
        if (CREATE2_FACTORY.code.length == 0) {
            vm.etch(
                CREATE2_FACTORY,
                hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
            );
        }
        fedArtist = _actor("federatedArtist");
        fedRegistry = deployment.federationRegistry;
        fed = _deployStream(fedArtist);
        streamHash = address(fed).codehash;
        editionsHash = address(_deployEditions(fedArtist, address(fed))).codehash;
        // Genesis approved exactly these: every copy runs the compiled runtime code.
        assertEq(streamHash, DeployV1.templateCodeHash("FederatedStream"));
        assertEq(editionsHash, DeployV1.templateCodeHash("FederatedEditions"));
    }

    // ------------------------------------------------------------------ governance

    /// @dev Maps a replacement federation registry's selectors to their genesis roles.
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
        _approveTemplate(
            reg, type(FederatedStream).creationCode, streamHash, 1, IFederationRegistry.Form.ERC721
        );
        _approveTemplate(
            reg,
            type(FederatedEditions).creationCode,
            editionsHash,
            1,
            IFederationRegistry.Form.ERC1155
        );
    }

    /// @dev Publishes `creationCode` in data contracts (reusing those already written) and has
    ///      governance approve `codeHash` with it as `version` of `form`.
    function _approveTemplate(
        FederationRegistry reg,
        bytes memory creationCode,
        bytes32 codeHash,
        uint32 version,
        IFederationRegistry.Form form
    ) internal {
        bytes32 creationHash = keccak256(creationCode);
        if (reg.codeOf(creationHash).length == 0) {
            address[] memory pointers = fedRegistry.codeOf(creationHash);
            if (pointers.length == 0) pointers = _store(creationCode);
            reg.publishCode(pointers);
        }
        _govern(
            hotAdmin,
            address(reg),
            abi.encodeCall(reg.approveTemplate, (codeHash, creationHash, version, form))
        );
    }

    /// @dev Writes `code` in `SSTORE2` chunks from this test.
    function _store(bytes memory code) internal returns (address[] memory pointers) {
        uint256 size = SSTORE2.MAX_CHUNK_LENGTH;
        pointers = new address[]((code.length + size - 1) / size);
        for (uint256 i; i < pointers.length; ++i) {
            uint256 start = i * size;
            uint256 end = start + size < code.length ? start + size : code.length;
            bytes memory chunk = new bytes(end - start);
            for (uint256 j; j < chunk.length; ++j) {
                chunk[j] = code[start + j];
            }
            pointers[i] = SSTORE2.write(chunk);
        }
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
        return _deployStream(_streamConfig(artist));
    }

    function _deployStream(IFederatedStream.Config memory c) internal returns (FederatedStream) {
        return FederatedStream(_copy(type(FederatedStream).creationCode, abi.encode(c)));
    }

    function _editionsConfig(address artist, address partner)
        internal
        view
        returns (IFederatedEditions.Config memory)
    {
        ProductEconomics memory e = economics.economics(PRODUCT_FEDERATED);
        return IFederatedEditions.Config(
            "Artist Editions",
            "ARTE",
            address(artists),
            address(splitFactory),
            uint160(artist),
            e.feeShare,
            e.feeRecipient,
            partner,
            artist
        );
    }

    function _deployEditions(address artist, address partner) internal returns (FederatedEditions) {
        return FederatedEditions(
            _copy(
                type(FederatedEditions).creationCode, abi.encode(_editionsConfig(artist, partner))
            )
        );
    }

    /// @dev Deploys `creationCode` with `config` through the deterministic deployment proxy, as
    ///      an artist does, and records the salt and arguments the copy presents to join.
    function _copy(bytes memory creationCode, bytes memory config)
        internal
        returns (address token)
    {
        bytes32 salt = bytes32(++_copies);
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(bytes.concat(salt, creationCode, config));
        require(ok && ret.length == 20, "deployment failed");
        token = address(bytes20(ret));
        provenanceSalt[token] = salt;
        provenanceConfig[token] = config;
    }

    /// @dev `token` joins, creating `artist`'s identity from its own signature if needed.
    function _join(address token, address artist) internal {
        _join(token, artist, "");
    }

    /// @dev `_join`, expecting the join to revert with `reason` when it is not empty.
    function _join(address token, address artist, bytes memory reason) internal {
        IFederationRegistry.Join memory j = _joinRequest(token, artist);
        if (reason.length != 0) vm.expectRevert(reason);
        vm.prank(artist);
        IFederatedStream(token).joinFederation(j);
    }

    /// @dev What `artist` passes to join `token`: its recorded provenance, a registration
    ///      signature if the artist has no identity yet, and the listing consent.
    function _joinRequest(address token, address artist)
        internal
        view
        returns (IFederationRegistry.Join memory j)
    {
        j.salt = provenanceSalt[token];
        j.config = provenanceConfig[token];
        j.profileId = _profileId(artist);
        j.profileDocHash = _profileDoc(artist);
        j.deadline = uint64(block.timestamp + 1 days);
        if (artists.artistIdOf(artist) == 0) {
            j.registration = _sign(
                artist,
                artists.registrationDigest(artist, j.profileId, j.profileDocHash, j.deadline)
            );
        }
        j.consent = _sign(artist, artists.listingDigest(uint160(artist), token, j.deadline));
    }

    /// @dev An empty join request.
    function _noJoin() internal pure returns (IFederationRegistry.Join memory none) {
        return none;
    }

    /// @dev An artist's pair, both halves linked and joined (the editions first).
    function _pair(address artist) internal returns (FederatedStream s, FederatedEditions ed) {
        s = _deployStream(artist);
        ed = _deployEditions(artist, address(s));
        vm.prank(artist);
        s.linkEditions(address(ed));
        _join(address(ed), artist);
        _join(address(s), artist);
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
