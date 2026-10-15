// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IContentStore } from "./IContentStore.sol";

/// @title IDependencyRegistry
/// @notice The shared registry of pinned libraries (p5.js, three.js and the like) that
///         generative works load by name and version from the {IContentStore} (ADR 0001 §8).
/// @dev A `(name, version)` pair maps to one content-store file forever. The MIME type and the
///      encoding are not copied here: they come from the file's manifest.
interface IDependencyRegistry {
    /// @notice A version was registered. It can never be changed or removed.
    /// @param name The library's name label.
    /// @param version The version label.
    /// @param fileId The content-store file holding that version.
    event DependencyRegistered(
        bytes32 indexed name, bytes32 indexed version, bytes32 indexed fileId
    );
    /// @notice A version was marked deprecated. Its content stays readable and resolvable.
    /// @param name The library's name label.
    /// @param version The deprecated version label.
    event DependencyDeprecated(bytes32 indexed name, bytes32 indexed version);

    /// @notice `name` or `version` is empty, or is not left-aligned `[a-z0-9._-]` followed only
    ///         by zero bytes.
    error DependencyLabelInvalid(bytes32 label);
    /// @notice `(name, version)` is already registered. Versions are immutable.
    error DependencyVersionExists(bytes32 name, bytes32 version);
    /// @notice `(name, version)` is not registered.
    error DependencyUnknown(bytes32 name, bytes32 version);
    /// @notice The file is not on-chain complete, so the version would not be readable.
    error DependencyContentIncomplete(bytes32 fileId);
    /// @notice `(name, version)` is already deprecated.
    error DependencyAlreadyDeprecated(bytes32 name, bytes32 version);

    /// @notice The content store the registry points at.
    /// @return The content store, fixed at deployment.
    function store() external view returns (IContentStore);

    /// @notice Registers `fileId` as `(name, version)`. The file must be registered and
    ///         on-chain complete in the store. PARAMETER_SETTER role (48 hours, so a guardian can
    ///         cancel a version before it is permanent).
    /// @param name The library's name: 1 to 32 bytes of `[a-z0-9._-]`, left-aligned, then zero
    ///        bytes.
    /// @param version The version label, in the same form as `name`; not yet registered for it.
    /// @param fileId The content-store file holding the library.
    function register(bytes32 name, bytes32 version, bytes32 fileId) external;

    /// @notice Marks `(name, version)` deprecated. A flag only: nothing is deleted, and works
    ///         that pin the version keep rendering. Cannot be undone. GUARDIAN role (immediate).
    /// @param name A registered library name.
    /// @param version A registered, not yet deprecated version of `name`.
    function deprecate(bytes32 name, bytes32 version) external;

    /// @notice Everything a consumer needs to load `(name, version)`: the store file, whether it
    ///         is deprecated, and the manifest data (MIME type and encoding). Reverts if unknown.
    /// @param name A registered library name.
    /// @param version A registered version of `name`.
    /// @return fileId The content-store file holding the version.
    /// @return deprecated True once the version is deprecated.
    /// @return file The file's manifest, as `IContentStore.fileInfo` returns it.
    function resolve(bytes32 name, bytes32 version)
        external
        view
        returns (bytes32 fileId, bool deprecated, IContentStore.FileInfo memory file);
}
