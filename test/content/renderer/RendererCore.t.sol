// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { CoreFixture } from "../../mocks/core/CoreFixture.sol";
import { HostileDelivery } from "./RendererCoreMocks.sol";
import { Renderer } from "src/content/Renderer.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IStatementLog } from "src/interfaces/IStatementLog.sol";
import { MintFacts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { License, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { StreamHashing } from "src/interfaces/types/StreamHashing.sol";
import { BoundedCall } from "src/libraries/BoundedCall.sol";

/// @dev A RECORDS module with no rules: passes calls to `IWorkFacts`, and names a delivery
///      contract (`IWorkRules.delivery`) the test sets.
contract RecordsWithDelivery {
    IWorkFacts public immutable facts;
    address public delivery;

    constructor(IWorkFacts facts_) {
        facts = facts_;
    }

    function setDelivery(address next) external {
        delivery = next;
    }

    function finalize(address token, uint256 id) external {
        facts.finalize(token, id);
    }
}

/// @notice The renderer against the real permanent core (`CoreFixture`: the real `Stream6529`,
///         `StreamEditions6529`, `StreamWorkFacts6529` and `ContentStore`), installed as the
///         Stream's RENDERER module and pinned at finalize: what it reads through the plain views,
///         the locator check against a finalized work, and the cost of `tokenURI`.
contract RendererCoreTest is CoreFixture {
    uint256 internal constant BUDGET = 8_000_000;
    bytes internal constant PNG = hex"89504e470d0a1a0a0000000d49484452";
    bytes internal constant RECORD =
        '{"artists":["Ada"],"description":"D","dimensions":"","medium":"Oil","name":"Title","year":2026}';

    Renderer internal real;
    RecordsWithDelivery internal rules;
    HostileDelivery internal delivery;
    bytes32 internal primary;
    bytes32 internal recordFile;
    bytes32 internal licenseText;

    function setUp() public override {
        super.setUp();
        real = new Renderer(store, IStatementLog(address(0)), 262_144);
        rules = new RecordsWithDelivery(facts);
        delivery = new HostileDelivery();
        rules.setDelivery(address(delivery));
        stream.setModuleDelay(0);
        stream.proposeModule(Slots.RENDERER, address(real));
        stream.activateModule(Slots.RENDERER);
        stream.proposeModule(Slots.RECORDS, address(rules));
        stream.activateModule(Slots.RECORDS);
        primary = _upload(PNG, "image/png");
        recordFile = _upload(RECORD, "application/json");
        licenseText = _upload("MIT License text.", "text/plain");
    }

    /// @dev Stores a one-chunk `Identity` file and uploads it.
    function _upload(bytes memory data, string memory mime) internal returns (bytes32 fileId) {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(data);
        fileId = store.registerManifest(
            hashes, data.length, uint8(IContentStore.Encoding.Identity), mime, sha256(data)
        );
        store.writeChunk(data);
    }

    function _item() internal view returns (PackageItem memory item, MediaFile[] memory media) {
        media = new MediaFile[](1);
        media[0] = MediaFile(primary, sha256(PNG), uint8(FileRole.PRIMARY));
        item.collectionId = 1;
        item.contentHash = sha256(PNG);
        item.mediaHash = keccak256(abi.encode(StreamHashing.MEDIA_DOMAIN, media));
        item.recordFileId = recordFile;
        item.license = License("MIT", licenseText);
    }

    /// @dev Mints a work of the item, opens its record, and (if `finalize`) finalizes it, which
    ///      pins the renderer.
    function _work(bool open, bool finalize) internal returns (uint256 id) {
        (PackageItem memory item, MediaFile[] memory media) = _item();
        MintFacts memory f = _facts(1);
        f.itemHash = StreamHashing.itemHash(item);
        f.contentHash = sha256(PNG);
        id = sale.mint(address(stream), f);
        if (open) facts.open(address(stream), id, item, media);
        if (finalize) rules.finalize(address(stream), id);
    }

    /// @dev The JSON of a `data:application/json;utf8,` URI, with `%25` and `%23` decoded.
    function _json(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        uint256 i = bytes("data:application/json;utf8,").length;
        bytes memory out = new bytes(b.length - i);
        uint256 n;
        for (; i < b.length; ++i) {
            if (b[i] == "%" && i + 2 < b.length && b[i + 1] == "2") {
                out[n++] = b[i + 2] == "3" ? bytes1("#") : bytes1("%");
                i += 2;
            } else {
                out[n++] = b[i];
            }
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
        return string(out);
    }

    function test_AFinalizedWorkRendersFromThePlainViews() public {
        uint256 id = _work(true, true);
        assertEq(stream.rendererOf(id), address(real), "pinned");
        string memory j = _json(stream.tokenURI(id));
        assertEq(vm.parseJsonString(j, ".name"), "Title");
        assertEq(vm.parseJsonString(j, ".license"), "MIT");
        assertEq(vm.parseJsonString(j, ".content_hash"), vm.toString(sha256(PNG)));
        assertEq(vm.parseJsonString(j, ".license_text_file"), vm.toString(licenseText));
        // Not marked on-chain complete: the primary is served by locator.
        assertEq(vm.parseJsonString(j, ".image"), "ar://honest");
        assertEq(vm.parseJsonString(j, ".attributes[3].value"), "Genesis");
        assertEq(vm.parseJsonUint(j, ".attributes[4].value"), 1, "serial");
    }

    function test_AWorkWithoutARecordIsCoreOnly() public {
        uint256 id = _work(false, false);
        string memory j = _json(stream.tokenURI(id));
        assertEq(vm.parseJsonString(j, ".record_status"), "not_open");
        assertEq(vm.parseJsonString(j, ".name"), "Genesis #1");
        assertEq(vm.parseJsonString(j, ".attributes[0].value"), "0x0a11ce", "the artist ID");
    }

    /// @dev An edition's ID is its master's token ID; the editions token is read through
    ///      `IEditions.stream()`.
    function test_AnEditionRendersItsMaster() public {
        uint256 id = _work(true, true);
        sale.createEdition(address(editions), id, 10, address(0xFEE), 500);
        string memory j = _json(editions.uri(id));
        assertEq(vm.parseJsonString(j, ".name"), "Title");
        assertTrue(vm.keyExistsJson(j, ".attributes[5]"));
        assertEq(vm.parseJsonString(j, ".attributes[5].trait_type"), "Edition of");
        assertEq(vm.parseJsonUint(j, ".attributes[5].value"), id);
    }

    /// @dev A finalized work whose delivery contract lies, answers too much or garbage, or
    ///      reverts, still renders, without the locator; one that burns all its gas is a
    ///      shortfall (the gas rule). A delivery contract can never change anything else.
    function test_HostileDeliveryAgainstAFinalizedWork() public {
        uint256 id = _work(true, true);
        string memory honest = stream.tokenURI(id);
        assertEq(vm.parseJsonString(_json(honest), ".image"), "ar://honest");
        rules.setDelivery(address(0));
        string memory none = stream.tokenURI(id);
        assertFalse(vm.keyExistsJson(_json(none), ".image"));
        rules.setDelivery(address(delivery));
        for (
            uint256 m = uint256(HostileDelivery.Mode.QUOTE);
            m <= uint256(HostileDelivery.Mode.REVERT);
            ++m
        ) {
            delivery.setMode(HostileDelivery.Mode(m), 0);
            assertEq(stream.tokenURI(id), none, vm.toString(m));
        }
        delivery.setMode(HostileDelivery.Mode.BURN_SOME, 500_000);
        assertEq(stream.tokenURI(id), honest, "dearer, the same");
        delivery.setMode(HostileDelivery.Mode.BURN_ALL, 0);
        vm.expectRevert(
            abi.encodeWithSelector(BoundedCall.BoundedCallShortfall.selector, address(delivery))
        );
        stream.tokenURI(id);
        // A URI of exactly the limit is printed; one byte more is not.
        delivery.setMode(HostileDelivery.Mode.HONEST, 0);
        bytes memory longest = new bytes(2_048);
        for (uint256 i; i < longest.length; ++i) {
            longest[i] = "a";
        }
        delivery.setUri(string(longest));
        assertEq(vm.parseJsonString(_json(stream.tokenURI(id)), ".image"), string(longest));
    }

    /// @dev `tokenURI` of a finalized work with its primary inlined, through the real core: well
    ///      within the 8M budget (the worst case is measured in `RendererGas.t.sol`).
    function test_TokenUriGas() public {
        uint256 id = _work(true, true);
        facts.markOnChainComplete(address(stream), id);
        uint256 before = gasleft();
        string memory uri = stream.tokenURI(id);
        uint256 used = before - gasleft();
        assertTrue(bytes(uri).length != 0);
        assertLt(used, BUDGET);
        emit log_named_uint("tokenURI gas, finalized, inlined, real core", used);
        rules.setDelivery(address(0));
        string memory j = _json(stream.tokenURI(id));
        assertEq(
            vm.parseJsonString(j, ".image"),
            string.concat("data:image/png;base64,", "iVBORw0KGgoAAAANSUhEUg==")
        );
    }
}
