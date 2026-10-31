// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IAssetAllowlist } from "src/economics/interfaces/IAssetAllowlist.sol";
import { IEconomicsResolver } from "src/interfaces/IEconomicsResolver.sol";
import { IEnglishAuction } from "src/interfaces/IEnglishAuction.sol";

/// @dev Everything the deployed English auction answers, as one type for the tests:
///      `IEnglishAuction`, the getters its lens adds (constants and dependencies), the functions
///      `EnglishAuction` itself adds (`lens`, `storageWords`, `settlePayout`), the ERC-721
///      receiver hook and `AccessManaged`. The auction declares some of these and forwards the
///      rest to its lens (`EnglishAuction.fallback`), so a test holds one address of this type.
interface IEnglishAuctionFull is IEnglishAuction, IERC721Receiver, IAccessManaged {
    function MAX_PAUSE() external view returns (uint64);
    function OPENING_BID_FLOORS() external view returns (uint256);
    function PAYOUT_GAS() external view returns (uint256);
    function allowlist() external view returns (IAssetAllowlist);
    function economicsResolver() external view returns (IEconomicsResolver);
    function permit2() external view returns (address);
    function federationRegistryCodeHash() external view returns (bytes32);
    function lens() external view returns (address);
    function storageWords(bytes32[] calldata slots) external view returns (bytes32[] memory);
    function settlePayout(address currency, address wallet, uint256 amount) external;
}
