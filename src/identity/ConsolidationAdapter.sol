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
    /// @notice Entries of an account's delegate list examined per scan.
    uint256 public constant MAX_DELEGATES_SCANNED = 2 * Limits.MAX_CANCELLERS;
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
        (wallets,) = _scan(account, true);
    }

    /// @inheritdoc IConsolidationSource
    /// @dev Every distinct consolidated wallet among the {MAX_DELEGATES_SCANNED} entries scanned,
    ///      in delegate-list order.
    function consolidations(address account)
        external
        view
        returns (address[] memory wallets, uint64[] memory effective)
    {
        return _scan(account, false);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IConsolidationSource).interfaceId;
    }

    /// @inheritdoc IConsolidationSource
    function isEstablished(address account, address wallet) public view returns (bool) {
        uint64 due = effectiveAt(account, wallet);
        // forge-lint: disable-next-line(block-timestamp)
        return due != 0 && due <= block.timestamp;
    }

    /// @inheritdoc IConsolidationSource
    /// @dev A pair is consolidated while each side holds a live registration of the other; it has
    ///      been continuously since the later side's earliest live registration (a revocation
    ///      deletes every registration of a pair), and is established {MIN_AGE} after that.
    function effectiveAt(address account, address wallet) public view returns (uint64) {
        if (account == wallet) return 0;
        uint256 forward = _liveSince(account, wallet);
        if (forward == 0) return 0;
        uint256 reverse = _liveSince(wallet, account);
        if (reverse == 0) return 0;
        // A registration date is a block timestamp, far below 2**64.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((forward > reverse ? forward : reverse) + MIN_AGE);
    }

    /// @dev Walks `account`'s delegate list for live two-way consolidations (only established
    ///      ones when `establishedOnly`).
    function _scan(address account, bool establishedOnly)
        private
        view
        returns (address[] memory wallets, uint64[] memory effective)
    {
        uint256 limit = establishedOnly ? Limits.MAX_CANCELLERS : MAX_DELEGATES_SCANNED;
        wallets = new address[](limit);
        effective = new uint64[](limit);
        uint256 found;
        bytes32 key = keccak256(abi.encodePacked(account, ALL_COLLECTIONS, USE_CASE_CONSOLIDATION));
        for (uint256 i; i < MAX_DELEGATES_SCANNED && found < limit; ++i) {
            (bool ok, bytes memory data) =
                _read(abi.encodeCall(IDelegationManagement.delegatorHashes, (key, i)), 32);
            if (!ok) break;
            address wallet = abi.decode(data, (address));
            if (_contains(wallets, found, wallet)) continue;
            uint64 due = effectiveAt(account, wallet);
            // forge-lint: disable-next-line(block-timestamp)
            if (due == 0 || (establishedOnly && due > block.timestamp)) continue;
            wallets[found] = wallet;
            effective[found++] = due;
        }
        assembly ("memory-safe") {
            mstore(wallets, found)
            mstore(effective, found)
        }
    }

    /// @dev The registration date of `from`'s earliest live registration of `to`, or zero.
    function _liveSince(address from, address to) private view returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(from, ALL_COLLECTIONS, to, USE_CASE_CONSOLIDATION));
        for (uint256 i; i < MAX_REGISTRATIONS_READ; ++i) {
            (bool ok, bytes memory data) =
                _read(abi.encodeCall(IDelegationManagement.globalDelegationHashes, (key, i)), 192);
            if (!ok) return 0;
            (,, uint256 registered, uint256 expiry,,) =
                abi.decode(data, (address, address, uint256, uint256, bool, uint256));
            // Expiry dates are wall-clock bounds; validator drift is immaterial.
            // forge-lint: disable-next-line(block-timestamp)
            if (expiry > block.timestamp && registered != 0 && registered <= block.timestamp) {
                return registered;
            }
        }
        return 0;
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
