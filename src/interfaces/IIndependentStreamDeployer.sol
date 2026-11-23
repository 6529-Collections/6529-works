// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IIndependentStreamDeployer
/// @notice The deployer of one Independent Stream template version (ADR 0008 §1): the only contract
///         whose copies of that version the Independent Stream registry lists. It deploys its one
///         creation code with the constructor arguments a caller gives, records every address it
///         deployed, and holds no other power.
interface IIndependentStreamDeployer {
    /// @notice The creation code was stored, at construction.
    /// @param creationHash The keccak256 of the creation code.
    /// @param pointers The data contracts (`SSTORE2`) holding it, in order.
    event CreationCodeStored(bytes32 indexed creationHash, address[] pointers);
    /// @notice A copy was deployed: `token` runs the creation code with `config` as constructor
    ///         arguments, so its starting storage is the constructor's from `config`.
    /// @param token The copy.
    /// @param caller Who deployed it (part of the CREATE2 salt).
    /// @param salt The caller's salt.
    /// @param config The ABI-encoded constructor arguments.
    event Deployed(address indexed token, address indexed caller, bytes32 salt, bytes config);

    /// @notice No creation code was given.
    error EmptyCreationCode();

    /// @notice Deploys a copy: CREATE2 of the creation code followed by `config`, with the salt
    ///         `keccak256(abi.encode(msg.sender, salt))`, so no one else can take the caller's
    ///         address. Anyone may call; the constructor arguments, not the caller, decide the
    ///         artist. Reverts with the constructor's error, or empty when the address is taken.
    /// @param salt The caller's salt.
    /// @param config The ABI-encoded constructor arguments.
    /// @return token The copy.
    function deploy(bytes32 salt, bytes calldata config) external returns (address token);

    /// @notice Whether this deployer deployed `token`.
    /// @param token An address.
    /// @return True for a copy this deployer created.
    function deployed(address token) external view returns (bool);

    /// @notice The keccak256 of the creation code this deployer deploys.
    /// @return The hash.
    function creationHash() external view returns (bytes32);

    /// @notice The data contracts holding the creation code, in order.
    /// @return The pointers.
    function codeOf() external view returns (address[] memory);
}
