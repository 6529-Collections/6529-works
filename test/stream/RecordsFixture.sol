// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ContentStore } from "src/content/ContentStore.sol";
import { Roles } from "src/governance/Roles.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { Payee } from "src/interfaces/types/EconomicsTypes.sol";
import { PackageItem, Party, PartyRole } from "src/interfaces/types/PackageTypes.sol";
import { Typehashes } from "src/interfaces/types/Typehashes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { WorkRecords } from "src/stream/WorkRecords.sol";
import { StreamFixture } from "./StreamFixture.sol";

/// @notice Adds the records satellite, a real content store and a second party to the Stream
///         fixture, with helpers for files, items, opening records and EIP-712 consents.
abstract contract RecordsFixture is StreamFixture {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint256 internal collaboratorKey = 0xB0B;
    address internal collaborator;
    address internal storageOperator = makeAddr("storageOperator");

    ContentStore internal store;
    WorkRecords internal records;

    function setUp() public virtual override {
        super.setUp();
        collaborator = vm.addr(collaboratorKey);
        artists.register(collaborator);
        store = new ContentStore();
        records =
            new WorkRecords(address(manager), address(stream), address(store), _license("CC0-1.0"));
        stream.bind(address(records), address(editionsMock));
        _map(address(records), records.addLocator.selector, Roles.PLATFORM);
        _map(address(records), records.relicense.selector, Roles.PARAMETER_SETTER);
        _map(address(records), records.setRoyaltyRate.selector, Roles.FUNDS_SETTER);
        _map(address(records), records.repinRenderer.selector, Roles.SUCCESSOR_SETTER);
        _map(address(records), records.setPreferredKind.selector, Roles.STORAGE_OPERATOR);
        _map(address(records), records.setCollectionPreferredKind.selector, Roles.STORAGE_OPERATOR);
        _map(address(records), records.setFilePreference.selector, Roles.STORAGE_OPERATOR);
        manager.grantRole(Roles.STORAGE_OPERATOR, storageOperator, 0);
    }

    // ---------------------------------------------------------------------------------- files

    /// @dev Registers a one-chunk file declaring `sha256(data)` and, if `upload`, stores it.
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

    function _mediaBytes(uint256 salt) internal pure returns (bytes memory) {
        return abi.encode("media", salt);
    }

    function _mediaFile(uint256 salt, FileRole role, bool upload)
        internal
        returns (MediaFile memory)
    {
        bytes memory data = _mediaBytes(salt);
        return MediaFile(_file(data, "image/png", upload), sha256(data), role);
    }

    function _upload(uint256 salt) internal {
        store.writeChunk(_mediaBytes(salt));
    }

    function _record(uint256 salt) internal returns (bytes32) {
        return _file(
            abi.encodePacked('{"name":"work ', vm.toString(salt), '"}'), "application/json", true
        );
    }

    // ---------------------------------------------------------------------------------- works

    /// @dev An item committing to `media`, with a real record file and the artist and the
    ///      collaborator as parties.
    function _recordsItem(uint256 salt, MediaFile[] memory media)
        internal
        returns (PackageItem memory item)
    {
        item = _item(salt);
        item.contentHash = media[0].sha256Hash;
        item.mediaHash = WorksHashing.mediaHash(media);
        item.recordFileId = _record(salt);
        item.parties = new Party[](2);
        item.parties[0] = Party(artist, PartyRole.ARTIST);
        item.parties[1] = Party(collaborator, PartyRole.COLLABORATOR);
        item.payees = new Payee[](2);
        item.payees[0] = Payee(0, collaborator, 20_000);
        item.payees[1] = Payee(uint256(uint160(artist)), address(0), 80_000);
    }

    function _single(uint256 salt, bool upload) internal returns (MediaFile[] memory media) {
        media = new MediaFile[](1);
        media[0] = _mediaFile(salt, FileRole.PRIMARY, upload);
    }

    /// @dev Mints a single-file work without opening its record.
    function _minted(uint256 salt, bool upload)
        internal
        returns (uint256 tokenId, PackageItem memory item, MediaFile[] memory media)
    {
        media = _single(salt, upload);
        item = _recordsItem(salt, media);
        tokenId = _mint(item);
    }

    /// @dev Mints a single-file work (media uploaded) and opens its record.
    function _work(uint256 salt) internal returns (uint256 tokenId, PackageItem memory item) {
        MediaFile[] memory media;
        (tokenId, item, media) = _minted(salt, true);
        records.openRecord(tokenId, item, media);
    }

    // ------------------------------------------------------------------------------- consents

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(Typehashes.WORK_RECORDS_NAME)),
                keccak256(bytes(Typehashes.DOMAIN_VERSION)),
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
