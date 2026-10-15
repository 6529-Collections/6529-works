// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IReleaseVerifier
/// @notice The one pinned verifier for signed split-wallet releases (ADR 0001 section 7, "signed
///         release authorization"). Every wallet calls it, so the EIP-712, ERC-1271 and EIP-7702
///         logic is deployed once instead of in every wallet.
interface IReleaseVerifier {
    /// @notice A payee's signed instruction to release `amount` of `asset` from `wallet` to
    ///         `recipient`.
    /// @dev Signed as the EIP-712 type `ReleaseAuthorization` in the verifier's domain, which binds
    ///      the chain; the struct binds the wallet. `account` is the signer and must be the payee's
    ///      payout address when the authorization is used, so a key the payout moved away from
    ///      cannot release. Moving away does not revoke its signatures, though: if the payout
    ///      returns to that key (A, then B, then A again) its unexpired authorizations work again.
    ///      Revoke outstanding nonces explicitly with {revokeNonce}, or sign short deadlines.
    ///      `amount` is released exactly; `type(uint256).max` releases the whole releasable amount.
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

    /// @notice Only `wallet` may consume its own authorizations; `caller` is not it.
    error WrongWallet(address wallet, address caller);
    /// @notice `account` already used or revoked `nonce`.
    error NonceAlreadyUsed(address account, uint256 nonce);

    /// @notice Checks the deadline (`SignatureVerifier.SignatureExpired`) and signature
    ///         (`SignatureVerifier.InvalidSignature`) of `authorization` and consumes its nonce.
    ///         Only the wallet the authorization names may call; the wallet checks that
    ///         `account` is the payee's current payout address.
    /// @param authorization The signed release; its `wallet` must be the caller.
    /// @param signature The signature of `authorization.account` over
    ///        `releaseDigest(authorization)`: 65 or 64 (ERC-2098) bytes for an EOA, or up to
    ///        4,096 bytes for an ERC-1271 account.
    function consume(Authorization calldata authorization, bytes calldata signature) external;

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
    /// @return The typed-data hash of `authorization` in this verifier's domain.
    function releaseDigest(Authorization calldata authorization) external view returns (bytes32);

    /// @notice The EIP-712 domain separator on the current chain.
    /// @return The separator for the domain "6529 Works Release Verifier", version "1".
    function domainSeparator() external view returns (bytes32);
}
