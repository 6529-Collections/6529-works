// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IClaimRouter } from "../economics/interfaces/IClaimRouter.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";

/// @title ProtocolContracts
/// @notice Recognises the protocol contracts that can neither pull a split-wallet payout nor
///         accept an ETH payment: the revenue escrow, the claim router, every sale adapter and
///         every mint target (6529 Stream, 6529 Editions). Each declares its interface through
///         ERC-165, so an artist payout or a network fee recipient set to one by mistake is
///         refused before any money is routed there.
/// @dev Internal functions only, so nothing here is a linked library. An address without code is
///      never one. That includes a split wallet's predicted CREATE2 address before deployment,
///      which no on-chain check can tell apart from an empty account; callers that care check
///      deployed split wallets through the factory.
library ProtocolContracts {
    /// @notice Whether `account` declares the interface of the revenue escrow, the claim
    ///         router, a sale adapter or a mint target.
    function isProtocolContract(address account) internal view returns (bool) {
        if (account.code.length == 0) return false;
        bytes4[] memory ids = new bytes4[](4);
        ids[0] = type(IRevenueEscrow).interfaceId;
        ids[1] = type(IClaimRouter).interfaceId;
        ids[2] = type(ISaleAdapter).interfaceId;
        ids[3] = type(IMintTarget).interfaceId;
        bool[] memory supported = ERC165Checker.getSupportedInterfaces(account, ids);
        return supported[0] || supported[1] || supported[2] || supported[3];
    }
}
