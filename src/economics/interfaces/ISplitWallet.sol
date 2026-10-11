// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistPayoutResolver } from "./IArtistPayoutResolver.sol";

/// @title ISplitWallet
/// @notice An immutable pull-payment split wallet (ADR 0001 section 7). Each payee is entitled to
///         `floor(observed * share / 100,000)` of every asset, where `observed` is the wallet's
///         balance plus everything already released. ETH is `address(0)`.
interface ISplitWallet {
    /// @notice One share holder. Exactly one of `artistId` and `account` is non-zero. A fixed payee
    ///         names its `account`. An artist-resolved payee names its `artistId` and is paid at the
    ///         address the resolver returns when funds are released (ADR 0001 section 11).
    /// @dev Field order packs `account` and `share` into one storage slot.
    struct Payee {
        uint256 artistId;
        address account;
        uint32 share;
    }

    /// @notice A payee's signed instruction to release `amount` of `asset` to `recipient`.
    /// @dev Signed as the EIP-712 type `ReleaseAuthorization` in the wallet's own domain, which
    ///      binds the chain and the wallet. `account` is the signer and must be the payee's payout
    ///      address when the authorization is used, so a replaced artist key stops working.
    ///      `amount` is released exactly; `type(uint256).max` releases the whole releasable amount.
    struct Authorization {
        address asset;
        uint256 payee;
        address account;
        address recipient;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice `amount` of `asset` owed to payee `payee` (payout address `account`) was paid to
    ///         `recipient`; `observed` is the wallet's cumulative receipts of `asset` at that time.
    event Released(
        address indexed asset,
        uint256 indexed payee,
        address indexed recipient,
        address account,
        uint256 amount,
        uint256 observed
    );

    /// @notice `account` used `nonce`: consumed by a signed release, or revoked when `revoked`.
    event NonceUsed(address indexed account, uint256 indexed nonce, bool revoked);

    /// @notice The payee list is empty or longer than the maximum.
    error PayeeCountOutOfRange(uint256 count);
    /// @notice The payee at `index` has a zero share or is neither exactly fixed nor artist-resolved.
    error InvalidPayee(uint256 index);
    /// @notice The payee at `index` does not sort strictly after its predecessor by
    ///         `(artistId, account)`, so the list is not canonical or has a duplicate.
    error PayeesNotCanonical(uint256 index);
    /// @notice The shares add up to `total` instead of 100,000.
    error SharesDoNotSum(uint256 total);
    /// @notice There is no payee at index `payee`.
    error UnknownPayee(uint256 payee);
    /// @notice The resolver returned no payout address for `artistId`.
    error PayoutUnresolved(uint256 artistId);
    /// @notice `recipient` is zero or the wallet itself.
    error InvalidRecipient(address recipient);
    /// @notice `caller` is not the payee's current payout address `payoutAddress`.
    error NotPayoutAddress(address caller, address payoutAddress);
    /// @notice Payee `payee` has nothing releasable in `asset`.
    error NothingToRelease(address asset, uint256 payee);
    /// @notice `amount` exceeds the `releasable` amount.
    error AmountExceedsReleasable(uint256 amount, uint256 releasable);
    /// @notice `asset` receipts fell below the recorded high-water mark, as a negative rebase or a
    ///         hostile token would cause. Releases of that asset fail closed until it recovers.
    error ObservedDecreased(address asset, uint256 recorded, uint256 current);
    /// @notice Sending `amount` wei to `recipient` failed.
    error ETHTransferFailed(address recipient, uint256 amount);
    /// @notice The authorization's `deadline` has passed.
    error AuthorizationExpired(uint256 deadline);
    /// @notice `account` already used or revoked `nonce`.
    error NonceAlreadyUsed(address account, uint256 nonce);
    /// @notice The signature is not valid for `account`.
    error InvalidSignature(address account);

    /// @notice The factory that deployed this wallet.
    function factory() external view returns (address);

    /// @notice The resolver for artist-resolved payees, fixed at deployment.
    function resolver() external view returns (IArtistPayoutResolver);

    /// @notice The number of payees.
    function payeeCount() external view returns (uint256);

    /// @notice The payee at `index`.
    function payee(uint256 index) external view returns (Payee memory);

    /// @notice Every payee, in canonical order.
    function payees() external view returns (Payee[] memory);

    /// @notice The address payee `index` is paid at now; reverts if it cannot be resolved.
    function payoutAddress(uint256 index) external view returns (address);

    /// @notice Cumulative receipts of `asset`: the current balance plus everything released.
    function observed(address asset) external view returns (uint256);

    /// @notice The highest cumulative receipts of `asset` recorded by a release.
    function recordedObserved(address asset) external view returns (uint256);

    /// @notice The amount of `asset` released for payee `index`.
    function released(address asset, uint256 index) external view returns (uint256);

    /// @notice The amount of `asset` released for all payees.
    function totalReleased(address asset) external view returns (uint256);

    /// @notice The amount of `asset` payee `index` can release now.
    function releasable(address asset, uint256 index) external view returns (uint256);

    /// @notice Pays payee `index` everything releasable in `asset`, at its payout address.
    ///         Anyone may call; the funds can only go to the payee.
    /// @return amount The amount released.
    function release(address asset, uint256 index) external returns (uint256 amount);

    /// @notice Pays payee `index` everything releasable in `asset` to `recipient`. Only the payee's
    ///         current payout address may call.
    /// @return amount The amount released.
    function releaseTo(address asset, uint256 index, address recipient)
        external
        returns (uint256 amount);

    /// @notice Executes a payee's signed release. Anyone may submit it.
    /// @return amount The amount released.
    function releaseWithAuthorization(
        Authorization calldata authorization,
        bytes calldata signature
    ) external returns (uint256 amount);

    /// @notice Revokes the caller's unused `nonce`, so no authorization carrying it can be used.
    function revokeNonce(uint256 nonce) external;

    /// @notice Returns whether `account` has used or revoked `nonce`.
    function nonceUsed(address account, uint256 nonce) external view returns (bool);

    /// @notice The EIP-712 digest a payee signs for `authorization`.
    function releaseDigest(Authorization calldata authorization) external view returns (bytes32);

    /// @notice The EIP-712 domain separator for this wallet on the current chain.
    function domainSeparator() external view returns (bytes32);
}
