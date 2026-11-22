// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title IAccounts
/// @notice The accounts module (replaceable, found through `IDirectory`, slot `ACCOUNTS`): who
///         may act for a 6529 consolidated account, and where an artist is paid. Every wallet of
///         an account has the same rights; none acts while the account is frozen or a network
///         replacement is pending.
/// @dev Today's `src/interfaces/IAccounts.sol` without the two federation views (they move to
///      `IFederationGate`), plus `payoutAddress`. A freeze blocks a contest of a
///      replacement, and a freeze can be placed again (ADR 0010).
interface IAccounts {
    /// @notice Whether `wallet` may act for the account now.
    /// @param accountId An artist ID, or an address (as a number) that is or was a root.
    /// @param wallet The wallet.
    /// @return True if it may act.
    function isWallet(uint256 accountId, address wallet) external view returns (bool);

    /// @notice Reverts unless `proof` is `abi.encodePacked(wallet, signature)` with `wallet` a
    ///         wallet of the account now and `signature` its signature of `digest` (ECDSA or
    ///         ERC-1271).
    /// @param accountId The account.
    /// @param digest The signed digest.
    /// @param proof The wallet and its signature.
    /// @return wallet The signing wallet.
    function requireSigned(uint256 accountId, bytes32 digest, bytes calldata proof)
        external
        view
        returns (address wallet);

    /// @notice `requireSigned` over `consentDigest(msg.sender, what)`: the account consents to
    ///         `what` for the calling contract.
    /// @param accountId The account.
    /// @param what The consent subject (for a federated work, `Core.federatedConsent`).
    /// @param proof The wallet and its signature.
    /// @return wallet The signing wallet.
    function requireConsent(uint256 accountId, bytes32 what, bytes calldata proof)
        external
        view
        returns (address wallet);

    /// @notice The EIP-712 digest a wallet signs to consent to `what` for `subject`.
    /// @param subject The contract the consent is for.
    /// @param what The consent subject.
    /// @return The digest.
    function consentDigest(address subject, bytes32 what) external view returns (bytes32);

    /// @notice When the account's freeze ends (zero or past: not frozen).
    /// @param accountId The account.
    /// @return The time.
    function frozenUntil(uint256 accountId) external view returns (uint48);

    /// @notice Where an artist is paid now; zero while the account is frozen or a pending change
    ///         would move the payout.
    /// @param artistId The artist.
    /// @return The payout address.
    function payoutAddress(uint256 artistId) external view returns (address);
}
