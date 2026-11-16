// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IFederatedDeployer } from "../interfaces/IFederatedDeployer.sol";
import { SSTORE2 } from "../libraries/SSTORE2.sol";

/// @title FederatedDeployer
/// @notice Deploys copies of one federated template version and records them (ADR 0008 §1). The
///         federation registry lists a copy only if the version's approved deployer recorded
///         it, so a listed copy's starting storage is its constructor's, whatever any other
///         initcode could write at any address.
/// @dev Ownerless and immutable: no owner, role, fee, upgrade, delegatecall or selfdestruct. The
///      constructor writes the creation code to data contracts it creates itself (`SSTORE2`)
///      and records their keccak256; nothing changes them afterwards. Every value is in
///      storage, written once by the constructor, so every deployer has one runtime code hash
///      (`VerifyV1` checks it against the build). A copy is created with CREATE2, which fails
///      at an occupied address, so the record names only contracts this deployer created.
contract FederatedDeployer is IFederatedDeployer {
    /// @inheritdoc IFederatedDeployer
    bytes32 public creationHash;
    /// @inheritdoc IFederatedDeployer
    mapping(address token => bool) public deployed;
    uint256 private _size;
    address[] private _pointers;

    /// @param creationCode The template version's creation code (constructor arguments
    ///        excluded).
    constructor(bytes memory creationCode) {
        uint256 size = creationCode.length;
        if (size == 0) revert EmptyCreationCode();
        uint256 chunk = SSTORE2.MAX_CHUNK_LENGTH;
        for (uint256 start; start < size; start += chunk) {
            uint256 n = size - start < chunk ? size - start : chunk;
            bytes memory part = new bytes(n);
            assembly ("memory-safe") {
                mcopy(add(part, 0x20), add(add(creationCode, 0x20), start), n)
            }
            _pointers.push(SSTORE2.write(part));
        }
        _size = size;
        creationHash = keccak256(creationCode);
        emit CreationCodeStored(creationHash, _pointers);
    }

    /// @inheritdoc IFederatedDeployer
    function deploy(bytes32 salt, bytes calldata config) external returns (address token) {
        address[] memory pointers = _pointers;
        uint256 size = _size;
        bytes memory init = new bytes(size + config.length);
        uint256 done;
        for (uint256 i; i < pointers.length; ++i) {
            done += SSTORE2.copyInto(pointers[i], init, done);
        }
        bytes32 key = keccak256(abi.encode(msg.sender, salt));
        assembly ("memory-safe") {
            calldatacopy(add(add(init, 0x20), size), config.offset, config.length)
            token := create2(0, add(init, 0x20), mload(init), key)
            if iszero(token) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        deployed[token] = true;
        emit Deployed(token, msg.sender, salt, config);
    }

    /// @inheritdoc IFederatedDeployer
    function codeOf() external view returns (address[] memory) {
        return _pointers;
    }
}
