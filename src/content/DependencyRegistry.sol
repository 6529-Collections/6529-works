// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IContentStore } from "../interfaces/IContentStore.sol";
import { IDependencyRegistry } from "../interfaces/IDependencyRegistry.sol";
import { Dependency } from "../libraries/Dependency.sol";

/// @title DependencyRegistry
/// @notice Pinned library versions for generative works: `(name, version)` to a {ContentStore}
///         file (ADR 0001 §8). Registration and deprecation are governed through the
///         AccessManager; reads are open.
/// @dev Versions are immutable: there is no function that rewrites or removes an entry, and
///      deprecation is a one-way flag. Because a registered file must already be complete in the
///      store, every registered version is readable for as long as the chain exists.
///
///      TODO(governance lane): grant `register` and `deprecate` to the registrar role from
///      `src/governance/Roles.sol` (a role with a delay, since a version is forever) when that
///      file lands; until then deployment scripts and tests wire a local role with
///      `AccessManager.setTargetFunctionRole`.
contract DependencyRegistry is IDependencyRegistry, AccessManaged {
    struct Entry {
        bytes32 fileId;
        bool deprecated;
    }

    /// @inheritdoc IDependencyRegistry
    IContentStore public immutable store;

    mapping(bytes32 name => mapping(bytes32 version => Entry)) private _entries;

    constructor(address authority, IContentStore store_) AccessManaged(authority) {
        Dependency.check(address(store_));
        store = store_;
    }

    /// @inheritdoc IDependencyRegistry
    function register(bytes32 name, bytes32 version, bytes32 fileId) external restricted {
        _requireLabel(name);
        _requireLabel(version);
        if (_entries[name][version].fileId != bytes32(0)) {
            revert DependencyVersionExists(name, version);
        }
        if (!store.isComplete(fileId)) revert DependencyContentIncomplete(fileId); // reverts if unknown
        _entries[name][version].fileId = fileId;
        emit DependencyRegistered(name, version, fileId);
    }

    /// @inheritdoc IDependencyRegistry
    function deprecate(bytes32 name, bytes32 version) external restricted {
        Entry storage entry = _entry(name, version);
        if (entry.deprecated) revert DependencyAlreadyDeprecated(name, version);
        entry.deprecated = true;
        emit DependencyDeprecated(name, version);
    }

    /// @inheritdoc IDependencyRegistry
    function resolve(bytes32 name, bytes32 version)
        external
        view
        returns (bytes32 fileId, bool deprecated, IContentStore.FileInfo memory file)
    {
        Entry storage entry = _entry(name, version);
        fileId = entry.fileId;
        deprecated = entry.deprecated;
        file = store.fileInfo(fileId);
    }

    function _entry(bytes32 name, bytes32 version) private view returns (Entry storage entry) {
        entry = _entries[name][version];
        if (entry.fileId == bytes32(0)) revert DependencyUnknown(name, version);
    }

    /// @dev Non-empty lowercase ASCII from `[a-z0-9._-]`, left-aligned, then zero padding, so
    ///      every name and version has one canonical spelling.
    function _requireLabel(bytes32 label) private pure {
        bool ended = false;
        for (uint256 i; i < 32; ++i) {
            bytes1 c = label[i];
            if (c == 0) {
                ended = true;
            } else if (
                ended
                    || !((c >= "a" && c <= "z")
                        || (c >= "0" && c <= "9")
                        || c == "."
                        || c == "_"
                        || c == "-")
            ) {
                revert DependencyLabelInvalid(label);
            }
        }
        if (label[0] == 0) revert DependencyLabelInvalid(label);
    }
}
