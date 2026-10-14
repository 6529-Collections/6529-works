// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Roles
/// @notice Canonical OpenZeppelin 5 `AccessManager` role IDs and delay classes for every
///         6529 Works contract (ADR 0001 §13). Import these constants; never hard-code a role ID.
/// @dev In `AccessManager` a delay belongs to a (role, holder) pair, not to a function. A delay
///      class is therefore a role whose holders always carry the class delay as their execution
///      delay, and "one selector, one class" means every governed selector maps to exactly one
///      of these roles. IDs are contiguous from 0 to `COUNT - 1`, so callers may loop over them.
library Roles {
    // ----------------------------------------------------------------- delay classes

    /// @notice Tightening actions and pauses.
    uint32 internal constant IMMEDIATE = 0;
    /// @notice Standard actions: sale parameters, defaults for new works, dispute outcomes.
    uint32 internal constant STANDARD = 48 hours;
    /// @notice Funds and network-level recipients.
    uint32 internal constant FUNDS = 14 days;
    /// @notice Verifier and successor-level swaps, one-way freezes, and meta-governance.
    uint32 internal constant SUCCESSOR = 30 days;

    // --------------------------------------------------------------------- role IDs

    /// @notice `AccessManager.ADMIN_ROLE`: the hot admin Safe and a cold recovery admin Safe,
    ///         30-day execution delay. Also the manager's own admin functions.
    uint64 internal constant ADMIN = 0;
    /// @notice Guardian Safes (at least two; three by default): `WorksAccessManager` lets them
    ///         cancel any scheduled operation and suspend a holder of a suspendable role
    ///         ({isSuspendable}). Mapped to immediate vetoes: dispute pause, identity-change
    ///         veto, curation `disableSigner`. Holds nothing but `PAUSER`.
    uint64 internal constant GUARDIAN = 1;
    /// @notice Immediate `pause` selectors. Held by the guardian Safes, never by an unpauser.
    uint64 internal constant PAUSER = 2;
    /// @notice `unpause` selectors, standard class so a guardian can cancel a hostile unpause.
    uint64 internal constant UNPAUSER = 3;
    /// @notice Curation signer keys whose EIP-712 attestations the v1 verifier accepts. A
    ///         signer registry, never an on-chain caller: no function maps to it.
    uint64 internal constant CURATION_SIGNER = 4;
    /// @notice Switches preferred locations among registered, hash-equal locators.
    uint64 internal constant STORAGE_OPERATOR = 5;
    /// @notice Shared sale adapters allowed to mint.
    uint64 internal constant MINTER = 6;
    /// @notice Maintenance bots for permissionless-equivalent upkeep.
    uint64 internal constant KEEPER = 7;
    /// @notice Platform operations: registering locators and posting platform statements
    ///         (`StatementLog.appendPlatform`). Zero delay: the log refuses delayed writers.
    uint64 internal constant PLATFORM = 8;
    /// @notice Standard-class governed setters (48 hours).
    uint64 internal constant PARAMETER_SETTER = 9;
    /// @notice Funds-and-recipients-class governed setters (14 days).
    uint64 internal constant FUNDS_SETTER = 10;
    /// @notice Verifier, renderer, successor, freeze and manifest setters (30 days).
    uint64 internal constant SUCCESSOR_SETTER = 11;
    /// @notice Appends curator statements, including `CURATION_EVIDENCE`
    ///         (`StatementLog.appendCurator`). Zero delay: the log refuses delayed writers.
    uint64 internal constant CURATOR = 12;
    /// @notice Number of role IDs defined here (0 through 12).
    uint64 internal constant COUNT = 13;
    /// @notice `AccessManager.PUBLIC_ROLE`. Never map a governed selector to it.
    uint64 internal constant PUBLIC = type(uint64).max;

    /// @notice `role` is not one of the IDs defined here.
    error UnknownRole(uint64 role);

    /// @notice Reverts with {UnknownRole} unless `role` is defined here.
    function requireKnown(uint64 role) internal pure {
        if (role >= COUNT) revert UnknownRole(role);
    }

    /// @notice The execution delay every holder of `role` must carry.
    function executionDelay(uint64 role) internal pure returns (uint32) {
        requireKnown(role);
        if (role == ADMIN || role == SUCCESSOR_SETTER) return SUCCESSOR;
        if (role == FUNDS_SETTER) return FUNDS;
        if (role == PARAMETER_SETTER || role == UNPAUSER) return STANDARD;
        return IMMEDIATE;
    }

    /// @notice The delay before a newly granted holder of `role` becomes active. Never shorter
    ///         than the role's execution delay (ADR 0001 §13.1).
    function grantDelay(uint64 role) internal pure returns (uint32) {
        requireKnown(role);
        if (
            role == ADMIN || role == GUARDIAN || role == CURATION_SIGNER || role == MINTER
                || role == SUCCESSOR_SETTER || role == CURATOR
        ) return SUCCESSOR;
        if (role == FUNDS_SETTER) return FUNDS;
        return STANDARD;
    }

    /// @notice Whether a guardian may suspend a holder of `role` at once
    ///         (`WorksAccessManager.suspend`): the zero-delay operational roles whose holders
    ///         are single keys. Never a governance role, a pause role or `MINTER`.
    function isSuspendable(uint64 role) internal pure returns (bool) {
        return
            role == PLATFORM || role == CURATOR || role == STORAGE_OPERATOR
                || role == CURATION_SIGNER;
    }

    /// @notice The label emitted for `role` at configuration. `ADMIN` cannot be labelled.
    function label(uint64 role) internal pure returns (string memory) {
        if (role == GUARDIAN) return "GUARDIAN";
        if (role == PAUSER) return "PAUSER";
        if (role == UNPAUSER) return "UNPAUSER";
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
