// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IReleaseVerifier } from "./IReleaseVerifier.sol";

/// @title IClaimRouter
/// @notice Stateless batch claims across split wallets (ADR 0001 section 7, "optional batch
///         claims"). Plain items call `ISplitWallet.release`, which pays only a fixed payee's own
///         account; artist-resolved payees are pull-only, so a plain item for one fails (and is
///         skipped in continue mode). Signed items call `releaseWithAuthorization`, so an artist
///         or any payee can batch its own releases with one signature per wallet. The router can
///         never redirect funds and never holds any.
/// @dev Continue mode reverts unless every item can be offered its minimum gas. It also reverts
///      when an item offered less than {SHORTFALL_REVERT_CEILING} fails after spending (all but
///      EIP-150's 1/64 reserve of) that gas, or because an ERC-1271 check could not get its gas,
///      so gas estimation raises the limit instead of settling where such an item silently runs
///      dry. An item that fails with gas to spare, or despite at least the ceiling, is reported
///      and skipped. A party to an item that burns gas on purpose can therefore revert a batch
///      only while its item is offered less than the ceiling; keepers simulate privately and
///      split batches whose items involve contract payees or unfamiliar tokens.
///      Declares itself through ERC-165, so the artist registry and the economics resolver can
///      refuse the router as a payout or fee recipient (`ProtocolContracts`).
interface IClaimRouter is IERC165 {
    /// @notice One plain release: payee `payee` of `wallet`, in `asset`.
    struct Claim {
        address wallet;
        address asset;
        uint256 payee;
    }

    /// @notice One signed release; the target is `authorization.wallet`.
    struct SignedClaim {
        IReleaseVerifier.Authorization authorization;
        bytes signature;
    }

    /// @notice In continue mode, item `index` failed. `size` is the size of the data the wallet
    ///         returned, and `reason` is at most its first 256 bytes, or a router error.
    event ClaimFailed(
        address indexed wallet,
        address indexed asset,
        uint256 indexed payee,
        uint256 index,
        uint256 size,
        bytes reason
    );

    /// @notice The batch has `count` items, more than its maximum.
    error TooManyClaims(uint256 count);
    /// @notice In continue mode, item `index` would get only `available` gas, less than its
    ///         minimum, or, offered `available` below {SHORTFALL_REVERT_CEILING}, it ran short of
    ///         gas; the whole batch reverts so gas estimation raises the limit.
    error ClaimInsufficientGas(uint256 index, uint256 available);
    /// @notice In atomic mode, item `index` failed and the whole batch reverted.
    error ClaimCallFailed(uint256 index, address wallet, uint256 size, bytes reason);
    /// @notice The claim target has no code.
    error ClaimTargetHasNoCode(address wallet);
    /// @notice The wallet succeeded but returned `size` bytes instead of one word.
    error InvalidClaimReturnData(uint256 size);

    /// @notice The most plain claims one batch may carry, so a batch fits the EIP-7825
    ///         per-transaction gas cap of 16,777,216.
    function MAX_CLAIMS() external view returns (uint256);

    /// @notice In continue mode, the least gas each plain item must be offered. A floor, not a
    ///         promise: an item that needs more (a first release under Glamsterdam) makes the
    ///         batch revert until it gets it.
    function MIN_ITEM_GAS() external view returns (uint256);

    /// @notice The most signed claims one batch may carry (each may verify an ERC-1271 signature
    ///         of up to 4 KiB), so a batch fits the EIP-7825 cap.
    function MAX_SIGNED_CLAIMS() external view returns (uint256);

    /// @notice In continue mode, the least gas each signed item must be offered. A floor, as
    ///         {MIN_ITEM_GAS} is.
    function MIN_SIGNED_ITEM_GAS() external view returns (uint256);

    /// @notice In continue mode, an item offered at least this much gas that still fails is
    ///         skipped, whatever it spent; below it, a shortfall reverts the batch.
    function SHORTFALL_REVERT_CEILING() external view returns (uint256);

    /// @notice Releases every plain claim in order. In atomic mode any failure reverts the batch;
    ///         in continue mode a failed item emits {ClaimFailed}, releases 0 and the batch goes
    ///         on.
    /// @param claims The plain releases, at most {MAX_CLAIMS}.
    /// @param continueOnFailure True for continue mode, false for atomic mode.
    /// @return amounts The amount each item released.
    function claim(Claim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts);

    /// @notice Executes every signed claim in order, with the same failure modes as {claim}.
    /// @return amounts The amount each item released.
    function claimSigned(SignedClaim[] calldata claims, bool continueOnFailure)
        external
        returns (uint256[] memory amounts);
}
