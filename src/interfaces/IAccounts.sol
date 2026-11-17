// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccounts
/// @notice How a contract asks who may act for an artist or collaborator account. An account is
///         a consolidated 6529 account: its root and every wallet consolidated with the root have
///         the same rights. The artist registry implements this interface; other contracts read
///         it and never keep their own copy of an account's wallets.
/// @dev Every `accountId` argument may be the account ID or any address that is or was its
///      root. An unregistered account is its own single wallet. The calls are views and a frozen
///      account has no acting wallet while the freeze lasts.
interface IAccounts {
    /// @notice Whether `wallet` may act for `accountId` now: the root, or consolidated with the
    ///         root. False for every wallet while the account is frozen.
    /// @param accountId The account ID, or any address that is or was its root.
    /// @param wallet The wallet to test.
    /// @return Whether `wallet` may act for the account now.
    function isWallet(uint256 accountId, address wallet) external view returns (bool);

    /// @notice Reverts unless `proof` is `abi.encodePacked(address wallet, bytes signature)`,
    ///         `wallet` may act for `accountId` now, and `signature` is that wallet signature of
    ///         `digest` (ECDSA or ERC-1271).
    /// @param accountId The account the wallet must act for.
    /// @param digest The digest that was signed.
    /// @param proof The signing wallet address followed by its signature bytes.
    /// @return wallet The wallet that signed.
    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        external
        view
        returns (address wallet);

    /// @notice As `requireSigned`, for the digest `consentDigest(msg.sender, what)`: a consent that
    ///         is only good for the calling contract.
    /// @param accountId The account the wallet must act for.
    /// @param what The thing consented to, as a 32-byte commitment chosen by the caller.
    /// @param proof The signing wallet address followed by its signature bytes.
    /// @return wallet The wallet that signed.
    function requireConsent(uint256 accountId, bytes32 what, bytes calldata proof)
        external
        view
        returns (address wallet);

    /// @notice The EIP-712 digest (registry domain) of `Consent(address subject,bytes32 what)`.
    /// @param subject The contract the consent is good for.
    /// @param what The thing consented to.
    /// @return The digest to sign.
    function consentDigest(address subject, bytes32 what) external view returns (bytes32);

    /// @notice The time the account freeze ends, zero or past when it is not frozen.
    /// @param accountId The account ID, or any address that is or was its root.
    /// @return The end of the freeze, in seconds since the epoch.
    function frozenUntil(uint256 accountId) external view returns (uint48);

    /// @notice Whether the network delisted this account from the federation.
    /// @param accountId The account ID, or any address that is or was its root.
    /// @return Whether the account is delisted.
    function isFederationDelisted(uint256 accountId) external view returns (bool);

    /// @notice The network fee share recorded for a listed federated contract, only ever lowered.
    /// @param token The federated contract.
    /// @return The recorded share of the network fee.
    function federatedFeeShare(address token) external view returns (uint32);
}
