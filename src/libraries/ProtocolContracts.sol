// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IClaimRouter } from "../economics/interfaces/IClaimRouter.sol";
import { IRevenueEscrow } from "../economics/interfaces/IRevenueEscrow.sol";
import { IArtistRegistry } from "../interfaces/IArtistRegistry.sol";
import { IEditions } from "../interfaces/core/IEditions.sol";
import { IStream } from "../interfaces/core/IStream.sol";
import { IEnglishAuction } from "../interfaces/IEnglishAuction.sol";
import { IPackageRegistry } from "../interfaces/IPackageRegistry.sol";
import { ISaleAdapter } from "../interfaces/ISaleAdapter.sol";
import { BoundedCall } from "./BoundedCall.sol";

/// @title ProtocolContracts
/// @notice Recognises the protocol contracts that can neither pull a split-wallet payout nor
///         accept an ETH payment: the revenue escrow, the claim router, every sale adapter
///         and the English auction, every token contract of the core (`IStream`, `IEditions`:
///         6529 Stream, 6529 Stream Editions and the federated tokens), the accounts module and
///         the package registry. Each declares its interface through ERC-165, so an
///         artist payout or a network fee recipient set to one by mistake is refused before any
///         money is routed there.
/// @dev Internal functions only, so nothing here is a linked library. An address without code is
///      never one. That includes a split vault's predicted address before deployment, which no
///      on-chain check can tell apart from an empty account; callers that care ask the split
///      ledger that derives it. Contracts that declare none of these interfaces (the split
///      ledger and release verifier, the split vaults and governed vaults, the content store,
///      the statement log, the AccessManager, the renderer and the other dependencies) are not
///      recognised here;
///      callers that know one compare its address, and the runbook covers the rest.
///      Each ERC-165 probe forwards all the gas EIP-150 allows (`BoundedCall`), and a probe that
///      runs short reverts with `BoundedCall.BoundedCallShortfall`: running short never reads as
///      "not a protocol contract", which would let a payout be routed to one.
library ProtocolContracts {
    /// @notice Whether `account` declares the interface of the revenue escrow, the claim
    ///         router, a sale adapter, the English auction, a core token contract, the accounts
    ///         module or the package registry.
    function isProtocolContract(address account) internal view returns (bool) {
        if (account.code.length == 0 || !BoundedCall.supportsERC165(account)) return false;
        return _declares(account, type(IRevenueEscrow).interfaceId)
            || _declares(account, type(IClaimRouter).interfaceId)
            || _declares(account, type(ISaleAdapter).interfaceId)
            || _declares(account, type(IEnglishAuction).interfaceId)
            || _declares(account, type(IStream).interfaceId)
            || _declares(account, type(IEditions).interfaceId)
            || _declares(account, type(IArtistRegistry).interfaceId)
            || _declares(account, type(IPackageRegistry).interfaceId);
    }

    function _declares(address account, bytes4 interfaceId) private view returns (bool) {
        return BoundedCall.supportsInterfaceUnchecked(account, interfaceId);
    }
}
