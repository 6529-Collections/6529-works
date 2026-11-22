// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { EditionsBase } from "src/core/EditionsBase.sol";
import { Edition, Minter, PendingModule } from "src/interfaces/core/CoreTypes.sol";
import { IEditions } from "src/interfaces/core/IEditions.sol";
import { IModuleSlots, IModules } from "src/interfaces/core/IModules.sol";

/// @notice An indexer for 6529 Stream Editions that knows only the contract's logs (and each
///         block's time, as any indexer does): it rebuilds every edition, every balance, the
///         owner, the contract URI, both waiting-period settings, the module slots, pending
///         modules and the minters.
contract EditionsCoreIndexer {
    address public immutable target;

    mapping(uint256 id => Edition) internal _editions;
    mapping(uint256 id => mapping(address account => uint256)) public balanceOf;
    mapping(bytes32 slot => address) public moduleOf;
    mapping(bytes32 slot => PendingModule) internal _pending;
    mapping(address minter => Minter) internal _minters;
    address public owner;
    string public contractURI;
    uint48 public rebindDelay;
    uint48 public moduleDelay;

    constructor(address target_, uint48 launchRebindDelay, uint48 launchModuleDelay) {
        target = target_;
        // The launch values are the deployment's, read from the deployment record.
        rebindDelay = launchRebindDelay;
        moduleDelay = launchModuleDelay;
    }

    function editionOf(uint256 id) external view returns (Edition memory) {
        return _editions[id];
    }

    function pendingModule(bytes32 slot) external view returns (PendingModule memory) {
        return _pending[slot];
    }

    function minterOf(address minter) external view returns (Minter memory) {
        return _minters[minter];
    }

    /// @dev Applies the logs of one block, emitted at `time`.
    function ingest(Vm.Log[] memory logs, uint256 time) external {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == target) _apply(logs[i], time);
        }
    }

    function _apply(Vm.Log memory l, uint256 time) internal {
        bytes32 t = l.topics[0];
        if (t == IEditions.EditionCreated.selector) {
            (uint40 max, address receiver, uint24 rate) =
                abi.decode(l.data, (uint40, address, uint24));
            Edition storage e = _editions[uint256(l.topics[1])];
            (e.minter, e.maxSupply, e.royaltyReceiver, e.royaltyRate) =
            (_address(l.topics[2]), max, receiver, rate);
        } else if (t == IEditions.EditionMinted.selector) {
            (uint256 amount,) = abi.decode(l.data, (uint256, uint256));
            _editions[uint256(l.topics[1])].minted += uint40(amount);
        } else if (t == IEditions.EditionSupplySealed.selector) {
            Edition storage e = _editions[uint256(l.topics[1])];
            (e.maxSupply, e.supplySealed) = (uint40(abi.decode(l.data, (uint256))), true);
        } else if (t == IEditions.EditionRebound.selector) {
            _editions[uint256(l.topics[1])].minter = _address(l.topics[3]);
        } else if (t == IEditions.RoyaltySet.selector) {
            (address receiver, uint24 rate) = abi.decode(l.data, (address, uint24));
            Edition storage e = _editions[uint256(l.topics[1])];
            (e.royaltyReceiver, e.royaltyRate) = (receiver, rate);
        } else if (t == IERC1155.TransferSingle.selector) {
            (uint256 id, uint256 value) = abi.decode(l.data, (uint256, uint256));
            _move(_address(l.topics[2]), _address(l.topics[3]), id, value);
        } else if (t == IERC1155.TransferBatch.selector) {
            (uint256[] memory ids, uint256[] memory values) =
                abi.decode(l.data, (uint256[], uint256[]));
            for (uint256 j; j < ids.length; ++j) {
                _move(_address(l.topics[2]), _address(l.topics[3]), ids[j], values[j]);
            }
        } else if (t == IEditions.OwnershipTransferred.selector) {
            owner = _address(l.topics[2]);
        } else if (t == IEditions.ContractURISet.selector) {
            contractURI = abi.decode(l.data, (string));
        } else if (t == IEditions.RebindDelaySet.selector) {
            (, rebindDelay) = abi.decode(l.data, (uint48, uint48));
        } else if (t == IModuleSlots.ModuleDelaySet.selector) {
            (, moduleDelay) = abi.decode(l.data, (uint48, uint48));
        } else if (t == IModuleSlots.ModuleProposed.selector) {
            (address module, uint48 readyAt) = abi.decode(l.data, (address, uint48));
            _pending[l.topics[1]] = PendingModule(module, readyAt);
        } else if (t == IModuleSlots.ModuleSet.selector) {
            (, address module) = abi.decode(l.data, (address, address));
            moduleOf[l.topics[1]] = module;
            // An installation or a removal ends any announcement for the slot.
            delete _pending[l.topics[1]];
        } else if (t == IModules.MinterAdded.selector) {
            address m = _address(l.topics[1]);
            uint48 activeFrom = abi.decode(l.data, (uint48));
            uint48 first = _minters[m].firstActiveFrom;
            _minters[m] = Minter(activeFrom, 0, first == 0 ? activeFrom : first);
        } else if (t == IModules.MinterRemoved.selector) {
            // A removal before the first activation is a cancellation: the record goes.
            Minter storage r = _minters[_address(l.topics[1])];
            if (time < r.firstActiveFrom) delete _minters[_address(l.topics[1])];
            else r.removedAt = uint48(time);
        }
    }

    function _move(address from, address to, uint256 id, uint256 value) internal {
        if (from != address(0)) balanceOf[id][from] -= value;
        if (to != address(0)) balanceOf[id][to] += value;
    }

    function _address(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }
}
