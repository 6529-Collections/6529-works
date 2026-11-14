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
    /// @notice Every renounceable power.
    uint16 internal constant ALL = 3;
}

/// @title IWorkPowers
/// @notice The 6529 Stream records satellite's renounceable powers, a second interface beside
///         `IWorkRecords` (whose interface ID 6529 Stream and 6529 Stream Editions check when
///         binding, so it does not change). The lead artist's active authority may give up,
///         for one work and for good, any further royalty-rate change and any further license
///         change. Both already need every party's signature, the lead artist's included, plus
///         a governed action, so the lead artist alone could always withhold them; renouncing
///         makes that refusal permanent and public, and grants nothing.
/// @dev The errata renderer repin (`IWorkRecords.repinRenderer`) cannot be renounced: a pinned
///      renderer that a future gas repricing or another change breaks could then never be
///      repaired.
///
///      Royalty changes are lower-only: `setRoyaltyRate` refuses a rate above the work's
///      current rate with `RoyaltyRateNotLowered` (an unchanged rate stays a no-op). The rate a
///      work mints with, which governance sets for new works through the economics resolver,
///      is not affected. A linked edition follows its master, so renouncing on the master also
///      fixes the edition's rate and license.
interface IWorkPowers {
    /// @notice The lead artist renounced powers over a work for good.
    /// @param tokenId The work's token ID.
    /// @param powers The `WorkPowers` bits the artist signed for.
    /// @param renounced Every bit renounced for the work after the call.
    /// @param stateHash The work's state hash after the call (the version bumped).
    event PowersRenounced(
        uint256 indexed tokenId, uint16 powers, uint16 renounced, bytes32 stateHash
    );

    /// @notice `powers` has a bit that names no renounceable power (`WorkPowers.ALL`).
    error UnknownPower(uint16 powers);
    /// @notice The work's lead artist renounced this power; its function always reverts.
    error PowerRenounced(uint256 tokenId, uint16 power);
    /// @notice A royalty-rate change may only lower the rate: `rate` is above `current`.
    error RoyaltyRateNotLowered(uint256 tokenId, uint32 current, uint32 rate);

    /// @notice Renounces `powers` over one work for good. Permissionless to submit: the lead
    ///         artist's active authority signs `Typehashes.RENOUNCE_POWERS` over the work's
    ///         state hash and a deadline, as for the errata repin, so nobody acts as the artist
    ///         while the artist registry restrains the authority. Allowed before and after
    ///         finalize. Bits are only ever added: renouncing only bits already renounced
    ///         (zero included) is a no-op that still requires an open record and known bits
    ///         but checks no state hash, deadline or signature; otherwise the version bumps, so
    ///         the signature can never apply again and every pending consent for the work
    ///         lapses. No metadata event follows: `tokenURI` does not show the mask.
    /// @param tokenId A live work with an open record (`RecordNotOpen` otherwise).
    /// @param powers The `WorkPowers` bits to renounce (`UnknownPower` for any other bit).
    /// @param expectedStateHash The work's current state hash, which the signature binds
    ///        (`StateHashMismatch` otherwise).
    /// @param deadline The signature's deadline, inclusive, in seconds since the epoch
    ///        (`SignatureVerifier.SignatureExpired` after it).
    /// @param artistSignature The signature of the active authority of the work's lead artist
    ///        (`IWorkRecords.InvalidConsent(tokenId, 0)` otherwise).
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
