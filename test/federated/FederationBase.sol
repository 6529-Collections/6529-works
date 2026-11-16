// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { FederatedDeployer } from "src/federated/FederatedDeployer.sol";
import { FederatedEditions } from "src/federated/FederatedEditions.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { FederationRegistry } from "src/federated/FederationRegistry.sol";
import { Roles } from "src/governance/Roles.sol";
import { IFederatedEditions } from "src/interfaces/IFederatedEditions.sol";
import { IFederatedStream } from "src/interfaces/IFederatedStream.sol";
import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { IFederatedToken } from "src/interfaces/IFederatedToken.sol";
import { IFederationRegistry } from "src/interfaces/IFederationRegistry.sol";
import { MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PRODUCT_FEDERATED, ProductEconomics } from "src/interfaces/types/EconomicsTypes.sol";
import { EditionTerms, ItemKind, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { SaleKind } from "src/interfaces/types/SaleTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { DeployV1 } from "script/DeployV1.sol";
import { IntegrationBase } from "../integration/IntegrationBase.sol";

/// @notice The real genesis stack, whose genesis wiring sets up the federation as ADR 0008
///         describes: the artist registry is bound to the federation registry and the English
///         auction points at it, the two v1 template versions (code hashes computed by
///         `DeployV1.templateCodeHash`, each bound to its `FederatedDeployer`) are approved, and
///         the English auction and the federated edition auction are admitted for new federated
///         works. Helpers deploy an artist's templates through their deployers, join (with the
///         artist's consent signature over the entry's facts), approve items and start sales.
abstract contract FederationBase is IntegrationBase {
    uint32 internal constant FED_SHARE = 10_000;
    uint32 internal constant RATE = 7_500;

    FederationRegistry internal fedRegistry;
    address internal fedArtist;
    FederatedStream internal fed;
    bytes32 internal streamHash;
    bytes32 internal editionsHash;
    /// @dev The deployer of each creation code (by its keccak256): the genesis deployers and
    ///      those tests create for custom templates.
    mapping(bytes32 creationHash => FederatedDeployer) internal deployerOf;
    uint256 private _copies;

    function setUp() public virtual override {
        super.setUp();
        deployerOf[keccak256(type(FederatedStream).creationCode)] =
        deployment.federatedStreamDeployer;
        deployerOf[keccak256(type(FederatedEditions).creationCode)] =
        deployment.federatedEditionsDeployer;
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

    /// @dev Has governance approve `codeHash` as `version` of `form`, bound to the deployer of
    ///      `creationCode` (created for it if none exists yet).
    function _approveTemplate(
        FederationRegistry reg,
        bytes memory creationCode,
        bytes32 codeHash,
        uint32 version,
        IFederationRegistry.Form form
    ) internal {
        address deployer = address(_deployerFor(creationCode));
        _govern(
            hotAdmin,
            address(reg),
            abi.encodeCall(reg.approveTemplate, (codeHash, deployer, version, form))
        );
    }

    /// @dev The deployer of `creationCode`, created on first use.
    function _deployerFor(bytes memory creationCode) internal returns (FederatedDeployer d) {
        d = deployerOf[keccak256(creationCode)];
        if (address(d) == address(0)) {
            d = new FederatedDeployer(creationCode);
            deployerOf[keccak256(creationCode)] = d;
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

    /// @dev Deploys `creationCode` with `config` through its deployer, as an artist does.
    function _copy(bytes memory creationCode, bytes memory config)
        internal
        returns (address token)
    {
        token = _deployerFor(creationCode).deploy(bytes32(++_copies), config);
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

    /// @dev What `artist` passes to join `token`: a registration signature if the artist has no
    ///      identity yet, and the listing consent over the entry's facts.
    function _joinRequest(address token, address artist)
        internal
        view
        returns (IFederationRegistry.Join memory j)
    {
        j.profileId = _profileId(artist);
        j.profileDocHash = _profileDoc(artist);
        j.deadline = uint64(block.timestamp + 1 days);
        if (artists.artistIdOf(artist) == 0) {
            j.registration = _sign(
                artist,
                artists.registrationDigest(artist, j.profileId, j.profileDocHash, j.deadline)
            );
        }
        j.consent = _sign(artist, _listingDigest(_listing(token, j.deadline)));
    }

    /// @dev The EIP-712 digest of a listing consent, computed as a wallet does from the artist
    ///      registry's domain (EIP-5267) and the golden typehash.
    function _listingDigest(IArtistRegistry.FederatedListing memory l)
        internal
        view
        returns (bytes32)
    {
        return
            _typedDigest(address(artists), keccak256(abi.encode(Typehashes.FEDERATED_LISTING, l)));
    }

    /// @dev The facts `token`'s listing will carry, as its artist consents to them.
    function _listing(address token, uint64 deadline)
        internal
        view
        returns (IArtistRegistry.FederatedListing memory l)
    {
        (,, uint256 artistId, uint32 share, address recipient, address partner) =
            IFederatedToken(token).federationTerms();
        bool editions = IERC165(token).supportsInterface(type(IFederatedEditions).interfaceId);
        l = IArtistRegistry.FederatedListing(
            artistId, token, editions ? 1 : 0, partner, share, recipient, deadline
        );
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
