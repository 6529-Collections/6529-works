// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { Payee } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem, Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { MockEditions, MockEntropy } from "../mocks/stream/StreamMocks.sol";
import { StreamFixture, StreamRoles } from "./StreamFixture.sol";

/// @notice Adds the records satellite, a real content store and a second party to the Stream
///         fixture, with helpers for files, items, registration and EIP-712 consents.
abstract contract RecordsFixture is StreamFixture {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint256 internal collaboratorKey = 0xB0B;
    address internal collaborator;
    address internal storageOperator = makeAddr("storageOperator");

    ContentStore internal store;
    MockEntropy internal entropy;
    WorkRecords internal records;

    function setUp() public virtual override {
        super.setUp();
        collaborator = vm.addr(collaboratorKey);
        artists.register(collaborator);
        store = new ContentStore();
        entropy = new MockEntropy();
        records =
            new WorkRecords(address(manager), address(stream), address(store), address(entropy));
        stream.bindRecords(address(records));
        editionsMock = new MockEditions();
        stream.bindEditions(address(editionsMock));
        _mapRecords(records.register.selector, StreamRoles.PLATFORM);
        _mapRecords(records.addLocator.selector, StreamRoles.PLATFORM);
        _mapRecords(records.relicense.selector, StreamRoles.PARAMETER_SETTER);
        _mapRecords(records.setRoyaltyRate.selector, StreamRoles.FUNDS_SETTER);
        _mapRecords(records.repinRenderer.selector, StreamRoles.SUCCESSOR_SETTER);
        _mapRecords(records.setPreferredKind.selector, StreamRoles.STORAGE_OPERATOR);
        _mapRecords(records.setCollectionPreferredKind.selector, StreamRoles.STORAGE_OPERATOR);
        _mapRecords(records.setFilePreference.selector, StreamRoles.STORAGE_OPERATOR);
        manager.grantRole(StreamRoles.STORAGE_OPERATOR, storageOperator, 0);
    }

    function _mapRecords(bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(address(records), selectors, role);
    }

    // ---------------------------------------------------------------------------------- files

    /// @dev Registers a one-chunk file and, if `upload`, stores its chunk.
    function _file(bytes memory data, string memory mime, bool upload)
        internal
        returns (bytes32 fileId)
    {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(data);
        fileId = store.registerManifest(
            hashes, data.length, IContentStore.Encoding.Identity, mime, sha256(data)
        );
        if (upload) store.writeChunk(data);
    }

    function _media(uint256 salt, bool upload) internal returns (bytes32) {
        return _file(abi.encode("media", salt), "image/png", upload);
    }

    function _upload(uint256 salt) internal {
        store.writeChunk(abi.encode("media", salt));
    }

    function _record(uint256 salt) internal returns (bytes32) {
        return _file(
            abi.encodePacked('{"title":"work ', vm.toString(salt), '"}'), "application/json", true
        );
    }

    // ---------------------------------------------------------------------------------- works

    /// @dev An item whose content and record are real content-store files, with the artist
    ///      and the collaborator as parties.
    function _recordsItem(uint256 salt, bool uploadMedia)
        internal
        returns (PackageItem memory item)
    {
        item = _item(salt);
        item.contentId = _media(salt, uploadMedia);
        item.metadataHash = _record(salt);
        item.parties = new Party[](2);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
        item.payees = new Payee[](2);
        item.payees[0] = Payee(0, collaborator, 20_000);
        item.payees[1] = Payee(uint256(uint160(artist)), address(0), 80_000);
    }

    function _one(bytes32 fileId) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = fileId;
    }

    /// @dev Mints and registers a single-file work; returns its token ID and item.
    function _work(uint256 salt) internal returns (uint256 tokenId, PackageItem memory item) {
        item = _recordsItem(salt, true);
        tokenId = _mint(item);
        records.register(tokenId, item, _one(item.contentId));
    }

    // ------------------------------------------------------------------------------- consents

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("6529 Stream Records"),
                keccak256("1"),
                block.chainid,
                address(records)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function _both(bytes32 structHash) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(collaboratorKey, structHash);
    }
}
