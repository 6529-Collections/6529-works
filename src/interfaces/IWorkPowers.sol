// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title WorkPowers
/// @notice The powers over one work that its lead artist may renounce for good
///         (`IWorkRules.renounce`), as bits of a `uint16` mask. Bits not named here are unknown
///         and refused.
/// @dev Constants only; nothing here is linked bytecode. Each power maps to a one-way lock in a
///      permanent contract, so a renunciation survives any replacement of the RECORDS module.
library WorkPowers {
    /// @notice Any further royalty-rate change. Locks the rate in the token contract
    ///         (`IStream.lockRoyaltyRate`, through the TERMS module).
    uint16 internal constant ROYALTY_RATE = 1;
    /// @notice Any further license change. Locks the license in `IWorkFacts`.
    uint16 internal constant RELICENSE = 2;
    /// @notice Any further repin of the renderer; renounceable only once the work is finalized.
    ///         Locks the pin in `IWorkFacts`.
    uint16 internal constant RENDERER_REPIN = 4;
    /// @notice Every renounceable power.
    uint16 internal constant ALL = 7;
}

/// @title IWorkPowers
/// @notice What the RECORDS module (`WorkRules`) answers about the powers renounced over a
///         work, beside `IWorkRules.renounce`.
/// @dev Renouncing `RENDERER_REPIN` fixes the work's pinned renderer for good: if a later
///      protocol change breaks that renderer, the work's metadata can never be repaired, and
///      `tokenURI` may revert or show less for good. The media, record and license stay
///      on-chain and readable by any other renderer off-chain. A master's edition follows its
///      master's royalty rate and license.
interface IWorkPowers {
    /// @notice `powers` has a bit that names no renounceable power (`WorkPowers.ALL`).
    error UnknownPower(uint16 powers);
    /// @notice The work's lead artist renounced this power; its function always reverts.
    error PowerRenounced(address token, uint256 tokenId, uint16 power);

    /// @notice The powers renounced over a work, as `WorkPowers` bits, read from the permanent
    ///         locks (the token's royalty-rate lock, the license and pin locks in
    ///         `IWorkFacts`); it only ever gains bits.
    /// @param token The token contract.
    /// @param tokenId The token.
    /// @return The renounced mask, zero when nothing is renounced.
    function renouncedPowers(address token, uint256 tokenId) external view returns (uint16);
}
