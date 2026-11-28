// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.37;

/// @title Roles
/// @notice Canonical OpenZeppelin 5 `AccessManager` role IDs and delays for every 6529 Stream
///         contract. Import these constants; never hard-code a role ID.
/// @dev Two kinds of role:
///      - Network roles (`ADMIN`, `NETWORK`, `PARAMETER_SETTER`, `FUNDS_SETTER`,
///        `SUCCESSOR_SETTER`) are held by one address only, the network
///        (`StreamAccessManager.network`). Each is a delay class: the network acts through it
///        with that role's class delay. Nobody can be granted one.
///      - Operational roles (`PAUSER`, `CURATION_SIGNER`, `STORAGE_OPERATOR`, `MINTER`,
///        `KEEPER`, `PLATFORM`, `CURATOR`) are ordinary keys the network grants and revokes at
///        once: genesis makes `NETWORK` their admin (no delay). They carry no delay.
///      The class delays below are the delays the manager is configured with at genesis. They
///      are the network's, like everything the manager holds: the network can remap a
///      selector to another class, or change a class's delay, with one action at the 7-day
///      class, so a class's delay holds until such a remap changes it. They are not
///      promises. The waiting periods of the permanent contracts (`moduleDelay`,
///      `rescueDelay`, `rebindDelay`, `unclaimedPeriod`) are not role delays: they are settings
///      stored in those contracts, with launch values, which the network changes at once
///      through the NETWORK role (ADR 0010).
///      ID 3 is unused (it was a separate unpause role).
library Roles {
    // ----------------------------------------------------------------------- delays

    /// @notice The short class: sale parameters, defaults for new works, operational keys.
    uint32 internal constant DELAY_24H = 24 hours;
    /// @notice The funds class: recipients and amounts of money.
    uint32 internal constant DELAY_3D = 3 days;
    /// @notice The long class: swaps of pinned dependencies, the manager's own administration,
    ///         handing the network over and setting the brake.
    uint32 internal constant DELAY_7D = 7 days;
    /// @notice How much later than its ready time the brake can make one scheduled network
    ///         action run, once per action (`StreamAccessManager.brakeOnce`).
    uint32 internal constant BRAKE_DELAY = 7 days;

    // --------------------------------------------------------------------- role IDs

    /// @notice `AccessManager.ADMIN_ROLE`: the network at the 7-day class. The manager's own
    ///         administration (remaps, closing targets, authority moves) and every unmapped
    ///         selector.
    uint64 internal constant ADMIN = 0;
    /// @notice The network with no delay: the powers this system gives it "at once" (dispute
    ///         cancel and resume, account freeze, identity-replacement cancel, protective
    ///         tightenings).
    uint64 internal constant NETWORK = 1;
    /// @notice Immediate `pause` selectors. An operational key.
    uint64 internal constant PAUSER = 2;
    /// @notice Curation signer keys whose EIP-712 attestations the v1 verifier accepts. A
    ///         signer registry, never an on-chain caller: no function maps to it.
    uint64 internal constant CURATION_SIGNER = 4;
    /// @notice Chooses preferred locations among the locators registered for a file.
    uint64 internal constant STORAGE_OPERATOR = 5;
    /// @notice Reserved and unused in v1: no selector maps to it and genesis grants it to
    ///         nobody. Minting is gated by each token's admitted-minter mapping.
    uint64 internal constant MINTER = 6;
    /// @notice Reserved and unused in v1: every upkeep call is permissionless, no selector maps
    ///         to it and genesis grants it to nobody.
    uint64 internal constant KEEPER = 7;
    /// @notice Platform operations: creating collections, registering locators, and posting
    ///         platform statements. Zero delay: the statement log refuses delayed writers.
    uint64 internal constant PLATFORM = 8;
    /// @notice The network at the 24-hour class.
    uint64 internal constant PARAMETER_SETTER = 9;
    /// @notice The network at the 3-day class.
    uint64 internal constant FUNDS_SETTER = 10;
    /// @notice The network at the 7-day class, for selectors on managed contracts.
    uint64 internal constant SUCCESSOR_SETTER = 11;
    /// @notice Appends curator statements. Zero delay: the statement log refuses delayed
    ///         writers.
    uint64 internal constant CURATOR = 12;
    /// @notice One past the highest role ID defined here.
    uint64 internal constant COUNT = 13;
    /// @notice `AccessManager.PUBLIC_ROLE`. Never map a governed selector to it.
    uint64 internal constant PUBLIC = type(uint64).max;

    /// @notice `role` is not one of the IDs defined here.
    error UnknownRole(uint64 role);

    /// @notice Whether `role` is defined here.
    function isKnown(uint64 role) internal pure returns (bool) {
        return role < COUNT && role != 3;
    }

    /// @notice Reverts with {UnknownRole} unless `role` is defined here.
    function requireKnown(uint64 role) internal pure {
        if (!isKnown(role)) revert UnknownRole(role);
    }

    /// @notice Whether `role` is a network role: held by the network address alone, never
    ///         granted.
    function isNetworkRole(uint64 role) internal pure returns (bool) {
        return role == ADMIN || role == NETWORK || role == PARAMETER_SETTER || role == FUNDS_SETTER
            || role == SUCCESSOR_SETTER;
    }

    /// @notice The delay with which the holder of `role` acts: the class delay for a network
    ///         role, zero for an operational role.
    function executionDelay(uint64 role) internal pure returns (uint32) {
        requireKnown(role);
        if (role == ADMIN || role == SUCCESSOR_SETTER) return DELAY_7D;
        if (role == FUNDS_SETTER) return DELAY_3D;
        if (role == PARAMETER_SETTER) return DELAY_24H;
        return 0;
    }

    /// @notice The label emitted for `role` at configuration. `ADMIN` cannot be labelled.
    function label(uint64 role) internal pure returns (string memory) {
        if (role == NETWORK) return "NETWORK";
        if (role == PAUSER) return "PAUSER";
        if (role == CURATION_SIGNER) return "CURATION_SIGNER";
        if (role == STORAGE_OPERATOR) return "STORAGE_OPERATOR";
        if (role == MINTER) return "MINTER";
        if (role == KEEPER) return "KEEPER";
        if (role == PLATFORM) return "PLATFORM";
        if (role == PARAMETER_SETTER) return "PARAMETER_SETTER";
        if (role == FUNDS_SETTER) return "FUNDS_SETTER";
        if (role == SUCCESSOR_SETTER) return "SUCCESSOR_SETTER";
        if (role == CURATOR) return "CURATOR";
        revert UnknownRole(role);
    }
}
