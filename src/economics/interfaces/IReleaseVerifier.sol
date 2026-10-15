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
    event NonceUsed(address indexed account, uint256 indexed nonce, bool revoked);

    /// @notice Only `wallet` may consume its own authorizations; `caller` is not it.
    error WrongWallet(address wallet, address caller);
    /// @notice The authorization's `deadline` has passed.
    error AuthorizationExpired(uint256 deadline);
    /// @notice `account` already used or revoked `nonce`.
    error NonceAlreadyUsed(address account, uint256 nonce);
    /// @notice The signature is not valid for `account`.
    error InvalidSignature(address account);

    /// @notice Checks the deadline and signature of `authorization` and consumes its nonce.
    ///         Only the wallet the authorization names may call; the wallet checks that
    ///         `account` is the payee's current payout address.
    function consume(Authorization calldata authorization, bytes calldata signature) external;

    /// @notice Revokes the caller's unused `nonce` for every wallet.
    /// @dev Nonces are any `uint256`, used in any order. 256 consecutive nonces (`n` with the same
    ///      `n / 256`) share one storage word, so signing them in order writes one new slot per
    ///      256 releases.
    function revokeNonce(uint256 nonce) external;

    /// @notice Returns whether `account` has used or revoked `nonce`.
    function nonceUsed(address account, uint256 nonce) external view returns (bool);

    /// @notice The EIP-712 digest a payee signs for `authorization`.
    function releaseDigest(Authorization calldata authorization) external view returns (bytes32);

    /// @notice The EIP-712 domain separator on the current chain.
    function domainSeparator() external view returns (bytes32);
}
