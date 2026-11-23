// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";
import { Dependency } from "../libraries/Dependency.sol";

/// @title IDelegationManagement
/// @notice The public storage getter of the 6529 delegation contract
///         (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`) that the consolidation adapter reads.
/// @dev A Solidity-generated getter of `mapping(bytes32 => T[])`; it reverts with no data when
///      `index` is past the end of the array (the deployed contract is compiled with solc 0.8.18).
interface IDelegationManagement {
    /// @notice The `index`-th registration under
    ///         `keccak256(abi.encodePacked(delegator, collection, delegate, useCase))`.
    /// @param key The hash of the delegator, the collection, the delegate and the use case.
    /// @param index The zero-based position among the pair's registrations.
    /// @return delegator The delegator the registration belongs to (`delegatorAddress`).
    /// @return delegate The delegate it registered (`delegationAddress`).
    /// @return registeredDate The block timestamp of the registration.
    /// @return expiryDate The registration's expiry as a Unix time in seconds; it is live while
    ///        this is later than the current block timestamp.
    /// @return allTokens Whether the registration covers every token of the collection.
    /// @return tokenId The single token ID covered when `allTokens` is false, otherwise zero
    ///        (the contract's `tokens` field).
    function globalDelegationHashes(bytes32 key, uint256 index)
        external
        view
        returns (
            address delegator,
            address delegate,
            uint256 registeredDate,
            uint256 expiryDate,
            bool allTokens,
            uint256 tokenId
        );
}

/// @title ConsolidationAdapter
/// @notice Answers the artist registry's one question from the 6529 delegation contract: is a
///         wallet consolidated with an account's root (use case 999, all collections)?
/// @dev A wallet is consolidated with `root` while each has a live registration of the other
///      (expiry later than now, registered no later than now), for all collections. There is no
///      minimum age. Specific-collection consolidations do not count. At most
///      {MAX_REGISTRATIONS_READ} registrations are read per direction.
///
///      Reads forward all gas (`BoundedCall.tryReadAll`): a shortfall reverts with
///      `BoundedCallShortfall`, which the registry also sees as a shortfall; any other failed
///      read (the end of a registration list, a revert, a malformed answer) counts as "no
///      registration". Replaceable: the network swaps it for a 6529-chain source later.
contract ConsolidationAdapter is IConsolidationSource {
    /// @notice The delegation contract's "all collections" collection address.
    address public constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    /// @notice The delegation contract's consolidation use case.
    uint256 public constant USE_CASE_CONSOLIDATION = 999;
    /// @notice Registrations read per direction of a pair: a safety bound on the work done.
    uint256 public constant MAX_REGISTRATIONS_READ = 4;

    /// @notice The 6529 delegation contract.
    IDelegationManagement public immutable delegation;

    /// @param delegation_ The 6529 delegation contract (`0x2202…f43d` on mainnet).
    constructor(IDelegationManagement delegation_) {
        Dependency.check(address(delegation_));
        delegation = delegation_;
    }

    /// @inheritdoc IConsolidationSource
    function isConsolidated(address root, address wallet) external view returns (bool) {
        return root != wallet && _live(root, wallet) && _live(wallet, root);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IConsolidationSource).interfaceId;
    }

    /// @dev Whether `from` holds a live all-collections consolidation registration of `to`.
    function _live(address from, address to) private view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(from, ALL_COLLECTIONS, to, USE_CASE_CONSOLIDATION));
        for (uint256 i; i < MAX_REGISTRATIONS_READ; ++i) {
            (bool ok, bytes memory data) = BoundedCall.tryReadAll(
                address(delegation),
                abi.encodeCall(IDelegationManagement.globalDelegationHashes, (key, i)),
                192
            );
            if (!ok || data.length != 192) return false;
            (,, uint256 registered, uint256 expiry,,) =
                abi.decode(data, (address, address, uint256, uint256, bool, uint256));
            // Expiry dates are wall-clock bounds; validator drift is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            if (expiry > block.timestamp && registered != 0 && registered <= block.timestamp) {
                return true;
            }
        }
        return false;
    }
}
