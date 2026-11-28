// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title IReleaseVerifier
/// @notice Signed split-wallet releases (ADR 0001 section 7, "signed release authorization"). The
///         split ledger implements it for every wallet, so the EIP-712, ERC-1271 and EIP-7702
///         logic and the nonces live once, in the contract that also executes the release.
interface IReleaseVerifier {
    /// @notice A payee's signed instruction to release `amount` of `asset` from `wallet` to
    ///         `recipient`.
    /// @dev Signed as the EIP-712 type `ReleaseAuthorization` in the ledger's domain, which binds
    ///      the chain and the ledger; the struct binds the wallet. `account` is the signer and
    ///      must be the payee's payout address when the authorization is used, so a key the
    ///      payout moved away from cannot release. Moving away does not revoke its signatures,
    ///      though: if the payout returns to that key (A, then B, then A again) its unexpired
    ///      authorizations work again. Revoke outstanding nonces explicitly with {revokeNonce},
    ///      or sign short deadlines. `amount` is released exactly; `type(uint256).max` releases
    ///      the whole releasable amount.
    struct Authorization {
        address wallet;
        address asset;
        uint256 payee;
        address account;
        address recipient;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice `account` used `nonce`: consumed by a signed release, or revoked when `revoked`.
    /// @param account The signer whose nonce was used.
    /// @param nonce The nonce, now unusable for every wallet.
    /// @param revoked True for {revokeNonce}, false for a signed release.
    event NonceUsed(address indexed account, uint256 indexed nonce, bool revoked);

    /// @notice `account` already used or revoked `nonce`.
    error NonceAlreadyUsed(address account, uint256 nonce);

    /// @notice Revokes the caller's unused `nonce` for every wallet.
    /// @dev Nonces are any `uint256`, used in any order. 256 consecutive nonces (`n` with the same
    ///      `n / 256`) share one storage word, so signing them in order writes one new slot per
    ///      256 releases.
    /// @param nonce The nonce to revoke; reverts with {NonceAlreadyUsed} if already used.
    function revokeNonce(uint256 nonce) external;

    /// @notice Returns whether `account` has used or revoked `nonce`.
    /// @param account The signer.
    /// @param nonce The nonce to check.
    /// @return True if the nonce was consumed or revoked.
    function nonceUsed(address account, uint256 nonce) external view returns (bool);

    /// @notice The EIP-712 digest a payee signs for `authorization`.
    /// @param authorization The release to sign.
    /// @return The typed-data hash of `authorization` in the ledger's domain.
    function releaseDigest(Authorization calldata authorization) external view returns (bytes32);

    /// @notice The EIP-712 domain separator on the current chain.
    /// @return The separator for the domain "6529 Works Release Verifier", version "1", with the
    ///        ledger as the verifying contract.
    function domainSeparator() external view returns (bytes32);
}
