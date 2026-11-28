// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice A smart account that approves digests on chain and answers ERC-1271 from storage,
///         whatever signature bytes it is given: the pre-approved-message route, which works for
///         any future signature scheme the account itself verifies. Usable as a deployed wallet
///         (with an owner) or as an EIP-7702 delegate (the delegating account calls itself).
contract PreApprovedWallet {
    address public immutable owner;
    mapping(bytes32 digest => bool) public approved;

    constructor(address owner_) {
        owner = owner_;
    }

    function approve(bytes32 digest) external {
        _onlyOwner();
        approved[digest] = true;
    }

    /// @dev Calls `target` as this account, so it can act as an artist authority.
    function execute(address target, bytes calldata data) external returns (bytes memory) {
        _onlyOwner();
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return approved[digest] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function _onlyOwner() private view {
        // Under EIP-7702 the immutable owner is the delegate's; the account calls itself.
        require(msg.sender == owner || msg.sender == address(this), "not owner");
    }
}

/// @notice 6529 Stream Editions whose `masterOf` burns a settable amount of gas before answering
///         a master on `stream`.
contract BurningEditionsMock {
    address public immutable stream;
    uint256 public burn;

    constructor(address stream_) {
        stream = stream_;
    }

    function setBurn(uint256 burn_) external {
        burn = burn_;
    }

    function masterOf(uint256 id) external view returns (address, uint256, bytes32) {
        uint256 start = gasleft();
        while (start - gasleft() < burn) { }
        return (stream, id, keccak256("content"));
    }
}
