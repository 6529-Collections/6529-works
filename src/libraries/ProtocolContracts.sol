// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { IClaimRouter } from "../economics/interfaces/IClaimRouter.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IMintTarget } from "../interfaces/IMintTarget.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { IWorkRecords } from "../interfaces/IWorkRecords.sol";

/// @title ProtocolContracts
/// @notice Recognises the protocol contracts that can neither pull a split-wallet payout nor
///         accept an ETH payment: the revenue escrow, the claim router, every sale adapter,
///         every mint target (6529 Stream, 6529 Editions), the artist registry, the package
///         registry and the work records. Each declares its interface through ERC-165, so an
///         artist payout or a network fee recipient set to one by mistake is refused before any
///         money is routed there.
/// @dev Internal functions only, so nothing here is a linked library. An address without code is
///      never one. That includes a split wallet's predicted CREATE2 address before deployment,
///      which no on-chain check can tell apart from an empty account; callers that care check
///      deployed split wallets through the factory. Contracts that declare none of these
///      interfaces (the release verifier, the content store, the statement log, the
///      AccessManager, the renderer and the other dependencies) are not recognised here;
///      callers that know one compare its address, and the runbook covers the rest.
library ProtocolContracts {
    /// @notice Whether `account` declares the interface of the revenue escrow, the claim
    ///         router, a sale adapter, a mint target, the artist registry, the package registry
    ///         or the work records.
    function isProtocolContract(address account) internal view returns (bool) {
        if (account.code.length == 0) return false;
        bytes4[] memory ids = new bytes4[](7);
        ids[0] = type(IRevenueEscrow).interfaceId;
        ids[1] = type(IClaimRouter).interfaceId;
        ids[2] = type(ISaleAdapter).interfaceId;
        ids[3] = type(IMintTarget).interfaceId;
        ids[4] = type(IArtistRegistry).interfaceId;
        ids[5] = type(IPackageRegistry).interfaceId;
        ids[6] = type(IWorkRecords).interfaceId;
        bool[] memory supported = ERC165Checker.getSupportedInterfaces(account, ids);
        for (uint256 i; i < supported.length; ++i) {
            if (supported[i]) return true;
        }
        return false;
    }
}
