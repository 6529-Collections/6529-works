// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

/// @title SuccessionProbe
/// @notice A stock OpenZeppelin `AccessManaged` contract with nothing else, created by
///         `WorksAccessManager.registerSuccessor` with the proposed successor as its authority.
///         The successor proves it can re-point a contract it governs by calling
///         `setAuthority(manager)` on it, the same call, with the same check, it will need on
///         every permanent contract to hand over again; `acceptSuccession` refuses until the
///         probe names the manager (governance spec, "Successor and migration").
/// @dev Holds no funds and governs nothing; its only state is its authority.
contract SuccessionProbe is AccessManaged {
    /// @param successor The proposed successor authority.
    constructor(address successor) AccessManaged(successor) { }
}
