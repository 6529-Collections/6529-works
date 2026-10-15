// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IArtistPayoutResolver } from "./IArtistPayoutResolver.sol";
import { IReleaseVerifier } from "./IReleaseVerifier.sol";

/// @title ISplitWallet
/// @notice An immutable pull-payment split wallet (ADR 0001 section 7). Each payee is entitled to
///         `floor(observed * share / 100,000)` of every asset, where `observed` is the wallet's
///         balance plus everything already released. ETH is `address(0)`.
/// @dev Fixed payees may be paid by anyone (push to their own account). Artist-resolved payees
///      are pull-only: only their current payout address may release, directly or by signature,
///      so a lost key cannot be paid before recovery redirects it (ADR 0001 section 11). A split
///      wallet therefore cannot serve as an artist's payout address, because it cannot pull;
///      nest a wallet as a fixed payee instead.
///      Because fixed payees are push, anyone may release a fixed payee's whole balance to its
///      own account just before that payee's signed release of an exact amount; the signed
///      release then reverts (nothing or too little left) without consuming its nonce, and the
///      funds are in the payee's account. Sign `type(uint256).max` to take whatever is due.
interface ISplitWallet {
    /// @notice One share holder. Exactly one of `artistId` and `account` is non-zero. A fixed payee
    ///         names its `account`. An artist-resolved payee names its `artistId` and is paid at
    ///         the address the resolver returns when funds are released (ADR 0001 section 11).
    /// @dev Field order packs `account` and `share` into one storage slot.
    struct Payee {
        uint256 artistId;
        address account;
        uint32 share;
    }

    /// @notice `amount` of `asset` owed to payee `payee` (payout address `account`) was paid to
    ///         `recipient`; `observed` is the wallet's cumulative receipts of `asset` at that time.
    /// @param asset The asset released (ETH is `address(0)`).
    /// @param payee The payee's index in the payee list.
    /// @param recipient The account that received the funds.
    /// @param account The payee's payout address: its fixed account, or its artist's resolved
    ///        payout address.
    /// @param amount The amount released, in the asset's base units.
    /// @param observed The wallet's cumulative receipts of the asset (balance plus everything
    ///        released) that the release was computed from.
    event Released(
        address indexed asset,
        uint256 indexed payee,
        address indexed recipient,
        address account,
        uint256 amount,
        uint256 observed
    );

    /// @notice The payee list is empty or longer than the maximum.
    error PayeeCountOutOfRange(uint256 count);
    /// @notice The payee at `index` has a zero share or is neither exactly fixed nor
    ///         artist-resolved.
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
    /// @notice ERC-20 `asset` receipts fell below the recorded high-water mark, as a negative
    ///         rebase or a hostile token would cause. Releases of that asset fail closed until it
    ///         recovers.
    error ObservedDecreased(address asset, uint256 recorded, uint256 current);
    /// @notice Sending `amount` wei to `recipient` failed.
    error ETHTransferFailed(address recipient, uint256 amount);

    /// @notice The factory that deployed this wallet.
    /// @return The deploying contract's address.
    function factory() external view returns (address);

    /// @notice The resolver for artist-resolved payees, fixed at deployment.
    /// @return The artist payout resolver (the artist registry).
    function resolver() external view returns (IArtistPayoutResolver);

    /// @notice The resolver's code hash, pinned at deployment.
    /// @return The resolver's code hash; artist-resolved payouts revert if its code changes.
    function resolverCodeHash() external view returns (bytes32);

    /// @notice The verifier for signed releases, fixed at deployment.
    /// @return The release verifier.
    function verifier() external view returns (IReleaseVerifier);

    /// @notice The number of payees.
    /// @return The payee count, from 1 to `Splits.MAX_PAYEES` (64).
    function payeeCount() external view returns (uint256);

    /// @notice The payee at `index`.
    /// @param index The payee's index; reverts with {UnknownPayee} if out of range.
    /// @return The payee's artist ID, account and share.
    function payee(uint256 index) external view returns (Payee memory);

    /// @notice Every payee, in canonical order.
    /// @return The payee list, indexed as the other functions index it.
    function payees() external view returns (Payee[] memory);

    /// @notice The address payee `index` is paid at now; reverts if it cannot be resolved.
    /// @param index The payee's index.
    /// @return A fixed payee's account, or an artist-resolved payee's current payout address.
    function payoutAddress(uint256 index) external view returns (address);

    /// @notice Cumulative receipts of `asset`: the current balance plus everything released.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The cumulative receipts, in the asset's base units.
    function observed(address asset) external view returns (uint256);

    /// @notice The highest cumulative receipts of ERC-20 `asset` recorded by a release. Always
    ///         zero for ETH (`address(0)`), whose receipts can never fall: nothing but a release
    ///         takes ETH out, and a release counts it as released first.
    /// @param asset The asset to look up.
    /// @return The recorded high-water mark, in the asset's base units; zero until a release of
    ///        the asset.
    function recordedObserved(address asset) external view returns (uint256);

    /// @notice The amount of `asset` released for payee `index`.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return The cumulative amount released for the payee, in the asset's base units.
    function released(address asset, uint256 index) external view returns (uint256);

    /// @notice The amount of `asset` released for all payees.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @return The cumulative amount released, in the asset's base units.
    function totalReleased(address asset) external view returns (uint256);

    /// @notice The amount of `asset` payee `index` can release now.
    /// @param asset The asset to look up (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return The payee's entitlement minus what it has already released, in the asset's base
    ///        units.
    function releasable(address asset, uint256 index) external view returns (uint256);

    /// @notice Pays payee `index` everything releasable in `asset`, at its payout address. Anyone
    ///         may call for a fixed payee; only the current payout address may call for an
    ///         artist-resolved payee.
    /// @param asset The asset to release (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @return amount The amount released.
    function release(address asset, uint256 index) external returns (uint256 amount);

    /// @notice Pays payee `index` everything releasable in `asset` to `recipient`. Only the payee's
    ///         current payout address may call.
    /// @param asset The asset to release (ETH is `address(0)`).
    /// @param index The payee's index.
    /// @param recipient The account to pay; not zero or this wallet.
    /// @return amount The amount released.
    function releaseTo(address asset, uint256 index, address recipient)
        external
        returns (uint256 amount);

    /// @notice Executes a payee's signed release, checked by the pinned verifier. Anyone may
    ///         submit it; it works for fixed and artist-resolved payees alike.
    /// @param authorization The signed release; it must name this wallet, and its `account`
    ///        must be the payee's current payout address.
    /// @param signature The signature of `authorization.account` over the verifier's
    ///        `releaseDigest(authorization)`.
    /// @return amount The amount released.
    function releaseWithAuthorization(
        IReleaseVerifier.Authorization calldata authorization,
        bytes calldata signature
    ) external returns (uint256 amount);
}
