// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { DelegatedEOA } from "./DelegatedEOA.sol";

/// @title Dependency
/// @notice The one install check for a contract that another v1 contract calls, binds, lists or
///         pins (ADR 0003, "Governance"; GV-22), and the use-time check of a pinned code hash
///         (DEPS-6). Installing requires code that is not an EIP-7702 delegation designator,
///         ERC-165 support for the interface the dependency is installed as (where it implements
///         ERC-165), and, where pinned, the reviewed code hash. The function a call site uses
///         shows which of these it applies.
/// @dev Internal functions only, so nothing here is a linked library. "Dependency" means an
///      installed contract (a registry, resolver, renderer, satellite, coordinator or listed
///      token), not a `DependencyRegistry` entry.
library Dependency {
    /// @notice `dependency` is refused: it has no code, is an EIP-7702 delegated account, does
    ///         not declare the required interface through ERC-165, or its code hash is not the
    ///         pinned one. A contract that refuses a dependency for a reason of its own (a
    ///         retired curation verifier, an artist registry that answered with another ID)
    ///         reverts with this error too, and documents why.
    /// @param dependency The refused address.
    error InvalidDependency(address dependency);
    /// @notice The code at a pinned `dependency` no longer has the code hash it was installed
    ///         with: code recreated at the same address is never trusted (DEPS-6).
    /// @param dependency The pinned address.
    error DependencyCodeChanged(address dependency);

    /// @notice Whether `dependency` has code and is not an EIP-7702 delegated account.
    /// @param dependency The address to check.
    /// @return Whether it can be installed where no interface is required.
    function isInstallable(address dependency) internal view returns (bool) {
        return dependency.code.length != 0 && !DelegatedEOA.isDelegated(dependency);
    }

    /// @notice `isInstallable(dependency)`, plus ERC-165 support for `interfaceId`.
    /// @param dependency The address to check.
    /// @param interfaceId The ERC-165 interface it must support.
    /// @return Whether it can be installed as `interfaceId`.
    function isInstallable(address dependency, bytes4 interfaceId) internal view returns (bool) {
        return isInstallable(dependency) && ERC165Checker.supportsInterface(dependency, interfaceId);
    }

    /// @notice Reverts with `InvalidDependency` unless `dependency` has code and is not an EIP-7702
    ///         delegated account.
    /// @param dependency The address to install.
    function check(address dependency) internal view {
        if (!isInstallable(dependency)) revert InvalidDependency(dependency);
    }

    /// @notice `check(dependency)`, plus ERC-165 support for `interfaceId`.
    /// @param dependency The address to install.
    /// @param interfaceId The ERC-165 interface it must support.
    function check(address dependency, bytes4 interfaceId) internal view {
        if (!isInstallable(dependency, interfaceId)) revert InvalidDependency(dependency);
    }

    /// @notice `check(dependency)`, plus the pinned `codeHash`, for a dependency that implements
    ///         no ERC-165 (the VRF coordinator).
    /// @param dependency The address to install.
    /// @param codeHash The reviewed code hash it must have.
    function checkPinned(address dependency, bytes32 codeHash) internal view {
        if (dependency.codehash != codeHash || !isInstallable(dependency)) {
            revert InvalidDependency(dependency);
        }
    }

    /// @notice `check(dependency, interfaceId)`, plus the pinned `codeHash`.
    /// @param dependency The address to install.
    /// @param interfaceId The ERC-165 interface it must support.
    /// @param codeHash The reviewed code hash it must have.
    function checkPinned(address dependency, bytes4 interfaceId, bytes32 codeHash) internal view {
        if (dependency.codehash != codeHash || !isInstallable(dependency, interfaceId)) {
            revert InvalidDependency(dependency);
        }
    }

    /// @notice Reverts with `DependencyCodeChanged` unless the code at `dependency` still has
    ///         the `codeHash` it was pinned with.
    /// @param dependency The pinned address.
    /// @param codeHash The code hash pinned at install.
    function checkUnchanged(address dependency, bytes32 codeHash) internal view {
        if (dependency.codehash != codeHash) revert DependencyCodeChanged(dependency);
    }
}
