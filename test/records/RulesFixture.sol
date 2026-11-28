// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { StreamDirectory6529 } from "src/core/StreamDirectory6529.sol";
import { StreamEditions6529 } from "src/core/StreamEditions6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { StreamWorkFacts6529 } from "src/core/StreamWorkFacts6529.sol";
import { IArtistPayoutResolver } from "src/economics/interfaces/IArtistPayoutResolver.sol";
import { ISplitWallet } from "src/economics/interfaces/ISplitWallet.sol";
import { SplitLedger } from "src/economics/SplitLedger.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import {
    EditionTerms,
    License,
    PackageItem,
    Party,
    PartyRole,
    SaleTerms
} from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { WorkRules } from "src/records/WorkRules.sol";
import { WorkDelivery } from "src/stream/WorkDelivery.sol";
import { StreamTerms } from "src/terms/StreamTerms.sol";
import { CoreFixture } from "../mocks/core/CoreFixture.sol";
import {
    MockAccounts,
    MockIndependentStreamGate,
    MockRecords,
    MockRenderer,
    MockSale,
    MockTerms
} from "../mocks/core/CoreMocks.sol";
import { SigningAccounts } from "../mocks/records/RulesMocks.sol";

/// @notice The permanent core with the real record and royalty modules: `stream` uses
///         `WorkRules` (RECORDS) and `StreamTerms` (TERMS), `editions` uses `StreamTerms`, and
///         the directory's accounts module checks real signatures. `bare` is a second token on
///         the same `StreamWorkFacts6529` whose RECORDS and TERMS modules pass calls straight
///         through, for tests of `StreamWorkFacts6529` alone. The content store is real and the CC0
///         text is a real stored file. The test contract is the network.
abstract contract RulesFixture is CoreFixture {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint256 internal artistKey = 0xA11CE5;
    uint256 internal collaboratorKey = 0xB0B;
    address internal artist;
    address internal collaborator;
    address internal stranger = makeAddr("stranger");

    SigningAccounts internal signers;
    WorkRules internal rules;
    StreamTerms internal streamTerms;
    WorkDelivery internal delivery;
    SplitLedger internal ledger;
    Stream6529 internal bare;

    bytes32 internal cc0Text;
    bytes32 internal mitText;

    function setUp() public virtual override {
        vm.warp(1_800_000_000);
        artist = vm.addr(artistKey);
        collaborator = vm.addr(collaboratorKey);
        manager = new AccessManager(address(this));
        store = new ContentStore();
        cc0Text = _text("CC0 1.0 Universal");
        mitText = _text("MIT License");
        facts = new StreamWorkFacts6529(address(store), cc0Text);
        renderer = new MockRenderer();
        terms = new MockTerms();
        records = new MockRecords(facts);
        sale = new MockSale();
        accounts = new MockAccounts();
        gate = new MockIndependentStreamGate();
        signers = new SigningAccounts();
        signers.setWallet(uint160(artist), artist, true);
        signers.setWallet(uint160(collaborator), collaborator, true);
        directory = new StreamDirectory6529(
            address(manager), address(signers), address(gate), address(terms), address(records)
        );
        rules = new WorkRules(address(manager), address(facts), address(directory), address(0));
        address[] memory minters = new address[](1);
        minters[0] = address(sale);
        stream = new Stream6529(
            address(manager),
            address(facts),
            marketOwner,
            address(renderer),
            address(terms),
            address(rules),
            minters
        );
        editions = new StreamEditions6529(
            address(manager), address(stream), marketOwner, address(terms), minters
        );
        ledger = new SplitLedger(IArtistPayoutResolver(address(directory)), address(manager));
        streamTerms = new StreamTerms(
            address(manager),
            address(ledger),
            address(stream),
            address(editions),
            address(directory)
        );
        _install(address(stream), Slots.TERMS, address(streamTerms));
        _install(address(editions), Slots.TERMS, address(streamTerms));
        delivery =
            new WorkDelivery(address(manager), address(rules), address(facts), address(directory));
        rules.setDelivery(address(0), address(delivery));
        bare = new Stream6529(
            address(manager),
            address(facts),
            marketOwner,
            address(renderer),
            address(terms),
            address(records),
            minters
        );
        stream.createCollection("Genesis", bytes32(uint256(1)));
        bare.createCollection("Genesis", bytes32(uint256(1)));
    }

    /// @dev Installs a module at once (the network sets the wait to zero, then back).
    function _install(address token, bytes32 slot, address module) internal {
        Stream6529(token).setModuleDelay(0);
        Stream6529(token).proposeModule(slot, module);
        Stream6529(token).activateModule(slot);
        Stream6529(token).setModuleDelay(7 days);
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
            hashes, data.length, uint8(IContentStore.Encoding.Identity), mime, sha256(data)
        );
        if (upload) store.writeChunk(data);
    }

    function _text(bytes memory text) internal returns (bytes32) {
        return _file(text, "text/plain", true);
    }

    function _mediaBytes(uint256 salt) internal pure returns (bytes memory) {
        return abi.encode("media", salt);
    }

    function _mediaFile(uint256 salt, FileRole role, bool upload)
        internal
        returns (MediaFile memory)
    {
        bytes memory data = _mediaBytes(salt);
        return MediaFile(_file(data, "image/png", upload), sha256(data), uint8(role));
    }

    function _record(uint256 salt) internal returns (bytes32) {
        return _file(
            abi.encodePacked('{"name":"work ', vm.toString(salt), '"}'), "application/json", true
        );
    }

    function _single(uint256 salt) internal returns (MediaFile[] memory media) {
        media = new MediaFile[](1);
        media[0] = _mediaFile(salt, FileRole.PRIMARY, true);
    }

    // ---------------------------------------------------------------------------------- works

    function _cc0() internal view returns (License memory) {
        return License("CC0-1.0", cc0Text);
    }

    /// @dev An item committing to `media` with a stored record, the artist and the
    ///      collaborator as parties, and the CC0 license.
    function _item(uint256 salt, MediaFile[] memory media)
        internal
        returns (PackageItem memory item)
    {
        item.collectionId = 1;
        item.contentHash = media[0].sha256Hash;
        item.mediaHash = StreamHashing.mediaHash(media);
        item.recordFileId = _record(salt);
        item.parties = new Party[](2);
        item.parties[0] = Party(artist, uint8(PartyRole.ARTIST));
        item.parties[1] = Party(collaborator, uint8(PartyRole.COLLABORATOR));
        item.payees = new ISplitWallet.Payee[](2);
        item.payees[0] = ISplitWallet.Payee(0, collaborator, 20_000);
        item.payees[1] = ISplitWallet.Payee(uint256(uint160(artist)), address(0), 80_000);
        item.license = _cc0();
        item.sale = SaleTerms(bytes32("ENGLISH_AUCTION"), address(0), "");
        item.edition = EditionTerms(0, address(0), bytes32(0), "");
    }

    /// @dev Mints `item` into the sale contract's custody on `token`.
    function _mintItem(Stream6529 token, PackageItem memory item) internal returns (uint256) {
        MintFacts memory f;
        f.itemHash = StreamHashing.itemHash(item);
        f.contentHash = item.contentHash;
        f.artistId = uint160(artist);
        f.collectionId = item.collectionId;
        f.royaltyReceiver = address(0xFEE);
        f.royaltyRate = 6529;
        f.mediaHash = item.mediaHash;
        f.recordFileId = item.recordFileId;
        f.seller = address(0x5E11);
        return sale.mint(address(token), f);
    }

    /// @dev Mints a single-file work on `token` and opens its record.
    function _work(Stream6529 token, uint256 salt)
        internal
        returns (uint256 tokenId, PackageItem memory item, MediaFile[] memory media)
    {
        media = _single(salt);
        item = _item(salt, media);
        tokenId = _mintItem(token, item);
        facts.open(address(token), tokenId, item, media);
    }

    // ------------------------------------------------------------------------------- consents

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("6529 Stream Rules")),
                keccak256(bytes("1")),
                block.chainid,
                address(rules)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @dev A consent proof: the signing wallet, then its signature.
    function _sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(structHash));
        return abi.encodePacked(vm.addr(key), r, s, v);
    }

    function _both(bytes32 structHash) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(artistKey, structHash);
        sigs[1] = _sign(collaboratorKey, structHash);
    }

    function _state(uint256 tokenId) internal view returns (bytes32) {
        return rules.workStateHash(address(stream), tokenId);
    }
}
