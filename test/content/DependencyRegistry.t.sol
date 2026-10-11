// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { ContentBase } from "./ContentBase.sol";
import { ContentStore } from "src/content/ContentStore.sol";
import { DependencyRegistry } from "src/content/DependencyRegistry.sol";
import { IContentStore } from "src/interfaces/IContentStore.sol";
import { IDependencyRegistry } from "src/interfaces/IDependencyRegistry.sol";

contract DependencyRegistryTest is ContentBase {
    /// @dev Local stand-in for the registrar role. TODO(governance lane): use the role from
    ///      `src/governance/Roles.sol` once it lands.
    uint64 internal constant REGISTRAR = 1;
    bytes32 internal constant THREE = "three";
    bytes32 internal constant R170 = "r170";
    bytes32 internal constant R171 = "r171";
    string internal constant JS = "text/javascript";

    AccessManager internal manager;
    DependencyRegistry internal registry;
    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal stranger = makeAddr("stranger");

    bytes internal library_;
    bytes32 internal fileId;

    function setUp() public {
        manager = new AccessManager(admin);
        store = new ContentStore();
        registry = new DependencyRegistry(address(manager), store);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = registry.register.selector;
        selectors[1] = registry.deprecate.selector;
        vm.startPrank(admin);
        manager.setTargetFunctionRole(address(registry), selectors, REGISTRAR);
        manager.grantRole(REGISTRAR, registrar, 0);
        vm.stopPrank();

        library_ = _data(CHUNK + 4000, 1); // two chunks, stored gzipped
        fileId = _publish(library_, IContentStore.Encoding.Gzip, JS);
    }

    // ---------------------------------------------------------------- register

    function test_Register_ResolvesWithManifestFlags() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit IDependencyRegistry.DependencyRegistered(THREE, R170, fileId);
        vm.prank(registrar);
        registry.register(THREE, R170, fileId);

        (bytes32 resolved, bool deprecated, IContentStore.FileInfo memory file) =
            registry.resolve(THREE, R170);
        assertEq(resolved, fileId);
        assertFalse(deprecated);
        assertTrue(file.encoding == IContentStore.Encoding.Gzip, "gzip flag from the manifest");
        assertEq(file.mimeType, JS, "MIME type from the manifest");
        assertEq(file.length, library_.length);
        assertEq(store.read(resolved, 0, file.length), library_);
        assertEq(address(registry.store()), address(store));
    }

    function test_Register_OnlyTheRegistrarRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        registry.register(THREE, R170, fileId);

        // Even the manager's admin must hold the function's role to call it.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, admin)
        );
        vm.prank(admin);
        registry.register(THREE, R170, fileId);
    }

    function test_Register_VersionsAreImmutable() public {
        vm.startPrank(registrar);
        registry.register(THREE, R170, fileId);

        bytes32 other = _publish(_data(500, 2), IContentStore.Encoding.Identity, JS);
        bytes memory exists = abi.encodeWithSelector(
            IDependencyRegistry.DependencyVersionExists.selector, THREE, R170
        );
        vm.expectRevert(exists);
        registry.register(THREE, R170, other); // repoint
        vm.expectRevert(exists);
        registry.register(THREE, R170, fileId); // even the same file again
        vm.stopPrank();

        (bytes32 resolved,,) = registry.resolve(THREE, R170);
        assertEq(resolved, fileId, "unchanged");
    }

    function test_Register_NamesAndVersionsAreIndependent() public {
        bytes32 other = _publish(_data(500, 3), IContentStore.Encoding.Identity, JS);
        vm.startPrank(registrar);
        registry.register(THREE, R170, fileId);
        registry.register(THREE, R171, other);
        registry.register("p5", R170, fileId); // the same file under another name
        vm.stopPrank();

        (bytes32 a,,) = registry.resolve(THREE, R170);
        (bytes32 b,,) = registry.resolve(THREE, R171);
        (bytes32 c,,) = registry.resolve("p5", R170);
        assertEq(a, fileId);
        assertEq(b, other);
        assertEq(c, fileId);
    }

    function test_Register_RequiresCompleteContent() public {
        bytes memory file = _data(2 * CHUNK, 4);
        (bytes32 id, bytes[] memory chunks,) = _declare(file, IContentStore.Encoding.Gzip, JS);
        store.writeChunk(chunks[1]); // one of two chunks

        vm.expectRevert(
            abi.encodeWithSelector(IDependencyRegistry.DependencyContentIncomplete.selector, id)
        );
        vm.prank(registrar);
        registry.register(THREE, R170, id);

        // Anyone can finish the upload; then the version can be registered.
        vm.prank(stranger);
        store.writeChunk(chunks[0]);
        vm.prank(registrar);
        registry.register(THREE, R170, id);
    }

    function test_Register_UnknownFileReverts() public {
        bytes32 id = keccak256("not a file");
        vm.expectRevert(abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, id));
        vm.prank(registrar);
        registry.register(THREE, R170, id);
        vm.expectRevert(
            abi.encodeWithSelector(IContentStore.ContentFileUnknown.selector, bytes32(0))
        );
        vm.prank(registrar);
        registry.register(THREE, R170, bytes32(0));
    }

    function test_Register_LabelExamples() public {
        bytes32[14] memory bad = [
            bytes32(0), // empty
            bytes32(hex"00746872656500"), // leading zero
            bytes32("a b"), // space
            bytes32("a/b"), // slash
            bytes32("a\"b"), // quote
            bytes32("a\nb"), // control character
            bytes32(hex"610062"), // byte after a zero byte
            bytes32(hex"c3a9"), // non-ASCII
            bytes32("Three"), // uppercase: names have one canonical spelling
            bytes32("r170+build"), // plus sign
            // Index 31 is the last byte, and it is checked like every other:
            bytes32("abcdefghijklmnopqrstuvwxyz01234!"), // bad character
            bytes32("abcdefghijklmnopqrstuvwxyz01234A"), // uppercase
            bytes32("abcdefghijklmnopqrstuvwxyz01234+"), // plus sign
            bytes32(abi.encodePacked("abc", bytes28(0), bytes1("z"))) // text after zero padding
        ];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory err =
                abi.encodeWithSelector(IDependencyRegistry.DependencyLabelInvalid.selector, bad[i]);
            vm.startPrank(registrar);
            vm.expectRevert(err);
            registry.register(bad[i], R170, fileId);
            vm.expectRevert(err);
            registry.register(THREE, bad[i], fileId);
            vm.stopPrank();
        }
        bytes32[6] memory good = [
            bytes32("1.9.0"),
            bytes32("r170"),
            bytes32("p5.min-js_1"),
            bytes32("a"),
            bytes32("abcdefghijklmnopqrstuvwxyz012345"), // all 32 bytes used
            bytes32("abcdefghijklmnopqrstuvwxyz0123._") // punctuation at the last byte
        ];
        for (uint256 i; i < good.length; ++i) {
            vm.prank(registrar);
            registry.register(good[i], good[i], fileId);
        }
    }

    /// @dev A bad byte at every position of an otherwise valid 32-byte label is refused, so no
    ///      index, the last one included, escapes the check.
    function testFuzz_Register_RejectsABadByteAtAnyIndex(uint8 index, uint8 bad) public {
        index = uint8(bound(index, 0, 31));
        bytes memory alphabet = "abcdefghijklmnopqrstuvwxyz0123456789._-";
        for (uint256 i; i < alphabet.length; ++i) {
            vm.assume(bad != uint8(alphabet[i]));
        }
        vm.assume(bad != 0); // a zero byte is padding, not a bad byte
        bytes memory raw = "abcdefghijklmnopqrstuvwxyz012345";
        raw[index] = bytes1(bad);
        bytes32 label = bytes32(raw);
        vm.expectRevert(
            abi.encodeWithSelector(IDependencyRegistry.DependencyLabelInvalid.selector, label)
        );
        vm.prank(registrar);
        registry.register(label, R170, fileId);
    }

    function testFuzz_Register_LabelValidity(bytes32 label) public {
        bool valid = _wellFormed(label);
        if (!valid) {
            vm.expectRevert(
                abi.encodeWithSelector(IDependencyRegistry.DependencyLabelInvalid.selector, label)
            );
        }
        vm.prank(registrar);
        registry.register(label, R170, fileId);
    }

    function testFuzz_Register_AcceptsWellFormedLabels(uint256 seed, uint256 length) public {
        bytes memory alphabet = "abcdefghijklmnopqrstuvwxyz0123456789._-";
        length = bound(length, 1, 32);
        bytes memory raw = new bytes(32);
        for (uint256 i; i < length; ++i) {
            raw[i] = alphabet[uint256(keccak256(abi.encode(seed, i))) % alphabet.length];
        }
        bytes32 label = bytes32(raw);
        assertTrue(_wellFormed(label));
        vm.prank(registrar);
        registry.register(label, label, fileId);
        (bytes32 resolved,,) = registry.resolve(label, label);
        assertEq(resolved, fileId);
    }

    // ---------------------------------------------------------------- deprecate

    function test_Deprecate_IsAFlagOnly() public {
        vm.startPrank(registrar);
        registry.register(THREE, R170, fileId);
        vm.expectEmit(true, true, false, true, address(registry));
        emit IDependencyRegistry.DependencyDeprecated(THREE, R170);
        registry.deprecate(THREE, R170);
        vm.stopPrank();

        // Still resolvable and readable: works that pin the version keep rendering.
        (bytes32 resolved, bool deprecated, IContentStore.FileInfo memory file) =
            registry.resolve(THREE, R170);
        assertTrue(deprecated);
        assertEq(resolved, fileId);
        assertEq(file.mimeType, JS);
        assertTrue(store.isComplete(fileId));
        assertEq(store.read(fileId, 0, library_.length), library_);

        // Deprecation neither frees the version for reuse nor affects other versions.
        bytes32 other = _publish(_data(500, 5), IContentStore.Encoding.Identity, JS);
        vm.startPrank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDependencyRegistry.DependencyVersionExists.selector, THREE, R170
            )
        );
        registry.register(THREE, R170, other);
        registry.register(THREE, R171, other);
        vm.stopPrank();
        (, bool otherDeprecated,) = registry.resolve(THREE, R171);
        assertFalse(otherDeprecated);
    }

    function test_Deprecate_Guards() public {
        vm.prank(registrar);
        registry.register(THREE, R170, fileId);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger)
        );
        vm.prank(stranger);
        registry.deprecate(THREE, R170);

        vm.startPrank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IDependencyRegistry.DependencyUnknown.selector, THREE, R171)
        );
        registry.deprecate(THREE, R171);
        registry.deprecate(THREE, R170);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDependencyRegistry.DependencyAlreadyDeprecated.selector, THREE, R170
            )
        );
        registry.deprecate(THREE, R170);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- reads and setup

    function test_Resolve_UnknownReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IDependencyRegistry.DependencyUnknown.selector, THREE, R170)
        );
        registry.resolve(THREE, R170);
    }

    function test_Constructor_RequiresAStoreContract() public {
        vm.expectRevert(
            abi.encodeWithSelector(IDependencyRegistry.DependencyStoreInvalid.selector, stranger)
        );
        new DependencyRegistry(address(manager), IContentStore(stranger));
        assertEq(registry.authority(), address(manager));
    }

    /// @dev Independent oracle: the label is 1 to 32 characters from the alphabet, then zeros.
    function _wellFormed(bytes32 label) internal pure returns (bool) {
        bytes memory alphabet = "abcdefghijklmnopqrstuvwxyz0123456789._-";
        uint256 used;
        while (used < 32 && label[used] != 0) ++used;
        if (used == 0) return false;
        for (uint256 i = used; i < 32; ++i) {
            if (label[i] != 0) return false;
        }
        for (uint256 i; i < used; ++i) {
            bool found;
            for (uint256 j; j < alphabet.length; ++j) {
                if (label[i] == alphabet[j]) found = true;
            }
            if (!found) return false;
        }
        return true;
    }
}
