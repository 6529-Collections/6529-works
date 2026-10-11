// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PrimaryTerms } from "./types/SaleTypes.sol";

/// @title IMintTarget
/// @notice The whole surface a shared sale adapter uses on a token contract: 6529 Stream,
///         6529 Editions, or a future 6529 Stream Federated template (ADR 0001 sections 5 and
///         16). Adapters are written against this and nothing else.
/// @dev The token, not the adapter, decides what may be minted and on what terms, so an adapter
///      can never sell outside the approved package. `mint` and `burn` accept only the adapters
///      the token admits (for 6529 Stream and 6529 Editions, through a timelocked governed
///      action; for a federated template, as its deployment records). The token checks that the
///      calling adapter's `ISaleAdapter.saleKind()` equals `terms.saleKind`.
interface IMintTarget {
    /// @notice The calling adapter's sale kind is not the one the terms require.
    error SaleKindMismatch(bytes32 expected, bytes32 actual);

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

    /// @notice The primary-sale terms of `id`. For a minted token they are the terms locked at
    ///         its mint (`data` is ignored), with `creator` resolved now; for a 6529 Stream item
    ///         not yet minted (`id` 0), a preview computed from `data` without verifying it.
    ///         Reverts when no terms exist (for example an unknown edition).
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory);

    /// @notice Burns `amount` of token `id` from the calling adapter's own balance after its sale
    ///         was cancelled (ADR 0001 section 12: an upheld dispute burns the token, leaving a
    ///         gap in the ID sequence). Admitted adapters only.
    function burn(uint256 id, uint256 amount) external;
}
