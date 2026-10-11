// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IConsolidationSource } from "../interfaces/IArtistRegistry.sol";
import { Limits } from "../interfaces/types/Limits.sol";
import { BoundedCall } from "../libraries/BoundedCall.sol";

/// @title IDelegationManagement
/// @notice The two public storage getters of the 6529 delegation contract
///         (`0x2202CB9c00487e7e8EF21e6d8E914B32e709f43d`) that the consolidation adapter reads.
/// @dev Both are Solidity-generated getters of `mapping(bytes32 => T[])` and revert when `index` is
///      past the end of the array; the contract exposes no array lengths.
interface IDelegationManagement {
    /// @notice The `index`-th delegate registered under
    ///         `keccak256(abi.encodePacked(delegator, collection, useCase))`.
    function delegatorHashes(bytes32 key, uint256 index) external view returns (address);

    /// @notice The `index`-th registration under
    ///         `keccak256(abi.encodePacked(delegator, collection, delegate, useCase))`.
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
/// @notice Reads 6529 consolidations (use case 999, all collections) for the artist registry
///         (ADR 0001 section 11 "Recovery uses 6529 consolidation").
/// @dev The vendored `checkConsolidationStatus` ignores consolidation age and expiry, so this
///      adapter walks the registrations and their dates directly. `wallet` is established for
///      `account` when both have registered a consolidation of the other for all collections, and
///      in each direction some registration is at least {MIN_AGE} old and not expired
///      (`expiryDate > now`, the delegation contract's own rule). A revocation deletes every
///      registration of the pair, so a registration that is still stored has been live since its
///      registration date. Specific-collection consolidations do not count.
///
///      Every read is a {BoundedCall} that forwards exactly {READ_GAS} and reverts when the caller
///      cannot forward it, so a caller choosing its gas limit cannot truncate a walk. The getters
///      cost at most about 16K gas cold (a `GlobalData` read is seven cold slots); the 50K
///      stipend assumes no repricing triples that. A failed read is therefore the end of the
///      array. Walks are bounded: {MAX_DELEGATES_SCANNED} delegates per account and
///      {MAX_REGISTRATIONS_READ} registrations per direction.
///
///      This is a live view, and the account's keys control it: its own key, and any use-case-998
///      sub-delegate of it (`registerDelegationAddressUsingSubDelegation`), can add, revoke or
///      reorder its delegate list (revocation is swap-and-pop). The registry's sticky standing
///      snapshot, not this list, protects an artist's wallets from a key thief.
contract ConsolidationAdapter is IConsolidationSource {
    /// @notice The delegation contract's "all collections" collection address.
    address public constant ALL_COLLECTIONS = 0x8888888888888888888888888888888888888888;
    /// @notice The delegation contract's consolidation use case.
    uint256 public constant USE_CASE_CONSOLIDATION = 999;
    /// @notice How long a consolidation must have been registered to count.
    uint256 public constant MIN_AGE = 30 days;
    /// @notice Entries of an account's delegate list examined by {establishedWallets}.
    uint256 public constant MAX_DELEGATES_SCANNED = 32;
    /// @notice Registrations read per direction of a pair.
    uint256 public constant MAX_REGISTRATIONS_READ = 4;
    /// @notice Gas forwarded to each getter call.
    uint256 public constant READ_GAS = 50_000;

    /// @notice The 6529 delegation contract.
    IDelegationManagement public immutable delegation;

    /// @notice The delegation address has no code.
    error NoDelegationCode(address delegation);

    /// @param delegation_ The 6529 delegation contract (`0x2202…f43d` on mainnet).
    constructor(IDelegationManagement delegation_) {
        if (address(delegation_).code.length == 0) revert NoDelegationCode(address(delegation_));
        delegation = delegation_;
    }

    /// @inheritdoc IConsolidationSource
    /// @dev At most `Limits.MAX_CANCELLERS` distinct wallets, in delegate-list order.
    function establishedWallets(address account) external view returns (address[] memory wallets) {
        wallets = new address[](Limits.MAX_CANCELLERS);
        uint256 found;
        bytes32 key = keccak256(abi.encodePacked(account, ALL_COLLECTIONS, USE_CASE_CONSOLIDATION));
        for (uint256 i; i < MAX_DELEGATES_SCANNED && found < Limits.MAX_CANCELLERS; ++i) {
            (bool ok, bytes memory data) =
                _read(abi.encodeCall(IDelegationManagement.delegatorHashes, (key, i)), 32);
            if (!ok) break;
            address wallet = abi.decode(data, (address));
            if (!_contains(wallets, found, wallet) && isEstablished(account, wallet)) {
                wallets[found++] = wallet;
            }
        }
        assembly ("memory-safe") {
            mstore(wallets, found)
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IConsolidationSource).interfaceId;
    }

    /// @inheritdoc IConsolidationSource
    function isEstablished(address account, address wallet) public view returns (bool) {
        return account != wallet && _registered(account, wallet) && _registered(wallet, account);
    }

    /// @dev Whether `from` holds a live registration of `to` that is at least {MIN_AGE} old.
    function _registered(address from, address to) private view returns (bool) {
        bytes32 key = keccak256(abi.encodePacked(from, ALL_COLLECTIONS, to, USE_CASE_CONSOLIDATION));
        for (uint256 i; i < MAX_REGISTRATIONS_READ; ++i) {
            (bool ok, bytes memory data) =
                _read(abi.encodeCall(IDelegationManagement.globalDelegationHashes, (key, i)), 192);
            if (!ok) return false;
            (,, uint256 registered, uint256 expiry,,) =
                abi.decode(data, (address, address, uint256, uint256, bool, uint256));
            // Ages of days and expiry dates are wall-clock bounds; validator drift is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            bool aged = registered <= block.timestamp && block.timestamp - registered >= MIN_AGE;
            // forge-lint: disable-next-line(block-timestamp)
            if (aged && expiry > block.timestamp) return true;
        }
        return false;
    }

    function _read(bytes memory input, uint256 maxReturn)
        private
        view
        returns (bool, bytes memory)
    {
        return BoundedCall.tryRead(address(delegation), input, READ_GAS, maxReturn, 0);
    }

    function _contains(address[] memory list, uint256 length, address value)
        private
        pure
        returns (bool)
    {
        for (uint256 i; i < length; ++i) {
            if (list[i] == value) return true;
        }
        return false;
    }
}
