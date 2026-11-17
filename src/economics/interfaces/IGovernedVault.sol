// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ISplitLedger } from "./ISplitLedger.sol";
import { ISplitWallet } from "./ISplitWallet.sol";

/// @title IGovernedVault
/// @notice A network account that outlives any key: the network fee recipient and the 6529
///         Network Museum. Every royalty wallet names the fee recipient as a fixed payee for good,
///         and the museum keeps every unbid work it receives, so neither may be an address whose
///         loss strands what it holds. The vault receives ETH, ERC-20s, ERC-721s and ERC-1155s,
///         and moves them only to its `destination`, which the network sets. Anyone may push its
///         holdings there and release its split-wallet shares to it. The network moves the
///         vault's escrow credits itself (`IRevenueEscrow.recover`, without consent, because the
///         vault answers to the same authority).
/// @dev Holds no other authority: it cannot approve, call arbitrary contracts or change what it
///      is owed. Its governance is the stock `AccessManaged` authority, so it follows the rest of
///      the protocol through any handover.
interface IGovernedVault {
    /// @notice The destination changed from `previous` to `next`; `revision` counts changes.
    /// @param previous The former destination.
    /// @param next The new destination.
    /// @param revision The destination's revision after the change (1 at deployment).
    event DestinationSet(address indexed previous, address indexed next, uint64 revision);
    /// @notice `amount` of ETH (`asset` zero) or of ERC-20 `asset` went to `destination`.
    /// @param asset The asset forwarded (ETH is `address(0)`).
    /// @param destination The account paid.
    /// @param amount The amount forwarded, in the asset's base units.
    event Forwarded(address indexed asset, address indexed destination, uint256 amount);
    /// @notice `amount` of token `id` of the ERC-721 or ERC-1155 contract `token` went to
    ///         `destination` (`amount` is 1 for an ERC-721).
    /// @param token The token contract.
    /// @param id The token ID.
    /// @param destination The account it went to.
    /// @param amount The number of tokens moved.
    event TokenForwarded(
        address indexed token, uint256 indexed id, address indexed destination, uint256 amount
    );

    /// @notice `destination` is zero or the vault itself.
    error InvalidDestination(address destination);
    /// @notice The queued change was written against `expected`, but the revision is `actual`.
    error RevisionMismatch(uint64 expected, uint64 actual);
    /// @notice Sending `amount` wei to `destination` failed.
    error ETHTransferFailed(address destination, uint256 amount);
    /// @notice There is nothing of `asset` to forward.
    error NothingToForward(address asset);

    /// @notice Where the vault's holdings go.
    /// @return The current destination.
    function destination() external view returns (address);

    /// @notice How many times the destination has been set, the deployment included.
    /// @return The destination's revision.
    function destinationRevision() external view returns (uint64);

    /// @notice Sets the destination, compare-and-set on its revision.
    /// @dev Governed: the network, 3 days for the fee vault and 7 days for the museum vault
    ///      (the role map sets each vault's class).
    /// @param expectedRevision The revision the change was written against.
    /// @param next The new destination; not zero or the vault.
    function setDestination(uint64 expectedRevision, address next) external;

    /// @notice Sends `amount` of ETH (`asset` zero) or of ERC-20 `asset` to the destination;
    ///         `type(uint256).max` sends the whole balance. Anyone may call.
    /// @param asset The asset (ETH is `address(0)`).
    /// @param amount The amount, or `type(uint256).max` for everything.
    /// @return sent The amount sent.
    function forward(address asset, uint256 amount) external returns (uint256 sent);

    /// @notice Moves ERC-721 `tokenId` of `token` to the destination with `safeTransferFrom`,
    ///         so a destination contract that does not accept ERC-721s (a split vault, a plain
    ///         contract) refuses the move and the work stays in the vault. Anyone may call: the
    ///         vault holds no key, and the destination, which the network sets with a delay, is
    ///         the decision. Setting a museum vault's
    ///         destination therefore lets anyone move every work it holds there.
    /// @param token The ERC-721 contract.
    /// @param tokenId The token to move.
    function forwardERC721(address token, uint256 tokenId) external;

    /// @notice Moves `amount` of ERC-1155 token `id` of `token` to the destination with
    ///         `safeTransferFrom`, so a destination contract that does not accept ERC-1155s
    ///         refuses the move. Anyone may call, as for {forwardERC721}.
    /// @param token The ERC-1155 contract.
    /// @param id The token ID.
    /// @param amount The number of tokens to move.
    function forwardERC1155(address token, uint256 id, uint256 amount) external;

    /// @notice Releases this vault's share as fixed payee `index` of the wallet for `payees` and
    ///         `salt` of split ledger `ledger` straight to the destination (the ledger's
    ///         `releaseTo`), for an asset that cannot be paid to the vault itself. Anyone may
    ///         call; the vault only ever names its destination.
    /// @param ledger The split ledger that keeps the wallet.
    /// @param payees The wallet's payee list; entry `index` must be this vault.
    /// @param salt The wallet's salt.
    /// @param asset The asset to release (ETH is `address(0)`).
    /// @param index This vault's index in the payee list.
    /// @return amount The amount released.
    function releaseToDestination(
        ISplitLedger ledger,
        ISplitWallet.Payee[] calldata payees,
        bytes32 salt,
        address asset,
        uint256 index
    ) external returns (uint256 amount);
}
