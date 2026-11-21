// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FederatedEditionAuction } from "src/federated/FederatedEditionAuction.sol";
import { FederatedStream } from "src/federated/FederatedStream.sol";
import { ISaleAdapter } from "src/interfaces/ISaleAdapter.sol";

/// @notice A refund recipient that, when paid, calls `settle` of another sale of the same adapter
///         and keeps what it reverted with.
contract SettleOnRefund {
    FederatedEditionAuction internal immutable _fea;
    uint256 internal immutable _saleId;
    bytes public revertData;

    constructor(FederatedEditionAuction fea_, uint256 saleId_) {
        (_fea, _saleId) = (fea_, saleId_);
    }

    receive() external payable {
        try _fea.settle(_saleId, new uint256[](0)) { }
        catch (bytes memory data) {
            revertData = data;
        }
    }
}

/// @notice Stands in for an editions contract whose `sealSupply` runs out of gas: it answers the
///         reads an abandonment makes and consumes every gas unit it is given on the seal.
contract StarvedSeal {
    address internal immutable _stream;

    constructor(address stream_) {
        _stream = stream_;
    }

    function stream() external view returns (address) {
        return _stream;
    }

    function exists(uint256) external pure returns (bool) {
        return false;
    }

    function sealSupply(uint256, uint256) external pure {
        assembly ("memory-safe") {
            invalid()
        }
    }
}

/// @dev An admitted sale adapter whose `claimDelivery` returns without delivering anything.
contract NonDeliveringAdapter {
    function mint(FederatedStream token, bytes calldata data) external returns (uint256 tokenId) {
        (tokenId,) = token.mint(address(this), 0, 1, data);
    }

    function saleIdOf(address, uint256 tokenId) external pure returns (uint256) {
        return tokenId;
    }

    function claimDelivery(uint256, address) external { }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(ISaleAdapter).interfaceId || id == 0x01ffc9a7;
    }
}
