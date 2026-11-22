// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StreamWorkFacts6529 } from "src/core/StreamWorkFacts6529.sol";
import { Stream6529 } from "src/core/Stream6529.sol";
import { Facts, Slots } from "src/interfaces/core/CoreTypes.sol";
import { License } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { FileRole, MediaFile } from "src/interfaces/types/ContentTypes.sol";
import { PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { CodeRenderer } from "../mocks/records/RulesMocks.sol";
import { RulesFixture } from "../records/RulesFixture.sol";

/// @notice A hostile RECORDS module: it calls every `StreamWorkFacts6529` function with any
///         arguments, swaps the token's RENDERER module, and records what each successful call
///         changed.
contract WorkFactsHandler is Test {
    StreamWorkFacts6529 internal facts;
    Stream6529 internal token;
    uint256[] internal ids;
    bytes32[] internal recordFiles;
    License[] internal licenses;
    address[] internal renderers;

    mapping(uint256 => address) public pinned;
    mapping(uint256 => address) public pinnedAtLock;
    /// @dev Bit `i` set once flag `i` (finalized, license lock, pin lock, on-chain) was seen.
    mapping(uint256 => uint256) public seen;
    mapping(uint256 => bytes32) public recordAtFinalize;

    /// @dev Folds what every work shows now into the ghosts (they only ever gain).
    modifier fold() {
        _;
        for (uint256 i; i < ids.length; ++i) {
            Facts memory f = facts.factsOf(address(token), ids[i]);
            bool[4] memory flags = [f.finalized, f.licenseLocked, f.repinLocked, f.onChainComplete];
            for (uint256 b; b < 4; ++b) {
                if (flags[b]) seen[ids[i]] |= 1 << b;
            }
            if (f.finalized && recordAtFinalize[ids[i]] == 0) {
                recordAtFinalize[ids[i]] = f.recordFileId;
            }
        }
    }

    constructor(
        StreamWorkFacts6529 facts_,
        Stream6529 token_,
        uint256[] memory ids_,
        bytes32[] memory recordFiles_,
        License[] memory licenses_,
        address[] memory renderers_
    ) {
        (facts, token, ids, recordFiles, renderers) =
        (facts_, token_, ids_, recordFiles_, renderers_);
        for (uint256 i; i < licenses_.length; ++i) {
            licenses.push(licenses_[i]);
        }
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function setRecord(uint256 w, uint256 r) external fold {
        try facts.setRecord(address(token), _id(w), recordFiles[r % recordFiles.length]) { }
            catch { }
    }

    function setLicense(uint256 w, uint256 l) external fold {
        try facts.setLicense(address(token), _id(w), licenses[l % licenses.length]) { } catch { }
    }

    function finalize(uint256 w) external fold {
        uint256 id = _id(w);
        try facts.finalize(address(token), id) {
            pinned[id] = token.moduleOf(Slots.RENDERER);
        } catch { }
    }

    function repin(uint256 w, uint256 r) external fold {
        uint256 id = _id(w);
        address next = renderers[r % renderers.length];
        try facts.repin(address(token), id, next) {
            pinned[id] = next;
        } catch { }
    }

    function lock(uint256 w, bool license, bool repin_) external fold {
        uint256 id = _id(w);
        try facts.lock(address(token), id, license, repin_) {
            if (facts.factsOf(address(token), id).repinLocked && pinnedAtLock[id] == address(0)) {
                pinnedAtLock[id] = pinned[id];
            }
        } catch { }
    }

    function markOnChainComplete(uint256 w) external fold {
        try facts.markOnChainComplete(address(token), _id(w)) { } catch { }
    }

    function swapRenderer(uint256 r) external fold {
        token.setModuleDelay(0);
        token.proposeModule(Slots.RENDERER, renderers[r % renderers.length]);
        token.activateModule(Slots.RENDERER);
    }
}

/// @notice Invariants of `StreamWorkFacts6529` under a hostile RECORDS module (256 runs, depth
///         128).
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract WorkFactsInvariantTest is RulesFixture {
    WorkFactsHandler internal handler;
    uint256[] internal ids;
    mapping(uint256 => bytes32) internal mediaAtOpen;
    mapping(uint256 => bool) internal cc0AtOpen;

    function setUp() public override {
        super.setUp();
        for (uint256 n = 1; n <= 3; ++n) {
            MediaFile[] memory media = new MediaFile[](2);
            media[0] = _mediaFile(n, FileRole.PRIMARY, true);
            media[1] = _mediaFile(100 + n, FileRole.PREVIEW, n != 2);
            PackageItem memory item = _item(n, media);
            if (n == 3) item.license = License("MIT", mitText);
            uint256 id = _mintItem(bare, item);
            facts.open(address(bare), id, item, media);
            ids.push(id);
            mediaAtOpen[id] = keccak256(abi.encode(facts.factsOf(address(bare), id).media));
            cc0AtOpen[id] = n != 3;
        }
        bytes32[] memory recordFiles = new bytes32[](3);
        recordFiles[0] = _record(50);
        recordFiles[1] = _record(51);
        recordFiles[2] = _file("{}", "application/json", false);
        License[] memory licenses = new License[](6);
        licenses[0] = _cc0();
        licenses[1] = License("cc0-1.0", cc0Text);
        licenses[2] = License("CC0-1.0", mitText);
        licenses[3] = License("MIT", mitText);
        licenses[4] = License("", cc0Text);
        licenses[5] = License("CC-BY-4.0", _file("unstored", "text/plain", false));
        address[] memory renderers = new address[](3);
        renderers[0] = address(new CodeRenderer(1));
        renderers[1] = address(new CodeRenderer(2));
        renderers[2] = address(renderer);
        handler = new WorkFactsHandler(facts, bare, ids, recordFiles, licenses, renderers);
        manager.grantRole(0, address(handler), 0);
        _install(address(bare), Slots.RECORDS, address(handler));
        targetContract(address(handler));
    }

    /// @dev Checks what the work shows now against the handler's ghosts.
    function _check(uint256 id) internal view {
        Facts memory f = facts.factsOf(address(bare), id);
        // Media never change after open.
        assertEq(keccak256(abi.encode(f.media)), mediaAtOpen[id], "media");
        // Flags never go back to false.
        bool[4] memory now_ = [f.finalized, f.licenseLocked, f.repinLocked, f.onChainComplete];
        uint256 seen = handler.seen(id);
        for (uint256 i; i < 4; ++i) {
            if ((seen >> i) & 1 == 1) assertTrue(now_[i], "a flag went back");
        }
        // The record never changes after finalize.
        if (f.finalized) {
            bytes32 record = handler.recordAtFinalize(id);
            if (record != 0) assertEq(f.recordFileId, record, "record after finalize");
        } else {
            assertEq(f.renderer, address(0), "a pin before finalize");
        }
        // A CC0 work stays CC0, with the CC0 text.
        if (cc0AtOpen[id]) {
            assertEq(WorksHashing.licenseKey(f.licenseId), WorksHashing.CC0_LICENSE_KEY, "CC0");
            assertEq(f.licenseTextFileId, cc0Text, "CC0 text");
        }
        // The renderer moves only by finalize or repin, and never past the lock.
        assertEq(f.renderer, handler.pinned(id), "renderer");
        if (f.repinLocked && handler.pinnedAtLock(id) != address(0)) {
            assertEq(f.renderer, handler.pinnedAtLock(id), "renderer past the lock");
        }
    }

    function invariant_TheFactsHold() public view {
        for (uint256 i; i < ids.length; ++i) {
            _check(ids[i]);
        }
    }
}
