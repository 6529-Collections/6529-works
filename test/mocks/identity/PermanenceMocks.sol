// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IConsolidationSource } from "src/interfaces/IArtistRegistry.sol";
import { InterfaceStub } from "./IdentityWorksMocks.sol";

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

/// @notice A consolidation source that reports one consolidated wallet with a settable
///         `effectiveAt`, after burning a settable amount of gas on every read (a source whose
///         reads were repriced), or reverting when `dead`.
contract BurningConsolidationSource is InterfaceStub {
    address public wallet;
    uint64 public time;
    uint256 public burn;
    bool public dead;

    constructor(address wallet_, uint64 time_)
        InterfaceStub(type(IConsolidationSource).interfaceId)
    {
        (wallet, time) = (wallet_, time_);
    }

    function set(uint256 burn_, uint64 time_, bool dead_) external {
        (burn, time, dead) = (burn_, time_, dead_);
    }

    function establishedWallets(address) external view returns (address[] memory wallets) {
        _burn();
        wallets = new address[](1);
        wallets[0] = wallet;
    }

    function isEstablished(address, address w) external view returns (bool) {
        _burn();
        return w == wallet && time <= block.timestamp;
    }

    function consolidations(address)
        external
        view
        returns (address[] memory wallets, uint64[] memory times)
    {
        _burn();
        wallets = new address[](1);
        times = new uint64[](1);
        (wallets[0], times[0]) = (wallet, time);
    }

    function effectiveAt(address, address w) external view returns (uint64) {
        _burn();
        return w == wallet ? time : 0;
    }

    function _burn() private view {
        if (dead) revert("dead");
        uint256 start = gasleft();
        while (start - gasleft() < burn) { }
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

/// @notice A replaced consolidation source that names wallets it was never told about: every
///         account other than the one asked about is "established" with it, since the Unix
///         epoch's first second, and its scan reports `named`. Models the worst a governed source
///         swap could install (review C, F2).
contract EveryoneEstablishedSource is InterfaceStub {
    address[] internal named;

    constructor(address[] memory named_) InterfaceStub(type(IConsolidationSource).interfaceId) {
        named = named_;
    }

    function establishedWallets(address account) external view returns (address[] memory) {
        (address[] memory wallets,) = _scan(account);
        return wallets;
    }

    function isEstablished(address account, address wallet) external pure returns (bool) {
        return account != wallet;
    }

    function consolidations(address account)
        external
        view
        returns (address[] memory, uint64[] memory)
    {
        return _scan(account);
    }

    function effectiveAt(address account, address wallet) external pure returns (uint64) {
        return account == wallet ? 0 : 1;
    }

    function _scan(address account)
        private
        view
        returns (address[] memory wallets, uint64[] memory times)
    {
        wallets = new address[](named.length);
        times = new uint64[](named.length);
        uint256 n;
        for (uint256 i; i < named.length; ++i) {
            if (named[i] == account) continue;
            (wallets[n], times[n]) = (named[i], 1);
            ++n;
        }
        assembly ("memory-safe") {
            mstore(wallets, n)
            mstore(times, n)
        }
    }
}

/// @notice A consolidation source whose scan answers bytes that are not a canonical ABI encoding
///         of `(address[], uint64[])` (an offset past the end of the data), and whose direct
///         read answers a `uint64` word with high bits set (review C, F7).
contract MalformedConsolidationSource is InterfaceStub {
    constructor() InterfaceStub(type(IConsolidationSource).interfaceId) { }

    function establishedWallets(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function isEstablished(address, address) external pure returns (bool) {
        return false;
    }

    function consolidations(address) external pure returns (address[] memory, uint64[] memory) {
        assembly {
            mstore(0, 0x1000)
            mstore(0x20, 0x40)
            return(0, 0x40)
        }
    }

    function effectiveAt(address, address) external pure returns (uint64) {
        assembly {
            mstore(0, not(0))
            return(0, 0x20)
        }
    }
}
