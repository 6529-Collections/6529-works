// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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

/// @dev ERC-165 answers of every shape, for comparison with OpenZeppelin's checker.
contract Erc165Shapes {
    enum Shape {
        COMPLIANT,
        NO_ERC165,
        REVERTS_ON_INVALID,
        TRUE_FOR_ALL,
        SHORT_ANSWER,
        LONG_ANSWER,
        DIRTY_TRUE
    }

    Shape internal immutable shape;
    bytes4 internal immutable declared;

    constructor(Shape shape_, bytes4 declared_) {
        shape = shape_;
        declared = declared_;
    }

    fallback() external {
        bytes4 id = bytes4(msg.data[4:8]);
        bool yes = id == type(IERC165).interfaceId || id == declared;
        Shape s = shape;
        if (s == Shape.NO_ERC165) yes = id == declared;
        if (s == Shape.REVERTS_ON_INVALID && id == 0xffffffff) revert();
        if (s == Shape.TRUE_FOR_ALL) yes = true;
        uint256 word = yes ? 1 : 0;
        if (s == Shape.DIRTY_TRUE && yes) word = 2;
        uint256 size = s == Shape.SHORT_ANSWER ? 31 : s == Shape.LONG_ANSWER ? 64 : 32;
        assembly ("memory-safe") {
            mstore(0, word)
            mstore(32, 0)
            return(0, size)
        }
    }
}
