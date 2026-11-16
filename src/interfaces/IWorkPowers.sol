// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title WorkPowers
/// @notice The powers over one work that its lead artist may renounce for good
///         (`IWorkPowers.renounce`), as bits of a `uint16` mask. Bits not named here are
///         unknown and refused.
/// @dev Constants only; nothing here is linked bytecode.
library WorkPowers {
    /// @notice Any further royalty-rate change (`IWorkRecords.setRoyaltyRate`).
    uint16 internal constant ROYALTY_RATE = 1;
    /// @notice Any further license change (`IWorkRecords.relicense`).
    uint16 internal constant RELICENSE = 2;
    /// @notice Any further errata renderer repin (`IWorkRecords.repinRenderer`); renounceable
    ///         only once the work is finalized.
    uint16 internal constant RENDERER_REPIN = 4;
    /// @notice Every renounceable power.
    uint16 internal constant ALL = 7;
}

/// @title IWorkPowers
/// @notice The 6529 Stream records satellite's renounceable powers, a second interface beside
///         `IWorkRecords`. The lead artist's account may give up, for one work and for good, the
///         errata renderer repin once the work is finalized, and, with the network's agreement,
///         any further royalty-rate change and any further license change (C7).
/// @dev Renouncing `RENDERER_REPIN` (ADR 0006 as amended, owner decision 15 November 2026)
///      fixes the work's pinned renderer for good: if a later protocol change (a gas repricing,
///      a change to code hashes, a renderer dependency that stops answering) breaks that
///      renderer, the work's metadata can never be repaired, and `tokenURI` may revert or show
///      less for good. The media, record and license stay on-chain and readable by any other
///      renderer off-chain.
///
///      Royalty changes go up or down with every party's consent and the network's action
///      (R10). A linked edition follows its master, so renouncing on the master also fixes the
///      edition's rate and license.
interface IWorkPowers {
    /// @notice The lead artist renounced powers over a work for good.
    /// @param tokenId The work's token ID.
    /// @param powers The `WorkPowers` bits the artist signed for.
    /// @param renounced Every bit renounced for the work after the call.
    /// @param stateHash The work's state hash after the call (the version bumped).
    event PowersRenounced(
        uint256 indexed tokenId, uint16 powers, uint16 renounced, bytes32 stateHash
    );

    /// @notice `powers` has a bit that names no renounceable power (`WorkPowers.ALL`). Renouncing
    ///         `RENDERER_REPIN` before finalize reverts with `IWorkRecords.WorkNotFinalized`.
    error UnknownPower(uint16 powers);
    /// @notice The work's lead artist renounced this power; its function always reverts.
    error PowerRenounced(uint256 tokenId, uint16 power);

    /// @notice Renounces `powers` over one work for good. A wallet of the lead artist's account
    ///         signs `Typehashes.RENOUNCE_POWERS` over the work's state hash and a deadline;
    ///         anyone submits it. When a newly renounced bit is `ROYALTY_RATE` or `RELICENSE`,
    ///         the call must also come through the role mapped to this selector (the network, 24
    ///         hours; `AccessManagedUnauthorized` otherwise); renouncing `RENDERER_REPIN` alone
    ///         needs only the signature. Allowed before and after finalize, except
    ///         `RENDERER_REPIN`, which needs a finalized work (a work has no pin to repair
    ///         before), and `RELICENSE` while the work's license is one `finalize` could never
    ///         accept (an identifier outside the mint rule, or a text unregistered, not SHA-256
    ///         or over 16 chunks: `IWorkRecords.InvalidLicense` or the store's refusal); missing
    ///         chunks, which anyone may write, do not stop it. Bits are only ever added:
    ///         renouncing only bits already renounced (zero included) is a no-op that still
    ///         requires an open record and known bits but checks no state hash, deadline or
    ///         signature; otherwise the version bumps, so the signature can never apply again and
    ///         every pending consent for the work lapses. No metadata event follows: `tokenURI`
    ///         does not show the mask.
    /// @param tokenId A live work with an open record (`RecordNotOpen` otherwise).
    /// @param powers The `WorkPowers` bits to renounce (`UnknownPower` for any other bit).
    /// @param expectedStateHash The work's current state hash, which the signature binds
    ///        (`StateHashMismatch` otherwise).
    /// @param deadline The signature's deadline, inclusive, in seconds since the epoch
    ///        (`SignatureVerifier.SignatureExpired` after it).
    /// @param artistSignature The signing wallet of the lead artist's account followed by its
    ///        signature (`abi.encodePacked(wallet, signature)`; the artist registry's
    ///        `IAccounts.requireSigned` reason otherwise).
    function renounce(
        uint256 tokenId,
        uint16 powers,
        bytes32 expectedStateHash,
        uint64 deadline,
        bytes calldata artistSignature
    ) external;

    /// @notice The powers renounced over a work, as `WorkPowers` bits; it only ever gains bits.
    /// @param tokenId A work with an open record (`RecordNotOpen` otherwise).
    /// @return The renounced mask, zero when nothing is renounced.
    function renouncedPowers(uint256 tokenId) external view returns (uint16);
}
