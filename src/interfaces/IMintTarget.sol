// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PrimaryTerms } from "./types/SaleTypes.sol";

/// @title IMintTarget
/// @notice The whole surface a shared sale adapter uses on a token contract: 6529 Stream,
///         6529 Editions, or a future 6529 Stream Federated template (ADR 0001 sections 5 and
///         16). Adapters are written against this and nothing else.
/// @dev The token, not the adapter, decides what may be minted and on what terms, so an adapter
///      can never sell outside the approved package. `mint` and `burn` are restricted to admitted
///      adapters (the MINTER role, granted per adapter by a timelocked AccessManager action).
///      The token checks that the calling adapter's `ISaleAdapter.saleKind()` equals
///      `terms.saleKind`.
interface IMintTarget {
    /// @notice Mints `amount` of token `id` to `to` for a sale run by the calling adapter, and
    ///         returns the minted ID and the terms the adapter must apply.
    /// @dev MINTER role. 6529 Stream: `id` must be 0 (Stream assigns the next global token ID),
    ///      `amount` must be 1, `to` is the adapter's own custody, and `data` is
    ///      `abi.encode(StreamMintRequest)`; the call consumes the package item. 6529 Editions:
    ///      `id` is the edition ID, `to` the buyer's recipient, and `data` is empty.
    /// @param to The recipient of the minted tokens.
    /// @param id The token ID to mint, or 0 where the token assigns it.
    /// @param amount The number of tokens.
    /// @param data Token-specific authorization, opaque to the adapter.
    /// @return tokenId The minted token ID.
    /// @return terms The primary-sale terms of `tokenId`.
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        returns (uint256 tokenId, PrimaryTerms memory terms);

    /// @notice The terms `mint` would return for the same `id` and `data` now, without minting.
    /// @dev A preview only: it does not verify approvals, signatures or supply, which `mint`
    ///      does. Reverts when the terms cannot be computed (for example an unknown edition).
    /// @param id As for `mint`.
    /// @param data As for `mint`.
    /// @return The primary-sale terms.
    function primaryTerms(uint256 id, bytes calldata data)
        external
        view
        returns (PrimaryTerms memory);

    /// @notice Burns `amount` of token `id` from the calling adapter's own balance after its sale
    ///         was cancelled (ADR 0001 section 12: an upheld dispute burns the token, leaving a
    ///         gap in the ID sequence).
    /// @dev MINTER role, and only tokens the caller holds.
    /// @param id The token ID.
    /// @param amount The number of tokens (1 for 6529 Stream).
    function burn(uint256 id, uint256 amount) external;
}
