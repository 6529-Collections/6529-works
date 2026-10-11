// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PrimaryTerms } from "./types/SaleTypes.sol";

/// @title IMintTarget
/// @notice The whole surface a shared sale adapter uses on a token contract: 6529 Stream,
///         6529 Editions, or a future 6529 Stream Federated template (ADR 0001 sections 5 and
///         16). Adapters are written against this and nothing else.
/// @dev The token, not the adapter, decides what may be minted and on what terms, so an adapter
///      can never sell outside the approved package. `mint` accepts only adapters in the token's
///      admitted-minter mapping (`isAdmittedMinter`), written by a governed setter on the 30-day
///      class (a mapping read is cheaper on the start path than an AccessManager hop). Removal
///      stops new mints only: the adapter that minted a token can still settle and burn it.
///      The token checks that the calling adapter's `ISaleAdapter.saleKind()` equals
///      `terms.saleKind`. Token IDs are never reused.
interface IMintTarget {
    /// @notice An adapter was admitted or removed as a minter.
    event AdmittedMinterSet(address indexed adapter, bool admitted);

    /// @notice The calling adapter's sale kind is not the one the terms require.
    error SaleKindMismatch(bytes32 expected, bytes32 actual);
    /// @notice The caller is not an admitted minter.
    error NotAdmittedMinter(address caller);

    /// @notice Mints `amount` of token `id` to `to` for a sale run by the calling adapter, and
    ///         returns the minted ID and the terms the adapter must apply.
    /// @dev 6529 Stream: `id` must be 0 (Stream assigns the next global token ID), `amount` 1,
    ///      `to` the adapter's own custody, and `data` `abi.encode(StreamMintRequest)`; the call
    ///      consumes the package item, and reverts for a VRF item whose seed is not delivered.
    ///      6529 Editions: `id` is the edition ID, `to` the buyer's recipient, `data` empty.
    /// @param to The recipient of the minted tokens.
    /// @param id The token ID to mint, or 0 where the token assigns it.
    /// @param amount The number of tokens.
    /// @param data Token-specific authorization, opaque to the adapter.
    /// @return tokenId The minted token ID.
    /// @return terms The primary-sale terms of `tokenId`.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms);

    /// @notice The primary-sale terms of `id`. For a minted 6529 Stream token only `saleKind`,
    ///         `seller`, `feeRecipient`, `feeShare` and `creator` (resolved now) are set: the
    ///         adapter that started the sale owns its currency. For an edition, the full terms.
    ///         For a 6529 Stream item not yet minted (`id` 0), a preview from `data`, unverified.
    ///         Reverts when no terms exist (for example an unknown edition).
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory);

    /// @notice Burns `amount` of token `id` from the calling adapter's own balance after its sale
    ///         was cancelled (ADR 0001 section 12: an upheld dispute burns the token, leaving a
    ///         gap in the ID sequence). Only the adapter that minted the token, even if it has
    ///         since been removed, so a cancelled sale can always burn; another adapter holding
    ///         the token never can. 6529 Stream also requires that the primary sale has not
    ///         settled (`IStream.SaleAlreadySettled`): after a sale nothing is confiscated.
    function burn(uint256 id, uint256 amount) external;

    /// @notice Marks token `id`'s primary sale settled, at settlement, while the token is still
    ///         in the calling adapter's custody and without waiting for delivery, so a winner who
    ///         never claims cannot block what depends on it (6529 Stream: edition creation).
    ///         Only the adapter that minted the token. Every mint target implements it, so a sale
    ///         can always settle; a token with nothing to record (6529 Editions) makes it a
    ///         no-op.
    function markPrimarySettled(uint256 id) external;

    /// @notice Whether `adapter` may call `mint`.
    function isAdmittedMinter(address adapter) external view returns (bool);
    /// @notice Admits or removes a sale adapter (ERC-165 checked for `ISaleAdapter`, not an
    ///         EIP-7702 delegated account). SUCCESSOR_SETTER role (30-day class).
    function setAdmittedMinter(address adapter, bool admitted) external;
}
