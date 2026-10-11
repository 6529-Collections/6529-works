// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Shared adversarial call targets for v1 tests. Every behaviour is fixed at
///         construction or set before the call, so `staticcall` reaches it unchanged.

/// @dev Answers every call by returning, or reverting with, exactly the configured bytes.
contract ReturnDataMock {
    bytes internal payload;
    bool internal shouldRevert;

    function configure(bytes calldata data, bool revertInstead) external {
        payload = data;
        shouldRevert = revertInstead;
    }

    fallback() external {
        bytes memory data = payload;
        if (shouldRevert) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        assembly ("memory-safe") {
            return(add(data, 0x20), mload(data))
        }
    }
}

/// @dev Burns every unit of gas it receives.
contract GasBurnerMock {
    fallback() external {
        assembly {
            for { } 1 { } { }
        }
    }
}

/// @dev Returns the gas left on entry, measured before anything else runs.
contract GasReporterMock {
    fallback() external {
        assembly {
            mstore(0, gas())
            return(0, 0x20)
        }
    }
}

/// @dev Returns `size` bytes whose first word is `firstWord` (a return-data bomb).
contract ReturnBombMock {
    uint256 internal immutable size;
    bytes32 internal immutable firstWord;

    constructor(uint256 size_, bytes32 firstWord_) {
        size = size_;
        firstWord = firstWord_;
    }

    fallback() external {
        uint256 n = size;
        bytes32 word = firstWord;
        assembly {
            mstore(0, word)
            return(0, n)
        }
    }
}

/// @dev An ERC-1271 wallet owned by one ECDSA key.
contract ERC1271WalletMock {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) return 0x1626ba7e;
        return 0xffffffff;
    }
}

/// @dev An EIP-7702 delegate whose ERC-1271 accepts `abi.encode(digest, "7702")`, a signature
///      that is not ECDSA, so only the delegated ERC-1271 path can accept it.
contract Delegate1271Mock {
    function isValidSignature(bytes32 digest, bytes calldata signature)
        external
        pure
        returns (bytes4)
    {
        if (keccak256(signature) == keccak256(abi.encode(digest, "7702"))) return 0x1626ba7e;
        return 0xffffffff;
    }
}
