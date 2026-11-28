// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IArtistRegistry } from "src/interfaces/IArtistRegistry.sol";
import { ArtistIdentity, PendingChange } from "src/interfaces/types/IdentityTypes.sol";

/// @notice Stands where a replaced accounts module stands (`Accounts.previous`) and forwards
///         every read to a real one, until the test makes it misbehave: revert every call,
///         answer nothing, answer with one word too many, claim that an address is a root of
///         an account of the test's choosing, or answer a record or a pending change of the
///         test's choosing for one account.
/// @dev ERC-165 probes are always forwarded, so a module can be deployed against it in any
///      mode. Reads are forwarded with STATICCALL; tests write to the real module directly.
contract PredecessorMock {
    enum Mode {
        HONEST,
        SILENT,
        EMPTY,
        OVERSIZED
    }

    address public immutable inner;
    Mode public mode;
    mapping(address account => uint256) public claimed;
    uint256 internal recordOf;
    ArtistIdentity internal record;
    uint256 internal pendingOf;
    PendingChange internal pending;

    constructor(address inner_) {
        inner = inner_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    /// @dev Makes `artistIdOf(account)` answer `artistId` whatever the real module says.
    function claim(address account, uint256 artistId) external {
        claimed[account] = artistId;
    }

    /// @dev Makes `artist(artistId)`, `authorityOf`, `activeAuthorityOf` and `payoutAddress`
    ///      answer `identity` (never frozen) whatever the real module says.
    function setRecord(uint256 artistId, ArtistIdentity calldata identity) external {
        (recordOf, record) = (artistId, identity);
    }

    /// @dev Makes `pendingChange(artistId)` answer `change` whatever the real module says.
    function setPending(uint256 artistId, PendingChange calldata change) external {
        (pendingOf, pending) = (artistId, change);
    }

    function artist(uint256 artistId) external view returns (ArtistIdentity memory, uint48) {
        if (mode != Mode.HONEST || artistId != recordOf || recordOf == 0) _forward();
        return (record, 0);
    }

    function authorityOf(uint256 artistId) external view returns (address) {
        if (mode != Mode.HONEST || artistId != recordOf || recordOf == 0) _forward();
        return record.root;
    }

    function activeAuthorityOf(uint256 artistId) external view returns (address) {
        if (mode != Mode.HONEST || artistId != recordOf || recordOf == 0) _forward();
        return record.root;
    }

    function payoutAddress(uint256 artistId) external view returns (address) {
        if (mode != Mode.HONEST || artistId != recordOf || recordOf == 0) _forward();
        return record.payout;
    }

    function pendingChange(uint256 artistId) external view returns (PendingChange memory) {
        if (mode != Mode.HONEST || artistId != pendingOf || pendingOf == 0) _forward();
        return pending;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return IArtistRegistry(inner).supportsInterface(interfaceId);
    }

    fallback() external {
        _forward();
    }

    /// @dev Answers the call as the mode says; never returns to its caller.
    function _forward() internal view {
        Mode m = mode;
        if (m == Mode.SILENT) revert("silent");
        if (m == Mode.EMPTY) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (bytes4(msg.data) == IArtistRegistry.artistIdOf.selector) {
            uint256 lie = claimed[abi.decode(msg.data[4:], (address))];
            if (lie != 0) {
                assembly ("memory-safe") {
                    mstore(0, lie)
                    return(0, 0x20)
                }
            }
        }
        (bool ok, bytes memory data) = inner.staticcall(msg.data);
        if (m == Mode.OVERSIZED) data = bytes.concat(data, bytes32(uint256(1)));
        assembly ("memory-safe") {
            if iszero(ok) { revert(add(data, 0x20), mload(data)) }
            return(add(data, 0x20), mload(data))
        }
    }
}
