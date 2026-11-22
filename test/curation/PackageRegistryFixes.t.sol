// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPackageRegistry } from "src/interfaces/IPackageRegistry.sol";
import { IStream } from "src/interfaces/core/IStream.sol";
import { IWorkFacts } from "src/interfaces/core/IWorkFacts.sol";
import { License, MoveAuthorization, PackageItem } from "src/interfaces/types/PackageTypes.sol";
import { WorksHashing } from "src/interfaces/types/WorksHashing.sol";
import { CurationBase } from "./CurationBase.sol";

/// @notice The 6529 Stream mint policy refuses a CC0 item whose text is not the deployment's CC0
///         text, the rule `WorkFacts.open` enforces (review B, B-2): no item mints a token whose
///         record could never open.
contract PackageRegistryFixesTest is CurationBase {
    function _readyWith(bytes32 sha, License memory license)
        internal
        returns (bytes32 root, PackageItem memory item, MoveAuthorization memory move)
    {
        item = _item(lead, sha);
        item.license = license;
        root = WorksHashing.leaf(_hash(item));
        _register(root);
        _accept(root, leadKey);
        move = _move(leadKey, root, _hash(item), 0);
    }

    function _cc0Text() internal view returns (bytes32) {
        return IWorkFacts(IStream(stream).facts()).cc0TextFileId();
    }

    function test_Authorize_RefusesCc0WithAnotherText() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _readyWith(sha256("a"), License("CC0-1.0", keccak256("another text")));
        vm.expectRevert(IPackageRegistry.InvalidLicenseId.selector);
        _authorize(root, item, new bytes32[](0), move);
    }

    function test_Authorize_RefusesAnyCaseOfCc0WithAnotherText() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _readyWith(sha256("b"), License("cc0-1.0", keccak256("another text")));
        vm.expectRevert(IPackageRegistry.InvalidLicenseId.selector);
        _authorize(root, item, new bytes32[](0), move);
    }

    function test_Authorize_TakesCc0WithTheDeploymentsText() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _readyWith(sha256("c"), License("CC0-1.0", _cc0Text()));
        _authorize(root, item, new bytes32[](0), move);
    }

    function test_Authorize_TakesAnotherLicenseWithAnyText() public {
        (bytes32 root, PackageItem memory item, MoveAuthorization memory move) =
            _readyWith(sha256("d"), License("MIT", keccak256("mit text")));
        _authorize(root, item, new bytes32[](0), move);
    }

    function test_Preview_RefusesCc0WithAnotherText() public {
        PackageItem memory item = _item(lead, sha256("e"));
        item.license = License("CC0-1.0", keccak256("another text"));
        MoveAuthorization memory move;
        vm.expectRevert(IPackageRegistry.InvalidLicenseId.selector);
        registry.preview(stream, _request(bytes32(0), item, new bytes32[](0), move));
    }
}
