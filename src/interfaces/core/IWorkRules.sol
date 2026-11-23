// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { License, PackageItem } from "../types/PackageTypes.sol";

/// @title IWorkRules
/// @notice The RECORDS module (replaceable): who may change a work's record in `IWorkFacts`,
///         and when. It carries over the rules of today's `WorkRecords`: the lead artist edits
///         the record until finalize and finalizes at any time; anyone finalizes 14 days after
///         a recorded notice once the first sale ended; relicensing and a royalty-rate change
///         need every party's consent (counted by account) and the network; the network alone
///         repairs a finalized work's renderer; the artist renounces powers (with the network
///         for the royalty and license powers). It also holds the delivery contract (locators)
///         and the list of added stores.
/// @dev Consents are EIP-712 signatures in this module's domain, bound to `workStateHash`,
///      which changes with every applied change, so no consent applies twice. A successor
///      module starts every work at a new state hash; pending signatures do not carry over.
interface IWorkRules {
    /// @notice A finalize notice was recorded; anyone may finalize from `dueAt`.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param dueAt When anyone may finalize.
    event FinalizeNoticeRecorded(address indexed token, uint256 indexed tokenId, uint256 dueAt);
    /// @notice Powers were renounced.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param powers The `WorkPowers` bits renounced by this call.
    event PowersRenounced(address indexed token, uint256 indexed tokenId, uint16 powers);
    /// @notice The delivery contract changed.
    /// @param previous The contract before.
    /// @param next The contract now.
    event DeliverySet(address previous, address next);

    /// @notice The caller is not a wallet of the work's lead artist.
    error NotWorkArtist(address token, uint256 tokenId, address caller);
    /// @notice The expected state hash is not the current one.
    error StateHashMismatch(bytes32 expected, bytes32 actual);
    /// @notice The finalize notice is not due.
    error FinalizeNotDue(address token, uint256 tokenId, uint256 dueAt);
    /// @notice A consent is missing or the item is not the token's.
    error InvalidConsent(address token, uint256 tokenId);

    /// @notice How long after a recorded notice anyone may finalize: 14 days.
    /// @return The wait, in seconds.
    function FINALIZE_NOTICE() external view returns (uint256);

    /// @notice The delivery contract (`IWorkDelivery`: locators and preferences).
    /// @return The delivery contract.
    function delivery() external view returns (address);

    /// @notice The hash a consent or an edit is bound to.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @return The state hash.
    function workStateHash(address token, uint256 tokenId) external view returns (bytes32);

    /// @notice When a finalize notice was recorded, or zero.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @return The time.
    function finalizeNoticeAt(address token, uint256 tokenId) external view returns (uint48);

    /// @notice The lead artist replaces the descriptive record, before finalize.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param recordFileId The new record file.
    /// @param expectedStateHash The state the caller saw.
    function setRecord(
        address token,
        uint256 tokenId,
        bytes32 recordFileId,
        bytes32 expectedStateHash
    ) external;

    /// @notice Finalizes a work: the lead artist at any time; anyone else records a notice once
    ///         the first sale ended, and finalizes `FINALIZE_NOTICE` after it.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param expectedStateHash The state the artist saw (not checked for a due notice).
    function finalize(address token, uint256 tokenId, bytes32 expectedStateHash) external;

    /// @notice Replaces the license with every party's consent. The network only.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param next The new license.
    /// @param item The token's item (names the parties).
    /// @param expectedStateHash The state the signers saw.
    /// @param deadline The signatures' deadline.
    /// @param partySignatures One proof per party, in order.
    function relicense(
        address token,
        uint256 tokenId,
        License calldata next,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;

    /// @notice Changes the royalty rate with every party's consent (through `ITerms`). The
    ///         network only.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param rate The new rate, out of 100,000.
    /// @param item The token's item.
    /// @param expectedStateHash The state the signers saw.
    /// @param deadline The signatures' deadline.
    /// @param partySignatures One proof per party, in order.
    function setRoyaltyRate(
        address token,
        uint256 tokenId,
        uint24 rate,
        PackageItem calldata item,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes[] calldata partySignatures
    ) external;

    /// @notice Replaces a finalized work's renderer. The network only.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param renderer The new renderer.
    /// @param expectedStateHash The state the caller saw.
    function repinRenderer(
        address token,
        uint256 tokenId,
        address renderer,
        bytes32 expectedStateHash
    ) external;

    /// @notice The lead artist gives up powers for good (`WorkPowers` bits). Renouncing the
    ///         royalty or license power also needs the network's call.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @param powers The powers.
    /// @param expectedStateHash The state the artist saw.
    /// @param deadline The signature's deadline.
    /// @param artistSignature The artist's proof.
    function renounce(
        address token,
        uint256 tokenId,
        uint16 powers,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    /// @notice Replaces the delivery contract. The network only. The new contract must name this
    ///         module and the record contract; that it serves its predecessor's locators is the
    ///         network's check before the call (`IWorkDelivery`).
    /// @param expected The current contract.
    /// @param next The new contract.
    function setDelivery(address expected, address next) external;
}
